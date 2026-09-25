#Requires -Version 5.1
<#
.SYNOPSIS
    Windows cleanup with preview, category selection and offline HTML/JSON reports.
.NOTES
    Windows 10/11 or Server 2016+, PowerShell 5.1+. New cache categories are opt-in.
    Recoverable cleanup errors are reported; fatal or report-write failures exit 1.
#>
[CmdletBinding()]
param(
    [switch]$AssumeYes,
    [switch]$Preview,
    [ValidateSet('UserTemp','WindowsTemp','Prefetch','RecentItems','BrowserCache','WindowsErrorReporting','WindowsUpdateDownloadCache','RecycleBin','DiskCleanup','CrashDumps','DirectXShaderCache','OperaGXCache')]
    [string[]]$Categories = @('UserTemp','WindowsTemp','Prefetch','RecentItems','BrowserCache','WindowsErrorReporting','WindowsUpdateDownloadCache','RecycleBin','DiskCleanup'),
    [string]$ReportDirectory,
    [switch]$NoOpenReport,
    [switch]$IncludePrefetch,
    [switch]$SkipBrowserClose,
    [switch]$SkipCleanMgr,
    [switch]$OpenLog,
    [switch]$SkipElevationRequest,
    [switch]$ElevationRelaunched,
    [ValidateRange(0, 10)][int]$DeleteRetryCount = 2,
    [ValidateRange(0, 60000)][int]$DeleteRetryDelayMs = 500,
    [ValidateRange(0, 60000)][int]$BrowserCloseTimeoutMs = 2500
)

function Initialize-CleanupRun {
    $script:StartTime = Get-Date
    $script:RunStatus = 'Completed'
    $script:RunId = '{0}_{1}' -f $script:StartTime.ToString('yyyyMMdd_HHmmss_fff'), [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:LogFile = $null
    $script:ProtectedPaths = @()
    $script:SoftErrors = New-Object 'System.Collections.Generic.List[object]'
    $script:Results = New-Object 'System.Collections.Generic.List[object]'
    $script:SeenTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $script:StoppedServices = @{}
    $script:Stats = [ordered]@{
        EstimatedBytesFreed = [int64]0
        EstimatedCleanableBytes = [int64]0
        EstimatedFilesSeen = [int64]0
        TargetsProcessed = 0
        TargetsSkipped = 0
        DeleteFailures = 0
        StepsCompleted = 0
        StepsFailed = 0
    }
}

function Test-PathWithin {
    param([string]$Path, [string]$Parent)
    $child = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    return $child.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $child.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-NoLinkedAncestor {
    param([string]$LiteralPath)
    $cursor = [IO.Path]::GetFullPath($LiteralPath)
    while ($cursor) {
        # Inspect ancestors even when the final path does not exist yet.
        if (Test-Path -LiteralPath $cursor -ErrorAction Stop) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $true
}

function Test-SafeCleanupPath {
    param([string]$LiteralPath)
    try {
        $full = [IO.Path]::GetFullPath($LiteralPath)
        if ($full.TrimEnd('\', '/') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')) { return $false }
        foreach ($protected in $script:ProtectedPaths) {
            if ((Test-PathWithin $full $protected) -or (Test-PathWithin $protected $full)) { return $false }
        }
        return (Test-NoLinkedAncestor $full)
    }
    catch { return $false }
}

function Initialize-ReportStorage {
    param([string[]]$CleanupPaths)
    $directory = $ReportDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = Join-Path $env:LOCALAPPDATA 'WindowsCleanup\Reports'
    }
    $directory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($directory)
    if (-not (Test-NoLinkedAncestor $directory)) { throw 'Report directory cannot contain a linked ancestor.' }
    foreach ($target in $CleanupPaths) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        if ((Test-PathWithin $directory $target) -or (Test-PathWithin $target $directory)) {
            throw "Report directory overlaps a cleanup target: $target"
        }
    }
    # Never store reports in any user's Recycle Bin, including on another drive.
    if ($directory -match '(^|[\\/])\$Recycle\.Bin([\\/]|$)') { throw 'Reports cannot be stored in the Recycle Bin.' }
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    $script:ProtectedPaths = @($directory)
    $base = Join-Path $directory ('CleanupReport_' + $script:RunId)
    $script:JsonFile = $base + '.json'
    $script:HtmlFile = $base + '.html'
    $script:LogFile = $base + '.log'
    # Fail before any cleanup if the destination is not writable.
    [IO.File]::WriteAllText($script:LogFile, "WindowsCleanup $($script:RunId)`r`n", [Text.UTF8Encoding]::new($false))
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR','STEP','SKIP')][string]$Level = 'INFO')
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value ('[{0:O}] [{1}] {2}' -f (Get-Date), $Level, $Message) -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Warning ('Could not write diagnostic log: ' + $_.Exception.Message) }
    }
    if ($Level -in @('STEP','WARN','ERROR')) {
        $color = if ($Level -eq 'STEP') { 'Cyan' } elseif ($Level -eq 'WARN') { 'Yellow' } else { 'Red' }
        Write-Host ('[{0}] {1}' -f $Level, $Message) -ForegroundColor $color
    }
}

