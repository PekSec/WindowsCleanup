# Run with powershell.exe or pwsh -NoProfile -File tests/Regression.ps1
# Loads only function definitions: never executes the real cleanup workflow.
param([string]$KeepReportDirectory)
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'WindowsCleanup.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($definition in $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Assert ([bool](Get-Command Initialize-CleanupRun -ErrorAction SilentlyContinue)) 'Run initialization/reporting is missing.'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WindowsCleanup-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $AssumeYes = $true; $Preview = $true; $NoOpenReport = $true; $OpenLog = $false
    $DeleteRetryCount = 0; $DeleteRetryDelayMs = 0; $SkipBrowserClose = $false
    $Categories = @('UserTemp'); $ReportDirectory = Join-Path $fixture 'reports'
    Initialize-CleanupRun
    $script:IsAdministrator = $true
    $target = Join-Path $fixture 'cache'
    New-Item -ItemType Directory -Path $target | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'example.txt'), 'abcdef')
    Initialize-ReportStorage -CleanupPaths @($target)
    Clear-CleanupTarget -Paths @($target, $target) -Category 'UserTemp'
    Assert (Test-Path (Join-Path $target 'example.txt')) 'Preview deleted a file.'
    Assert ($script:Results.Count -eq 1) 'Duplicate target counted twice.'
    Assert ($script:Stats.EstimatedBytesFreed -eq 0) 'Preview claimed freed space.'
    Assert ($script:Stats.EstimatedCleanableBytes -eq 6) 'Preview measured bytes incorrectly.'
    Add-SoftError -Context 'HTML <test>' -Message '<script>alert("x")</script> & café'
    $script:RunStatus = 'Preview'
    $report = New-CleanupReport
    Export-CleanupReports -Report $report
    $json = Get-Content -LiteralPath $script:JsonFile -Raw | ConvertFrom-Json
    $html = Get-Content -LiteralPath $script:HtmlFile -Raw
    Assert ($json.SchemaVersion -eq 1 -and $json.Results.Count -eq 1) 'JSON report lost result data.'
    Assert ($json.Stats.EstimatedCleanableBytes -eq 6) 'JSON totals differ from measurement.'
    Assert ($html.Contains('&lt;script&gt;') -and -not $html.Contains('<script>alert')) 'HTML content was not escaped.'
    Assert ($html.Contains([IO.Path]::GetFileName($script:JsonFile))) 'HTML does not link to matching JSON.'
    Assert (-not ($html -match '(src|href)="https?://')) 'Report requires remote assets.'
    Assert ($json.Errors[0].Message -eq '<script>alert("x")</script> & café') 'JSON changed error text.'
    $firstHtml = $script:HtmlFile
    Initialize-CleanupRun
    $script:IsAdministrator = $true
    Initialize-ReportStorage -CleanupPaths @($target)
    Assert ($script:HtmlFile -ne $firstHtml) 'Runs reuse report filenames.'
    $Preview = $false
    Clear-CleanupTarget -Paths @($target) -Category 'UserTemp'
    Assert (-not (Test-Path (Join-Path $target 'example.txt'))) 'Cleanup left ordinary fixture file.'
    Assert ($script:Stats.EstimatedBytesFreed -eq 6) 'Freed bytes incorrect.'
    Assert (Test-Path $target) 'Cleanup removed target root.'
    Assert (-not (Test-SafeCleanupPath -LiteralPath $fixture)) 'Allowed deletion of report ancestor.'
    Assert (-not (Test-SafeCleanupPath -LiteralPath $script:LogFile)) 'Allowed deletion of log.'
    $ReportDirectory = Join-Path $target 'unsafe-reports'
    $rejected = $false
    try { Initialize-ReportStorage -CleanupPaths @($target) } catch { $rejected = $true }
    Assert $rejected 'Allowed reports inside cleanup target.'
    if ($KeepReportDirectory) {
        New-Item -ItemType Directory -Path $KeepReportDirectory -Force | Out-Null
        Copy-Item -LiteralPath $firstHtml -Destination $KeepReportDirectory
        Copy-Item -Path (Join-Path $fixture 'reports/*.json') -Destination $KeepReportDirectory
    }
    # Discovery runs against synthetic environment roots, never the user's real caches.
    $environment = @{}
    foreach ($name in @('LOCALAPPDATA','APPDATA','WINDIR','ProgramData','TEMP')) {
        $environment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, (Join-Path $fixture $name))
    }
    try {
        $groups = @(Get-CleanupGroups)
        Assert ($groups.Count -eq 10) 'Discovery lost cleanup categories.'
        Assert (@($groups | Where-Object Category -eq 'OperaGXCache')[0].Paths.Count -ge 6) 'Opera GX cache discovery failed.'
    }
    finally {
        foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
    }

    $ReportDirectory = Join-Path $fixture 'more reports [local]'
    Initialize-CleanupRun
    $script:IsAdministrator = $true
    Initialize-ReportStorage -CleanupPaths @($target)
    Assert (-not (Test-SafeCleanupPath ([IO.Path]::GetPathRoot($fixture)))) 'Allowed drive-root cleanup.'
    $outside = Join-Path $fixture 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep me')
    $link = Join-Path $target 'linked-directory'
    $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $link -Target $outside | Out-Null
    try {
        $measurement = Measure-CleanupPath $target
        Assert (-not $measurement.Complete -and $measurement.Bytes -eq 0) 'Measurement traversed a linked directory.'
        Assert (-not (Remove-PathWithSelfHeal $link 'LinkTest')) 'Deletion accepted a linked directory.'
        Clear-CleanupTarget @($target) 'UserTemp'
        Assert (Test-Path (Join-Path $outside 'keep.txt')) 'Nested link destination was deleted.'
        Assert ($script:Results[0].Status -eq 'Partial') 'Skipped linked child was not reported as partial.'
        Assert ($script:Stats.EstimatedBytesFreed -eq 0) 'Incomplete measurement claimed reclaimed space.'
        $ReportDirectory = Join-Path $link 'reports'
        $rejected = $false
        try { Initialize-ReportStorage @() } catch { $rejected = $true }
        Assert $rejected 'Reports allowed through linked ancestor.'
    }
    finally { (Get-Item -LiteralPath $link -Force).Delete() }

    # Failures are visible and do not fabricate freed bytes.
    $realRemove = ${function:Remove-PathWithSelfHeal}
    try {
        function Remove-PathWithSelfHeal { $script:Stats.DeleteFailures++; return $false }
        $script:SeenTargets.Clear()
        [IO.File]::WriteAllText((Join-Path $target 'locked.txt'), 'locked')
        Clear-CleanupTarget @($target) 'UserTemp'
        Assert ($script:Results[-1].Status -eq 'Partial') 'Failed deletion was reported as completed.'
        Assert ($script:Results[-1].EstimatedBytesFreed -eq 0) 'Failed deletion claimed freed bytes.'
    }
    finally { Set-Item Function:Remove-PathWithSelfHeal $realRemove }

    # Workflow orchestration: synthetic groups plus strict OS-action stubs.
    $ReportDirectory = Join-Path $fixture 'workflow reports'
    $fixtureGroups = @(
        [pscustomobject]@{ Category = 'UserTemp'; Admin = $false; Paths = @($target) }
        [pscustomobject]@{ Category = 'WindowsUpdateDownloadCache'; Admin = $true; Paths = @($outside) }
    )
    function Start-Process { throw 'Unexpected process launch' }
    function Get-Process { throw 'Unexpected process inspection' }
    function Get-Service { throw 'Unexpected service operation' }
    function Clear-RecycleBin { throw 'Unexpected Recycle Bin operation' }
    $Preview = $true; $AssumeYes = $true; $IncludePrefetch = $false
    $Categories = @('UserTemp','WindowsUpdateDownloadCache','RecycleBin','DiskCleanup')
    Initialize-CleanupRun
    $script:IsAdministrator = $true
    Initialize-ReportStorage @($target, $outside)
    Invoke-CleanupWorkflow $fixtureGroups
    Assert ($script:SoftErrors.Count -eq 0) 'Preview performed an OS action.'
    Assert (Test-Path (Join-Path $target 'locked.txt')) 'Workflow preview deleted files.'
    Assert ($script:Stats.EstimatedBytesFreed -eq 0) 'Workflow preview reported freed bytes.'
    $Categories = @('UserTemp'); $Preview = $false
    $script:SeenTargets.Clear()
    Invoke-CleanupWorkflow $fixtureGroups
    Assert (-not (Test-Path (Join-Path $target 'locked.txt'))) 'Selected category was not cleaned.'
    Assert (Test-Path (Join-Path $outside 'keep.txt')) 'Unselected category was cleaned.'
    $Categories = @('WindowsUpdateDownloadCache')
    $script:IsAdministrator = $false
    Invoke-CleanupWorkflow $fixtureGroups
    Assert ($script:SoftErrors.Count -eq 0) 'Non-admin workflow attempted service operations.'
    Assert ($script:Results[-3].Reason -eq 'Administrator privileges required.') 'Non-admin target missing skip reason.'
    $script:IsAdministrator = $true
    Invoke-CleanupWorkflow $fixtureGroups
    Assert (Test-Path (Join-Path $outside 'keep.txt')) 'Update cache deleted after service-stop failure.'
    Assert (@($script:Results | Where-Object Reason -eq 'Required services could not be stopped.').Count -eq 1) 'Service failure did not skip target.'

    $script:Services = @{}
    foreach ($name in @('wuauserv','bits')) {
        $service = [pscustomobject]@{ Name = $name; Status = 'Stopped' }
        $service | Add-Member ScriptMethod Refresh {}
        $service | Add-Member ScriptMethod WaitForStatus { param($Desired, $Timeout) if ($this.Status -ne [string]$Desired) { throw 'Service did not reach requested state' } }
        $script:Services[$name] = $service
    }
    $script:Services.wuauserv.Status = 'Running'
    $script:ServiceStarts = @()
    function Get-Service { param($Name) return $script:Services[$Name] }
    function Stop-Service { param($Name) $script:Services[$Name].Status = 'Stopped' }
    function Start-Service { param($Name) $script:Services[$Name].Status = 'Running'; $script:ServiceStarts += $Name }
    $script:StoppedServices = @{}
    Assert (Stop-ServicesSafely @('wuauserv','bits')) 'Stopped services were not accepted.'
    Restore-StoppedServices
    Assert ($script:Services.wuauserv.Status -eq 'Running') 'Running service was not restored.'
    Assert ($script:Services.bits.Status -eq 'Stopped') 'Previously stopped service was started.'
    Assert ($script:ServiceStarts.Count -eq 1) 'Unexpected service restoration count.'

    $summary = New-CleanupReport
    Assert ($summary.Stats.TargetsSkipped -eq @($summary.Results | Where-Object Status -eq 'Skipped').Count) 'Summary skipped count differs from result rows.'
    Assert ($summary.Stats.TargetsProcessed -eq @($summary.Results | Where-Object { $_.Status -in @('Completed','Partial','Preview') }).Count) 'Summary processed count differs from result rows.'

    # Completion exports first; browser failure is only a warning; unattended never launches.
    $script:RunStatus = 'Completed'
    $AssumeYes = $false; $NoOpenReport = $false
    Assert ((Complete-CleanupRun) -eq 0) 'Browser launch failure changed successful completion.'
    Assert (Test-Path $script:HtmlFile) 'Browser launch failure lost HTML report.'
    $script:RunId += '_unattended'
    Initialize-ReportStorage @($target, $outside)
    $AssumeYes = $true
    $script:LaunchCount = 0
    function Start-Process { $script:LaunchCount++ }
    Assert ((Complete-CleanupRun) -eq 0) 'Unattended completion failed.'
    Assert ($script:LaunchCount -eq 0) 'Unattended completion launched a process.'
    $script:RunId += '_failed'
    Initialize-ReportStorage @($target, $outside)
    $script:RunStatus = 'Failed'
    Assert ((Complete-CleanupRun) -eq 1) 'Fatal workflow failure returned success.'
    $script:RunStatus = 'Cancelled'
    Assert ((New-CleanupReport).Status -eq 'Cancelled') 'Cancellation was labeled success.'
    $script:RunStatus = 'Completed'
    $script:HtmlFile = Join-Path (Join-Path $fixture 'missing-parent') 'report.html'
    Assert ((Complete-CleanupRun) -eq 1) 'Report-write failure returned success.'

    $arguments = New-ElevatedInvocationArguments "C:\it's a folder\clean.ps1" @{
        Categories = @('UserTemp','CrashDumps'); Preview = [switch]$false; ReportDirectory = "C:\Reports [é]\it's here"
    }
    $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($arguments[-1]))
    $elevationErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$elevationErrors)
    Assert (-not $elevationErrors.Count) 'Elevation command has invalid quoting.'
    Assert ($command.Contains("'UserTemp','CrashDumps'")) 'Elevation lost array parameters.'
    Assert ($command.Contains('-Preview:$false')) 'Elevation lost explicit false switch.'

    Write-Host 'Regression checks passed.'
}
finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
