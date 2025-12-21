#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Gelişmiş Windows Sistem Temizlik Betiği v3.0 🚀
    
.DESCRIPTION
    Güvenli ve kapsamlı sistem temizliği yapar.
    - Detaylı loglama
    - Disk alanı hesaplama
    - Kullanıcı onayı
    - Servis yönetimi
    - Tarayıcı kontrolleri
    
.NOTES
    Yazar: Barış PEKALP (İyileştirilmiş Versiyon)
    Versiyon: 3.0
    Gereksinim: PowerShell 5.1+, Yönetici Yetkisi
#>

# ============================================================================
# YAPILANDIRMA ve GLOBAL DEĞİŞKENLER
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# İstatistikler
$script:TotalFilesDeleted = 0
$script:TotalSpaceFreed = 0
$script:StartTime = Get-Date
$script:LogFile = "$env:TEMP\CleanupLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Renkler
$Colors = @{
    Success = "Green"
    Warning = "Yellow"
    Error = "Red"
    Info = "Cyan"
    Header = "Magenta"
}

# ============================================================================
# YARDIMCI FONKSİYONLAR
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $logEntry
    
    switch ($Level) {
        "SUCCESS" { Write-Host $Message -ForegroundColor $Colors.Success }
        "WARNING" { Write-Host $Message -ForegroundColor $Colors.Warning }
        "ERROR"   { Write-Host $Message -ForegroundColor $Colors.Error }
        default   { Write-Host $Message -ForegroundColor $Colors.Info }
    }
}

function Write-Banner {
    param([string]$Text, [string]$Color = "Cyan")
    $line = "=" * 80
    Write-Host "`n$line" -ForegroundColor $Color
    Write-Host $Text -ForegroundColor $Color
    Write-Host "$line`n" -ForegroundColor $Color
}

function Get-FolderSize {
    param([string]$Path)
    
    if (Test-Path $Path) {
        try {
            $size = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | 
                     Measure-Object -Property Length -Sum).Sum
            return $size
        }
        catch {
            return 0
        }
    }
    return 0
}

function Format-FileSize {
    param([long]$Size)
    
    if ($Size -gt 1TB) { return "{0:N2} TB" -f ($Size / 1TB) }
    if ($Size -gt 1GB) { return "{0:N2} GB" -f ($Size / 1GB) }
    if ($Size -gt 1MB) { return "{0:N2} MB" -f ($Size / 1MB) }
    if ($Size -gt 1KB) { return "{0:N2} KB" -f ($Size / 1KB) }
    return "{0:N2} Bytes" -f $Size
}

function Stop-BrowserProcesses {
    $browsers = @("chrome", "firefox", "msedge", "opera", "brave", "iexplore")
    $stoppedProcesses = @()
    
    foreach ($browser in $browsers) {
        $processes = Get-Process -Name $browser -ErrorAction SilentlyContinue
        if ($processes) {
            Write-Log "⏸️  $browser kapatılıyor..." "WARNING"
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue
            $stoppedProcesses += $browser
            Start-Sleep -Milliseconds 500
        }
    }
    
    if ($stoppedProcesses.Count -gt 0) {
        Write-Log "✅ Kapatılan tarayıcılar: $($stoppedProcesses -join ', ')" "SUCCESS"
    }
}

function Stop-WindowsUpdateService {
    try {
        $service = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq "Running") {
            Write-Log "⏸️  Windows Update servisi durduruluyor..." "INFO"
            Stop-Service -Name wuauserv -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            Write-Log "✅ Windows Update servisi durduruldu" "SUCCESS"
            return $true
        }
    }
    catch {
        Write-Log "⚠️  Windows Update servisi durdurulamadı: $_" "WARNING"
        return $false
    }
    return $false
}

function Start-WindowsUpdateService {
    param([bool]$WasStopped)
    
    if ($WasStopped) {
        try {
            Write-Log "▶️  Windows Update servisi başlatılıyor..." "INFO"
            Start-Service -Name wuauserv -ErrorAction Stop
            Write-Log "✅ Windows Update servisi başlatıldı" "SUCCESS"
        }
        catch {
            Write-Log "⚠️  Windows Update servisi başlatılamadı: $_" "WARNING"
        }
    }
}

