# ==============================================================================
# CloudAnchor - START Services Script
# Launches Fog Gateway, Cloud API, LocalTunnel (with auto-URL detection),
# Frontend dashboard, and the Tinkercad Telemetry Bridge.
# Background services are spawned with WindowStyle Hidden so they survive when
# the launcher window is closed.
# ==============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# 1. Resolve Project Root dynamically
$scriptDir = $PSScriptRoot
$rootDir = (Resolve-Path "$scriptDir\..").Path
$runtimeDir = "$rootDir\.cloudanchor_runtime"
$logsDir = "$runtimeDir\logs"
$servicesFile = "$runtimeDir\services.json"
$tunnelUrlFile = "$rootDir\tunnel_url.txt"

if (-not (Test-Path $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       CloudAnchor: Automated Resilient Gateway Launcher   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Project Root: $rootDir" -ForegroundColor Gray
Write-Host "Runtime Dir : $runtimeDir" -ForegroundColor Gray
Write-Host "Logs Dir    : $logsDir" -ForegroundColor Gray
Write-Host ""

# ------------------------------------------------------------------------------
# STEP 1: Check Project Configuration & Dependencies
# ------------------------------------------------------------------------------
Write-Host "[START] Checking project configuration..." -ForegroundColor Yellow

$gatewayFile = "$rootDir\backend\main.py"
$cloudFile   = "$rootDir\cloud_api\main.py"
$bridgeFile  = "$rootDir\tinkercad\tinkercad_bridge.py"

foreach ($f in @($gatewayFile, $cloudFile, $bridgeFile)) {
    if (-not (Test-Path $f)) {
        Write-Host "[ERROR] Required source file missing: $f" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  Project Source Files: Verified" -ForegroundColor Green

Write-Host "[START] Checking required dependencies..." -ForegroundColor Yellow

$pythonExe = $null
$venvPython = "$rootDir\.venv\Scripts\python.exe"
if (Test-Path $venvPython) {
    $pythonExe = $venvPython
    Write-Host "  Using Python Virtual Environment: $pythonExe" -ForegroundColor Green
} else {
    $sysPython = Get-Command python -ErrorAction SilentlyContinue
    if ($sysPython) {
        $pythonExe = "python"
        $pyVer = & python --version 2>&1
        Write-Host "  Using System Python: $pyVer" -ForegroundColor Green
    } else {
        Write-Host "`n[FATAL ERROR] Python is not installed or not in PATH." -ForegroundColor Red
        Write-Host "Please install Python 3.10+ from https://python.org and add it to your PATH." -ForegroundColor Red
        exit 1
    }
}

$depCheckCmd = "$pythonExe -c ""import fastapi, uvicorn, pydantic, requests; print('OK')"""
$depCheck = Invoke-Expression $depCheckCmd 2>&1
if ($depCheck -ne "OK") {
    Write-Host "`n[FATAL ERROR] Missing required Python packages." -ForegroundColor Red
    Write-Host "Details: $depCheck" -ForegroundColor Red
    Write-Host "Please install required packages by running:" -ForegroundColor Yellow
    Write-Host "  $pythonExe -m pip install -r `"$rootDir\requirements.txt`"" -ForegroundColor Cyan
    exit 1
}
Write-Host "  Python dependencies: Verified (FastAPI, Uvicorn, Pydantic, Requests)" -ForegroundColor Green

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue
if (-not $npxCmd) { $npxCmd = Get-Command npx -ErrorAction SilentlyContinue }
if (-not $nodeCmd -or -not $npxCmd) {
    Write-Host "`n[FATAL ERROR] Node.js and npx are required for LocalTunnel." -ForegroundColor Red
    Write-Host "Please install Node.js (v18+) from https://nodejs.org and verify 'npx' is available." -ForegroundColor Red
    exit 1
}
$nodeVer = & node --version 2>&1
Write-Host "  Node.js / npx       : Verified ($nodeVer)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 2: Duplicate Prevention & Port Conflict Protection
# ------------------------------------------------------------------------------
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
            Write-Host "`n[WARNING] CloudAnchor is already running!" -ForegroundColor Yellow
            Write-Host "Active session started at: $($existing.started_at)" -ForegroundColor Yellow
            if ($existing.tunnel_url) {
                Write-Host "Active LocalTunnel URL   : $($existing.tunnel_url)" -ForegroundColor Cyan
            }
            Write-Host "`nTo restart, please run STOP.bat first to terminate running processes safely." -ForegroundColor Yellow
            exit 0
        } else {
            Remove-Item $servicesFile -Force -ErrorAction SilentlyContinue
            Write-Host "  Cleared stale session metadata (previous processes exited)" -ForegroundColor Gray
        }
    } catch { }
}

# Verify Port 8000 (Fog Gateway)
$occupied8000 = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
if ($occupied8000) {
    $procId = $occupied8000[0].OwningProcess
    $isGateway = $false
    try {
        $probe = Invoke-WebRequest -Uri "http://127.0.0.1:8000/openapi.json" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($probe.StatusCode -eq 200 -and $probe.Content -like "*CloudAnchor*") { $isGateway = $true }
    } catch { }

    if (-not $isGateway) {
        Write-Host "`n[ERROR] Port 8000 is occupied by an unrelated process (PID: $procId)." -ForegroundColor Red
        Write-Host "Please close that application or change its port before running CloudAnchor." -ForegroundColor Red
        Write-Host "CloudAnchor will NOT terminate unrelated processes." -ForegroundColor Red
        exit 1
    }
}

# Verify Port 8001 (Cloud API)
$occupied8001 = Get-NetTCPConnection -LocalPort 8001 -State Listen -ErrorAction SilentlyContinue
if ($occupied8001) {
    $procId = $occupied8001[0].OwningProcess
    $isCloud = $false
    try {
        $probe = Invoke-WebRequest -Uri "http://127.0.0.1:8001/openapi.json" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($probe.StatusCode -eq 200 -and $probe.Content -like "*CloudAnchor*") { $isCloud = $true }
    } catch { }

    if (-not $isCloud) {
        Write-Host "`n[ERROR] Port 8001 is occupied by an unrelated process (PID: $procId)." -ForegroundColor Red
        Write-Host "Please close that application or change its port before running CloudAnchor." -ForegroundColor Red
        Write-Host "CloudAnchor will NOT terminate unrelated processes." -ForegroundColor Red
        exit 1
    }
}

# Verify Port 5173 (React Frontend)
$occupied5173 = Get-NetTCPConnection -LocalPort 5173 -State Listen -ErrorAction SilentlyContinue
if ($occupied5173) {
    $procId = $occupied5173[0].OwningProcess
    $isFrontend = $false
    try {
        $probe = Invoke-WebRequest -Uri "http://localhost:5173/" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($probe.StatusCode -eq 200 -and ($probe.Content -like "*CloudAnchor*" -or $probe.Content -like "*vite*")) { $isFrontend = $true }
    } catch { }

    if (-not $isFrontend) {
        Write-Host "`n[ERROR] Port 5173 is occupied by an unrelated process (PID: $procId)." -ForegroundColor Red
        Write-Host "Please close that application or change its port before running CloudAnchor." -ForegroundColor Red
        Write-Host "CloudAnchor will NOT terminate unrelated processes." -ForegroundColor Red
        exit 1
    }
}

Write-Host "  Port Availability   : Verified (8000, 8001, 5173 clean)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 3: Invalidate Stale URL & Prepare Session Logs
# ------------------------------------------------------------------------------
if (Test-Path $tunnelUrlFile) {
    Remove-Item $tunnelUrlFile -Force -ErrorAction SilentlyContinue
    Write-Host "  Cleared stale tunnel_url.txt" -ForegroundColor Gray
}

$gatewayOut   = "$logsDir\gateway.log"
$gatewayErr   = "$logsDir\gateway_err.log"
$cloudOut     = "$logsDir\cloud_api.log"
$cloudErr     = "$logsDir\cloud_api_err.log"
$tunnelOut    = "$logsDir\tunnel.log"
$tunnelErr    = "$logsDir\tunnel_err.log"
$frontendOut  = "$logsDir\frontend.log"
$frontendErr  = "$logsDir\frontend_err.log"

foreach ($l in @($gatewayOut, $gatewayErr, $cloudOut, $cloudErr, $tunnelOut, $tunnelErr, $frontendOut, $frontendErr)) {
    if (Test-Path $l) { Remove-Item $l -Force -ErrorAction SilentlyContinue }
}

$spawnedServices = [System.Collections.Generic.List[PSCustomObject]]::new()

function Abort-Startup {
    param([string]$Reason)
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "  STARTUP FAILED: $Reason" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "Safely terminating services started during this attempt..." -ForegroundColor Yellow

    if (Test-Path $tunnelUrlFile) {
        Remove-Item $tunnelUrlFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $servicesFile) {
        Remove-Item $servicesFile -Force -ErrorAction SilentlyContinue
    }

    for ($i = $spawnedServices.Count - 1; $i -ge 0; $i--) {
        $svc = $spawnedServices[$i]
        Write-Host "  Stopping $($svc.name) (PID: $($svc.pid))..." -ForegroundColor Gray
        try {
            & taskkill.exe /PID $svc.pid /T /F 2>&1 | Out-Null
        } catch { }
    }

    Write-Host "Cleanup completed. Local database and source files are untouched." -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------------------------------------------
# STEP 4: Start Cloud API & Fog Gateway
# ------------------------------------------------------------------------------
Write-Host "`n[START] Starting Cloud API on port 8001..." -NoNewline

$cloudProc = Start-Process -FilePath $pythonExe `
    -ArgumentList "-m uvicorn cloud_api.main:app --host 127.0.0.1 --port 8001" `
    -WorkingDirectory $rootDir `
    -RedirectStandardOutput $cloudOut `
    -RedirectStandardError $cloudErr `
    -WindowStyle Hidden `
    -PassThru

$spawnedServices.Add([PSCustomObject]@{
    name            = "cloud_api"
    pid             = $cloudProc.Id
    command         = "uvicorn cloud_api.main:app --port 8001"
    executable      = $pythonExe
    project_root    = $rootDir
    port            = 8001
    log_file        = $cloudOut
    expected_token  = "cloud_api.main:app"
})

$cloudReady = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8001/health" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $cloudReady = $true; break }
    } catch {
        try {
            $r2 = Invoke-WebRequest -Uri "http://127.0.0.1:8001/control" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
            if ($r2.StatusCode -eq 200) { $cloudReady = $true; break }
        } catch { }
    }
}

