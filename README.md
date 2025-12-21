# 🧹 PowerShell Sistem Temizleyici

Windows sisteminizde biriken geçici, önbellek ve gereksiz dosyaları otomatik temizleyen gelişmiş PowerShell betiği.

## ✨ Özellikler

- **Kapsamlı Temizlik:** Geçici dosyalar, sistem önbellekleri, Windows Update kalıntıları
- **Tarayıcı Desteği:** Chrome, Edge, Firefox, Opera, Brave önbelleklerini temizler
- **Otomatik Güvenlik:** Tarayıcı ve Windows Update servislerini otomatik yönetir
- **Detaylı Raporlama:** Temizlenen alan, dosya sayısı ve işlem süresini gösterir
- **Akıllı Sistem:** Kullanıcı onayı ile güvenli temizlik yapar
- **Log Kayıtları:** Tüm işlemleri detaylı olarak kaydeder

## 🚀 Hızlı Başlangıç

1. **Betiği İndirin:**
```powershell
git clone https://github.com/PekSec/WindowsCleanup.git
cd WindowsCleanup
```

2. **Yönetici Olarak Çalıştırın:**
   - `WindowsCleanup.ps1` dosyasına sağ tık
   - **"PowerShell ile Çalıştır"** seçin
   - Yönetici onayını verin

Ya da PowerShell'den:
```powershell
.\WindowsCleanup.ps1
```

## 📦 Ne Temizlenir?

| Kategori | Konum | Açıklama |
|----------|-------|----------|
| **Geçici Dosyalar** | `%TEMP%`, `C:\Windows\Temp` | Kullanıcı ve sistem geçici dosyaları |
| **Tarayıcı Önbellekleri** | Chrome, Edge, Firefox, Opera, Brave | Tarayıcı cache ve code cache |
| **Windows Update** | `SoftwareDistribution\Download` | Güncelleme geçici dosyaları |
| **Prefetch** | `C:\Windows\Prefetch` | Uygulama başlatma önbelleği (isteğe bağlı) |
| **Hata Raporları** | WER klasörleri | Windows hata raporlama dosyaları |
| **Geri Dönüşüm Kutusu** | Recycle Bin | Tüm sürücülerdeki silinmiş dosyalar |

## 📊 Örnek Çıktı

```
╔═══════════════════════════════════════════════════════════════════════════╗
║                        TEMİZLİK İŞLEMİ TAMAMLANDI                         ║
╚═══════════════════════════════════════════════════════════════════════════╝

🎯 İSTATİSTİKLER:
   ✅ Temizlenen Alan      : 3.47 GB
   📄 Silinen Dosya Sayısı : 12,847
   ⏱️  Toplam Süre         : 2 dakika 34 saniye
   📅 Tarih                : 21.12.2024 14:23:45
```

## ⚠️ Önemli Notlar

### Yönetici Yetkisi
Betik yönetici yetkisi olmadan çalışmaz. Yönetici olarak çalıştırmazsanız otomatik kapanır.

### Tarayıcılar
Betik, tarayıcıları otomatik kapatır. Açık sekmelerinizi kaydetmeyi unutmayın!

### Prefetch Klasörü
Prefetch temizliği için ayrı onay istenir. İlk çalıştırmada bazı uygulamalar yavaş açılabilir ancak sistem kısa sürede optimize olur.

### Windows Update
Windows Update servisi geçici olarak durdurulur, temizlik yapılır ve tekrar başlatılır.

## 📅 Zamanlanmış Görev Oluşturma

Haftalık otomatik temizlik için:

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\Scripts\WindowsCleanup.ps1"

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3AM

Register-ScheduledTask -TaskName "WeeklyCleanup" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

## 🔧 Sorun Giderme 

**"Script Çalıştırma Devre Dışı" Hatası:**
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
```

**"Erişim Engellendi" Hatası:**
- PowerShell'i yönetici olarak açın
- Tarayıcıları kapatın ve tekrar deneyin

**Log Dosyası Konumu:**
```powershell
$env:TEMP\CleanupLog_*.txt
```

## 📋 Gereksinimler 

- Windows 10/11 veya Windows Server 2016+
- PowerShell 5.1 veya üzeri
- Yönetici (Administrator) yetkisi

## 🆕 v3.0 Yenilikleri

- ✅ Kullanıcı onay sistemi
- ✅ Detaylı loglama ve raporlama
- ✅ Temizlenen alan hesaplama
- ✅ Otomatik tarayıcı yönetimi
- ✅ Windows Update servis kontrolü
- ✅ İşlem süresi takibi
- ✅ Gelişmiş hata yönetimi
