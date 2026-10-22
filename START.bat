@echo off
setlocal EnableExtensions
title CloudAnchor - Service Launcher

:: 1. Dynamically resolve project root from script directory
set "PROJECT_ROOT=%~dp0"
if "%PROJECT_ROOT:~-1%"=="\" set "PROJECT_ROOT=%PROJECT_ROOT:~0,-1%"

cd /d "%PROJECT_ROOT%"
if errorlevel 1 (
    echo ==========================================================
    echo [ERROR] Failed to navigate to project directory:
    echo   %PROJECT_ROOT%
    echo ==========================================================
    pause
    exit /b 1
)

echo ==========================================================
echo Starting CloudAnchor via START.bat...
echo Project directory: %PROJECT_ROOT%
echo ==========================================================
echo.

:: 2. Verify that scripts\start_services.ps1 exists before executing
set "START_SCRIPT=%PROJECT_ROOT%\scripts\start_services.ps1"
if not exist "%START_SCRIPT%" (
    echo ==========================================================
    echo [ERROR] Required startup script missing!
    echo   Expected file: %START_SCRIPT%
    echo.
    echo Expected folder structure:
    echo   %PROJECT_ROOT%\
    echo     START.bat
    echo     STOP.bat
    echo     backend\
    echo     cloud_api\
    echo     frontend\
    echo     scripts\
    echo       start_services.ps1
    echo       stop_services.ps1
    echo     tinkercad\
    echo ==========================================================
    echo.
    pause
    exit /b 1
)

:: 3. Execute startup script and propagate exact exit code
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%START_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% neq 0 (
    echo.
    echo ==========================================================
    echo [ERROR] CloudAnchor startup failed with exit code %EXIT_CODE%.
    echo Please review the diagnostic messages above.
    echo ==========================================================
    echo.
    pause
    exit /b %EXIT_CODE%
)

if "%1"=="--no-pause" goto finish
echo.
echo Press any key to close this launcher window (services will remain running in background).
pause >nul
:finish
endlocal & exit /b 0