if (-not $cloudReady) {
    Write-Host " FAILED!" -ForegroundColor Red
    if (Test-Path $cloudErr) { Get-Content $cloudErr -Tail 15 }
    Abort-Startup "Cloud API failed to become ready on http://127.0.0.1:8001"
}
Write-Host " READY (HTTP 200)" -ForegroundColor Green

Write-Host "[START] Starting Fog Gateway on port 8000..." -NoNewline

$gwProc = Start-Process -FilePath $pythonExe `
    -ArgumentList "-m uvicorn backend.main:app --host 127.0.0.1 --port 8000" `
    -WorkingDirectory $rootDir `
    -RedirectStandardOutput $gatewayOut `
    -RedirectStandardError $gatewayErr `
    -WindowStyle Hidden `
    -PassThru

$spawnedServices.Add([PSCustomObject]@{
    name            = "gateway"
    pid             = $gwProc.Id
    command         = "uvicorn backend.main:app --port 8000"
    executable      = $pythonExe
    project_root    = $rootDir
    port            = 8000
    log_file        = $gatewayOut
    expected_token  = "backend.main:app"
})

$gwReady = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8000/health" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $gwReady = $true; break }
    } catch {
        try {
            $r2 = Invoke-WebRequest -Uri "http://127.0.0.1:8000/openapi.json" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
            if ($r2.StatusCode -eq 200) { $gwReady = $true; break }
        } catch { }
    }
}

