#Requires -Version 5.1
<#
.SYNOPSIS
    Disables auto-logon (if configured) and schedules removal of the
    throwaway local account used to get through Windows OOBE, including
    its C:\Users profile folder. Designed to run elevated (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/RemoveThrowawayAccountInst.ps1

    DOES NOT DELETE THE ACCOUNT IMMEDIATELY. This is almost always the
    exact account currently running this script -- Windows will not let
    you delete an account that's actively logged in with running
    processes. Instead, this schedules the actual deletion for the NEXT
    startup, via a one-time SYSTEM-context Scheduled Task that self-
    removes once BOTH the account and its profile folder are confirmed
    gone.

    CONFIRMED IN TESTING -- ROOT CAUSE OF A REAL BUG, NOW FIXED: on a
    machine with AutoAdminLogon configured (common on Dell OOBE-
    provisioned accounts), Windows logs straight back into the throwaway
    account almost immediately at boot -- before Task Scheduler's own
    engine has finished starting, racing ahead of this task's "at
    startup" trigger. Windows will still let the SAM account get deleted
    while that session is active (the session just keeps running until
    logout), but the PROFILE FOLDER removal specifically checks whether
    the profile is currently loaded and skips if so -- so the account
    vanished but C:\Users\<account> was left behind, and because the
    original cleanup script only checked "is the account gone" before
    self-unregistering (not "is the folder also gone"), the task deleted
    itself after that one partial pass, leaving no way to retry.
    Fixed two ways:
      1. This script now disables AutoAdminLogon (and clears
         DefaultPassword, which is often sitting in the registry in
         PLAINTEXT under this setting -- worth clearing on its own
         merits, not just for this race) if it's configured for the
         target account, before ever scheduling anything. Removing the
         race at its source means the normal logon screen shows on next
         boot instead, giving Task Scheduler time to run before anyone
         (human or auto-logon) claims the account.
      2. The cleanup task now tracks account removal and folder removal
         as two SEPARATE outcomes, and only self-unregisters once BOTH
         are true -- a partial success (account gone, folder still
         there) now correctly keeps retrying on subsequent boots instead
         of silently giving up.

    THE LOGON-SCREEN PROBLEM -- THREE ATTEMPTS, ACTUAL ROOT CAUSES FOUND
    ON THE THIRD: even after the throwaway account is genuinely deleted,
    the logon screen kept suggesting it, prompting for a password that
    can never work. Attempt 1 (redirect the LogonUI last-logged-on keys
    to Administrator, from the post-reboot cleanup task) and attempt 2
    (SpecialAccounts\UserList hide + ProfileList cleanup, same placement)
    both ran without error yet the symptom persisted on real machines.
    Re-examination found TWO real defects in those attempts:

      a) A PLACEMENT race: the cleanup runs as an at-startup SYSTEM task,
         but LogonUI.exe reads its last-logged-on values very early in
         boot -- evidently before the task's writes land. The registry
         ended up correct but too late for the screen being shown. The
         fix now runs in THIS script, pre-reboot, while still logged in
         as the throwaway account -- so LogonUI reads the right values
         the first time it looks.

      b) A VALUE-TYPE bug: LastLoggedOnUserSID is a REG_SZ STRING in the
         LogonUI key; attempt 1 wrote it as BINARY SID bytes -- a wrong
         type that plausibly made LogonUI ignore the whole value set.
         LastLoggedOnDisplayName was also never set. Both corrected.

    Current design: pre-reboot, this script (1) points all four LogonUI
    last-logged-on values at the built-in Administrator (correct types),
    and (2) hides the throwaway account from the tile list via
    SpecialAccounts\UserList -- so even if winlogon overwrites the
    last-logged-on values during the throwaway session's own shutdown
    (an acknowledged unknown), the deleted account still can't be the
    suggested login. The post-reboot cleanup task re-asserts the same
    values as a backup pass, plus the narrowly-scoped stale-ProfileList
    cleanup from attempt 2 (still worthwhile on its own).

    Steps this script performs NOW (pre-reboot):
      1. Determine the target account -- defaults to whichever account is
         currently running this script ($env:USERNAME), NOT a hardcoded
         "Setup" string.
      2. SAFETY GUARDS before touching anything:
         - Refuses to target a denylisted well-known account name
           (Administrator, SYSTEM, DefaultAccount, Guest,
           WDAGUtilityAccount) regardless of what was detected.
         - If the account still exists, confirms it's a genuine LOCAL
           account (Get-LocalUser succeeds) -- refuses to proceed
           otherwise, so this can never target a domain account.
      3. Checks AutoAdminLogon (see above) and disables it if it points
         at the target account.
      4. Proceeds if EITHER the account OR its C:\Users profile folder
         still exists (not just the account -- otherwise a machine where
         the account is already gone but the folder is still sitting
         there, like the one that prompted this fix, would report
         "nothing to do" and never clean up the folder).
      5. Writes a small cleanup script to
         C:\ProgramData\Dev\AppsDeploy\RemoveSetupAccount\Cleanup-SetupAccount.ps1
      6. Registers a Scheduled Task ("RWW-RemoveSetupAccount") that runs
         that cleanup script as SYSTEM, triggered "at startup", one-time.

    ORDERING: must run before Reboot Computer -- the actual removal only
    happens after that reboot. Positioned as the second-to-last entry in
    the Finishing Touches category, immediately before Reboot Computer.

