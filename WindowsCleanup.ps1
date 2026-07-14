#Requires -Version 5.1
<#
.SYNOPSIS
    Windows cleanup script with soft-error handling and self-heal retries.

.DESCRIPTION
    Runs the cleanup workflow without hard exits and with centralized error handling.
    The script continues on non-critical failures, logs soft errors, retries failed deletions,
    clears restrictive file attributes, tries a quarantine/rename delete fallback, and restores
    services that it stopped.

.NOTES
    PowerShell: 5.1+
    Recommended: Run as Administrator for full cleanup coverage.
    If not elevated, the script can relaunch itself with a UAC prompt while preserving soft-error behavior.
    Console output uses Nerd Font glyphs; install a Nerd Font for best results (plain text otherwise).
#>

[CmdletBinding()]
param(
    [switch]$AssumeYes,
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

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
    # Some hosts do not allow changing the output encoding. Ignore.
}

$script:InitialBoundParameters = @{}
foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $script:InitialBoundParameters[$entry.Key] = $entry.Value
}

$script:StartTime = Get-Date

# Keep logs outside every cleanup target so the script never deletes its own log.
$script:LogDirectory = Join-Path $env:LOCALAPPDATA 'WindowsCleanup'
try {
    if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
        New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop | Out-Null
    }
}
catch {
    $script:LogDirectory = $env:TEMP
}
$script:LogFile = Join-Path $script:LogDirectory ("CleanupLog_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$script:SoftErrors = New-Object 'System.Collections.Generic.List[object]'
$script:StoppedServices = @{}
$script:Stats = [ordered]@{
    EstimatedBytesFreed = [int64]0
    EstimatedFilesSeen  = [int64]0
    TargetsProcessed    = 0
    TargetsSkipped      = 0
    DeleteFailures      = 0
    StepsCompleted      = 0
    StepsFailed         = 0
}

$script:Colors = @{
    OK    = 'Green'
    WARN  = 'Yellow'
    ERROR = 'Red'
    INFO  = 'Cyan'
    STEP  = 'Magenta'
    SKIP  = 'DarkYellow'
}

# Nerd Font glyphs (rendered correctly with any Nerd Font patched terminal font).
$script:Icons = @{
    OK    = [char]0xF00C   # nf-fa-check
    WARN  = [char]0xF071   # nf-fa-warning
    ERROR = [char]0xF057   # nf-fa-times_circle
    INFO  = [char]0xF05A   # nf-fa-info_circle
    STEP  = [char]0xF0A9   # nf-fa-arrow_circle_right
    SKIP  = [char]0xF051   # nf-fa-step_forward
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','STEP','SKIP')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning ("Could not write to log file: {0}" -f $_.Exception.Message)
    }

    $color = if ($script:Colors.ContainsKey($Level)) { $script:Colors[$Level] } else { 'White' }
    $icon = if ($script:Icons.ContainsKey($Level)) { $script:Icons[$Level] } else { ' ' }
    Write-Host (' {0}  {1}' -f $icon, $Message) -ForegroundColor $color
}

function Write-Banner {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Color = 'Cyan'
    )

    $width = 78
    $inner = $Text
    if ($inner.Length -gt ($width - 4)) {
        $inner = $inner.Substring(0, $width - 4)
    }
    # Count display characters, not UTF-16 code units, so surrogate-pair glyphs align.
    $innerLength = ([System.Globalization.StringInfo]::new($inner)).LengthInTextElements
    $padTotal = $width - 2 - $innerLength
    $padLeft = [int][Math]::Floor($padTotal / 2)
    $padRight = $padTotal - $padLeft

    Write-Host ''
    Write-Host ('╭' + ('─' * ($width - 2)) + '╮') -ForegroundColor $Color
    Write-Host ('│' + (' ' * $padLeft) + $inner + (' ' * $padRight) + '│') -ForegroundColor $Color
    Write-Host ('╰' + ('─' * ($width - 2)) + '╯') -ForegroundColor $Color
    Write-Host ''
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

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][object]$Value)

    $text = [string]$Value
    if ($text -notmatch '[\s`"'']') {
        return $text
    }

    return '"{0}"' -f ($text -replace '"', '\"')
}

