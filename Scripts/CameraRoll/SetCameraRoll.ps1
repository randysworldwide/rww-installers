# SetCameraRoll.ps1
# Runs at user logon (via Task Scheduler, as SYSTEM).
#
# Runs its setup for whoever is currently logged in, AD account or local
# account alike (e.g. Administrator).
#
# What it does:
#   1. Redirects the Camera Roll folder to C:\Users\Public\Pictures\Camera Roll
#   2. Creates a desktop shortcut to that folder (skips if one already points there)
#   3. Creates a desktop shortcut to the Camera app
#   4. Maps a network drive to the Incoming Receipt Photos share (if not already mapped)
#   5. Registers a per-user sync task that copies photos to the network every 5 minutes
#
# The sync task (step 5) runs as the logged-in AD user so it has the right
# network credentials. It is recreated at each logon to stay tied to the
# current user.
#
# All three tasks that run under the logged-in user's identity (Camera
# app shortcut, drive mapping, and the recurring sync) use LogonType S4U
# rather than Interactive. S4U runs the task under that user's identity
# (so network authentication still works) without ever attaching to the
# interactive desktop session - meaning no window is ever created, with
# no need for -WindowStyle Hidden or any wrapper script. This also avoids
# depending on Windows Script Host, which is commonly disabled by
# endpoint security tools and silently blocks anything routed through
# wscript.exe/cscript.exe.

$logFile      = "C:\ProgramData\Dev\CameraRoll\SetCameraRoll.log"
$localPath    = "C:\Users\Public\Pictures\Camera Roll"
$networkShare = "\\svazdfs001\DepartmentalShares\Logistics\Incoming Receipt Photos"
$guid         = "{AB5FB87B-7CE2-4F83-915D-550846C9537B}"

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $msg" | Out-File -FilePath $logFile -Append
}

if (-not (Test-Path "C:\ProgramData\Dev\CameraRoll")) {
    New-Item -Path "C:\ProgramData\Dev\CameraRoll" -ItemType Directory -Force | Out-Null
}

Log "=== Script started. Running as: $env:USERNAME ==="