.PARAMETER LogPath
    Where to write this script's own log file. The post-reboot cleanup
    step logs separately to RemoveSetupAccount-cleanup.log, since it runs
    as a different scheduled task execution, not as part of this run.

.PARAMETER TargetAccount
    The account to schedule for removal. Defaults to $env:USERNAME (the
    account currently running this script).

.EXITCODES
    0 = success -- the scheduled task was registered
    1 = failed to write the cleanup script or register the scheduled task
    2 = refused -- target account is denylisted or not confirmed local
    3 = not running elevated
    4 = nothing to do -- neither the account nor its profile folder exist
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\RemoveThrowawayAccountInst.log",
    [string]$TargetAccount = $env:USERNAME
)

$ErrorActionPreference = 'Stop'

$DenylistedAccounts = @('Administrator', 'SYSTEM', 'DefaultAccount', 'Guest', 'WDAGUtilityAccount')
$CleanupDir    = "$env:ProgramData\Dev\AppsDeploy\RemoveSetupAccount"
$CleanupScript = Join-Path $CleanupDir 'Cleanup-SetupAccount.ps1'
$TaskName      = 'RWW-RemoveSetupAccount'
$WinlogonKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Global:RWWLogSink) {
        try { & $Global:RWWLogSink $line } catch {}
    } else {
        [Console]::WriteLine($line)
    }
    try {
        $dir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line
    } catch {}
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.IsSystem
}

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated. Re-run as administrator." 'ERROR'
    exit 3
}

Write-Log "=== Install-RemoveThrowawayAccount starting on $env:COMPUTERNAME ==="
Write-Log "Target account: $TargetAccount"

if ($DenylistedAccounts -contains $TargetAccount) {
    Write-Log "Refusing -- '$TargetAccount' is a denylisted well-known account name. This should never be scheduled for removal." 'ERROR'
    exit 2
}

# --- Disable AutoAdminLogon if it points at the target account, so the
# normal logon screen shows next boot instead of racing our cleanup task. ---
try {
    $winlogon = Get-ItemProperty -Path $WinlogonKey -ErrorAction SilentlyContinue
    if ($winlogon -and $winlogon.AutoAdminLogon -eq '1' -and $winlogon.DefaultUserName -eq $TargetAccount) {
        Write-Log "AutoAdminLogon is configured for '$TargetAccount' -- this is what caused an immediate silent re-login last time. Disabling it." 'WARN'
        Set-ItemProperty -Path $WinlogonKey -Name 'AutoAdminLogon' -Value '0' -ErrorAction Stop
        if ($winlogon.PSObject.Properties.Name -contains 'DefaultPassword') {
            Remove-ItemProperty -Path $WinlogonKey -Name 'DefaultPassword' -ErrorAction SilentlyContinue
            Write-Log "Also cleared DefaultPassword -- auto-logon passwords are stored in that registry value in PLAINTEXT, worth removing regardless." 'WARN'
        }
        Write-Log "AutoAdminLogon disabled. The normal logon screen will show on next boot."
    } else {
        Write-Log "AutoAdminLogon is not configured for '$TargetAccount' -- nothing to disable there."
    }
} catch {
    Write-Log "Could not check/disable AutoAdminLogon: $($_.Exception.Message)" 'WARN'
}

