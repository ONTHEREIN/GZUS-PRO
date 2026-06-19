$ErrorActionPreference = "Continue"
$ProjectRoot = "D:\REINs\Documents\GZUS-PRO"
$FlutterBin = "D:\REINs\Documents\flutter\bin\flutter.bat"
$BackendUrl = "http://127.0.0.1:8000"

function Stop-PortListeners {
    param([int]$Port)
    $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    $listenerProcessIds = $connections | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($processId in $listenerProcessIds) {
        if ($processId -and $processId -ne $PID) {
            Write-Host "  Killing port $Port listener (PID $processId)..." -ForegroundColor Yellow
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Wait-BackendHealth {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 45
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri "$Url/health" -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return $true
            }
        } catch {
            Start-Sleep -Milliseconds 700
        }
    }
    return $false
}

Write-Host "[1/4] Stopping existing processes..." -ForegroundColor Cyan

Stop-PortListeners -Port 8000

Get-Process -Name dart,dartvm,dartaotruntime -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  Killing $($_.ProcessName) (PID $($_.Id))..." -ForegroundColor Yellow
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 2

Write-Host "[2/4] Starting backend (uvicorn --reload-dir app --host 0.0.0.0)..." -ForegroundColor Cyan
Start-Process PowerShell -ArgumentList "-NoExit", "-Command", "cd '$ProjectRoot\services\api'; .\.venv\Scripts\Activate.ps1; uvicorn app.main:app --reload --reload-dir app --reload-exclude .venv --host 0.0.0.0"
Write-Host "  Backend started in new window." -ForegroundColor Green

Write-Host "  Waiting for backend health..." -ForegroundColor Cyan
if (-not (Wait-BackendHealth -Url $BackendUrl)) {
    Write-Host "  Backend health check timed out: $BackendUrl/health" -ForegroundColor Red
    Write-Host "  Frontend will not start until the API is reachable." -ForegroundColor Red
    exit 1
}
Write-Host "  Backend healthy: $BackendUrl/health" -ForegroundColor Green

Write-Host "[3/4] Starting frontend (Flutter Web Chrome)..." -ForegroundColor Cyan
Start-Process PowerShell -ArgumentList "-NoExit", "-Command", "cd '$ProjectRoot\apps\mobile_web'; $FlutterBin run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000"
Write-Host "  Frontend started in new window." -ForegroundColor Green

Write-Host "[4/4] Done!" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Backend:  http://0.0.0.0:8000" -ForegroundColor White
Write-Host "  Frontend: Chrome debug mode" -ForegroundColor White
