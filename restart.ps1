$ErrorActionPreference = "Continue"
$ProjectRoot = "D:\REINs\Documents\GZUS-PRO"
$FlutterBin = "D:\REINs\Documents\flutter\bin\flutter.bat"

Write-Host "[1/4] Stopping existing processes..." -ForegroundColor Cyan

$port8000 = netstat -ano | Select-String ":8000\s.*LISTENING"
if ($port8000) {
    $pid8000 = ($port8000 -split '\s+')[-1]
    Write-Host "  Killing backend (PID $pid8000)..." -ForegroundColor Yellow
    Stop-Process -Id $pid8000 -Force -ErrorAction SilentlyContinue
}

Get-Process -Name dart,dartvm,dartaotruntime -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Killing $($_.ProcessName) (PID $($_.Id))..." -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 2

Write-Host "[2/4] Starting backend (uvicorn --reload-dir app --host 0.0.0.0)..." -ForegroundColor Cyan
Start-Process PowerShell -ArgumentList "-NoExit", "-Command", "cd '$ProjectRoot\services\api'; .\.venv\Scripts\Activate.ps1; uvicorn app.main:app --reload --reload-dir app --reload-exclude .venv --host 0.0.0.0"
Write-Host "  Backend started in new window." -ForegroundColor Green

Start-Sleep -Seconds 3

Write-Host "[3/4] Starting frontend (Flutter Web Chrome)..." -ForegroundColor Cyan
Start-Process PowerShell -ArgumentList "-NoExit", "-Command", "cd '$ProjectRoot\apps\mobile_web'; $FlutterBin run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000"
Write-Host "  Frontend started in new window." -ForegroundColor Green

Write-Host "[4/4] Done!" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Backend:  http://0.0.0.0:8000" -ForegroundColor White
Write-Host "  Frontend: Chrome debug mode" -ForegroundColor White
