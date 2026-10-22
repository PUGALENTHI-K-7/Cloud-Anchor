@echo off
setlocal EnableExtensions
title CloudAnchor - Service Stopper

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
echo Stopping CloudAnchor via STOP.bat...
echo Project directory: %PROJECT_ROOT%
echo ==========================================================
echo.

:: 2. Verify that scripts\stop_services.ps1 exists before invoking
set "STOP_SCRIPT=%PROJECT_ROOT%\scripts\stop_services.ps1"
if not exist "%STOP_SCRIPT%" (
    echo ==========================================================
    echo [ERROR] Required shutdown script missing!
    echo   Expected file: %STOP_SCRIPT%
    echo.
    echo Expected folder structure:
    echo   %PROJECT_ROOT%\
    echo     START.bat
    echo     STOP.bat
    echo     scripts\
    echo       stop_services.ps1
    echo ==========================================================
    echo.
    pause
    exit /b 1
)

:: 3. Execute shutdown script and propagate exact exit code
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%STOP_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% neq 0 (
    echo.
    echo ==========================================================
    echo [WARNING] Shutdown finished with exit code %EXIT_CODE%.
    echo One or more services could not be stopped.
    echo ==========================================================
    echo.
    pause
    exit /b %EXIT_CODE%
)

if "%1"=="--no-pause" goto finish
echo.
pause
:finish
endlocal & exit /b 0