function New-ElevatedInvocationArguments {
    param([string]$ScriptPath, [hashtable]$BoundParameters)
    # -File cannot reliably forward array parameters in Windows PowerShell 5.1.
    # Quote PowerShell literals and encode the command, preserving arrays and false switches.
    $parts = New-Object 'System.Collections.Generic.List[string]'
    [void]$parts.Add("& '" + $ScriptPath.Replace("'", "''") + "'")
    foreach ($key in ($BoundParameters.Keys | Sort-Object)) {
        if ($key -eq 'ElevationRelaunched') { continue }
        $value = $BoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            [void]$parts.Add(('-{0}:${1}' -f $key, ([bool]$value).ToString().ToLowerInvariant()))
        }
        else {
            $values = @($value | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })
            [void]$parts.Add((' -{0} {1}' -f $key, ($values -join ',')))
        }
    }
    [void]$parts.Add('-ElevationRelaunched')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($parts -join ' ')))
    return @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

function Measure-CleanupPath {
    param([string]$LiteralPath)
    $result = [pscustomobject]@{ Exists = $false; Bytes = [int64]0; Files = [int64]0; IsDirectory = $false; Complete = $true }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($LiteralPath)
    while ($pending.Count) {
        $path = $pending.Pop()
        try {
            if (-not (Test-SafeCleanupPath $path)) { throw "Protected, linked or uninspectable path skipped: $path" }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($path -eq $LiteralPath) { $result.Exists = $true; $result.IsDirectory = $item.PSIsContainer }
            if ($item.PSIsContainer) {
                foreach ($child in (Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)) { $pending.Push($child.FullName) }
            }
            else { $result.Bytes += $item.Length; $result.Files++ }
        }
        catch {
            $result.Complete = $false
            Add-SoftError -Context 'Measure' -Message ("Could not fully measure: $path") -Exception $_.Exception
        }
    }
    return $result
}

function Remove-PathWithSelfHeal {
    param([string]$LiteralPath, [string]$Context)
    if ($Preview) { return $false }
    try {
        if (-not (Test-SafeCleanupPath $LiteralPath)) { throw "Protected, linked or uninspectable path skipped: $LiteralPath" }
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $failed = $false
            foreach ($child in (Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction Stop)) {
                if (-not (Remove-PathWithSelfHeal -LiteralPath $child.FullName -Context $Context)) { $failed = $true }
            }
            if ($failed) { return $false }
        }
        for ($attempt = 0; $attempt -le $DeleteRetryCount; $attempt++) {
            try {
                if (-not (Test-SafeCleanupPath $LiteralPath)) { throw 'Path became unsafe during deletion.' }
                $item.Refresh()
                # Never use recursive deletion or recursive attrib: nested links must stay untouched.
                $item.Delete()
                return $true
            }
            catch {
                if ($attempt -eq $DeleteRetryCount) { throw }
                if (-not (Test-SafeCleanupPath $LiteralPath)) { throw 'Path became unsafe during retry.' }
                $item.Attributes = $item.Attributes -band (-bnot ([IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))
                Start-Sleep -Milliseconds $DeleteRetryDelayMs
            }
        }
    }
    catch {
        $script:Stats.DeleteFailures++
        Add-SoftError -Context $Context -Message ("Could not delete: $LiteralPath") -Exception $_.Exception
        return $false
    }
}

function Add-TargetResult {
    param([string]$Category, [string]$Path, [string]$Status, [string]$Reason = '')
    $record = [pscustomobject][ordered]@{
        Category = $Category; Path = $Path; Status = $Status; Reason = $Reason
        BytesBefore = [int64]0; FilesSeen = [int64]0; EstimatedBytesFreed = [int64]0
        EstimatedCleanableBytes = [int64]0; MeasurementComplete = $null; DurationSeconds = 0.0
    }
    [void]$script:Results.Add($record)
    return $record
}