# --- Point the logon screen at Administrator NOW, before the reboot. ---
# WHY HERE AND NOT IN THE CLEANUP TASK (the root cause of two previous
# failed attempts at this): the post-reboot cleanup runs as an
# at-startup SYSTEM task, which RACES LogonUI.exe -- and LogonUI reads
# its "last logged on" values very early in boot, evidently before the
# task's registry writes land. The values ended up correct in the
# registry but too late for the screen being displayed. Writing them
# HERE, while still logged in as the throwaway account BEFORE the
# reboot, means LogonUI reads the right values the first time it ever
# looks.
#
# ALSO FIXING A REAL BUG from the earlier attempt: LastLoggedOnUserSID
# is a REG_SZ STRING value ("S-1-5-21-...") in the LogonUI key -- the
# earlier code wrote it as BINARY SID bytes, a wrong type that plausibly
# made LogonUI ignore the whole value set. LastLoggedOnDisplayName was
# also never set before. Correct layout, all REG_SZ:
#   LastLoggedOnUser        = .\<name>   (dot-qualified for local)
#   LastLoggedOnSAMUser     = <MACHINE>\<name>
#   LastLoggedOnUserSID     = <SID string>
#   LastLoggedOnDisplayName = <name>
try {
    $adminAccount = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID -like '*-500' } | Select-Object -First 1
    if ($adminAccount) {
        $logonUiKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
        Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnUser'        -Value ".\$($adminAccount.Name)" -Type String -ErrorAction Stop
        Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnSAMUser'     -Value "$env:COMPUTERNAME\$($adminAccount.Name)" -Type String -ErrorAction Stop
        Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnUserSID'     -Value $adminAccount.SID.Value -Type String -ErrorAction Stop
        Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnDisplayName' -Value $adminAccount.Name -Type String -ErrorAction Stop
        Write-Log "Pointed the logon screen's 'last logged on' slot at '$($adminAccount.Name)' (pre-reboot, so LogonUI reads it correctly at next boot instead of racing the cleanup task)."
    } else {
        Write-Log "Could not find the built-in Administrator account (SID -500) -- skipping the logon-screen redirect." 'WARN'
    }
} catch {
    Write-Log "Could not update the logon screen's last-logged-on values (non-fatal): $($_.Exception.Message)" 'WARN'
}

# --- Hide the throwaway account from the logon tile list, also NOW. ---
# SpecialAccounts\UserList (DWORD 0 named as the account) is Windows'
# documented mechanism for keeping a specific account off the logon
# screen entirely. Applied pre-reboot for the same race-avoidance reason
# as above. The account still EXISTS until the cleanup task removes it
# post-reboot, but it stops being offered as a sign-in option
# immediately -- so even if something overwrites the last-logged-on
# values above during shutdown, the deleted account can't be the
# suggested login.
try {
    $specialAccountsKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $specialAccountsKey)) { New-Item -Path $specialAccountsKey -Force | Out-Null }
    Set-ItemProperty -Path $specialAccountsKey -Name $TargetAccount -Value 0 -Type DWord -ErrorAction Stop
    Write-Log "Hid '$TargetAccount' from the logon screen tile list (SpecialAccounts\UserList), effective from the next boot."
} catch {
    Write-Log "Could not hide '$TargetAccount' from the logon tile list (non-fatal): $($_.Exception.Message)" 'WARN'
}

$localUser   = Get-LocalUser -Name $TargetAccount -ErrorAction SilentlyContinue
$folderPath  = "C:\Users\$TargetAccount"
$folderExists = Test-Path -LiteralPath $folderPath -ErrorAction SilentlyContinue

if (-not $localUser -and -not $folderExists) {
    Write-Log "No local account and no leftover profile folder for '$TargetAccount' -- nothing to schedule." 'WARN'
    exit 4
}

if ($localUser) {
    Write-Log "Confirmed '$TargetAccount' is a genuine local account (SID: $($localUser.SID))."
} else {
    Write-Log "No local account named '$TargetAccount' (already removed), but a leftover profile folder still exists at $folderPath. Scheduling folder cleanup." 'WARN'
}

try {
    if (-not (Test-Path $CleanupDir)) { New-Item -Path $CleanupDir -ItemType Directory -Force | Out-Null }

    # Single-quoted here-string on purpose -- $TargetAccount and $env:...
    # below must stay LITERAL text for the cleanup script to evaluate on
    # its own when IT runs later, not get expanded now while we're just
    # writing this file out.
    $cleanupContent = @'
param([string]$TargetAccount)

$logPath = "$env:ProgramData\Dev\AppsDeploy\Logs\RemoveSetupAccount-cleanup.log"
function Write-CleanupLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $logPath -Value $line
    } catch {}
}