if (-not $gwReady) {
    Write-Host " FAILED!" -ForegroundColor Red
    if (Test-Path $gatewayErr) { Get-Content $gatewayErr -Tail 15 }
    Abort-Startup "Fog Gateway failed to become ready on http://127.0.0.1:8000"
}
Write-Host " READY (HTTP 200)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 5: Start React Frontend (Port 5173) if present
# ------------------------------------------------------------------------------
$frontendPkg = "$rootDir\frontend\package.json"
if (Test-Path $frontendPkg) {
    Write-Host "[START] Starting frontend on port 5173..." -NoNewline

    $feProc = Start-Process -FilePath "npm.cmd" `
        -ArgumentList "run dev -- --host" `
        -WorkingDirectory "$rootDir\frontend" `
        -RedirectStandardOutput $frontendOut `
        -RedirectStandardError $frontendErr `
        -WindowStyle Hidden `
        -PassThru

    $spawnedServices.Add([PSCustomObject]@{
        name            = "frontend"
        pid             = $feProc.Id
        command         = "npm run dev -- --host"
        executable      = "npm.cmd"
        project_root    = $rootDir
        port            = 5173
        log_file        = $frontendOut
        expected_token  = "frontend"
    })

    $feReady = $false
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:5173/" -UseBasicParsing -TimeoutSec 1 -ErrorAction SilentlyContinue
            if ($r.StatusCode -eq 200) { $feReady = $true; break }
        } catch { }
    }

    if ($feReady) {
        Write-Host " READY (http://localhost:5173/)" -ForegroundColor Green
    } else {
        Write-Host " STARTING (will be ready shortly)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[START] Frontend directory not present. Skipping UI dashboard." -ForegroundColor Gray
}

