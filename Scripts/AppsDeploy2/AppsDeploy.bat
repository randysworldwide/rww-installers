@echo off
REM =====================================================================
REM  RWW Apps Deploy v2 -- PRODUCTION launcher
REM  Downloads the latest UI/worker/manifest from the rww-installers
REM  repo (main branch) into %TEMP%\RWW-AppsDeploy\ and runs from
REM  there, so every machine always runs the current repo version and
REM  Windows' own temp cleanup clears the copies when no longer needed
REM  (logs and the Stage cache still persist under ProgramData\RWW).
REM  Works as the lone file in the Automate Toolbox: the Toolbox only
REM  delivers this .bat, and everything else comes from GitHub.
REM  If a download fails but a previously-downloaded copy exists, it
REM  runs that copy and says so (deliberate: a GitHub blip should not
REM  brick the tool in the field).
REM  For local development use AppsDeploy-Test.bat instead -- it runs
REM  the files in its own folder and never downloads anything.
REM =====================================================================
setlocal
set "BASEURL=https://raw.githubusercontent.com/randysworldwide/rww-installers/main/Scripts/AppsDeploy2"
set "APPDIR=%TEMP%\RWW-AppsDeploy"

REM Strip the Mark-of-the-Web from this launcher's folder so the Open
REM File security warning cannot fire a second time on the elevation
REM relaunch below.
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting elevation...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%APPDIR%" mkdir "%APPDIR%"

echo Fetching the latest Apps Deploy from GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ok = $true;" ^
  "foreach ($f in 'AppsDeploy-UI.ps1','AppsDeploy-Worker.ps1','AppsDeploy-Manifest.ps1') {" ^
  "  try { Invoke-WebRequest -Uri ('%BASEURL%/' + $f) -OutFile (Join-Path '%APPDIR%' ($f + '.new')) -UseBasicParsing -ErrorAction Stop }" ^
  "  catch { Write-Host ('  Download failed for ' + $f + ': ' + $_.Exception.Message); $ok = $false; break } };" ^
  "if ($ok) { foreach ($f in 'AppsDeploy-UI.ps1','AppsDeploy-Worker.ps1','AppsDeploy-Manifest.ps1') { Move-Item -LiteralPath (Join-Path '%APPDIR%' ($f + '.new')) -Destination (Join-Path '%APPDIR%' $f) -Force } ; exit 0 } else { exit 1 }"

if %errorlevel% neq 0 (
    if exist "%APPDIR%\AppsDeploy-UI.ps1" (
        echo.
        echo WARNING: could not fetch the latest version -- running the
        echo previously downloaded copy in %APPDIR% instead.
        echo.
    ) else (
        echo.
        echo ERROR: could not download Apps Deploy and no previous copy
        echo exists on this machine.
        if exist "%~dp0AppsDeploy-UI.ps1" (
            echo.
            echo NOTE: local copies of the .ps1 files are sitting right next
            echo to this launcher. If you meant to run those -- local testing,
            echo or the files are not on GitHub yet -- use AppsDeploy-Test.bat
            echo instead: this launcher ALWAYS runs the GitHub version.
        ) else (
            echo Check network access to raw.githubusercontent.com and try again.
        )
        pause
        exit /b 2
    )
)

powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%APPDIR%\AppsDeploy-UI.ps1"
endlocal