function Clear-CleanupTarget {
    param([AllowEmptyCollection()][string[]]$Paths, [string]$Category, [bool]$RequiresAdministrator = $false)
    if (-not $Paths.Count) {
        $script:Stats.TargetsSkipped++
        Add-TargetResult $Category '' 'Skipped' 'No installed profiles found.' | Out-Null
    }
    foreach ($rawPath in $Paths) {
        $started = Get-Date
        $target = [IO.Path]::GetFullPath($rawPath)
        if ($target -ne [IO.Path]::GetPathRoot($target)) { $target = $target.TrimEnd('\', '/') }
        if (-not $script:SeenTargets.Add($target)) { continue }
        $result = Add-TargetResult $Category $target 'Skipped'
        try {
            if ($RequiresAdministrator -and -not $script:IsAdministrator) { $result.Reason = 'Administrator privileges required.'; continue }
            if (-not (Test-SafeCleanupPath $target)) { $result.Reason = 'Protected, linked or uninspectable path.'; continue }
            if (-not (Test-Path -LiteralPath $target -ErrorAction Stop)) { $result.Reason = 'Path does not exist.'; continue }
            $measure = Measure-CleanupPath $target
            $result.BytesBefore = $measure.Bytes
            $result.FilesSeen = $measure.Files
            $result.MeasurementComplete = $measure.Complete
            $script:Stats.EstimatedFilesSeen += $measure.Files
            if ($Preview) {
                $result.Status = 'Preview'
                $result.EstimatedCleanableBytes = $measure.Bytes
                $script:Stats.EstimatedCleanableBytes += $measure.Bytes
            }
            else {
                $failed = -not $measure.Complete
                if ($measure.IsDirectory) {
                    foreach ($child in (Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop)) {
                        if (-not (Remove-PathWithSelfHeal $child.FullName $Category)) { $failed = $true }
                    }
                }
                elseif (-not (Remove-PathWithSelfHeal $target $Category)) { $failed = $true }
                $freed = $measure.Bytes
                if ($failed) {
                    $remaining = Measure-CleanupPath $target
                    if ($remaining.Complete) { $freed = [Math]::Max([int64]0, $measure.Bytes - $remaining.Bytes) }
                    else { $freed = 0; $result.MeasurementComplete = $false }
                }
                $result.EstimatedBytesFreed = $freed
                $script:Stats.EstimatedBytesFreed += $freed
                $result.Status = if ($failed) { 'Partial' } else { 'Completed' }
                if ($failed) { $result.Reason = 'Some entries could not be measured or removed; see errors.' }
            }
            if (-not $measure.Complete) { $result.Reason = 'Measurement incomplete; totals may be understated.' }
            $script:Stats.TargetsProcessed++
        }
        catch {
            $result.Status = 'Failed'; $result.Reason = $_.Exception.Message
            Add-SoftError -Context $Category -Message ("Target failed: $target") -Exception $_.Exception
        }
        finally {
            if ($result.Status -eq 'Skipped') { $script:Stats.TargetsSkipped++ }
            $result.DurationSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 3)
            Write-Log ("$Category | $($result.Status) | $target | $($result.Reason)")
        }
    }
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Log $Name 'STEP'
    try { & $Action; $script:Stats.StepsCompleted++ }
    catch {
        $script:Stats.StepsFailed++
        Add-SoftError -Context $Name -Message 'Step failed unexpectedly; continuing workflow.' -Exception $_.Exception
        Add-TargetResult $Name '' 'Failed' $_.Exception.Message | Out-Null
    }
}

function Stop-ServicesSafely {
    param([string[]]$Names)
    if ($Preview -or -not $script:IsAdministrator) { return $false }
    $ready = $true
    foreach ($name in $Names) {
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            if ($service.Status -eq 'Running') {
                $script:StoppedServices[$name] = 'Running'
                Stop-Service -Name $name -ErrorAction Stop
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
            }
            $service.Refresh()
            if ($service.Status -ne 'Stopped') { throw "Service $name is not stopped." }
        }
        catch { $ready = $false; Add-SoftError -Context 'ServiceStop' -Message "Could not stop $name; update cache will be skipped." -Exception $_.Exception }
    }
    return $ready
}

function Add-SoftError {
    param(
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Exception = $null
    )

    $record = [pscustomobject]@{
        Time      = Get-Date
        Context   = $Context
        Message   = $Message
        Exception = if ($Exception) { $Exception.ToString() } else { $null }
    }

    [void]$script:SoftErrors.Add($record)
    Write-Log ("Soft error [{0}]: {1}" -f $Context, $Message) 'WARN'
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Add-SoftError -Context 'PrivilegeCheck' -Message 'Could not determine administrator state.' -Exception $_.Exception
        return $false
    }
}

function Request-AdministratorElevation {
    param([Parameter(Mandatory = $true)][hashtable]$BoundParameters)

    if ($script:IsAdministrator) {
        return $false
    }

    if ($Preview -or $SkipElevationRequest) {
        Write-Log 'Administrator elevation request was skipped by parameter.' 'SKIP'
        return $false
    }

    if ($ElevationRelaunched) {
        Add-SoftError -Context 'Elevation' -Message 'The elevated relaunch flag is present, but administrator privileges are still unavailable. Continuing without elevated-only targets.'
        return $false
    }

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        Add-SoftError -Context 'Elevation' -Message 'The script path could not be resolved, so automatic elevation is not possible. Save the script to disk and run it again to enable UAC relaunch.'
        return $false
    }

    if (-not (Read-YesNo -Prompt 'Administrator privileges are recommended for full cleanup. Relaunch elevated now?' -DefaultYes $true)) {
        Write-Log 'Administrator relaunch declined. Protected targets will be skipped, not fatal.' 'WARN'
        return $false
    }

    try {
        $hostProcess = Get-Process -Id $PID -ErrorAction SilentlyContinue
        $hostExecutable = if ($hostProcess -and $hostProcess.Path) { $hostProcess.Path } else { $null }

        if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $hostExecutable = 'pwsh.exe'
            }
            else {
                $hostExecutable = 'powershell.exe'
            }
        }

        $argumentList = New-ElevatedInvocationArguments -ScriptPath $scriptPath -BoundParameters $BoundParameters
        Start-Process -FilePath $hostExecutable -Verb RunAs -ArgumentList $argumentList -ErrorAction Stop | Out-Null
        Write-Host 'Cleanup continues in the elevated window.'
        return $true
    }
    catch {
        Add-SoftError -Context 'Elevation' -Message 'Could not start elevated instance. Continuing without elevated-only targets.' -Exception $_.Exception
        return $false
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $false
    )

    if ($AssumeYes) {
        return $true
    }

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }

    try {
        $answer = Read-Host ("{0} {1}" -f $Prompt, $suffix)
    }
    catch {
        # Non-interactive host (e.g. scheduled task without -AssumeYes): use the default.
        Write-Log ("No interactive input available; using default answer for: {0}" -f $Prompt) 'WARN'
        return $DefaultYes
    }

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    return ($answer -match '^[YyEe]')
}

function Format-FileSize {
    param([Nullable[Int64]]$Size)

    if ($null -eq $Size) { return '0 Bytes' }
    if ($Size -ge 1TB) { return ('{0:N2} TB' -f ($Size / 1TB)) }
    if ($Size -ge 1GB) { return ('{0:N2} GB' -f ($Size / 1GB)) }
    if ($Size -ge 1MB) { return ('{0:N2} MB' -f ($Size / 1MB)) }
    if ($Size -ge 1KB) { return ('{0:N2} KB' -f ($Size / 1KB)) }
    return ('{0:N0} Bytes' -f $Size)
}