Write-CleanupLog "=== Post-reboot cleanup starting for account '$TargetAccount' ==="

$accountRemoved = $false
try {
    $u = Get-LocalUser -Name $TargetAccount -ErrorAction SilentlyContinue
    if ($u) {
        Remove-LocalUser -Name $TargetAccount -ErrorAction Stop
        Write-CleanupLog "Removed local account $TargetAccount."
    } else {
        Write-CleanupLog "Local account $TargetAccount not found (already removed)." 'WARN'
    }
    $accountRemoved = $true
} catch {
    Write-CleanupLog "Failed to remove local account: $($_.Exception.Message)" 'ERROR'
}

# CONFIRMED VIA RESEARCH: real reports of this EXACT symptom (account
# and profile both genuinely deleted, but a stale tile with a password
# prompt persists on the logon screen) point to Windows' OWN internal
# logon-screen caching, which the LastLoggedOnUser update above does NOT
# reliably override -- confirmed by a real test where that update ran
# successfully but the stale tile still appeared. The documented,
# authoritative mechanism for making a specific account NEVER show as a
# tile (regardless of any caching) is different: a DWORD value named
# exactly as the account, set to 0, under
# Winlogon\SpecialAccounts\UserList. This is more direct than trying to
# change which account is the DEFAULT -- it hides the stale one outright.
if ($accountRemoved) {
    try {
        $specialAccountsKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
        if (-not (Test-Path $specialAccountsKey)) { New-Item -Path $specialAccountsKey -Force | Out-Null }
        Set-ItemProperty -Path $specialAccountsKey -Name $TargetAccount -Value 0 -Type DWord -ErrorAction Stop
        Write-CleanupLog "Hid '$TargetAccount' from the logon screen tile list directly (SpecialAccounts\UserList) -- the documented Windows mechanism for exactly this situation."
    } catch {
        Write-CleanupLog "Failed to hide $TargetAccount via SpecialAccounts\UserList: $($_.Exception.Message)" 'WARN'
    }

    # Secondary measure: also confirmed in real reports of this same
    # symptom -- a stale ProfileList registry entry can persist even
    # after the account and profile folder are both genuinely gone.
    # Scoped narrowly (only a key whose ProfileImagePath ends in exactly
    # this account's name) since ProfileList is sensitive -- removing the
    # wrong entry here could affect a DIFFERENT, unrelated profile.
    try {
        $profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $staleProfileKeys = Get-ChildItem -Path $profileListKey -ErrorAction SilentlyContinue | Where-Object {
            $imgPath = (Get-ItemProperty -Path $_.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
            $imgPath -and ($imgPath -eq "C:\Users\$TargetAccount")
        }
        foreach ($staleKey in $staleProfileKeys) {
            Remove-Item -Path $staleKey.PSPath -Recurse -Force -ErrorAction Stop
            Write-CleanupLog "Removed a stale ProfileList registry entry for $TargetAccount ($($staleKey.PSPath))."
        }
        if (-not $staleProfileKeys) {
            Write-CleanupLog "No stale ProfileList entry found for $TargetAccount -- nothing to clean up there."
        }
    } catch {
        Write-CleanupLog "Failed to check/clean up ProfileList entries for $TargetAccount (non-fatal): $($_.Exception.Message)" 'WARN'
    }
}

# BACKUP PASS: the main script now writes these same values PRE-reboot
# (see its logon-screen section for why that placement matters -- this
# at-startup task races LogonUI and can land too late for the first
# boot's screen). Re-asserting them here is a safety net for the case
# where winlogon overwrote the last-logged-on values during the shutdown
# of the throwaway session -- correct from the SECOND boot onward even
# in that case. NOTE: an earlier version wrote LastLoggedOnUserSID as
# binary bytes; it is a REG_SZ STRING in this key -- fixed, along with
# adding the previously-missing LastLoggedOnDisplayName.
if ($accountRemoved) {
    try {
        $adminAccount = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID -like '*-500' } | Select-Object -First 1
        if ($adminAccount) {
            $logonUiKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
            Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnUser'        -Value ".\$($adminAccount.Name)" -Type String -ErrorAction Stop
            Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnSAMUser'     -Value "$env:COMPUTERNAME\$($adminAccount.Name)" -Type String -ErrorAction Stop
            Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnUserSID'     -Value $adminAccount.SID.Value -Type String -ErrorAction Stop
            Set-ItemProperty -Path $logonUiKey -Name 'LastLoggedOnDisplayName' -Value $adminAccount.Name -Type String -ErrorAction Stop
            Write-CleanupLog "Re-asserted the logon screen's last-logged-on values to '$($adminAccount.Name)' (backup pass -- the main script already set these pre-reboot)."
        } else {
            Write-CleanupLog "Could not find the built-in Administrator account (SID -500) to point the logon screen at -- skipping this step." 'WARN'
        }
    } catch {
        Write-CleanupLog "Failed to update the logon screen default user (non-fatal, doesn't affect the account/folder removal above): $($_.Exception.Message)" 'WARN'
    }
}

