@echo off
setlocal enabledelayedexpansion

title SKODA Manual Downloader

echo.
echo ====================================================
echo       SKODA Manual Downloader
echo ====================================================
echo.

REM --- Check that PowerShell is available ---
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell is not installed or not found in PATH.
    echo.
    echo Please install PowerShell 5.1 or later:
    echo   https://aka.ms/powershell
    echo.
    pause
    exit /b 1
)

REM --- Check PowerShell version (5.1 minimum) ---
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul`) do (
    set "PS_MAJOR=%%v"
)

if not defined PS_MAJOR (
    echo WARNING: Could not determine PowerShell version. Proceeding anyway...
    goto :run
)

if %PS_MAJOR% LSS 5 (
    echo ERROR: PowerShell %PS_MAJOR%.x is installed, but version 5.1 or higher is required.
    echo.
    echo Please update PowerShell:
    echo   https://aka.ms/powershell
    echo.
    pause
    exit /b 1
)

:run
REM --- Check that skoda.ps1 exists next to this bat file ---
if not exist "%~dp0skoda.ps1" (
    echo ERROR: skoda.ps1 not found in the same folder as this script.
    echo Expected: %~dp0skoda.ps1
    echo.
    pause
    exit /b 1
)

REM --- Run skoda.ps1 ---
REM -ExecutionPolicy Bypass allows the script to run even when the system
REM policy would otherwise block unsigned/local scripts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0skoda.ps1" %*

set EXIT_CODE=%errorlevel%
if %EXIT_CODE% neq 0 (
    echo.
    echo Script exited with error code %EXIT_CODE%.
    echo.
    pause
)

endlocal