function New-ElevatedInvocationArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][hashtable]$BoundParameters
    )

    $argumentItems = New-Object 'System.Collections.Generic.List[string]'
    [void]$argumentItems.Add('-NoProfile')
    [void]$argumentItems.Add('-ExecutionPolicy')
    [void]$argumentItems.Add('Bypass')
    [void]$argumentItems.Add('-File')
    [void]$argumentItems.Add((ConvertTo-ProcessArgument -Value $ScriptPath))

    foreach ($key in ($BoundParameters.Keys | Sort-Object)) {
        if ($key -eq 'ElevationRelaunched') {
            continue
        }

        $value = $BoundParameters[$key]

        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                [void]$argumentItems.Add("-$key")
            }
            continue
        }

        if ($value -is [bool]) {
            if ($value) {
                [void]$argumentItems.Add("-$key")
            }
            continue
        }

        if ($null -ne $value) {
            [void]$argumentItems.Add("-$key")
            [void]$argumentItems.Add((ConvertTo-ProcessArgument -Value $value))
        }
    }

    [void]$argumentItems.Add('-ElevationRelaunched')
    return $argumentItems.ToArray()
}

function Request-AdministratorElevation {
    param([Parameter(Mandatory = $true)][hashtable]$BoundParameters)

    if ($script:IsAdministrator) {
        return $false
    }

    if ($SkipElevationRequest) {
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
        Write-Log 'Elevated instance was requested through UAC. The current non-elevated instance will stop without a hard exit.' 'OK'
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

function Resolve-CleanupPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = New-Object 'System.Collections.Generic.List[string]'

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return @()
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($Path)

        if ($expanded -match '[\*\?]') {
            $items = Resolve-Path -Path $expanded -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                if ($item.ProviderPath) {
                    [void]$resolved.Add($item.ProviderPath)
                }
            }
        }
        elseif (Test-Path -LiteralPath $expanded) {
            [void]$resolved.Add((Get-Item -LiteralPath $expanded -Force -ErrorAction Stop).FullName)
        }
    }
    catch {
        Add-SoftError -Context 'PathResolve' -Message ("Could not resolve path: {0}" -f $Path) -Exception $_.Exception
    }

    return $resolved.ToArray()
}

function Measure-CleanupPath {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $result = [ordered]@{
        Exists = $false
        Bytes  = [int64]0
        Files  = [int64]0
        IsDirectory = $false
    }

    try {
        if (-not (Test-Path -LiteralPath $LiteralPath)) {
            return [pscustomobject]$result
        }

        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        $result.Exists = $true
        $result.IsDirectory = [bool]$item.PSIsContainer

        if (-not $item.PSIsContainer) {
            $result.Bytes = [int64]$item.Length
            $result.Files = 1
            return [pscustomobject]$result
        }

        $measured = Get-ChildItem -LiteralPath $LiteralPath -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum

        if ($measured) {
            $result.Files = [int64]$measured.Count
            if ($null -ne $measured.Sum) {
                $result.Bytes = [int64]$measured.Sum
            }
        }
    }
    catch {
        Add-SoftError -Context 'Measure' -Message ("Could not fully measure: {0}" -f $LiteralPath) -Exception $_.Exception
    }

    return [pscustomobject]$result
}

function Reset-RestrictiveAttributes {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    try {
        if (-not (Test-Path -LiteralPath $LiteralPath)) {
            return
        }

        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            & attrib.exe -R -S -H $LiteralPath /D 2>$null | Out-Null
            & attrib.exe -R -S -H (Join-Path $LiteralPath '*') /S /D 2>$null | Out-Null
        }
        else {
            $item.Attributes = [System.IO.FileAttributes]::Normal
        }
    }
    catch {
        Add-SoftError -Context 'SelfHealAttributes' -Message ("Could not reset attributes: {0}" -f $LiteralPath) -Exception $_.Exception
    }
}

