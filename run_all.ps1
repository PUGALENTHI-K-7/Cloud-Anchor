# CloudAnchor Startup Helper Script
Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   CloudAnchor: Fog-Assisted Resilient Gateway Startup    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$rootDir = $PSScriptRoot
if (-not $rootDir) { $rootDir = (Get-Location).Path }
$servicesFile = "$rootDir\.cloudanchor_runtime\services.json"

# Check if services were already started via START.bat / runtime tracker
if (Test-Path $servicesFile) {
    try {
        $existing = Get-Content $servicesFile -Raw | ConvertFrom-Json
        $anyRunning = $false
        if ($existing.services) {
            foreach ($s in $existing.services) {
                $p = Get-Process -Id $s.pid -ErrorAction SilentlyContinue
                if ($p -and -not $p.HasExited) {
                    $anyRunning = $true
                    break
                }
            }
        }
        if ($anyRunning) {
            Write-Host "`n[NOTE] CloudAnchor services are already running via START.bat tracker!" -ForegroundColor Yellow
            Write-Host "Active session started at: $($existing.started_at)" -ForegroundColor Yellow
            if ($existing.tunnel_url) {
                Write-Host "LocalTunnel Public URL   : $($existing.tunnel_url)" -ForegroundColor Cyan
            }
            Write-Host "Web Dashboard            : http://localhost:5173" -ForegroundColor White
            Write-Host "`nTo avoid duplicate service conflicts, use STOP.bat to stop existing services first." -ForegroundColor Yellow
            Write-Host "==========================================================" -ForegroundColor Cyan
            exit 0
        }
    } catch { }
}

# Check if ports 8000, 8001, or 5173 are already in use
Write-Host "[1/4] Checking environment ports..." -ForegroundColor Gray
$ports = @(8000, 8001, 5173)
foreach ($port in $ports) {
    $portActive = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($portActive) {
        Write-Host "WARNING: Port $port is already active. Please ensure no old uvicorn or vite tasks are running." -ForegroundColor Yellow
    }
}

# 1. Launch Cloud API
Write-Host "[2/4] Launching Simulated Cloud API (Port 8001)..." -ForegroundColor Green
Start-Process powershell -WorkingDirectory $rootDir -ArgumentList "-NoExit", "-Command", "`$Host.UI.RawUI.WindowTitle = 'CloudAnchor - Simulated Cloud API (Port 8001)'; python -m uvicorn cloud_api.main:app --host 127.0.0.1 --port 8001"

# 2. Launch Gateway Backend
Write-Host "[3/4] Launching Fog Gateway Backend (Port 8000)..." -ForegroundColor Green
Start-Process powershell -WorkingDirectory $rootDir -ArgumentList "-NoExit", "-Command", "`$Host.UI.RawUI.WindowTitle = 'CloudAnchor - Fog Gateway Backend (Port 8000)'; python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000"

# 3. Launch React Frontend
Write-Host "[4/4] Launching React Dev Server (Port 5173)..." -ForegroundColor Green
Start-Process powershell -WorkingDirectory "$rootDir\frontend" -ArgumentList "-NoExit", "-Command", "`$Host.UI.RawUI.WindowTitle = 'CloudAnchor - React Frontend (Port 5173)'; npm run dev"

Write-Host "----------------------------------------------------------" -ForegroundColor Gray
Write-Host "All processes spawned successfully!" -ForegroundColor Cyan
Write-Host "Tip: You can also use START.bat and STOP.bat for automated LocalTunnel detection & tracking." -ForegroundColor Gray
Write-Host "Please wait a moment for the build process, then open:" -ForegroundColor Gray
Write-Host ">>> http://localhost:5173 <<<" -ForegroundColor Yellow -NoNewline
Write-Host " in your web browser." -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan
