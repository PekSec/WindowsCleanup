# 🧹 WindowsCleanup

A PowerShell cleanup tool for Windows that removes temporary files, browser caches, and system leftovers — safely. No hard exits, no red walls of errors: every failure is caught, logged, retried, and reported at the end.

## ✨ Features

- 🛡️ **Soft-error handling** — the script never dies mid-run; failures are collected and summarized
- 🔁 **Self-heal deletes** — retries locked files, strips restrictive attributes, and falls back to a quarantine-rename delete
- 🌐 **Browser aware** — gracefully closes Chrome, Edge, Firefox, Opera, and Brave before clearing their caches
- ⚙️ **Service safe** — stops Windows Update services for cache cleanup and always restores them afterwards
- 🔐 **Elevation friendly** — offers a UAC relaunch when not elevated; without admin rights it simply skips protected targets
- 📊 **Honest statistics** — freed space is measured before cleaning and re-measured when deletes fail, so numbers stay accurate
- 📝 **Full logging** — every action lands in a timestamped log file kept safely outside the cleaned folders
- 💎 **Pretty console output** — colored, icon-decorated output (uses [Nerd Font](https://www.nerdfonts.com/) glyphs; falls back to plain text on other fonts)

## 📋 Requirements

- Windows 10 / 11 or Windows Server 2016+
- PowerShell 5.1 or newer (PowerShell 7 works too)
- Administrator rights recommended — not required (protected targets are skipped without them)
- Optional: a Nerd Font terminal font for the icons

## 🚀 Quick Start

```powershell
git clone https://github.com/PekSec/WindowsCleanup.git
cd WindowsCleanup
.\WindowsCleanup.ps1
```

The script asks for confirmation before cleaning, offers a UAC elevation prompt when not running as Administrator, and asks separately before touching Prefetch or launching the Disk Cleanup wizard.

For a fully unattended run:

```powershell
.\WindowsCleanup.ps1 -AssumeYes -SkipCleanMgr
```

## 🧰 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-AssumeYes` | switch | off | Answer *yes* to all prompts (unattended mode); skips the interactive Disk Cleanup wizard and the "open log" prompt |
| `-IncludePrefetch` | switch | off | Clean `C:\Windows\Prefetch` without asking |
| `-SkipBrowserClose` | switch | off | Don't close running browsers (their caches may then be locked) |
| `-SkipCleanMgr` | switch | off | Never offer the Windows Disk Cleanup wizard |
| `-OpenLog` | switch | off | Open the log file in Notepad when finished |
| `-SkipElevationRequest` | switch | off | Don't offer the UAC relaunch; run with current privileges |
| `-DeleteRetryCount` | int | `2` | Retries per failed delete before the quarantine fallback |
| `-DeleteRetryDelayMs` | int | `500` | Delay between delete retries |
| `-BrowserCloseTimeoutMs` | int | `2500` | Grace period before browsers are force-closed |

## 🗑️ What Gets Cleaned

| Category | Location | Admin needed |
|---|---|---|
| 🗂️ User temp files | `%TEMP%`, `%LOCALAPPDATA%\Temp` | No |
| 🖥️ System temp files | `C:\Windows\Temp` | Yes |
| 🚀 Prefetch (optional) | `C:\Windows\Prefetch` | Yes |
| 🕘 Recent items | `%APPDATA%\Microsoft\Windows\Recent` | No |
| 🌐 Browser caches | Chrome, Edge, Brave, Opera, Firefox (all profiles) | No |
| 💥 Error reports | `%ProgramData%\Microsoft\Windows\WER` | Yes |
| 📦 Windows Update cache | `C:\Windows\SoftwareDistribution\Download` | Yes |
| ♻️ Recycle Bin | All fixed drives | No¹ |

¹ Uses `Clear-RecycleBin`; the filesystem fallback (`$Recycle.Bin` folders) requires admin.

Browser caches cover `Cache`, `Code Cache`, `GPUCache`, shader caches, and Service Worker storage per profile — bookmarks, passwords, and history are **never** touched.

## 📊 Sample Output

```
╭──────────────────────────────────────────────────────────────╮
│                   󰃢  WINDOWS SYSTEM CLEANUP TOOL             │
╰──────────────────────────────────────────────────────────────╯
   Log file: C:\Users\you\AppData\Local\WindowsCleanup\CleanupLog_20260714_143000.log
   Administrator privileges detected.

╭──────────────────────────────────────────────────────────────╮
│                    STEP 2 - TEMPORARY FILES                │
╰──────────────────────────────────────────────────────────────╯
   Cleaning [UserTemp]: C:\Users\you\AppData\Local\Temp (1.82 GB, 4,213 files)
   Completed [UserTemp]: C:\Users\you\AppData\Local\Temp

╭──────────────────────────────────────────────────────────────╮
│                        CLEANUP REPORT                       │
╰──────────────────────────────────────────────────────────────╯
   Estimated space freed : 3.47 GB
   Files discovered      : 12,847
   Targets processed     : 38
   Delete failures       : 0
   Duration              : 2 minute(s) 34 second(s)
```

## 📝 Logging

Each run writes a timestamped log to:

```
%LOCALAPPDATA%\WindowsCleanup\CleanupLog_YYYYMMDD_HHMMSS.log
```

The log lives outside every cleanup target, so the script can never delete its own log. It contains every action, all soft errors with full exception details, and the final summary.

## 📅 Scheduled Weekly Cleanup

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\WindowsCleanup.ps1 -AssumeYes -SkipCleanMgr"

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3AM

Register-ScheduledTask -TaskName "WeeklyCleanup" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

> ⚠️ `-AssumeYes` also closes running browsers. Schedule it for a time when you're not browsing, or add `-SkipBrowserClose`.

## 🔧 Troubleshooting

**"Running scripts is disabled on this system"**
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
```

**"Access denied" on some targets**
Run elevated (accept the UAC prompt) and close browsers first. Non-elevated runs skip protected system folders by design.

**Icons look like boxes (□)**
Your terminal font isn't a Nerd Font. Install one (e.g. *CaskaydiaCove Nerd Font*) or ignore it — functionality is unaffected.

**Some files survive the cleanup**
Locked files held by running processes are retried, then skipped and reported as soft errors. They usually disappear on the next run after a reboot.

## 📄 License

[GPL-3.0](LICENSE)