function Remove-PathWithSelfHeal {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return $true
    }

    # Junctions and symlinks must be unlinked, never recursed into: Remove-Item -Recurse
    # on PowerShell 5.1 can follow a reparse point and delete the *target's* contents.
    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            try {
                $item.Delete()
                return $true
            }
            catch {
                $script:Stats.DeleteFailures++
                Add-SoftError -Context $Context -Message ("Could not remove reparse point (link left untouched): {0}" -f $LiteralPath) -Exception $_.Exception
                return $false
            }
        }
    }
    catch {
        # Could not inspect attributes; continue with the normal delete path.
    }

    for ($attempt = 0; $attempt -le $DeleteRetryCount; $attempt++) {
        try {
            Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
            return $true
        }
        catch {
            $lastError = $_.Exception

            if ($attempt -lt $DeleteRetryCount) {
                Reset-RestrictiveAttributes -LiteralPath $LiteralPath
                [GC]::Collect()
                Start-Sleep -Milliseconds $DeleteRetryDelayMs
                continue
            }

            $quarantinePath = $null
            try {
                if (Test-Path -LiteralPath $LiteralPath) {
                    $parent = [System.IO.Path]::GetDirectoryName($LiteralPath)
                    $leaf = [System.IO.Path]::GetFileName($LiteralPath)
                    $quarantineName = '.cleanup_pending_{0}_{1}' -f ([guid]::NewGuid().ToString('N')), $leaf
                    $quarantinePath = Join-Path $parent $quarantineName

                    Rename-Item -LiteralPath $LiteralPath -NewName $quarantineName -Force -ErrorAction Stop
                    Remove-Item -LiteralPath $quarantinePath -Recurse -Force -ErrorAction Stop
                    Write-Log ("Recovered by quarantine delete: {0}" -f $LiteralPath) 'OK'
                    return $true
                }
            }
            catch {
                $lastError = $_.Exception

                # Undo a half-finished quarantine so no ".cleanup_pending_*" litter remains.
                if ($quarantinePath -and (Test-Path -LiteralPath $quarantinePath)) {
                    try {
                        Rename-Item -LiteralPath $quarantinePath -NewName ([System.IO.Path]::GetFileName($LiteralPath)) -Force -ErrorAction Stop
                    }
                    catch {
                        Add-SoftError -Context $Context -Message ("Quarantined item could not be renamed back: {0}" -f $quarantinePath) -Exception $_.Exception
                    }
                }
            }

            $script:Stats.DeleteFailures++
            Add-SoftError -Context $Context -Message ("Could not delete after retries: {0}" -f $LiteralPath) -Exception $lastError
            return $false
        }
    }

    return $false
}

function Clear-CleanupTarget {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$Category,
        [bool]$RequiresAdministrator = $false
    )

    if ($RequiresAdministrator -and -not $script:IsAdministrator) {
        $script:Stats.TargetsSkipped += $Paths.Count
        Add-SoftError -Context $Category -Message 'Administrator privileges are required. This target group was skipped.'
        return
    }

    $seenTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($rawPath in $Paths) {
        $targets = @(Resolve-CleanupPath -Path $rawPath)

        if ($targets.Count -eq 0) {
            $script:Stats.TargetsSkipped++
            Write-Log ("Skipped missing path: {0}" -f $rawPath) 'SKIP'
            continue
        }

        foreach ($target in $targets) {
            $normalized = $target.TrimEnd('\')
            if (-not $seenTargets.Add($normalized)) {
                Write-Log ("Skipped duplicate target: {0}" -f $target) 'SKIP'
                continue
            }

            try {
                $measure = Measure-CleanupPath -LiteralPath $target
                if (-not $measure.Exists) {
                    $script:Stats.TargetsSkipped++
                    Write-Log ("Skipped missing path: {0}" -f $target) 'SKIP'
                    continue
                }

                Write-Log ("Cleaning [{0}]: {1} ({2}, {3} files)" -f $Category, $target, (Format-FileSize $measure.Bytes), $measure.Files) 'INFO'

                $failedChildren = 0

                if ($measure.IsDirectory) {
                    Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($_.FullName -eq $script:LogFile) {
                            return
                        }
                        if (-not (Remove-PathWithSelfHeal -LiteralPath $_.FullName -Context $Category)) {
                            $failedChildren++
                        }
                    }
                }
                else {
                    if (-not (Remove-PathWithSelfHeal -LiteralPath $target -Context $Category)) {
                        $failedChildren++
                    }
                }

                # Re-measure only when something failed, so the freed-space figure stays honest.
                $freedBytes = [int64]$measure.Bytes
                if ($failedChildren -gt 0) {
                    $remaining = Measure-CleanupPath -LiteralPath $target
                    $freedBytes = [Math]::Max([int64]0, [int64]($measure.Bytes - $remaining.Bytes))
                }

                $script:Stats.TargetsProcessed++
                $script:Stats.EstimatedBytesFreed += $freedBytes
                $script:Stats.EstimatedFilesSeen += [int64]$measure.Files

                if ($failedChildren -eq 0) {
                    Write-Log ("Completed [{0}]: {1}" -f $Category, $target) 'OK'
                }
                else {
                    Add-SoftError -Context $Category -Message ("Completed with {0} failed child item(s): {1}" -f $failedChildren, $target)
                }
            }
            catch {
                $script:Stats.TargetsSkipped++
                Add-SoftError -Context $Category -Message ("Target failed but workflow will continue: {0}" -f $target) -Exception $_.Exception
            }
        }
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Color = 'Cyan'
    )

    Write-Banner ('{0}  {1}' -f $script:Icons.STEP, $Name) $Color

    try {
        & $Action
        $script:Stats.StepsCompleted++
        return $true
    }
    catch {
        $script:Stats.StepsFailed++
        Add-SoftError -Context $Name -Message 'Step failed unexpectedly; continuing workflow.' -Exception $_.Exception
        return $false
    }
}

function Stop-BrowserProcesses {
    if ($SkipBrowserClose) {
        Write-Log 'Browser close step skipped by parameter.' 'SKIP'
        return
    }

    $browserNames = @('chrome','firefox','msedge','opera','brave','brave-browser','iexplore')
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

function Stop-ServicesSafely {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        try {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $service) {
                Add-SoftError -Context 'ServiceStop' -Message ("Service not found: {0}" -f $name)
                continue
            }

            $script:StoppedServices[$name] = $service.Status.ToString()

            if ($service.Status -ne 'Running') {
                Write-Log ("Service already not running: {0} ({1})" -f $name, $service.Status) 'SKIP'
                continue
            }

            Write-Log ("Stopping service: {0}" -f $name) 'INFO'
            Stop-Service -Name $name -Force -ErrorAction Stop
            $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(10))
            Write-Log ("Service stopped: {0}" -f $name) 'OK'
        }
        catch {
            Add-SoftError -Context 'ServiceStop' -Message ("Normal stop failed for service {0}; trying sc.exe fallback." -f $name) -Exception $_.Exception
            try {
                & sc.exe stop $name 2>$null | Out-Null
                Start-Sleep -Seconds 2
            }
            catch {
                Add-SoftError -Context 'ServiceStopFallback' -Message ("sc.exe fallback failed for service {0}." -f $name) -Exception $_.Exception
            }
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

    if (-not (Test-Path -LiteralPath $UserDataRoot)) {
        return @()
    }

    $profileDirs = Get-ChildItem -LiteralPath $UserDataRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'Default' -or
        $_.Name -like 'Profile *' -or
        $_.Name -eq 'Guest Profile'
    }

    foreach ($profileDir in $profileDirs) {
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
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $profileDirs = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue
        foreach ($profileDir in $profileDirs) {
            foreach ($relative in @('cache2','startupCache','thumbnails')) {
                [void]$paths.Add((Join-Path $profileDir.FullName $relative))
            }
        }
    }

    return $paths.ToArray()
}

function Clear-RecycleBinSafely {
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Log 'Recycle Bin cleared.' 'OK'
        return
    }
    catch {
        Add-SoftError -Context 'RecycleBin' -Message 'Clear-RecycleBin failed; trying filesystem fallback when elevated.' -Exception $_.Exception
    }

    if (-not $script:IsAdministrator) {
        Add-SoftError -Context 'RecycleBin' -Message 'Filesystem fallback requires administrator privileges. Skipped.'
        return
    }

    try {
        $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        foreach ($drive in $drives) {
            $recyclePath = Join-Path ($drive.DeviceID + '\') '$Recycle.Bin'
            if (Test-Path -LiteralPath $recyclePath) {
                Clear-CleanupTarget -Paths @($recyclePath) -Category 'RecycleBinFallback' -RequiresAdministrator $true
            }
        }
    }
    catch {
        Add-SoftError -Context 'RecycleBinFallback' -Message 'Recycle Bin fallback failed.' -Exception $_.Exception
    }
}

function Start-CleanMgrSafely {
    if ($SkipCleanMgr) {
        Write-Log 'Disk Cleanup wizard skipped by parameter.' 'SKIP'
        return
    }

    $cleanMgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
    if (-not (Test-Path -LiteralPath $cleanMgr)) {
        Add-SoftError -Context 'CleanMgr' -Message 'cleanmgr.exe was not found.'
        return
    }

    try {
        Write-Log 'Starting Windows Disk Cleanup wizard.' 'INFO'
        Start-Process -FilePath $cleanMgr -ArgumentList ("/d {0}" -f $env:SystemDrive) -Wait -ErrorAction Stop
        Write-Log 'Windows Disk Cleanup wizard finished.' 'OK'
    }
    catch {
        Add-SoftError -Context 'CleanMgr' -Message 'Windows Disk Cleanup wizard failed or was closed unexpectedly.' -Exception $_.Exception
    }
}