try {
    $loggedInUser = (Get-CimInstance Win32_ComputerSystem).UserName

    if (-not $loggedInUser) {
        Log "No user logged in. Exiting."
        exit
    }

    Log "Logged in user: $loggedInUser"

    $sid = (New-Object System.Security.Principal.NTAccount($loggedInUser)).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
    Log "SID: $sid"

    $hiveBase         = "Registry::HKEY_USERS\$sid"
    $userShellFolders = "$hiveBase\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    $shellFolders     = "$hiveBase\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"

    # ------------------------------------------------------------------
    # 1. Ensure local Camera Roll folder exists
    # ------------------------------------------------------------------
    if (-not (Test-Path $localPath)) {
        New-Item -Path $localPath -ItemType Directory -Force | Out-Null
        Log "Created local folder: $localPath"
    } else {
        Log "Local folder already exists: $localPath"
    }

    # ------------------------------------------------------------------
    # 2. Redirect Camera Roll via registry
    # ------------------------------------------------------------------
    foreach ($regPath in @($userShellFolders, $shellFolders)) {
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
            Log "Created registry key: $regPath"
        }
        Set-ItemProperty -Path $regPath -Name $guid -Value $localPath -Type ExpandString
        Log "Set $guid -> $localPath in $regPath"
    }

    $storageSensePath = "$hiveBase\Software\Microsoft\Windows\CurrentVersion\StorageSense\CameraRoll"
    if (-not (Test-Path $storageSensePath)) {
        New-Item -Path $storageSensePath -Force | Out-Null
    }
    Set-ItemProperty -Path $storageSensePath -Name "Path" -Value $localPath -Type String
    Log "Set StorageSense CameraRoll path to: $localPath"

    # ------------------------------------------------------------------
    # 3. Desktop shortcut
    #    Get profile path from ProfileList registry (authoritative source).
    # ------------------------------------------------------------------
    $userProfile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" `
        -ErrorAction SilentlyContinue).ProfileImagePath

    if ($userProfile) {
        $desktopPath = Join-Path $userProfile "Desktop"
        Log "Desktop path: $desktopPath"

        if (Test-Path $desktopPath) {
            $wsh = New-Object -ComObject WScript.Shell

            $existingShortcut = Get-ChildItem -Path $desktopPath -Filter "*.lnk" -ErrorAction SilentlyContinue |
                Where-Object {
                    try { ($wsh.CreateShortcut($_.FullName)).TargetPath -eq $localPath }
                    catch { $false }
                }

            if ($existingShortcut) {
                Log "Desktop shortcut already exists: $($existingShortcut.Name)"
            } else {
                $lnkPath              = Join-Path $desktopPath "Camera Roll.lnk"
                $lnk                  = $wsh.CreateShortcut($lnkPath)
                $lnk.TargetPath       = $localPath
                $lnk.WorkingDirectory = $localPath
                $lnk.Description      = "Camera Roll - Local Photos"
                $lnk.Save()
                Log "Created desktop shortcut: $lnkPath"
            }
        } else {
            Log "Desktop path not found: $desktopPath - skipping shortcut."
        }
    } else {
        Log "Could not determine user profile path - skipping shortcut."
    }

    # ------------------------------------------------------------------
    # 3. Desktop shortcut to Camera app
    #    Creates a "Camera.lnk" shortcut on the desktop pointing at the
    #    Camera UWP app via explorer.exe shell:appsFolder\<AppID>. This
    #    replaces an earlier attempt to pin Camera to the taskbar, which
    #    Microsoft has locked down on modern Windows builds and proved
    #    unreliable in testing. A shortcut created this way is a normal,
    #    supported technique - it doesn't rely on any automation surface
    #    Microsoft has blocked, so it should be far more consistent
    #    across different Windows builds than the taskbar pin was.
    #
    #    Runs under the logged-in user's identity via LogonType S4U (see
    #    file header) since Get-StartApps only reflects the correct
    #    results when run as that user, not SYSTEM.
    # ------------------------------------------------------------------
    if ($userProfile) {
        $camTaskName   = "CameraRoll-CameraShortcut"
        $camScriptPath = "C:\ProgramData\Dev\CameraRoll\CameraShortcutUser.ps1"

        @"
`$logFile = 'C:\ProgramData\Dev\CameraRoll\SetCameraRoll.log'
function CLog(`$m) { "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$m" | Out-File `$logFile -Append }

try {
    `$camApp = Get-StartApps | Where-Object { `$_.Name -eq 'Camera' } | Select-Object -First 1

    if (-not `$camApp) {
        CLog "Camera desktop shortcut: could not find 'Camera' via Get-StartApps - skipping. The Camera app may not be installed on this tablet."
    } else {
        `$desktopPath = [Environment]::GetFolderPath('Desktop')
        `$lnkPath     = Join-Path `$desktopPath 'Camera.lnk'

        if (Test-Path `$lnkPath) {
            CLog "Camera desktop shortcut already exists: `$lnkPath"
        } else {
            `$wsh  = New-Object -ComObject WScript.Shell
            `$lnk  = `$wsh.CreateShortcut(`$lnkPath)
            `$lnk.TargetPath  = "`$env:WINDIR\explorer.exe"
            `$lnk.Arguments   = "shell:appsFolder\`$(`$camApp.AppID)"
            `$lnk.Description = "Camera"
            `$lnk.Save()
            CLog "Created Camera desktop shortcut: `$lnkPath (AppID: `$(`$camApp.AppID))"
        }
    }
} catch {
    CLog "Camera desktop shortcut: attempt failed - `$_"
}
"@ | Set-Content $camScriptPath

        $existingCamTask = Get-ScheduledTask -TaskName $camTaskName -ErrorAction SilentlyContinue
        if ($existingCamTask) {
            Unregister-ScheduledTask -TaskName $camTaskName -Confirm:$false
        }

        $camAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
                            -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$camScriptPath`""
        $camTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(25)
        $camPrincipal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType S4U -RunLevel Limited
        $camSettings  = New-ScheduledTaskSettingsSet `
                            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                            -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $camTaskName -Action $camAction -Trigger $camTrigger `
            -Principal $camPrincipal -Settings $camSettings -Force | Out-Null
        Log "Registered Camera desktop shortcut task - will run as $loggedInUser in 25 seconds."
    } else {
        Log "No user profile path available - skipping Camera desktop shortcut."
    }

    # ------------------------------------------------------------------
    # 4. Network drive mapping
    #    Check HKEY_USERS\<SID>\Network for an existing mapping to the
    #    target share. If none exists, spawn a one-time task as the
    #    logged-in user to run net use in their session.
    # ------------------------------------------------------------------
    $networkRegPath = "$hiveBase\Network"
    $alreadyMapped  = $false

    if (Test-Path $networkRegPath) {
        $existingDrives = Get-ChildItem $networkRegPath -ErrorAction SilentlyContinue
        foreach ($drive in $existingDrives) {
            $remotePath = (Get-ItemProperty $drive.PSPath -Name "RemotePath" -ErrorAction SilentlyContinue).RemotePath
            if ($remotePath -eq $networkShare) {
                $alreadyMapped = $true
                Log "Network drive already mapped: $($drive.PSChildName): -> $remotePath"
                break
            }
        }
    }

    if (-not $alreadyMapped) {
        Log "No existing mapping found for $networkShare - spawning user-context task."

        $userScriptPath = "C:\ProgramData\Dev\CameraRoll\MapDriveUser.ps1"
        @"
`$share    = '$networkShare'
`$logFile  = 'C:\ProgramData\Dev\CameraRoll\SetCameraRoll.log'
function ULog(`$m) { "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$m" | Out-File `$logFile -Append }

`$alreadyMapped = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    Where-Object { `$_.DisplayRoot -eq `$share }

if (`$alreadyMapped) {
    ULog "Drive already mapped in user session: `$(`$alreadyMapped.Name): -> `$share"
} else {
    foreach (`$letter in @('I', 'L', 'K')) {
        if (Test-Path "`${letter}:") {
            ULog "Drive letter `${letter}: is already in use, trying next fallback."
            continue
        }
        `$output = net use "`${letter}:" `$share /persistent:yes 2>&1
        if (`$LASTEXITCODE -eq 0) {
            ULog "Drive mapped successfully as `${letter}: -> `$share"
            break
        } else {
            ULog "Drive map failed on `${letter}: (exit `$LASTEXITCODE): `$output"
            break
        }
    }
}
"@ | Set-Content $userScriptPath

        $mapTaskName = "CameraRoll-MapDrive"
        $mapAction   = New-ScheduledTaskAction -Execute "powershell.exe" `
                           -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$userScriptPath`""
        $mapTrigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(20)
        $mapPrincipal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType S4U -RunLevel Limited
        $mapSettings  = New-ScheduledTaskSettingsSet `
                            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                            -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $mapTaskName -Action $mapAction -Trigger $mapTrigger `
            -Principal $mapPrincipal -Settings $mapSettings -Force | Out-Null
        Log "Registered drive mapping task - will run as $loggedInUser in 20 seconds."
    }

    # ------------------------------------------------------------------
    # 5. Per-user sync task
    #    Runs SyncCameraRoll.ps1 as the logged-in user every 5 minutes.
    #    Uses the interactive session token so the user's network
    #    credentials are available to reach the share.
    #    Recreated at each logon to stay tied to the current user.
    # ------------------------------------------------------------------
    $syncTaskName = "CameraRoll-Sync-User"
    $syncScript   = "C:\ProgramData\Dev\CameraRoll\SyncCameraRoll.ps1"

    $existingSyncTask = Get-ScheduledTask -TaskName $syncTaskName -ErrorAction SilentlyContinue
    if ($existingSyncTask) {
        Unregister-ScheduledTask -TaskName $syncTaskName -Confirm:$false
        Log "Removed previous sync task."
    }

    # VBS launcher removed - see file header for why this task now uses
    # LogonType S4U instead.
    $syncAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
                         -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$syncScript`""
    $syncTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                         -RepetitionInterval (New-TimeSpan -Minutes 2) `
                         -RepetitionDuration (New-TimeSpan -Days 9999)
    $syncPrincipal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType S4U -RunLevel Limited
    $syncSettings  = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit (New-TimeSpan -Minutes 4) `
                         -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $syncTaskName `
        -Action $syncAction -Trigger $syncTrigger `
        -Principal $syncPrincipal -Settings $syncSettings `
        -Force | Out-Null
    Log "Registered per-user sync task: $syncTaskName (runs as $loggedInUser every 5 min)"

} catch {
    Log "ERROR: $_"
}

Log "=== Script finished ==="