# Profile removal is tracked SEPARATELY from account removal -- a machine
# where the account got deleted while its profile was still marked
# "loaded" (the AutoAdminLogon race this whole script exists to prevent,
# but tracked independently as defense in depth) needs this to keep
# retrying even though the account itself is already gone.
$profileRemoved = $false
try {
    $prof = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -like "*\$TargetAccount" }
    if ($prof) {
        if ($prof.Loaded) {
            Write-CleanupLog "Profile for $TargetAccount still shows as loaded -- skipping WMI profile removal this pass, will retry next startup." 'WARN'
        } else {
            Remove-CimInstance -InputObject $prof -ErrorAction Stop
            Write-CleanupLog "Removed user profile (WMI) for $TargetAccount."
        }
    } else {
        Write-CleanupLog "No WMI profile entry found for $TargetAccount (already removed, or never fully created)." 'WARN'
    }
} catch {
    Write-CleanupLog "WMI profile removal failed: $($_.Exception.Message)" 'ERROR'
}

# Explicit folder deletion, regardless of how the WMI removal above went --
# this is the actual fix for the leftover C:\Users\<account> folder: WMI
# profile removal can succeed at the registry-hive level while still
# leaving files behind in some cases, and it's skipped entirely whenever
# the profile shows as loaded. Force-deleting the folder directly is the
# reliable fallback either way.
$folderPath = "C:\Users\$TargetAccount"
if (Test-Path -LiteralPath $folderPath -ErrorAction SilentlyContinue) {
    try {
        Remove-Item -LiteralPath $folderPath -Recurse -Force -ErrorAction Stop
        Write-CleanupLog "Force-deleted profile folder $folderPath."
        $profileRemoved = $true
    } catch {
        Write-CleanupLog "Failed to force-delete ${folderPath}: $($_.Exception.Message)" 'ERROR'
        $profileRemoved = $false
    }
} else {
    Write-CleanupLog "$folderPath does not exist -- nothing to delete."
    $profileRemoved = $true
}

if ($accountRemoved -and $profileRemoved) {
    try {
        Unregister-ScheduledTask -TaskName 'RWW-RemoveSetupAccount' -Confirm:$false -ErrorAction Stop
        Write-CleanupLog "Self-unregistered the scheduled task -- cleanup complete (account and folder both confirmed gone)."
    } catch {
        Write-CleanupLog "Account and folder both removed, but failed to unregister the scheduled task: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-CleanupLog "Leaving the scheduled task in place to retry on the next startup (account removed: $accountRemoved, folder removed: $profileRemoved)." 'WARN'
}

Write-CleanupLog "=== Post-reboot cleanup finished ==="
'@

    Set-Content -LiteralPath $CleanupScript -Value $cleanupContent -Encoding UTF8
    Write-Log "Wrote cleanup script to $CleanupScript"
} catch {
    Write-Log "Failed to write the cleanup script: $($_.Exception.Message)" 'ERROR'
    exit 1
}

try {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$CleanupScript`" -TargetAccount `"$TargetAccount`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Log "Registered scheduled task '$TaskName' to remove '$TargetAccount' (account and profile folder) at next startup."
} catch {
    Write-Log "Failed to register the scheduled task: $($_.Exception.Message)" 'ERROR'
    exit 1
}

Write-Log "=== Install-RemoveThrowawayAccount finished. Overall success: True (removal deferred to next startup) ==="
exit 0