# ------------------------------------------------------------------------------
# STEP 6: Start LocalTunnel & Detect Public URL
# ------------------------------------------------------------------------------
Write-Host "`n[START] Establishing LocalTunnel for Fog Gateway (Port 8000)..." -ForegroundColor Yellow

$tunnelPsi = New-Object System.Diagnostics.ProcessStartInfo
$tunnelPsi.FileName = "cmd.exe"
$tunnelPsi.Arguments = "/c npx --yes localtunnel --port 8000 > `"$tunnelOut`" 2>&1"
$tunnelPsi.WorkingDirectory = $rootDir
$tunnelPsi.UseShellExecute = $false
$tunnelPsi.CreateNoWindow = $true
$tunnelProc = [System.Diagnostics.Process]::Start($tunnelPsi)

$spawnedServices.Add([PSCustomObject]@{
    name            = "localtunnel"
    pid             = $tunnelProc.Id
    command         = "npx localtunnel --port 8000"
    executable      = "cmd.exe"
    project_root    = $rootDir
    port            = 8000
    log_file        = $tunnelOut
    expected_token  = "localtunnel"
})

Write-Host "  Awaiting public HTTPS tunnel assignment (up to 60s)..." -ForegroundColor Gray

$detectedUrl = $null
$tunnelTimeoutSeconds = 60

for ($i = 1; $i -le $tunnelTimeoutSeconds; $i++) {
    Start-Sleep -Seconds 1
    Write-Host -NoNewline "."

    if (Test-Path $tunnelOut) {
        $content = Get-Content $tunnelOut -Raw -ErrorAction SilentlyContinue
        if ($content) {
            if ($content -match 'https://[a-zA-Z0-9.-]+\.loca\.lt') {
                $detectedUrl = $matches[0].Trim().TrimEnd('/')
                break
            }
            if ($content -match 'your url is:\s*(https://[^\s\r\n]+)') {
                $detectedUrl = $matches[1].Trim().TrimEnd('/')
                break
            }
            if ($content -match 'Error:|ECONNREFUSED|ENOTFOUND') {
                Write-Host "`n  [ERROR] Tunnel reported error: $content" -ForegroundColor Red
                break
            }
        }
    }

    if ($tunnelProc.HasExited) {
        Write-Host "`n  [ERROR] LocalTunnel process exited unexpectedly with code $($tunnelProc.ExitCode)" -ForegroundColor Red
        break
    }
}

Write-Host ""