function Show-Summary {
    $endTime = Get-Date
    $duration = $endTime - $script:StartTime
    $durationText = '{0} minute(s) {1} second(s)' -f [int][Math]::Floor($duration.TotalMinutes), $duration.Seconds

    Write-Banner ('{0}  CLEANUP REPORT' -f [char]0xF080) 'Green'

    $iconDisk  = [char]0xF0A0   # nf-fa-hdd_o
    $iconFile  = [char]0xF0F6   # nf-fa-file_text_o
    $iconOk    = $script:Icons.OK
    $iconSkip  = $script:Icons.SKIP
    $iconFail  = $script:Icons.ERROR
    $iconWarn  = $script:Icons.WARN
    $iconClock = [char]0xF017   # nf-fa-clock_o
    $iconLog   = [char]0xF15C   # nf-fa-file_text

    $summary = @"
Cleanup completed with soft-error handling.

 $iconDisk  Estimated space freed : $(Format-FileSize $script:Stats.EstimatedBytesFreed)
 $iconFile  Files discovered      : $($script:Stats.EstimatedFilesSeen)
 $iconOk  Targets processed     : $($script:Stats.TargetsProcessed)
 $iconSkip  Targets skipped       : $($script:Stats.TargetsSkipped)
 $iconFail  Delete failures       : $($script:Stats.DeleteFailures)
 $iconWarn  Soft errors           : $($script:SoftErrors.Count)
 $iconClock  Duration              : $durationText
 $iconLog  Log file              : $script:LogFile

Note:
  Freed space is estimated from pre-clean measurements; targets with failures are
  re-measured so the figure stays accurate. Some locked files may remain until the
  owning process is closed or the system is rebooted.
"@

    Write-Host $summary -ForegroundColor Green

    try {
        Add-Content -LiteralPath $script:LogFile -Value $summary -Encoding UTF8 -ErrorAction Stop

        if ($script:SoftErrors.Count -gt 0) {
            Add-Content -LiteralPath $script:LogFile -Value 'Soft error details:' -Encoding UTF8
            foreach ($errorRecord in $script:SoftErrors) {
                Add-Content -LiteralPath $script:LogFile -Value ($errorRecord | Format-List | Out-String) -Encoding UTF8
            }
        }
    }
    catch {
        Write-Warning ("Could not write summary to log file: {0}" -f $_.Exception.Message)
    }

    if ($script:SoftErrors.Count -gt 0) {
        Write-Host (' {0}  Soft error summary:' -f $script:Icons.WARN) -ForegroundColor Yellow
        $script:SoftErrors |
            Select-Object -First 15 Time, Context, Message |
            Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Yellow
    }
}

# Main workflow
try {
    Clear-Host
}
catch {
    # Non-interactive hosts may not support Clear-Host. Ignore.
}

$script:IsAdministrator = Test-IsAdministrator

if (-not $script:IsAdministrator) {
    if (Request-AdministratorElevation -BoundParameters $script:InitialBoundParameters) {
        return
    }
}

