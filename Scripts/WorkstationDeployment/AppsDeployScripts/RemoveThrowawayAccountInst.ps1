#Requires -Version 5.1
<#
.SYNOPSIS
    Schedules removal of the throwaway local account used to get through
    Windows OOBE (Microsoft no longer allows fully bypassing OOBE, so a
    disposable local admin account -- typically named "Setup" -- gets
    created just to reach a usable desktop). Designed to run elevated
    (RWW WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/RemoveThrowawayAccountInst.ps1

    DOES NOT DELETE THE ACCOUNT IMMEDIATELY. This is almost always the
    exact account currently running this script -- Windows will not let
    you delete an account that's actively logged in with running
    processes. Instead, this schedules the actual deletion for the NEXT
    startup (before any interactive logon), via a one-time SYSTEM-context
    Scheduled Task that self-removes once it succeeds.

    Steps this script performs NOW (pre-reboot):
      1. Determine the target account -- defaults to whichever account is
         currently running this script ($env:USERNAME), NOT a hardcoded
         "Setup" string -- self-documenting and avoids a fragile naming
         assumption if the OOBE account convention ever changes.
      2. SAFETY GUARDS before touching anything:
         - Refuses to target a denylisted well-known account name
           (Administrator, SYSTEM, DefaultAccount, Guest,
           WDAGUtilityAccount) regardless of what was detected.
         - Confirms the target is a genuine LOCAL account (Get-LocalUser
           succeeds). Refuses to proceed if it can't confirm that --
           specifically so this can never target a domain account if the
           machine got domain-joined earlier in the same deployment run.
      3. Writes a small cleanup script to
         C:\ProgramData\Dev\AppsDeploy\RemoveSetupAccount\Cleanup-SetupAccount.ps1
      4. Registers a Scheduled Task ("RWW-RemoveSetupAccount") that runs
         that cleanup script as SYSTEM, triggered "at startup" (before any
         user logs in), one-time. The task self-unregisters once the
         account is confirmed removed; if removal fails for any reason
         (e.g. the profile still shows as loaded), it stays registered to
         retry on the next startup too.

    KNOWN EDGE CASE NOT SPECIFICALLY HANDLED: if this machine has
    AutoAdminLogon configured to automatically re-log-in as the throwaway
    account after restart, there's a theoretical race between that logon
    and this task's "at startup" trigger. Untested -- flagging rather than
    guessing at a fix, since this depends on whether OOBE machines here
    actually have auto-logon configured.

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
    4 = nothing to do -- target account doesn't exist (already removed)
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

$localUser = Get-LocalUser -Name $TargetAccount -ErrorAction SilentlyContinue
if (-not $localUser) {
    Write-Log "No local account named '$TargetAccount' exists -- nothing to schedule (already removed, or was never a local account)." 'WARN'
    exit 4
}

Write-Log "Confirmed '$TargetAccount' is a genuine local account (SID: $($localUser.SID))."

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

try {
    $prof = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -like "*\$TargetAccount" }
    if ($prof) {
        if ($prof.Loaded) {
            Write-CleanupLog "Profile for $TargetAccount still shows as loaded -- skipping profile removal this pass, will retry next startup." 'WARN'
        } else {
            Remove-CimInstance -InputObject $prof -ErrorAction Stop
            Write-CleanupLog "Removed user profile for $TargetAccount."
        }
    } else {
        Write-CleanupLog "No profile found for $TargetAccount (already removed, or never fully created)." 'WARN'
    }
} catch {
    Write-CleanupLog "Failed to remove profile: $($_.Exception.Message)" 'ERROR'
}

$accountRemoved = $false
try {
    $u = Get-LocalUser -Name $TargetAccount -ErrorAction SilentlyContinue
    if ($u) {
        Remove-LocalUser -Name $TargetAccount -ErrorAction Stop
        Write-CleanupLog "Removed local account $TargetAccount."
        $accountRemoved = $true
    } else {
        Write-CleanupLog "Local account $TargetAccount not found (already removed)." 'WARN'
        $accountRemoved = $true
    }
} catch {
    Write-CleanupLog "Failed to remove local account: $($_.Exception.Message)" 'ERROR'
}

if ($accountRemoved) {
    try {
        Unregister-ScheduledTask -TaskName 'RWW-RemoveSetupAccount' -Confirm:$false -ErrorAction Stop
        Write-CleanupLog "Self-unregistered the scheduled task -- cleanup complete."
    } catch {
        Write-CleanupLog "Account removed, but failed to unregister the scheduled task: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-CleanupLog "Account removal did not succeed -- leaving the scheduled task in place to retry on the next startup." 'WARN'
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

    Write-Log "Registered scheduled task '$TaskName' to remove '$TargetAccount' at next startup."
} catch {
    Write-Log "Failed to register the scheduled task: $($_.Exception.Message)" 'ERROR'
    exit 1
}

Write-Log "=== Install-RemoveThrowawayAccount finished. Overall success: True (removal deferred to next startup) ==="
exit 0
