# SetCameraRoll.ps1
# Runs at user logon (via Task Scheduler, as SYSTEM).
#
# Only runs its setup for AD (domain) accounts. Local accounts, such as
# Administrator or any other machine-local login, are detected and skipped
# entirely - nothing on this tablet is touched for those sessions.
#
# What it does (for AD accounts only):
#   1. Redirects the Camera Roll folder to C:\Users\Public\Pictures\Camera Roll
#   2. Creates a desktop shortcut to that folder (skips if one already points there)
#   3. Pins the Camera app to the taskbar (best-effort - see notes at that step)
#   4. Maps a network drive to the Incoming Receipt Photos share (if not already mapped)
#   5. Registers a per-user sync task that copies photos to the network every 5 minutes
#
# The sync task (step 5) runs as the logged-in AD user so it has the right
# network credentials. It is recreated at each logon to stay tied to the
# current user.

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

    # ------------------------------------------------------------------
    # AD-only check
    #    $loggedInUser is formatted "<Domain>\<Username>". For a local
    #    account, the domain portion equals this computer's own name
    #    (e.g. "WSCA1WHS027\Administrator"). For an AD account it's the
    #    NetBIOS domain (e.g. "RPSINC\jsmith"). Skip entirely for local
    #    accounts - nothing below this point should run for them.
    # ------------------------------------------------------------------
    $domainPart = $loggedInUser.Split('\')[0]
    if ($domainPart -ieq $env:COMPUTERNAME) {
        Log "'$loggedInUser' is a local account (domain part matches this computer's name) - skipping Camera Roll setup. This deployment only applies to AD accounts."
        exit
    }
    Log "Confirmed AD account (domain: $domainPart) - continuing."

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
    # 3. Pin Camera app to taskbar
    #    Taskbar personalization is per-session, so this must run as the
    #    interactive user rather than SYSTEM - same pattern used for the
    #    drive mapping below: spawn a short-lived scheduled task that
    #    executes in the logged-in user's own session.
    #
    #    IMPORTANT CAVEAT: Microsoft has progressively locked down
    #    programmatic taskbar pinning since Windows 10 20H2, and there is
    #    no officially supported command-line method for pinning an
    #    already-existing user's taskbar at runtime. This uses the classic
    #    Shell.Application COM "verb" approach, which still works on some
    #    Windows 10 builds but may silently do nothing on others, and is
    #    NOT reliable on Windows 11. Treat this as best-effort: it logs a
    #    clear message either way, but verify on this tablet's actual
    #    Windows build before assuming it will work fleet-wide. If it
    #    doesn't work on your build, the supported alternative is a
    #    taskbar layout XML applied via Group Policy, which only takes
    #    effect for new user profiles rather than existing ones.
    # ------------------------------------------------------------------
    if ($userProfile) {
        $pinTaskName   = "CameraRoll-PinTaskbar"
        $pinScriptPath = "C:\ProgramData\Dev\CameraRoll\PinCameraUser.ps1"

        @"
`$logFile = 'C:\ProgramData\Dev\CameraRoll\SetCameraRoll.log'
function PLog(`$m) { "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$m" | Out-File `$logFile -Append }

try {
    `$shellApp    = New-Object -ComObject Shell.Application
    `$appsFolder  = `$shellApp.Namespace('shell:AppsFolder')
    `$cameraItem  = `$appsFolder.Items() | Where-Object { `$_.Name -eq 'Camera' }

    if (-not `$cameraItem) {
        PLog "Taskbar pin: could not locate 'Camera' in shell:AppsFolder - skipping."
    } else {
        `$pinVerb = `$cameraItem.Verbs() | Where-Object { (`$_.Name -replace '&','') -match 'Pin to taskbar' }
        if (`$pinVerb) {
            `$pinVerb.DoIt()
            PLog "Taskbar pin: pin verb invoked for Camera app."
        } else {
            PLog "Taskbar pin: 'Pin to taskbar' verb not available on this Windows build (already pinned, or this build blocks scripted pinning) - Camera app was NOT pinned."
        }
    }
} catch {
    PLog "Taskbar pin: attempt failed - `$_"
}
"@ | Set-Content $pinScriptPath

        $existingPinTask = Get-ScheduledTask -TaskName $pinTaskName -ErrorAction SilentlyContinue
        if ($existingPinTask) {
            Unregister-ScheduledTask -TaskName $pinTaskName -Confirm:$false
        }

        $pinAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
                            -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$pinScriptPath`""
        $pinTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(25)
        $pinPrincipal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
        $pinSettings  = New-ScheduledTaskSettingsSet `
                            -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
                            -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $pinTaskName -Action $pinAction -Trigger $pinTrigger `
            -Principal $pinPrincipal -Settings $pinSettings -Force | Out-Null
        Log "Registered taskbar pin task - will attempt to pin Camera app as $loggedInUser in 25 seconds. Check log for whether the pin verb was actually available."
    } else {
        Log "No user profile path available - skipping taskbar pin attempt."
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
        $mapPrincipal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
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

    $syncAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
                         -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$syncScript`""
    $syncTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                         -RepetitionInterval (New-TimeSpan -Minutes 2) `
                         -RepetitionDuration (New-TimeSpan -Days 9999)
    $syncPrincipal = New-ScheduledTaskPrincipal -UserId $loggedInUser -LogonType Interactive -RunLevel Limited
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