function Remove-ItemsSafely {
    param(
        [string[]]$Paths,
        [string]$Category,
        [string]$Emoji = "🧹"
    )
    
    $categorySize = 0
    $categoryFiles = 0
    
    foreach ($path in $Paths) {
        # Wildcard desteği
        $expandedPaths = @()
        if ($path -like "*`**") {
            $expandedPaths = Get-Item -Path $path -ErrorAction SilentlyContinue
        } else {
            if (Test-Path $path) {
                $expandedPaths = @($path)
            }
        }
        
        foreach ($expandedPath in $expandedPaths) {
            if (Test-Path $expandedPath) {
                try {
                    # Boyut hesapla
                    $sizeBefore = Get-FolderSize -Path $expandedPath
                    $fileCount = (Get-ChildItem -Path $expandedPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
                    
                    Write-Log "$Emoji Temizleniyor: $expandedPath ($(Format-FileSize $sizeBefore), $fileCount dosya)" "INFO"
                    
                    # Dosyaları sil
                    Remove-Item -Path "$expandedPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                    
                    $categorySize += $sizeBefore
                    $categoryFiles += $fileCount
                    
                    Write-Log "  ✅ Temizlendi: $(Format-FileSize $sizeBefore)" "SUCCESS"
                }
                catch {
                    Write-Log "  ❌ Hata: $_" "ERROR"
                }
            }
        }
    }
    
    $script:TotalSpaceFreed += $categorySize
    $script:TotalFilesDeleted += $categoryFiles
    
    if ($categorySize -gt 0) {
        Write-Log "📊 $Category Toplamı: $(Format-FileSize $categorySize), $categoryFiles dosya`n" "SUCCESS"
    }
}

# ============================================================================
# ANA PROGRAM
# ============================================================================

Clear-Host
Write-Banner "🚀 WINDOWS SİSTEM TEMİZLİK ARACI v3.0 🚀" "Magenta"

Write-Log "📝 Log dosyası: $script:LogFile" "INFO"
Write-Log "⏰ Başlangıç zamanı: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')" "INFO"

# Kullanıcı Onayı
Write-Host "`n⚠️  Bu işlem aşağıdaki temizlikleri yapacaktır:" -ForegroundColor Yellow
Write-Host "   • Geçici sistem ve kullanıcı dosyaları" -ForegroundColor Gray
Write-Host "   • Tarayıcı önbellekleri (Tarayıcılar kapatılacak!)" -ForegroundColor Gray
Write-Host "   • Windows Update geçici dosyaları" -ForegroundColor Gray
Write-Host "   • Prefetch dosyaları (İsteğe bağlı)" -ForegroundColor Gray
Write-Host "   • Geri dönüşüm kutusu" -ForegroundColor Gray
Write-Host "   • Windows hata raporları`n" -ForegroundColor Gray

$confirm = Read-Host "Devam etmek istiyor musunuz? (E/H)"
if ($confirm -notmatch '^[EeYy]') {
    Write-Log "❌ İşlem kullanıcı tarafından iptal edildi" "WARNING"
    exit
}

# Prefetch Onayı
$cleanPrefetch = Read-Host "`n⚠️  Prefetch dosyalarını temizlemek bazı uygulamaların açılış süresini geçici olarak etikleybilir. Yine de temizlensin mi? (E/H)"
$includePrefetch = $cleanPrefetch -match '^[EeYy]'

# ============================================================================
# TEMİZLİK İŞLEMLERİ
# ============================================================================

Write-Banner "🧹 TEMİZLİK İŞLEMLERİ BAŞLIYOR" "Cyan"

# 1. Tarayıcıları Kapat
Write-Banner "🌐 TARAYICILAR KAPATILIYOR" "Yellow"
Stop-BrowserProcesses

# 2. Geçici Dosyalar
Write-Banner "📁 GEÇİCİ DOSYALAR TEMİZLENİYOR" "Cyan"
$tempPaths = @(
    "$env:TEMP",
    "$env:WINDIR\Temp",
    "$env:LOCALAPPDATA\Temp"
)
Remove-ItemsSafely -Paths $tempPaths -Category "Geçici Dosyalar" -Emoji "🗑️"

# 3. Prefetch (isteğe bağlı)
if ($includePrefetch) {
    Write-Banner "⚡ PREFETCH DOSYALARI TEMİZLENİYOR" "Cyan"
    Remove-ItemsSafely -Paths @("$env:WINDIR\Prefetch") -Category "Prefetch" -Emoji "⚡"
}

# 4. Son Kullanılan Dosyalar
Write-Banner "📋 SON KULLANILAN DOSYALAR TEMİZLENİYOR" "Cyan"
Remove-ItemsSafely -Paths @("$env:APPDATA\Microsoft\Windows\Recent") -Category "Son Kullanılanlar" -Emoji "📋"

# 5. Tarayıcı Önbellekleri
Write-Banner "🌐 TARAYICI ÖNBELLEKLERİ TEMİZLENİYOR" "Cyan"
$browserPaths = @(
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
    "$env:LOCALAPPDATA\Opera Software\Opera Stable\Cache",
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
)

# Firefox profilleri için özel işlem
$firefoxProfiles = Get-ChildItem -Path "$env:APPDATA\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue
foreach ($profile in $firefoxProfiles) {
    $browserPaths += "$($profile.FullName)\cache2"
    $browserPaths += "$($profile.FullName)\startupCache"
}

Remove-ItemsSafely -Paths $browserPaths -Category "Tarayıcı Önbellekleri" -Emoji "🌐"

# 6. Windows Hata Raporları
Write-Banner "📊 WINDOWS HATA RAPORLARI TEMİZLENİYOR" "Cyan"
$werPaths = @(
    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
    "$env:ProgramData\Microsoft\Windows\WER\Temp"
)
Remove-ItemsSafely -Paths $werPaths -Category "Hata Raporları" -Emoji "📊"

# 7. Windows Update Geçici Dosyaları
Write-Banner "🔄 WINDOWS UPDATE DOSYALARI TEMİZLENİYOR" "Cyan"
$wuStopped = Stop-WindowsUpdateService
Remove-ItemsSafely -Paths @("C:\Windows\SoftwareDistribution\Download") -Category "Windows Update" -Emoji "🔄"
Start-WindowsUpdateService -WasStopped $wuStopped

# 8. Geri Dönüşüm Kutusu
Write-Banner "🗑️  GERİ DÖNÜŞÜM KUTUSU BOŞALTILIYOR" "Cyan"
try {
    Clear-RecycleBin -Force -ErrorAction Stop
    Write-Log "✅ Geri dönüşüm kutusu boşaltıldı" "SUCCESS"
}
catch {
    Write-Log "❌ Geri dönüşüm kutusu boşaltılamadı: $_" "ERROR"
}

# 9. Disk Temizleme (isteğe bağlı)
$runCleanmgr = Read-Host "`n🚀 Windows Disk Temizleme Sihirbazı çalıştırılsın mı? (E/H)"
if ($runCleanmgr -match '^[EeYy]') {
    Write-Banner "🧹 DİSK TEMİZLEME SİHİRBAZI BAŞLATILIYOR" "Cyan"
    Write-Log "🚀 Cleanmgr.exe başlatılıyor..." "INFO"
    Start-Process cleanmgr.exe -ArgumentList "/sagerun:1" -Wait -ErrorAction SilentlyContinue
}

# ============================================================================
# RAPOR OLUŞTURMA
# ============================================================================

$endTime = Get-Date
$duration = $endTime - $script:StartTime

Write-Banner "📊 TEMİZLİK RAPORU 📊" "Green"

$report = @"

╔═══════════════════════════════════════════════════════════════════════════╗
║                        TEMİZLİK İŞLEMİ TAMAMLANDI                         ║
╚═══════════════════════════════════════════════════════════════════════════╝

🎯 İSTATİSTİKLER:
   ✅ Temizlenen Alan      : $(Format-FileSize $script:TotalSpaceFreed)
   📄 Silinen Dosya Sayısı : $script:TotalFilesDeleted
   ⏱️  Toplam Süre         : $($duration.Minutes) dakika $($duration.Seconds) saniye
   📅 Tarih                : $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')

📝 LOG DOSYASI:
   $script:LogFile

💡 ÖNERİLER:
   • Bilgisayarınızı yeniden başlatmanız önerilir
   • Disk birleştirme (defragmentation) yapabilirsiniz
   • Düzenli temizlik için bu betiği ayda bir çalıştırın

"@

Write-Host $report -ForegroundColor Green
Add-Content -Path $script:LogFile -Value $report

Write-Host "`n✨ İyi günler dilerim! 😊`n" -ForegroundColor Cyan

# Raporu aç
$openLog = Read-Host "📄 Log dosyasını açmak ister misiniz? (E/H)"
if ($openLog -match '^[EeYy]') {
    Start-Process notepad.exe -ArgumentList $script:LogFile
}
