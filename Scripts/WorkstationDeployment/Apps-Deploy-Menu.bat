@echo off
:: --- rww-installers workstation deployment menu ---
:: Double-click entry point for USB sticks / the network deployment share.
:: Opens a GUI checkbox menu (Windows Forms) -- requires -STA below.
:: This is a separate project from the older ConnectWise Automate scripting
:: in this repo -- left alone for now, may be revisited later.
::
:: This file always downloads the current Apps-Deploy-Menu.ps1 from GitHub
:: and runs it elevated, so the menu on a USB/share is never stale. Do not
:: edit menu/install logic here -- that lives in the repo.

:: --- Elevate if needed ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

setlocal
set "REPO_OWNER=randysworldwide"
set "REPO_NAME=rww-installers"
set "BRANCH=main"
set "REPO_PATH=Scripts/WorkstationDeployment/Apps-Deploy-Menu.ps1"
set "LOCAL_DIR=%ProgramData%\Dev\AppsDeploy"
set "LOCAL_PATH=%LOCAL_DIR%\Apps-Deploy-Menu.ps1"

if not exist "%LOCAL_DIR%" mkdir "%LOCAL_DIR%" >nul 2>&1

echo.
echo Downloading the current deployment menu from GitHub...
powershell -NoProfile -Command ^
  "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/%REPO_OWNER%/%REPO_NAME%/%BRANCH%/%REPO_PATH%' -OutFile '%LOCAL_PATH%' -UseBasicParsing } catch { Write-Host '[ERROR] Failed to download menu script:' $_.Exception.Message; exit 5 }"

if errorlevel 1 (
    echo.
    echo [ERROR] Could not download the deployment menu.
    echo Check that this machine can reach raw.githubusercontent.com and that
    echo the TLS inspection proxy's root cert is trusted on this machine.
    echo.
    pause
    exit /b 5
)

powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%LOCAL_PATH%"
set "EXITCODE=%errorlevel%"

echo.
echo Deployment menu finished with exit code %EXITCODE%.
pause
endlocal
exit /b %EXITCODE%
