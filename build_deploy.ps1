$ErrorActionPreference = "Stop"
$ProjectRoot = "D:\REINs\Documents\GZUS-PRO"
$FlutterBin = "D:\REINs\Documents\flutter\bin\flutter.bat"
$ApkPath = "$ProjectRoot\apps\mobile_web\build\app\outputs\flutter-apk\app-release.apk"

$LocalIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.6.*" } | Select-Object -First 1).IPAddress
if (-not $LocalIP) {
    $LocalIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.*" -and $_.PrefixOrigin -ne "WellKnown" -and $_.InterfaceAlias -notmatch "VPN|vEthernet|WSL|Hyper|Docker|Loopback" } | Select-Object -First 1).IPAddress
}
if (-not $LocalIP) {
    Write-Host "Cannot detect LAN IP, falling back to 10.0.2.2 (emulator only)" -ForegroundColor Red
    $LocalIP = "10.0.2.2"
}

$ApiUrl = "http://${LocalIP}:8000"

Write-Host "[1/3] Building APK (API_BASE_URL=$ApiUrl)..." -ForegroundColor Cyan
Push-Location "$ProjectRoot\apps\mobile_web"
& $FlutterBin build apk --dart-define=API_BASE_URL=$ApiUrl
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!" -ForegroundColor Red
    Pop-Location
    exit 1
}
Pop-Location

if (-not (Test-Path $ApkPath)) {
    Write-Host "APK not found at $ApkPath" -ForegroundColor Red
    exit 1
}
$ApkInfo = Get-Item $ApkPath
Write-Host "  APK: $($ApkInfo.Length / 1MB -f '{0:F1}')MB  $($ApkInfo.LastWriteTime)" -ForegroundColor Green

Write-Host "[2/3] Finding ADB device..." -ForegroundColor Cyan
$devices = adb devices | Select-String "device$" | ForEach-Object { ($_ -split "`t")[0] }
if ($devices.Count -eq 0) {
    Write-Host "No ADB device found!" -ForegroundColor Red
    exit 1
}

$target = $null
foreach ($d in $devices) {
    if ($d -match "^192\.168\.") {
        $target = $d
        break
    }
}
if (-not $target) {
    $target = $devices[0]
}
Write-Host "  Target: $target" -ForegroundColor Green

Write-Host "[3/3] Installing APK to $target..." -ForegroundColor Cyan
adb -s $target install -r $ApkPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "Install failed!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Done! APK installed to $target" -ForegroundColor Green
Write-Host "  API: $ApiUrl" -ForegroundColor White
