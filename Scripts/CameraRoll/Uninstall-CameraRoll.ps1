# Uninstall-CameraRoll.ps1
# Idempotent removal of the Camera Roll tablet deployment.
#
# Removes:
#   - SetCameraRoll scheduled task (logon trigger, SYSTEM)
#   - CameraRoll-Sync-User, CameraRoll-MapDrive, CameraRoll-PinTaskbar
#     scheduled tasks (per-user / one-time helper tasks, in case any are
#     still present when this runs)
#   - SetCameraRoll.ps1, SyncCameraRoll.ps1, and the two dynamically
#     generated per-user helper scripts (MapDriveUser.ps1,
#     PinCameraUser.ps1) from C:\ProgramData\Dev\CameraRoll
#   - The registry redirection that pointed Camera Roll at the shared
#     local folder, restoring it to %USERPROFILE%\Pictures\Camera Roll
#     for the CURRENTLY LOGGED-IN user
#   - Any photos still sitting in the shared local folder are moved back
#     into that user's own Pictures\Camera Roll folder first, so nothing
#     is lost, then the now-empty shared folder is removed
#   - The stale desktop shortcut that pointed at the shared folder
#
# Does NOT remove:
#   - Any photos already copied to the network share.
#   - The registry redirection for any user OTHER than whoever is
#     currently logged in - if no one is logged in when this runs, or a
#     different user previously used this tablet, their redirect won't
#     be reverted until this uninstall is re-run while they're signed in.
#     Only reverts values that currently match our known override, so an
#     unrelated user customization is never overwritten.
#
# Each step checks before acting, so this is safe to re-run at any time -
# for example if a tablet is being repurposed or retired.

$ErrorActionPreference = 'Continue'
$logFile   = "C:\ProgramData\Dev\CameraRoll\Uninstall-CameraRoll.log"
$scriptDir = "C:\ProgramData\Dev\CameraRoll"
$localPath = "C:\Users\Public\Pictures\Camera Roll"
$guid      = "{AB5FB87B-7CE2-4F83-915D-550846C9537B}"

$tasks = @("SetCameraRoll", "CameraRoll-Sync-User", "CameraRoll-MapDrive", "CameraRoll-PinTaskbar")
$files = @(
    "SetCameraRoll.ps1", "SyncCameraRoll.ps1", "MapDriveUser.ps1", "PinCameraUser.ps1",
    "SyncCameraRoll-Launcher.vbs", "MapDriveUser-Launcher.vbs", "PinCameraUser-Launcher.vbs"
)

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

# ------------------------------------------------------------------
# Restore Camera Roll to its original per-user location
# ------------------------------------------------------------------
try {
    $loggedInUser = (Get-CimInstance Win32_ComputerSystem).UserName

    if (-not $loggedInUser) {
        Log "No user currently logged in - skipping Camera Roll location restore. Re-run this uninstall while the affected user is logged in to complete the restore."
    } else {
        $sid = (New-Object System.Security.Principal.NTAccount($loggedInUser)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value

        $hiveBase         = "Registry::HKEY_USERS\$sid"
        $userShellFolders = "$hiveBase\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        $shellFolders     = "$hiveBase\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        $storageSensePath = "$hiveBase\Software\Microsoft\Windows\CurrentVersion\StorageSense\CameraRoll"
        $defaultPath      = "%USERPROFILE%\Pictures\Camera Roll"

        $userProfile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" `
            -ErrorAction SilentlyContinue).ProfileImagePath

        $revertedAny = $false

        # Only overwrite the registry value if it currently matches our
        # known override - never clobber an unrelated user customization.
        foreach ($regPath in @($userShellFolders, $shellFolders)) {
            $current = (Get-ItemProperty -Path $regPath -Name $guid -ErrorAction SilentlyContinue).$guid
            if ($current -eq $localPath) {
                Set-ItemProperty -Path $regPath -Name $guid -Value $defaultPath -Type ExpandString
                Log "Reverted $guid in $regPath back to default: $defaultPath"
                $revertedAny = $true
            } else {
                Log "$regPath does not point to our override (current value: '$current') - leaving as-is."
            }
        }

        if (Test-Path $storageSensePath) {
            $currentStorageSense = (Get-ItemProperty -Path $storageSensePath -Name "Path" -ErrorAction SilentlyContinue).Path
            if ($currentStorageSense -eq $localPath) {
                Remove-Item -Path $storageSensePath -Recurse -Force
                Log "Removed StorageSense CameraRoll override for $loggedInUser."
            }
        }

        # Move any remaining local photos back into the user's own profile
        # before removing the shared folder, so nothing gets lost.
        if ($userProfile -and (Test-Path $localPath)) {
            $userCameraRoll = Join-Path $userProfile "Pictures\Camera Roll"
            if (-not (Test-Path $userCameraRoll)) {
                New-Item -Path $userCameraRoll -ItemType Directory -Force | Out-Null
            }

            $filesToMove = Get-ChildItem -Path $localPath -Recurse -File -ErrorAction SilentlyContinue
            $moved = 0; $moveFailed = 0
            foreach ($file in $filesToMove) {
                $relativePath = $file.FullName.Substring($localPath.Length).TrimStart('\')
                $destPath     = Join-Path $userCameraRoll $relativePath
                $destDir      = Split-Path $destPath -Parent
                try {
                    if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
                    Move-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Stop
                    $moved++
                } catch {
                    Log "[ERROR] Failed to move '$($file.FullName)' back to user profile: $_"
                    $moveFailed++
                }
            }
            Log "Moved $moved photo(s) from $localPath to $userCameraRoll. Failed to move: $moveFailed."
            if ($moveFailed -gt 0) { $errors++ }

            # Remove the shared folder only if it's now completely empty
            $remaining = Get-ChildItem -Path $localPath -Recurse -File -ErrorAction SilentlyContinue
            if (-not $remaining -or $remaining.Count -eq 0) {
                Remove-Item -Path $localPath -Recurse -Force -ErrorAction SilentlyContinue
                Log "Removed now-empty shared folder: $localPath"
            } else {
                Log "$localPath still contains $($remaining.Count) file(s) that failed to move - left in place rather than risk data loss."
            }
        } else {
            Log "No shared folder found at $localPath - nothing to move."
        }

        # Remove the stale desktop shortcut pointing at the shared folder
        if ($userProfile) {
            $desktopPath = Join-Path $userProfile "Desktop"
            if (Test-Path $desktopPath) {
                $wsh = New-Object -ComObject WScript.Shell
                $staleShortcuts = Get-ChildItem -Path $desktopPath -Filter "*.lnk" -ErrorAction SilentlyContinue |
                    Where-Object {
                        try { ($wsh.CreateShortcut($_.FullName)).TargetPath -eq $localPath }
                        catch { $false }
                    }
                if ($staleShortcuts) {
                    $staleShortcuts | Remove-Item -Force
                    Log "Removed stale desktop shortcut(s): $($staleShortcuts.Name -join ', ')"
                }
            }
        }

        if ($revertedAny) {
            Log "Camera Roll location restored to default for $loggedInUser."
        } else {
            Log "No registry override matching our known path was found for $loggedInUser - nothing to restore (may already be reverted, or this user never had it set)."
        }
    }
} catch {
    Log "[ERROR] Failed to restore Camera Roll location: $_"
    $errors++
}

if ($errors -gt 0) {
    Log "[ERROR] Uninstall completed with $errors error(s)."
    Log "=== Camera Roll uninstall finished with errors ==="
    exit 1
} else {
    Log "Uninstall completed cleanly."
    Log "=== Camera Roll uninstall finished ==="
}