if (-not $detectedUrl -or -not ($detectedUrl.ToLower().StartsWith("https://"))) {
    Write-Host "`n[ERROR] LocalTunnel did not become ready." -ForegroundColor Red
    if (Test-Path $tunnelOut) {
        Write-Host "LocalTunnel output was:" -ForegroundColor Yellow
        Get-Content $tunnelOut -Tail 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
    Abort-Startup "LocalTunnel did not output a valid HTTPS URL within $tunnelTimeoutSeconds seconds."
}

Write-Host "  Tunnel URL Assigned: $detectedUrl" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 7: Validate Current Tunnel URL via Public Reachability Probe (FAIL CLOSED)
# ------------------------------------------------------------------------------
Write-Host "[START] Validating current tunnel URL reachability..." -NoNewline

$reachVerified = $false
for ($attempt = 1; $attempt -le 10; $attempt++) {
    try {
        $reachProbe = Invoke-WebRequest -Uri "$detectedUrl/openapi.json" `
            -Headers @{"bypass-tunnel-reminder"="true"; "User-Agent"="CloudAnchorStartupCheck/1.0"} `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($reachProbe.StatusCode -eq 200 -and $reachProbe.Content -like "*CloudAnchor*") {
            $reachVerified = $true
            break
        }
    } catch { }
    Start-Sleep -Seconds 3
}

# FAIL CLOSED: If public reachability cannot be verified, abort immediately!
if (-not $reachVerified) {
    Write-Host " FAILED!" -ForegroundColor Red
    Write-Host "`n[ERROR] LocalTunnel endpoint '$detectedUrl' failed public reachability verification." -ForegroundColor Red
    Write-Host "        Aborting startup to prevent saving an unverified endpoint or launching the bridge." -ForegroundColor Red
    Abort-Startup "Public LocalTunnel endpoint failed reachability check after 10 attempts."
}

Write-Host " VERIFIED (HTTP 200 Reachable)" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 8: Save Base URL to tunnel_url.txt
# ------------------------------------------------------------------------------
Write-Host "[START] Saving tunnel_url.txt..." -ForegroundColor Yellow
[System.IO.File]::WriteAllText($tunnelUrlFile, $detectedUrl, [System.Text.UTF8Encoding]::new($false))
Write-Host "  Saved active base URL to: $tunnelUrlFile" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 9: Launch Tinkercad Telemetry Bridge
# ------------------------------------------------------------------------------
Write-Host "[START] Launching telemetry bridge..." -ForegroundColor Yellow

$bridgePsi = New-Object System.Diagnostics.ProcessStartInfo
$bridgePsi.FileName = "cmd.exe"
$bridgePsi.Arguments = "/c title CloudAnchor - Tinkercad Telemetry Bridge & `"$pythonExe`" tinkercad\tinkercad_bridge.py"
$bridgePsi.WorkingDirectory = $rootDir
$bridgePsi.UseShellExecute = $true
$bridgeProc = [System.Diagnostics.Process]::Start($bridgePsi)

$spawnedServices.Add([PSCustomObject]@{
    name            = "telemetry_bridge"
    pid             = $bridgeProc.Id
    command         = "tinkercad_bridge.py"
    executable      = "cmd.exe"
    project_root    = $rootDir
    log_file        = "interactive_window"
    expected_token  = "tinkercad_bridge.py"
})

Write-Host "  Telemetry bridge launched in dedicated interactive console window (PID: $($bridgeProc.Id))" -ForegroundColor Green

# ------------------------------------------------------------------------------
# Record Services Metadata to services.json
# ------------------------------------------------------------------------------
$metadata = [PSCustomObject]@{
    session_id   = (Get-Date -Format "yyyyMMdd-HHmmss")
    started_at   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    project_root = $rootDir
    tunnel_url   = $detectedUrl
    services     = $spawnedServices
}

$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path $servicesFile -Encoding utf8 -Force

# ------------------------------------------------------------------------------
# Summary Output
# ------------------------------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  [SUCCESS] Required services are healthy and ONLINE      " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Fog Gateway (Local)    : http://127.0.0.1:8000" -ForegroundColor White
Write-Host "  Simulated Cloud API    : http://127.0.0.1:8001" -ForegroundColor White
Write-Host "  Web Dashboard          : http://localhost:5173" -ForegroundColor White
Write-Host "  Public LocalTunnel URL : $detectedUrl" -ForegroundColor Cyan
Write-Host "  Public Ingest Endpoint : $detectedUrl/api/ingest" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "How to use:" -ForegroundColor Yellow
Write-Host " 1. Use the interactive 'CloudAnchor - Tinkercad Telemetry Bridge' window." -ForegroundColor White
Write-Host " 2. Paste Arduino JSON telemetry strings directly from Tinkercad Serial Monitor." -ForegroundColor White
Write-Host " 3. Monitor live resilience & synchronization at: http://localhost:5173" -ForegroundColor White
Write-Host " 4. When finished, double-click STOP.bat to shut down cleanly." -ForegroundColor White
Write-Host "==========================================================`n" -ForegroundColor Green