function Stop-BrowserProcesses {
    if ($Preview -or $SkipBrowserClose) {
        Write-Log 'Browser close step skipped by parameter.' 'SKIP'
        return
    }

    $browserNames = if ($Categories -contains 'BrowserCache') { @('chrome','firefox','msedge','opera','brave','brave-browser') } else { @('opera') }
    $processes = @(Get-Process -Name $browserNames -ErrorAction SilentlyContinue | Sort-Object Id -Unique)

    if ($processes.Count -eq 0) {
        Write-Log 'No supported browser processes were running.' 'OK'
        return
    }

    Write-Log ("Trying graceful browser close for {0} process(es)." -f $processes.Count) 'INFO'

    foreach ($process in $processes) {
        try {
            if ($process.MainWindowHandle -ne 0) {
                [void]$process.CloseMainWindow()
            }
        }
        catch {
            Add-SoftError -Context 'BrowserClose' -Message ("Graceful close failed for PID {0}." -f $process.Id) -Exception $_.Exception
        }
    }

    Start-Sleep -Milliseconds $BrowserCloseTimeoutMs

    foreach ($process in $processes) {
        try {
            $stillRunning = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            if ($stillRunning) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-Log ("Force-stopped browser process: {0} (PID {1})" -f $process.ProcessName, $process.Id) 'OK'
            }
        }
        catch {
            Add-SoftError -Context 'BrowserClose' -Message ("Could not stop browser PID {0}." -f $process.Id) -Exception $_.Exception
        }
    }
}

function Restore-StoppedServices {
    foreach ($name in @($script:StoppedServices.Keys)) {
        if ($script:StoppedServices[$name] -ne 'Running') {
            continue
        }

        try {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne 'Running') {
                Write-Log ("Restoring service: {0}" -f $name) 'INFO'
                Start-Service -Name $name -ErrorAction Stop
                Write-Log ("Service restored: {0}" -f $name) 'OK'
            }
        }
        catch {
            Add-SoftError -Context 'ServiceRestore' -Message ("Could not restore service: {0}" -f $name) -Exception $_.Exception
        }
    }
}

function Get-ChromiumCachePaths {
    param([Parameter(Mandatory = $true)][string]$UserDataRoot)

    $paths = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-Path -LiteralPath $UserDataRoot) -or -not (Test-NoLinkedAncestor $UserDataRoot)) {
        return @()
    }

    $profileDirs = Get-ChildItem -LiteralPath $UserDataRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'Default' -or
        $_.Name -like 'Profile *' -or
        $_.Name -eq 'Guest Profile'
    }

    foreach ($profileDir in $profileDirs) {
        if ($profileDir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        foreach ($relative in @('Cache','Code Cache','GPUCache','GrShaderCache','ShaderCache','Service Worker\CacheStorage')) {
            [void]$paths.Add((Join-Path $profileDir.FullName $relative))
        }
    }

    return $paths.ToArray()
}

function Get-FirefoxCachePaths {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'),
        (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles')
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root) -or -not (Test-NoLinkedAncestor $root)) {
            continue
        }

        $profileDirs = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
        foreach ($profileDir in $profileDirs) {
        if ($profileDir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            foreach ($relative in @('cache2','startupCache','thumbnails')) {
                [void]$paths.Add((Join-Path $profileDir.FullName $relative))
            }
        }
    }

    return $paths.ToArray()
}

function Get-CleanupGroups {
    $browserPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in @('Google\Chrome\User Data','Microsoft\Edge\User Data','BraveSoftware\Brave-Browser\User Data')) {
        foreach ($path in (Get-ChromiumCachePaths (Join-Path $env:LOCALAPPDATA $root))) { [void]$browserPaths.Add($path) }
    }
    foreach ($path in (Get-FirefoxCachePaths)) { [void]$browserPaths.Add($path) }
    $operaGX = New-Object 'System.Collections.Generic.List[string]'
    foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
        foreach ($edition in @('Opera Stable','Opera GX Stable')) {
            $root = Join-Path $base ('Opera Software\' + $edition)
            if ($edition -eq 'Opera Stable') { $destination = $browserPaths } else { $destination = $operaGX }
            # Opera versions use both the root and Chromium-style profile directories.
            foreach ($relative in @('Cache','Code Cache','GPUCache','ShaderCache','GrShaderCache','Service Worker\CacheStorage')) {
                [void]$destination.Add((Join-Path $root $relative))
            }
            foreach ($path in (Get-ChromiumCachePaths $root)) { [void]$destination.Add($path) }
        }
    }
    @(
        [pscustomobject]@{ Category = 'UserTemp'; Admin = $false; Paths = @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp')) }
        [pscustomobject]@{ Category = 'WindowsTemp'; Admin = $true; Paths = @((Join-Path $env:WINDIR 'Temp')) }
        [pscustomobject]@{ Category = 'Prefetch'; Admin = $true; Paths = @((Join-Path $env:WINDIR 'Prefetch')) }
        [pscustomobject]@{ Category = 'RecentItems'; Admin = $false; Paths = @((Join-Path $env:APPDATA 'Microsoft\Windows\Recent')) }
        [pscustomobject]@{ Category = 'BrowserCache'; Admin = $false; Paths = $browserPaths.ToArray() }
        [pscustomobject]@{ Category = 'WindowsErrorReporting'; Admin = $true; Paths = @('ReportArchive','ReportQueue','Temp' | ForEach-Object { Join-Path $env:ProgramData ('Microsoft\Windows\WER\' + $_) }) }
        [pscustomobject]@{ Category = 'WindowsUpdateDownloadCache'; Admin = $true; Paths = @((Join-Path $env:WINDIR 'SoftwareDistribution\Download')) }
        [pscustomobject]@{ Category = 'CrashDumps'; Admin = $false; Paths = @((Join-Path $env:LOCALAPPDATA 'CrashDumps')) }
        [pscustomobject]@{ Category = 'DirectXShaderCache'; Admin = $false; Paths = @((Join-Path $env:LOCALAPPDATA 'D3DSCache')) }
        [pscustomobject]@{ Category = 'OperaGXCache'; Admin = $false; Paths = $operaGX.ToArray() }
    )
}

function Invoke-CleanupWorkflow {
    param([object[]]$Groups)
    if (-not $Preview -and -not (Read-YesNo 'Continue cleanup?' $false)) { $script:RunStatus = 'Cancelled'; return }
    $cleanPrefetch = [bool]$IncludePrefetch
    if ($Categories -contains 'Prefetch' -and -not $cleanPrefetch -and -not $AssumeYes) {
        $cleanPrefetch = Read-YesNo 'Include Prefetch? Deleting it can slow initial application launches.' $false
    }
    if (-not $Preview -and ($Categories -contains 'BrowserCache' -or $Categories -contains 'OperaGXCache')) {
        Invoke-Step 'Browser process handling' { Stop-BrowserProcesses }
    }
    foreach ($group in $Groups) {
        $reason = ''
        if ($Categories -notcontains $group.Category) { $reason = 'Category not selected.' }
        elseif ($group.Category -eq 'Prefetch' -and -not $cleanPrefetch) { $reason = 'Prefetch was not opted in.' }
        if ($reason) {
            Add-TargetResult $group.Category '' 'Skipped' $reason | Out-Null
            continue
        }
        Invoke-Step $group.Category {
            if ($group.Category -eq 'WindowsUpdateDownloadCache' -and -not $Preview -and $script:IsAdministrator) {
                try {
                    if (Stop-ServicesSafely @('wuauserv','bits')) {
                        Clear-CleanupTarget $group.Paths $group.Category $group.Admin
                    }
                    else {
                        $script:Stats.TargetsSkipped++
                        Add-TargetResult $group.Category $group.Paths[0] 'Skipped' 'Required services could not be stopped.' | Out-Null
                    }
                }
                finally { Restore-StoppedServices }
            }
            else { Clear-CleanupTarget $group.Paths $group.Category $group.Admin }
        }
    }
    foreach ($category in @('RecycleBin','DiskCleanup')) {
        if ($Categories -notcontains $category) { Add-TargetResult $category '' 'Skipped' 'Category not selected.' | Out-Null; continue }
        if ($Preview) {
            Add-TargetResult $category '' 'Preview' 'Not run; size is not measured by this script.' | Out-Null
            continue
        }
        if ($category -eq 'RecycleBin') {
            Invoke-Step $category {
                # Native cmdlet is scoped to the current user; never delete other users' bins.
                Clear-RecycleBin -Force -ErrorAction Stop
                Add-TargetResult $category '' 'Completed' 'Current user Recycle Bin cleared. Freed bytes are not measured.' | Out-Null
            }
        }
        elseif ($SkipCleanMgr -or $AssumeYes) {
            Add-TargetResult $category '' 'Skipped' 'Disk Cleanup wizard disabled or unattended.' | Out-Null
        }
        elseif (Read-YesNo 'Run the Windows Disk Cleanup wizard?' $false) {
            Invoke-Step $category {
                $cleanMgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
                $process = Start-Process -FilePath $cleanMgr -ArgumentList ("/d {0}" -f $env:SystemDrive) -Wait -PassThru -ErrorAction Stop
                if ($process.ExitCode -ne 0) { throw "Disk Cleanup exited with code $($process.ExitCode)." }
                Add-TargetResult $category '' 'Completed' 'Disk Cleanup finished. Freed bytes are not measured.' | Out-Null
            }
        }
        else { Add-TargetResult $category '' 'Skipped' 'Disk Cleanup wizard declined.' | Out-Null }
    }
}

function New-CleanupReport {
    # Include native operations and category skips, not only filesystem targets.
    $script:Stats.TargetsProcessed = @($script:Results | Where-Object { $_.Status -in @('Completed','Partial','Preview') }).Count
    $script:Stats.TargetsSkipped = @($script:Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $endTime = Get-Date
    $status = $script:RunStatus
    if ($status -eq 'Completed') {
        if ($Preview) { $status = 'Preview' }
        elseif ($script:SoftErrors.Count -or @($script:Results | Where-Object { $_.Status -in @('Partial','Failed') }).Count) { $status = 'CompletedWithWarnings' }
    }
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        RunId = $script:RunId
        StartedAt = $script:StartTime.ToString('o')
        FinishedAt = $endTime.ToString('o')
        DurationSeconds = [Math]::Round(($endTime - $script:StartTime).TotalSeconds, 3)
        Mode = if ($Preview) { 'Preview' } else { 'Cleanup' }
        Status = $status
        IsAdministrator = $script:IsAdministrator
        SelectedCategories = @($Categories)
        Stats = [pscustomobject]$script:Stats
        Results = @($script:Results.ToArray())
        Errors = @($script:SoftErrors | ForEach-Object {
            [pscustomobject]@{ Time = $_.Time.ToString('o'); Context = $_.Context; Message = $_.Message; Exception = $_.Exception }
        })
        Reports = [pscustomobject]@{ Html = $script:HtmlFile; Json = $script:JsonFile; Log = $script:LogFile }
    }
}

function ConvertTo-ReportHtml {
    param([object]$Report)
    function Encode([object]$Value) { [Net.WebUtility]::HtmlEncode([string]$Value) }
    $previewMode = $Report.Mode -eq 'Preview'
    $metric = if ($previewMode) { 'Estimated cleanable space' } else { 'Estimated space freed' }
    $bytes = if ($previewMode) { $Report.Stats.EstimatedCleanableBytes } else { $Report.Stats.EstimatedBytesFreed }
    $statusText = switch ($Report.Status) {
        'CompletedWithWarnings' { 'Completed with warnings' }
        'Preview' { 'Preview only' }
        default { $Report.Status }
    }
    $duration = [TimeSpan]::FromSeconds($Report.DurationSeconds)
    $durationText = '{0}m {1}s' -f [Math]::Floor($duration.TotalMinutes), $duration.Seconds
    $warningClass = if ($Report.Errors.Count -or $Report.Status -eq 'Failed') { 'warning' } else { '' }
    $categoryCards = New-Object Text.StringBuilder
    $rows = New-Object Text.StringBuilder
    foreach ($group in ($Report.Results | Group-Object Category)) {
        $groupBytes = [int64]0
        foreach ($item in $group.Group) {
            $groupBytes += $(if ($previewMode) { $item.EstimatedCleanableBytes } else { $item.EstimatedBytesFreed })
        }
        $percent = if ($bytes -gt 0) { [Math]::Round(100 * $groupBytes / $bytes) } else { 0 }
        $label = Encode (($group.Name -creplace '(?<=[a-z])(?=[A-Z])', ' ') -creplace '(?<=[A-Z])(?=[A-Z][a-z])', ' ')
        $active = @($group.Group | Where-Object { $_.Status -ne 'Skipped' }).Count
        [void]$categoryCards.Append(@"
<article class="category"><div class="category-title"><h3>$label</h3><strong>$(Encode (Format-FileSize $groupBytes))</strong></div><progress value="$percent" max="100" aria-label="$label share of estimated space">$percent%</progress><p>$active active · $($group.Count - $active) skipped</p></article>
"@)
        foreach ($item in $group.Group) {
            $measurement = if ($null -eq $item.MeasurementComplete) { 'Not measured' } elseif ($item.MeasurementComplete) { 'Measured' } else { 'Incomplete measurement' }
            $size = if ($previewMode) { $item.EstimatedCleanableBytes } else { $item.EstimatedBytesFreed }
            [void]$rows.Append(@"
<tr><th scope="row">$label<span class="path">$(Encode $item.Path)</span></th><td><span class="chip">$(Encode $item.Status)</span></td><td class="number">$(Encode (Format-FileSize $size))<span class="muted">$(Encode $measurement)</span></td><td>$(Encode $item.Reason)</td></tr>
"@)
        }
    }
    $errorsHtml = New-Object Text.StringBuilder
    foreach ($errorRecord in $Report.Errors) {
        [void]$errorsHtml.Append(@"
<details class="error"><summary>$(Encode $errorRecord.Context)<span>$(Encode $errorRecord.Message)</span></summary><p>$(Encode $errorRecord.Time)</p><pre>$(Encode $errorRecord.Exception)</pre></details>
"@)
    }
    if (-not $Report.Errors.Count) { [void]$errorsHtml.Append('<p class="empty">No errors</p>') }
    $jsonName = Encode ([Uri]::EscapeDataString([IO.Path]::GetFileName($Report.Reports.Json)))
    $logName = Encode ([Uri]::EscapeDataString([IO.Path]::GetFileName($Report.Reports.Log)))
    $date = Encode ([DateTimeOffset]::Parse($Report.FinishedAt).ToString('dd MMM yyyy · HH:mm zzz'))
    $privilege = if ($Report.IsAdministrator) { 'Administrator' } else { 'Standard user' }
    return @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>WindowsCleanup · $(Encode $statusText)</title>
<style>
/* Material 3 baseline color roles and type scale. Local-only, no font or CDN requests. */
:root{color-scheme:light dark;--primary:#6750a4;--on-primary:#fff;--primary-container:#eaddff;--on-primary-container:#21005d;--surface:#fef7ff;--surface-container:#f3edf7;--surface-high:#ece6f0;--on-surface:#1d1b20;--on-variant:#49454f;--outline:#79747e;--outline-variant:#cac4d0;--error-container:#f9dedc;--on-error-container:#410e0b;--radius:28px}
@media(prefers-color-scheme:dark){:root{--primary:#d0bcff;--on-primary:#381e72;--primary-container:#4f378b;--on-primary-container:#eaddff;--surface:#141218;--surface-container:#211f26;--surface-high:#2b2930;--on-surface:#e6e0e9;--on-variant:#cac4d0;--outline:#938f99;--outline-variant:#49454f;--error-container:#8c1d18;--on-error-container:#f9dedc}}
*{box-sizing:border-box}body{margin:0;background:var(--surface);color:var(--on-surface);font:400 16px/1.5 'Segoe UI',Roboto,Arial,sans-serif}main,header,footer{width:min(1160px,calc(100% - 48px));margin:auto}header{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:32px 0}a{color:var(--primary)}a:focus-visible,summary:focus-visible{outline:3px solid var(--primary);outline-offset:5px}.brand{font-size:20px;font-weight:650;display:flex;align-items:center;gap:12px}.brand-icon{width:40px;height:40px;border-radius:14px;background:var(--primary);color:var(--on-primary);display:grid;place-items:center;font-size:24px}.hero{background:var(--primary-container);color:var(--on-primary-container);border-radius:36px;padding:40px;display:grid;grid-template-columns:1.5fr 1fr;gap:32px;align-items:center}.eyebrow{font-size:12px;letter-spacing:.12em;text-transform:uppercase;font-weight:700}h1{font-weight:450;font-size:clamp(32px,4vw,48px);line-height:1.15;letter-spacing:-1.5px;margin:20px 0 16px;max-width:620px}.hero-metric{border-left:1px solid currentColor;padding-left:32px}.hero-metric strong{display:block;font-size:clamp(36px,4.8vw,64px);font-weight:500;line-height:1.2;letter-spacing:-2px}.hero-metric span{font-size:14px}.chip{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--outline-variant);border-radius:8px;padding:4px 10px;font-size:12px;font-weight:600;background:var(--surface-container);color:var(--on-surface);white-space:nowrap}.hero .chip{border:0;padding:7px 12px}.chip.warning{background:var(--error-container);color:var(--on-error-container)}.toolbar{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:16px;margin:24px 0 32px}.meta{font-size:14px;color:var(--on-variant)}.actions{display:flex;gap:12px;align-items:center}.button{display:inline-block;padding:10px 24px;border-radius:999px;text-decoration:none;font-size:14px;font-weight:600;background:var(--primary);color:var(--on-primary);min-height:44px}.button.secondary{background:var(--surface-high);color:var(--primary)}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}.stat{padding:24px;background:var(--surface-container);border-radius:var(--radius)}.stat span{display:block;font-size:14px;color:var(--on-variant)}.stat strong{display:block;font-weight:500;font-size:32px;margin-top:8px;letter-spacing:-.8px}section{margin-top:40px}h2{font-size:24px;line-height:32px;font-weight:500;margin:0}h3{font-size:14px;font-weight:600;margin:0}.section-heading{display:flex;align-items:baseline;justify-content:space-between;gap:16px;margin-bottom:20px}.categories{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}.category{padding:20px;border:1px solid var(--outline-variant);border-radius:20px}.category-title{display:flex;align-items:baseline;justify-content:space-between;gap:12px}.category-title strong{font-size:14px;white-space:nowrap}.category p{font-size:12px;margin:8px 0 0;color:var(--on-variant)}progress{display:block;width:100%;height:8px;margin-top:16px;border:0;border-radius:8px;background:var(--surface-high);color:var(--primary);accent-color:var(--primary);overflow:hidden}progress::-webkit-progress-bar{background:var(--surface-high)}progress::-webkit-progress-value{background:var(--primary);border-radius:8px}progress::-moz-progress-bar{background:var(--primary)}.table-wrap{overflow-x:auto;border:1px solid var(--outline-variant);border-radius:20px}table{border-collapse:collapse;width:100%;text-align:left;font-size:14px}thead{background:var(--surface-container)}th,td{padding:16px 20px;border-bottom:1px solid var(--outline-variant);vertical-align:top}thead th{font-size:12px;color:var(--on-variant);font-weight:600}tbody th{font-weight:500;min-width:220px}tbody tr:last-child>*{border-bottom:0}.path,.muted{display:block;font-size:12px;font-weight:400;color:var(--on-variant);margin-top:6px;overflow-wrap:anywhere}.path{max-width:380px}.number{white-space:nowrap}td:last-child{min-width:180px;color:var(--on-variant)}.error{background:var(--surface-container);border-radius:16px;padding:16px 20px;margin-top:12px}.error summary{cursor:pointer;font-weight:600;min-height:32px}.error summary span{font-weight:400;display:block;color:var(--on-variant);margin:6px 0 0 18px;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}.error p{font-size:12px;color:var(--on-variant)}.empty{padding:24px;border:1px solid var(--outline-variant);border-radius:20px;color:var(--on-variant)}footer{border-top:1px solid var(--outline-variant);padding:24px 0 40px;margin-top:40px;color:var(--on-variant);font-size:12px;overflow-wrap:anywhere}footer p{margin:4px 0}.skip-link{position:absolute;top:-80px;left:24px;z-index:2}.skip-link:focus{top:12px}.target-disclosure>summary{cursor:pointer;font-size:24px;line-height:32px;font-weight:500;min-height:44px;margin-bottom:12px}
@media(max-width:800px){.hero{grid-template-columns:1fr;padding:28px;gap:24px}.hero-metric{border-left:0;border-top:1px solid currentColor;padding:24px 0 0}.categories{grid-template-columns:repeat(2,minmax(0,1fr))}.stats{grid-template-columns:repeat(2,1fr)}.section-heading{display:block}}
@media(max-width:480px){main,header,footer{width:calc(100% - 32px)}header{padding:24px 0}.hero{border-radius:28px;padding:24px}.categories{grid-template-columns:1fr}.stat{padding:20px}.actions{width:100%;flex-wrap:wrap}.section-heading{gap:8px}h1{letter-spacing:-1px}}
@media print{.actions,.skip-link{display:none}body{background:#fff;color:#000}.hero,.stat,.category{break-inside:avoid}.table-wrap{overflow:visible}footer{margin-top:24px}}
</style></head><body>
<a class="skip-link button" href="#overview">Skip to report</a>
<header><div class="brand"><span class="brand-icon" aria-hidden="true">✦</span>WindowsCleanup</div></header>
<main id="overview">
<div class="hero"><div><span class="chip $warningClass">$(Encode $statusText)</span><h1>Cleanup report</h1></div><div class="hero-metric"><span class="eyebrow">$(Encode $metric)</span><strong>$(Encode (Format-FileSize $bytes))</strong></div></div>
<div class="toolbar"><div class="meta">$date · $privilege</div><div class="actions"><a class="button" href="$jsonName">Open JSON</a><a class="button secondary" href="$logName">View log</a></div></div>
<div class="stats"><div class="stat"><span>Files discovered</span><strong>$(Encode ('{0:N0}' -f $Report.Stats.EstimatedFilesSeen))</strong></div><div class="stat"><span>Targets processed</span><strong>$($Report.Stats.TargetsProcessed)</strong></div><div class="stat"><span>Issues recorded</span><strong>$($Report.Errors.Count)</strong></div><div class="stat"><span>Time elapsed</span><strong>$(Encode $durationText)</strong></div></div>
<section aria-labelledby="breakdown"><div class="section-heading"><h2 id="breakdown">Categories</h2></div><div class="categories">$categoryCards</div></section>
<section><details class="target-disclosure"><summary>Target details · $($Report.Results.Count) results</summary><div class="table-wrap" tabindex="0" role="region" aria-label="Cleanup target results"><table><thead><tr><th scope="col">Category / location</th><th scope="col">Outcome</th><th scope="col">Estimated space</th><th scope="col">Notes</th></tr></thead><tbody>$rows</tbody></table></div></details></section>
<section aria-labelledby="issues"><div class="section-heading"><h2 id="issues">Errors · $($Report.Errors.Count)</h2></div>$errorsHtml</section>
</main><footer><p>HTML: $(Encode $Report.Reports.Html)</p><p>JSON: $(Encode $Report.Reports.Json)</p></footer>
</body></html>
"@
}

function Export-CleanupReports {
    param([object]$Report)
    $json = ConvertTo-Json -InputObject $Report -Depth 8
    $html = ConvertTo-ReportHtml $Report
    $encoding = [Text.UTF8Encoding]::new($false)
    try {
        [IO.File]::WriteAllText(($script:JsonFile + '.tmp'), $json, $encoding)
        [IO.File]::WriteAllText(($script:HtmlFile + '.tmp'), $html, $encoding)
        Move-Item -LiteralPath ($script:JsonFile + '.tmp') -Destination $script:JsonFile -ErrorAction Stop
        Move-Item -LiteralPath ($script:HtmlFile + '.tmp') -Destination $script:HtmlFile -ErrorAction Stop
    }
    finally {
        foreach ($temporary in @(($script:JsonFile + '.tmp'), ($script:HtmlFile + '.tmp'))) {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Complete-CleanupRun {
    $report = New-CleanupReport
    try { Export-CleanupReports $report }
    catch {
        Write-Host ('Could not save both reports: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ("Report destination: {0}" -f (Split-Path -Parent $script:HtmlFile))
        return 1
    }
    if (-not $AssumeYes -and -not $NoOpenReport) {
        try { Start-Process -FilePath $script:HtmlFile -ErrorAction Stop | Out-Null }
        catch { Write-Warning ('Could not open HTML automatically: ' + $_.Exception.Message) }
    }
    if ($OpenLog) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:LogFile) -ErrorAction Stop | Out-Null }
        catch { Write-Warning ('Could not open the log: ' + $_.Exception.Message) }
    }
    Write-Host ("{0}. Reports saved:`nHTML: {1}`nJSON: {2}" -f $report.Status, $script:HtmlFile, $script:JsonFile) -ForegroundColor Cyan
    if ($report.Status -eq 'Failed') { return 1 }
    return 0
}

# Main workflow. Keep side effects here so regression checks can load functions safely.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Initialize-CleanupRun
try {
    if ($env:OS -ne 'Windows_NT') { throw 'WindowsCleanup requires Windows. No cleanup was performed.' }
    $script:IsAdministrator = Test-IsAdministrator
    # Resolve relative output paths before a UAC relaunch changes the working directory.
    if ($ReportDirectory) {
        $ReportDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportDirectory)
        $PSBoundParameters['ReportDirectory'] = $ReportDirectory
    }
    if (-not $Preview -and -not $script:IsAdministrator -and (Request-AdministratorElevation $PSBoundParameters)) { exit 0 }
    $groups = @(Get-CleanupGroups)
    Initialize-ReportStorage -CleanupPaths @($groups | ForEach-Object { $_.Paths })
}
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
Write-Host $(if ($Preview) { 'WindowsCleanup | Preview: no cleanup actions will run.' } else { 'WindowsCleanup | Temporary files, selected caches and system leftovers.' }) -ForegroundColor Cyan
try { Invoke-CleanupWorkflow $groups }
catch {
    $script:RunStatus = 'Failed'
    Add-SoftError -Context 'Workflow' -Message 'Cleanup stopped unexpectedly.' -Exception $_.Exception
}
finally { Restore-StoppedServices }
exit (Complete-CleanupRun)
