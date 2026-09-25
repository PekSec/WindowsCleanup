# WindowsCleanup

A Windows cleanup script with preview mode, category selection, and local HTML/JSON reports. It removes temporary files and selected caches, retries failed deletions, and reports recoverable errors without abandoning the run.

The standalone report uses [Material 3](https://m3.material.io/) color roles, rounded cards, responsive layouts, accessible native controls, and automatic light/dark themes. It works offline without a font download, JavaScript, or external dependencies.

## Requirements

- Windows 10/11 or Windows Server 2016+
- Windows PowerShell 5.1 or PowerShell 7
- Administrator rights recommended for protected system categories

## Run

```powershell
.\WindowsCleanup.ps1

# Measure first: no deletion, browser shutdown, service changes, or UAC request.
.\WindowsCleanup.ps1 -Preview -AssumeYes

# Select categories, including the new opt-in caches.
.\WindowsCleanup.ps1 -Categories UserTemp,CrashDumps,DirectXShaderCache,OperaGXCache

# Scheduled/unattended run: no browser opens when finished.
.\WindowsCleanup.ps1 -AssumeYes -SkipCleanMgr -SkipElevationRequest

# Custom output folder and no automatic report opening.
.\WindowsCleanup.ps1 -ReportDirectory 'D:\Cleanup Reports' -NoOpenReport
```

Interactive cleanup asks for confirmation and offers UAC elevation when needed. Prefetch requires `-IncludePrefetch` or a separate interactive opt-in, even when selected with `-Categories`. `-Categories` replaces the default selection; omitted categories are not cleaned. Preview writes reports and a log, and labels measured bytes as **cleanable**, never freed.

## Reports and completion

Each run saves matching files under:

```text
%LOCALAPPDATA%\WindowsCleanup\Reports\
  CleanupReport_YYYYMMDD_HHMMSS_fff_<run-id>.html
  CleanupReport_YYYYMMDD_HHMMSS_fff_<run-id>.json
  CleanupReport_YYYYMMDD_HHMMSS_fff_<run-id>.log
```

After both reports are saved, the HTML opens in the default browser, the terminal prints both absolute report paths, and the script exits without waiting for Enter. `-AssumeYes` and `-NoOpenReport` suppress HTML opening. A failed browser launch leaves the reports available and prints a warning.

- Exit **0**: completed, completed with recoverable warnings, preview, cancellation, or successful UAC handoff. The report distinguishes these outcomes; cancellation is never labeled completed.
- Exit **1**: fatal workflow failure, unsupported platform, unsafe/unwritable report directory, or failure to save both reports. A fatal workflow attempts to save a failure report after restoring services.

Reports include timestamps, selected categories, numeric byte totals, per-target outcomes and skip reasons, measurement completeness, errors, and report paths. JSON has `SchemaVersion: 1` and top-level `RunId`, `StartedAt`, `FinishedAt`, `DurationSeconds`, `Mode`, `Status`, `IsAdministrator`, `SelectedCategories`, `Stats`, `Results`, `Errors`, and `Reports` fields. Timestamps use ISO 8601 with offsets; sizes are bytes and durations are seconds. The HTML renders the same results and links to the matching JSON and log.

Space figures are estimates based on measured file sizes, not free-space readings. Failed deletions trigger remeasurement; incomplete remeasurement conservatively credits zero reclaimed bytes. Recycle Bin and Disk Cleanup wizard savings are not measured. Missing folders, unselected categories, and administrator-only skips remain visible in the report. Reports contain local paths and exception details; review them before sharing.

## Parameters

| Parameter | Default | Behavior |
| --- | --- | --- |
| `-Preview` | Off | Measure selected targets; do not perform cleanup or change processes/services. |
| `-Categories` | Existing categories below | Clean only these category names; comma-separated in PowerShell. |
| `-ReportDirectory` | `%LOCALAPPDATA%\WindowsCleanup\Reports` | Folder for HTML, JSON, and log. Unsafe paths are rejected before cleanup. |
| `-NoOpenReport` | Off | Save reports without opening HTML. |
| `-AssumeYes` | Off | Confirm cleanup and elevation automatically; suppress optional prompts, Disk Cleanup wizard, and HTML opening. Prefetch still requires `-IncludePrefetch`. |
| `-IncludePrefetch` | Off | Opt into Prefetch cleanup when that category is selected. |
| `-SkipBrowserClose` | Off | Leave browsers running; locked caches may remain. |
| `-SkipCleanMgr` | Off | Do not offer the Disk Cleanup wizard. |
| `-OpenLog` | Off | Explicitly open the diagnostic log in Notepad, including with `-AssumeYes`. |
| `-SkipElevationRequest` | Off | Use current privileges and skip protected targets when needed. |
| `-DeleteRetryCount` | `2` | Retries per failed file or empty-directory deletion, from 0 to 10. |
| `-DeleteRetryDelayMs` | `500` | Delay between retries, from 0 to 60000 ms. |
| `-BrowserCloseTimeoutMs` | `2500` | Grace period before remaining relevant browser processes are force-closed. |

When launching from `cmd.exe`, use `powershell.exe -Command "& '.\WindowsCleanup.ps1' -Categories UserTemp,CrashDumps"` for array arguments. UAC relaunch preserves category arrays, paths containing spaces, and explicit false switches.

## Cleanup categories

| Category | Locations / operation | Admin | Selection |
| --- | --- | --- | --- |
| `UserTemp` | `%TEMP%`, `%LOCALAPPDATA%\Temp` | No | Default |
| `WindowsTemp` | `%WINDIR%\Temp` | Yes | Default |
| `Prefetch` | `%WINDIR%\Prefetch` | Yes | Default selection; separate opt-in |
| `RecentItems` | `%APPDATA%\Microsoft\Windows\Recent` | No | Default |
| `BrowserCache` | Chrome, Edge, Brave, Firefox, Opera cache directories across recognized profiles | No | Default |
| `WindowsErrorReporting` | `%ProgramData%\Microsoft\Windows\WER\{ReportArchive,ReportQueue,Temp}` | Yes | Default |
| `WindowsUpdateDownloadCache` | `%WINDIR%\SoftwareDistribution\Download` | Yes | Default |
| `RecycleBin` | Native `Clear-RecycleBin`, current user's bins | No | Default |
| `DiskCleanup` | Optional Windows Disk Cleanup wizard | Depends on selected operations | Default selection; separate interactive opt-in |
| `CrashDumps` | `%LOCALAPPDATA%\CrashDumps` | No | Explicit selection only |
| `DirectXShaderCache` | `%LOCALAPPDATA%\D3DSCache` | No | Explicit selection only |
| `OperaGXCache` | Cache subdirectories under local/roaming `Opera Software\Opera GX Stable` | No | Explicit selection only |

Browser cleanup covers recognized cache folders, including shader and Service Worker caches. Bookmarks, passwords, history, installations, and general application data are preserved. Shader caches rebuild on demand; removing crash dumps discards those diagnostic files.

## Safety and performance

Targets are deduplicated across a run. Deletion is sequential, with no forced garbage collection during retries. Ordinary files are measured before cleanup; failed targets are measured again. Links/junctions and paths with linked ancestors are skipped during measurement and deletion. Directories are deleted only after processing their children, without recursive deletion or recursive attribute changes.

The output directory cannot overlap any discovered cleanup target, even an unselected one, or use a linked ancestor or Recycle Bin path. There is no temporary-folder fallback. The directory is protected from subsequent cleanup, including attempts to remove its ancestors.

Only selected browser categories trigger browser closing. Opera and Opera GX share a process name, so selecting either may close both. Windows Update cleanup checks that both `wuauserv` and `bits` stopped successfully, then restores services that were originally running in `finally`. Non-admin runs do not attempt service changes. Recycle Bin failures are reported; there is no filesystem fallback that could erase other users' bins. Failed deletes stay in place, without quarantine renaming.

`-AssumeYes` can force-close browsers. For a scheduled run, add `-SkipBrowserClose` to keep them open:

```powershell
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\WindowsCleanup.ps1 -AssumeYes -SkipCleanMgr -SkipElevationRequest -SkipBrowserClose'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3AM
Register-ScheduledTask -TaskName 'WeeklyCleanup' -Action $action -Trigger $trigger -RunLevel Highest
```

## Verification

```powershell
powershell.exe -NoProfile -File .\tests\Regression.ps1
pwsh -NoProfile -File .\tests\Regression.ps1
```

The dependency-free checks load only function definitions, use temporary fixtures, and replace OS actions with stubs. They exercise preview, discovery, category selection, report consistency/escaping, protected paths, linked directories, partial deletion, service restoration, elevation arguments, and completion errors. Run on both Windows PowerShell 5.1 and PowerShell 7 before a Windows release; fixture checks on Linux do not verify actual UAC, services, browser shutdown, or Windows file locking.

## License

[GPL-3.0](LICENSE)