Write-Banner ('{0}  WINDOWS SYSTEM CLEANUP TOOL' -f [char]::ConvertFromUtf32(0xF00E2)) 'Magenta'
Write-Log ("Log file: {0}" -f $script:LogFile) 'INFO'
Write-Log ("Start time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'INFO'

if ($script:IsAdministrator) {
    Write-Log 'Administrator privileges detected.' 'OK'
}
else {
    Write-Log 'Administrator privileges were not detected. Protected system targets will be skipped, not fatal.' 'WARN'
}

$iconBullet = [char]0xF054   # nf-fa-chevron_right

Write-Host ''
Write-Host 'This workflow can clean:' -ForegroundColor Yellow
Write-Host (" $iconBullet User and system temporary files") -ForegroundColor Gray
Write-Host (" $iconBullet Browser caches, after browser shutdown unless skipped") -ForegroundColor Gray
Write-Host (" $iconBullet Windows Update temporary downloads") -ForegroundColor Gray
Write-Host (" $iconBullet Prefetch files, when selected") -ForegroundColor Gray
Write-Host (" $iconBullet Recent-items shortcuts") -ForegroundColor Gray
Write-Host (" $iconBullet Windows Error Reporting files") -ForegroundColor Gray
Write-Host (" $iconBullet Recycle Bin") -ForegroundColor Gray
Write-Host ''

if (-not (Read-YesNo -Prompt 'Continue cleanup?' -DefaultYes $false)) {
    Write-Log 'Cleanup cancelled by user. No hard exit was used.' 'WARN'
    Show-Summary
    return
}

$cleanPrefetch = [bool]$IncludePrefetch
if (-not $AssumeYes -and -not $IncludePrefetch) {
    $cleanPrefetch = Read-YesNo -Prompt 'Clean Prefetch files? This can temporarily slow first application launches.' -DefaultYes $false
}

Invoke-Step -Name 'STEP 1 - BROWSER PROCESS HANDLING' -Color 'Yellow' -Action {
    Stop-BrowserProcesses
} | Out-Null

Invoke-Step -Name 'STEP 2 - TEMPORARY FILES' -Action {
    Clear-CleanupTarget -Paths @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp')) -Category 'UserTemp'
    Clear-CleanupTarget -Paths @((Join-Path $env:WINDIR 'Temp')) -Category 'WindowsTemp' -RequiresAdministrator $true
} | Out-Null

if ($cleanPrefetch) {
    Invoke-Step -Name 'STEP 3 - PREFETCH FILES' -Action {
        Clear-CleanupTarget -Paths @((Join-Path $env:WINDIR 'Prefetch')) -Category 'Prefetch' -RequiresAdministrator $true
    } | Out-Null
}
else {
    Write-Log 'Prefetch cleanup skipped.' 'SKIP'
}

Invoke-Step -Name 'STEP 4 - RECENT ITEMS' -Action {
    Clear-CleanupTarget -Paths @((Join-Path $env:APPDATA 'Microsoft\Windows\Recent')) -Category 'RecentItems'
} | Out-Null

Invoke-Step -Name 'STEP 5 - BROWSER CACHES' -Action {
    $browserPaths = New-Object 'System.Collections.Generic.List[string]'

    foreach ($root in @(
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
        (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data'),
        (Join-Path $env:APPDATA 'Opera Software\Opera Stable'),
        (Join-Path $env:LOCALAPPDATA 'Opera Software\Opera Stable')
    )) {
        if ($root -like '*Opera Stable') {
            foreach ($relative in @('Cache','Code Cache','GPUCache')) {
                [void]$browserPaths.Add((Join-Path $root $relative))
            }
        }
        else {
            foreach ($path in (Get-ChromiumCachePaths -UserDataRoot $root)) {
                [void]$browserPaths.Add($path)
            }
        }
    }

    foreach ($path in (Get-FirefoxCachePaths)) {
        [void]$browserPaths.Add($path)
    }

    Clear-CleanupTarget -Paths $browserPaths.ToArray() -Category 'BrowserCache'
} | Out-Null

Invoke-Step -Name 'STEP 6 - WINDOWS ERROR REPORTING' -Action {
    $werPaths = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\Temp')
    )
    Clear-CleanupTarget -Paths $werPaths -Category 'WindowsErrorReporting' -RequiresAdministrator $true
} | Out-Null

Invoke-Step -Name 'STEP 7 - WINDOWS UPDATE DOWNLOAD CACHE' -Action {
    try {
        Stop-ServicesSafely -Names @('wuauserv','bits')
        Clear-CleanupTarget -Paths @((Join-Path $env:WINDIR 'SoftwareDistribution\Download')) -Category 'WindowsUpdateDownloadCache' -RequiresAdministrator $true
    }
    finally {
        Restore-StoppedServices
    }
} | Out-Null

Invoke-Step -Name 'STEP 8 - RECYCLE BIN' -Action {
    Clear-RecycleBinSafely
} | Out-Null

if (-not $SkipCleanMgr) {
    $runCleanMgr = $false
    if (-not $AssumeYes) {
        $runCleanMgr = Read-YesNo -Prompt 'Run the Windows Disk Cleanup wizard?' -DefaultYes $false
    }

    if ($runCleanMgr) {
        Invoke-Step -Name 'STEP 9 - WINDOWS DISK CLEANUP WIZARD' -Action {
            Start-CleanMgrSafely
        } | Out-Null
    }
    else {
        Write-Log 'Windows Disk Cleanup wizard not requested.' 'SKIP'
    }
}

Show-Summary

if ($OpenLog -or ((-not $AssumeYes) -and (Read-YesNo -Prompt 'Open the log file now?' -DefaultYes $false))) {
    try {
        Start-Process notepad.exe -ArgumentList $script:LogFile -ErrorAction Stop
    }
    catch {
        Add-SoftError -Context 'OpenLog' -Message 'Could not open log file in Notepad.' -Exception $_.Exception
    }
}
