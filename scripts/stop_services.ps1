# ==============================================================================
# CloudAnchor - STOP Services Script
# Safely terminates launcher-owned processes in reverse order with strict
# ownership verification without affecting unrelated applications or databases.
# ==============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

$scriptDir = $PSScriptRoot
$rootDir = (Resolve-Path "$scriptDir\..").Path
$runtimeDir = "$rootDir\.cloudanchor_runtime"
$servicesFile = "$runtimeDir\services.json"
$tunnelUrlFile = "$rootDir\tunnel_url.txt"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "          CloudAnchor: Graceful Service Shutdown          " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Check if services.json exists
if (-not (Test-Path $servicesFile)) {
    Write-Host "`n[INFO] CloudAnchor is already stopped. No active services found." -ForegroundColor Green
    
    # Clean up tunnel_url.txt if left over
    if (Test-Path $tunnelUrlFile) {
        Remove-Item $tunnelUrlFile -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared stale tunnel_url.txt." -ForegroundColor Gray
    }
    Write-Host "==========================================================" -ForegroundColor Cyan
    exit 0
}

# 2. Parse services.json
try {
    $session = Get-Content $servicesFile -Raw | ConvertFrom-Json
} catch {
    Write-Host "[WARNING] Could not parse services.json. Removing corrupt tracker file." -ForegroundColor Yellow
    Remove-Item $servicesFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $tunnelUrlFile) { Remove-Item $tunnelUrlFile -Force -ErrorAction SilentlyContinue }
    exit 0
}

Write-Host "Stopping session started at: $($session.started_at)`n" -ForegroundColor Gray
Write-Host "[STOP] Stopping tracked CloudAnchor processes..." -ForegroundColor Yellow

$shutdownFailed = $false

# Helper function to stop a process safely with strict ownership verification
function Stop-ServiceProcessStrict {
    param(
        [PSCustomObject]$Svc,
        [string]$ProjectRoot
    )

    $name = $Svc.name
    $pidToStop = [int]$Svc.pid
    $expectedToken = $Svc.expected_token
    $expectedCmd = $Svc.command

    if ($pidToStop -le 0) { return $true }

    # Check if process exists
    $proc = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "  [-] $name (PID: $pidToStop) is already stopped." -ForegroundColor DarkGray
        return $true
    }

    # Query WMI for process identity and command line
    $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $pidToStop" -ErrorAction SilentlyContinue
    if (-not $cimProc) {
        Write-Host "  [-] $name (PID: $pidToStop) is already stopped." -ForegroundColor DarkGray
        return $true
    }

    $cmdLine = $cimProc.CommandLine
    $procName = $cimProc.Name

    # STRICT PROCESS OWNERSHIP VERIFICATION:
    # Must match the expected token/command of this specific service AND project context.
    # NEVER treat any generic 'python.exe', 'node.exe', or 'cmd.exe' as safe!
    $isOwnerVerified = $false

    if ($cmdLine) {
        $hasToken = $false
        if ($expectedToken -and ($cmdLine -like "*$expectedToken*")) {
            $hasToken = $true
        }

        # Role-specific strict verification
        switch ($name) {
            "cloud_api" {
                if ($cmdLine -like "*cloud_api.main:app*" -and ($cmdLine -like "*8001*" -or $cmdLine -like "*$ProjectRoot*" -or $cmdLine -like "*cloud_final*")) {
                    $isOwnerVerified = $true
                }
            }
            "gateway" {
                if ($cmdLine -like "*backend.main:app*" -and ($cmdLine -like "*8000*" -or $cmdLine -like "*$ProjectRoot*" -or $cmdLine -like "*cloud_final*")) {
                    $isOwnerVerified = $true
                }
            }
            "frontend" {
                if (($cmdLine -like "*npm*" -and $cmdLine -like "*run dev*") -or ($cmdLine -like "*vite*")) {
                    $isOwnerVerified = $true
                }
            }
            "localtunnel" {
                if ($cmdLine -like "*localtunnel*" -and $cmdLine -like "*8000*") {
                    $isOwnerVerified = $true
                }
            }
            "telemetry_bridge" {
                if ($cmdLine -like "*tinkercad_bridge.py*" -and ($cmdLine -like "*$ProjectRoot*" -or $cmdLine -like "*CloudAnchor*" -or $cmdLine -like "*cloud_final*")) {
                    $isOwnerVerified = $true
                }
            }
            default {
                if ($hasToken -and ($cmdLine -like "*$ProjectRoot*" -or $cmdLine -like "*cloud_final*")) {
                    $isOwnerVerified = $true
                }
            }
        }
    }

    if (-not $isOwnerVerified) {
        Write-Host "  [!] PROCESS OWNERSHIP REJECTED: PID $pidToStop ($procName)" -ForegroundColor Red
        Write-Host "      Role expected : $name ($expectedCmd)" -ForegroundColor Red
        Write-Host "      Command line  : $cmdLine" -ForegroundColor Yellow
        Write-Host "      Refusing to terminate unverified process to protect unrelated applications." -ForegroundColor Red
        return $false
    }

    # Attempt graceful close first if process has an active top-level GUI window
    try {
        if ($proc.MainWindowHandle -ne 0) {
            $proc.CloseMainWindow() | Out-Null
            $proc.WaitForExit(1500) | Out-Null
        }
    } catch { }

    # Terminate the verified process tree recursively using taskkill /T /F
    try {
        & taskkill.exe /PID $pidToStop /T /F 2>&1 | Out-Null
    } catch {
        Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue
    }

    # Confirm process has stopped
    Start-Sleep -Milliseconds 300
    $stillRunning = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue
    if ($stillRunning -and -not $stillRunning.HasExited) {
        Write-Host "  [ERROR] Failed to terminate $name (PID: $pidToStop)." -ForegroundColor Red
        return $false
    }

    Write-Host "  [OK] $name (PID: $pidToStop) stopped." -ForegroundColor Green
    return $true
}

