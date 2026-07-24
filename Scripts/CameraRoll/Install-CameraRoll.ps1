# Install-CameraRoll.ps1
# Idempotent bootstrapper for the Camera Roll tablet deployment.
# Deploys SetCameraRoll.ps1 and SyncCameraRoll.ps1 to C:\ProgramData\Dev\CameraRoll and
# registers the SetCameraRoll scheduled task (logon trigger, SYSTEM).
#
# The per-user sync task (CameraRoll-Sync-User) is NOT created here - it is
# registered dynamically by SetCameraRoll.ps1 itself every time a user logs
# on, so it always runs as whoever is currently signed in on the tablet.
#
# Safe to re-run: overwrites payload files with the latest version from
# GitHub and re-registers the scheduled task if it already exists.
# Emits an [ERROR]-tagged line on any failure for Automate's
# IF Variable Check step, and writes progress to the console (captured by
# Automate) as well as C:\ProgramData\Dev\CameraRoll\Install-CameraRoll.log.

$ErrorActionPreference = 'Stop'
$logFile   = "C:\ProgramData\Dev\CameraRoll\Install-CameraRoll.log"
$scriptDir = "C:\ProgramData\Dev\CameraRoll"
$repoBase  = "https://raw.githubusercontent.com/randysworldwide/rww-installers/main/Scripts/CameraRoll"

$files = @(
    "SetCameraRoll.ps1",
    "SyncCameraRoll.ps1"
)

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $msg"
    $line | Out-File -FilePath $logFile -Append
    Write-Output $line
}

if (-not (Test-Path "C:\ProgramData\Dev\CameraRoll")) { New-Item -Path "C:\ProgramData\Dev\CameraRoll" -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $scriptDir)) { New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null }

Log "=== Camera Roll install started ==="

try {
    foreach ($file in $files) {
        $url  = "$repoBase/$file"
        $dest = Join-Path $scriptDir $file
        Log "Downloading $file from $url"

        try {
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        } catch {
            # TLS inspection proxy workaround - retry once forcing TLS 1.2,
            # same fix used for the VS Code / Windows Terminal installers.
            Log "Initial download failed ($_) - retrying with TLS 1.2 forced."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        }

        if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) {
            throw "Downloaded file is missing or empty: $dest"
        }
        Log "Deployed: $dest"
    }

    # ------------------------------------------------------------------
    # Register the SetCameraRoll scheduled task (logon trigger, SYSTEM)
    # ------------------------------------------------------------------
    $taskName = "SetCameraRoll"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Log "Removed existing scheduled task before re-registering: $taskName"
    }

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-ExecutionPolicy Bypass -File `"$scriptDir\SetCameraRoll.ps1`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                     -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Log "Registered scheduled task: $taskName (logon trigger, runs as SYSTEM)"

    # ------------------------------------------------------------------
    # Verification
    # ------------------------------------------------------------------
    $verifyTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $verifyTask) {
        throw "Verification failed: scheduled task '$taskName' not found after registration."
    }
    if (-not (Test-Path "$scriptDir\SetCameraRoll.ps1") -or -not (Test-Path "$scriptDir\SyncCameraRoll.ps1")) {
        throw "Verification failed: one or more payload scripts missing from $scriptDir."
    }

    Log "Verification passed - SUCCESS"
    Log "=== Camera Roll install finished ==="
} catch {
    Log "[ERROR] Install-CameraRoll failed: $_"
    Log "=== Camera Roll install finished with errors ==="
    exit 1
}
