# Uninstall-CameraRoll.ps1
# Idempotent removal of the Camera Roll tablet deployment.
#
# Removes:
#   - SetCameraRoll scheduled task (logon trigger, SYSTEM)
#   - CameraRoll-Sync-User scheduled task (per-user, registered dynamically
#     by SetCameraRoll.ps1 at logon)
#   - CameraRoll-MapDrive scheduled task (one-time drive-mapping helper, in
#     case it's still present when this runs)
#   - SetCameraRoll.ps1 and SyncCameraRoll.ps1 from C:\ProgramData\Dev\CameraRoll
#
# Does NOT remove:
#   - The local "Camera Roll" folder, its registry redirection, or the
#     desktop shortcut, so a tablet doesn't lose local photos mid-sync.
#   - Any photos already copied to the network share.
#
# Each step checks before acting, so this is safe to re-run at any time -
# for example if a tablet is being repurposed or retired.

$ErrorActionPreference = 'Continue'
$logFile   = "C:\ProgramData\Dev\CameraRoll\Uninstall-CameraRoll.log"
$scriptDir = "C:\ProgramData\Dev\CameraRoll"

$tasks = @("SetCameraRoll", "CameraRoll-Sync-User", "CameraRoll-MapDrive")
$files = @("SetCameraRoll.ps1", "SyncCameraRoll.ps1")

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $msg"
    $line | Out-File -FilePath $logFile -Append
    Write-Output $line
}

if (-not (Test-Path "C:\ProgramData\Dev\CameraRoll")) { New-Item -Path "C:\ProgramData\Dev\CameraRoll" -ItemType Directory -Force | Out-Null }

Log "=== Camera Roll uninstall started ==="
$errors = 0

foreach ($taskName in $tasks) {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Log "Removed scheduled task: $taskName"
        } else {
            Log "Scheduled task not present (already removed): $taskName"
        }
    } catch {
        Log "[ERROR] Failed to remove task '$taskName': $_"
        $errors++
    }
}

foreach ($file in $files) {
    $path = Join-Path $scriptDir $file
    try {
        if (Test-Path $path) {
            Remove-Item -Path $path -Force
            Log "Removed file: $path"
        } else {
            Log "File not present (already removed): $path"
        }
    } catch {
        Log "[ERROR] Failed to remove file '$path': $_"
        $errors++
    }
}

if ($errors -gt 0) {
    Log "[ERROR] Uninstall completed with $errors error(s)."
    Log "=== Camera Roll uninstall finished with errors ==="
    exit 1
} else {
    Log "Uninstall completed cleanly."
    Log "=== Camera Roll uninstall finished ==="
}