# 3. Stop processes in REVERSE order:
# 1. Telemetry bridge
# 2. LocalTunnel
# (Clear tunnel_url.txt so no new requests are forwarded)
# 3. Frontend
# 4. Fog Gateway
# 5. Cloud API

$servicesList = $session.services
if ($servicesList) {
    # 3.1 Stop bridge and localtunnel first
    $bridgeSvc = $servicesList | Where-Object { $_.name -eq "telemetry_bridge" }
    if ($bridgeSvc) {
        $res = Stop-ServiceProcessStrict -Svc $bridgeSvc -ProjectRoot $rootDir
        if (-not $res) { $shutdownFailed = $true }
    }

    $tunnelSvc = $servicesList | Where-Object { $_.name -eq "localtunnel" }
    if ($tunnelSvc) {
        $res = Stop-ServiceProcessStrict -Svc $tunnelSvc -ProjectRoot $rootDir
        if (-not $res) { $shutdownFailed = $true }
    }

    # 3.2 Clear obsolete tunnel URL immediately after bridge & tunnel stop
    Write-Host "`n[STOP] Clearing the obsolete tunnel URL..." -ForegroundColor Yellow
    if (Test-Path $tunnelUrlFile) {
        Remove-Item $tunnelUrlFile -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared $tunnelUrlFile" -ForegroundColor Green
    }

    # 3.3 Stop frontend, gateway, and cloud API in reverse order
    $remaining = $servicesList | Where-Object { $_.name -notin @("telemetry_bridge", "localtunnel") }
    $remainingReversed = @($remaining)
    [Array]::Reverse($remainingReversed)

    foreach ($svc in $remainingReversed) {
        $res = Stop-ServiceProcessStrict -Svc $svc -ProjectRoot $rootDir
        if (-not $res) { $shutdownFailed = $true }
    }
}

# 4. Preserve SQLite telemetry history & logs
Write-Host "`n[STOP] Preserving SQLite telemetry history and session logs..." -ForegroundColor Yellow
Write-Host "  SQLite databases intact: backend\gateway.db and cloud_api\cloud.db" -ForegroundColor Green
Write-Host "  Diagnostic logs retained under: .cloudanchor_runtime\logs\" -ForegroundColor Green

# 5. Check final status
if ($shutdownFailed) {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "  [ERROR] CloudAnchor shutdown was incomplete.            " -ForegroundColor Red
    Write-Host "  One or more processes could not be verified or stopped. " -ForegroundColor Red
    Write-Host "  Session metadata preserved in services.json for review. " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
}

# 6. Remove session metadata only if all verified stopped
if (Test-Path $servicesFile) {
    Remove-Item $servicesFile -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed session metadata file: services.json" -ForegroundColor Gray
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  [SUCCESS] CloudAnchor has stopped                       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
exit 0
