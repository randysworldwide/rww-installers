#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the ConnectWise Automate agent via the pre-built MSI + MST
    transform. Designed to run elevated on a single box (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/CWAgentInst.ps1

    IMPORTANT -- source files are NOT pulled from GitHub like every other
    script in this project. Agent_Install.mst contains a plaintext
    SERVERPASS value (the shared secret an agent uses to authenticate to
    our Automate/RMM server) baked in by whoever generated the transform.
    This repo is public, so that file can never be committed or hosted as
    a Release asset here -- anyone could pull it and register a rogue
    agent against our server. Instead, both files are read directly from
    the private, authenticated network share where they already live:

        \\svazdfs001\systems$\Software\ConnectWise\ConnectwiseAgent\Agent_Install.msi
        \\svazdfs001\systems$\Software\ConnectWise\ConnectwiseAgent\Agent_Install.mst

    (falls back to the \\10.1.0.5\... IP path if the hostname doesn't
    resolve, e.g. DNS not yet available on a very freshly imaged machine).

    This means this script only works on a machine that's already on the
    network and able to authenticate to that share -- which in practice is
    true for essentially any machine this would ever be run on, since
    deploying a monitoring agent to a machine with no network path to
    corporate resources isn't a meaningful scenario anyway.

    CONFIRMED IN TESTING -- THE "GHOST AGENT" ISSUE: msiexec can report a
    clean success and LTService can exist as a running Windows service,
    while the agent never actually shows up in Programs & Features, the
    system tray, or the Automate console -- effectively invisible despite
    "installing" successfully. Per ConnectWise's own community-documented
    troubleshooting (and general knowledge of how the LabTech/Automate
    agent works): the MSI itself is really just a bootstrap step -- it
    installs LTService, and THAT service is what actually phones home to
    the Automate server afterward to complete real provisioning (device
    registration, tray icon, and the full Programs & Features entry). If
    that phone-home step fails, or the server has a stale/conflicting
    record for this machine already, the agent can get stuck in this
    half-installed state indefinitely. The known manual fix is to
    uninstall, then reinstall fresh -- this script now automates that same
    cycle rather than declaring success based on the service alone.
    FLAGGING HONESTLY: the exact phone-home mechanism and timing are
    inferred from general knowledge and community reports, not something
    directly confirmed for this specific instance's server behavior.

    Steps:
      1. Skip only if the agent is BOTH running (LTService exists) AND
         fully registered (a matching Programs & Features entry exists) --
         checking the service alone would incorrectly treat a stuck ghost
         install from an earlier run as "already done" and never repair it.
      2. Copy both files from the network share to a local staging folder
         (so a flaky share connection can't interrupt an in-progress
         install, same reasoning as the Cisco Secure Client script staging
         to $env:TEMP).
      3. msiexec /i <msi> TRANSFORMS=<mst> /quiet /norestart
         REBOOT=ReallySuppress /lvx* <log>, with retry/backoff on exit code
         1618 (installer mutex held), same pattern as
         Scripts/SecureConnect/Install-SecureClient-Automate.ps1.
      4. After a successful msiexec exit, wait up to 90 seconds (checking
         every 15) for the Programs & Features entry to appear -- giving
         the service time to complete its own phone-home registration
         before judging the install. This wait duration is a reasonable
         guess, not measured against real registration timing data.
      5. If still not registered after that wait, automatically repair:
         uninstall via the local MSI file (falling back to directly
         stopping/deleting the LTService service if Windows Installer
         itself doesn't think anything needs removing -- a real
         possibility in exactly the stuck state this exists to fix), then
         reinstall fresh once, with the same wait-and-recheck afterward.

.PARAMETER LogPath
    Where to write this script's own log file. Defaults under ProgramData
    so it's readable without a user profile loaded.

.EXITCODES
    0 = success -- agent installed and confirmed fully registered this run
        (possibly after an automatic repair cycle -- see the log for which)
    1 = msiexec install failed, or the agent was still not fully
        registered even after the automatic repair cycle -- may need the
        same manual fix as before, or a check of the Automate console for
        a stale/conflicting device record for this machine
    2 = could not reach/copy the MSI or MST from the network share
    3 = not running elevated
    4 = nothing to do -- agent was already installed AND fully registered
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\CWAgentInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir     = "$env:ProgramData\Dev\AppsDeploy\ConnectWiseAgent"
$MsiLogPath   = "$env:ProgramData\Dev\AppsDeploy\Logs\CWAgentInst-msi.log"
$SharePaths   = @(
    '\\svazdfs001\systems$\Software\ConnectWise\ConnectwiseAgent',
    '\\10.1.0.5\systems$\Software\ConnectWise\ConnectwiseAgent'
)
$MsiFileName  = 'Agent_Install.msi'
$MstFileName  = 'Agent_Install.mst'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
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
    } catch {
        # Logging failures shouldn't kill the install
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
           $identity.IsSystem
}

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated. Re-run as administrator." 'ERROR'
    exit 3
}

# ---------------------------------------------------------------------------
# Detection -- TWO separate checks, not one. LTService is the actual
# Automate/LabTech agent SERVICE name (stable across versions), but its
# existence alone doesn't mean the agent actually finished registering --
# see the "ghost agent" note above. Both need to be true for a genuine,
# complete install.
# ---------------------------------------------------------------------------
function Test-CWAgentServiceExists {
    return [bool](Get-Service -Name 'LTService' -ErrorAction SilentlyContinue)
}

function Test-CWAgentFullyRegistered {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*ConnectWise*' -or $_.DisplayName -like '*Automate*' -or $_.DisplayName -like '*LabTech*' }
        if ($match) { return $true }
    }
    return $false
}

function Wait-ForCWAgentRegistration {
    param([int]$MaxWaitSeconds = 90, [int]$PollSeconds = 15)
    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        if (Test-CWAgentFullyRegistered) { return $true }
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds
    }
    return (Test-CWAgentFullyRegistered)
}

# ---------------------------------------------------------------------------
# Install (used for both the initial attempt and the repair retry)
# ---------------------------------------------------------------------------
function Install-CWAgentOnce {
    param([string]$LocalMsi, [string]$LocalMst, [string]$AttemptLabel)

    $msiArgs = '/i "{0}" TRANSFORMS="{1}" /quiet /norestart REBOOT=ReallySuppress /lvx* "{2}"' -f $LocalMsi, $LocalMst, $MsiLogPath
    $maxAttempts = 6; $delay = 15; $finalCode = -1
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Log "[$AttemptLabel] msiexec attempt $attempt/$maxAttempts"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        $finalCode = $proc.ExitCode
        Write-Log "[$AttemptLabel] msiexec exit code: $finalCode"
        if ($finalCode -in @(0, 1641, 3010)) { break }
        if ($finalCode -eq 1618 -and $attempt -lt $maxAttempts) {
            Write-Log "[$AttemptLabel] Installer busy (1618). Waiting ${delay}s then retrying." 'WARN'
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay + 15, 60)
            continue
        }
        break
    }
    return $finalCode
}

function Uninstall-CWAgentForRepair {
    param([string]$LocalMsi)
    Write-Log "Repair: uninstalling via the local MSI file (Windows Installer's own tracking may still recognize this exact package even though ARP doesn't show it -- the defining trait of the ghost state)."
    $uninstallArgs = '/x "{0}" /quiet /norestart' -f $LocalMsi
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
    Write-Log "Repair: uninstall exit code: $($proc.ExitCode)"

    # Belt-and-suspenders: if Windows Installer itself doesn't think
    # anything needs removing (plausible in this exact stuck state),
    # directly stop and delete the service too. Both calls are safe
    # no-ops if the service doesn't exist.
    try {
        Stop-Service -Name 'LTService' -Force -ErrorAction SilentlyContinue
        Start-Process -FilePath 'sc.exe' -ArgumentList 'delete LTService' -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-CWAgent starting on $env:COMPUTERNAME ==="

$serviceExists   = Test-CWAgentServiceExists
$fullyRegistered = if ($serviceExists) { Test-CWAgentFullyRegistered } else { $false }

if ($serviceExists -and $fullyRegistered) {
    Write-Log "ConnectWise Automate agent already installed and fully registered (service + Programs & Features entry both present). Skipping."
    Write-Log "Nothing was installed -- agent was already present." 'WARN'
    exit 4
} elseif ($serviceExists -and -not $fullyRegistered) {
    Write-Log "LTService exists but no matching Programs & Features entry was found -- this looks like the 'ghost agent' state from an earlier run (service running but never finished registering). Proceeding to repair via uninstall+reinstall." 'WARN'
}

# --- Locate a reachable copy of the source files ---
$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $msiCandidate = Join-Path $candidate $MsiFileName
    $mstCandidate = Join-Path $candidate $MstFileName
    Write-Log "Checking share path: $candidate"
    if ((Test-Path $msiCandidate -ErrorAction SilentlyContinue) -and (Test-Path $mstCandidate -ErrorAction SilentlyContinue)) {
        $sourceDir = $candidate
        Write-Log "Found both files at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach Agent_Install.msi/.mst on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    Write-Log "This machine may not be on the network yet, or may not have permission to \systems$." 'ERROR'
    exit 2
}

# --- Stage locally so a flaky share connection can't interrupt msiexec ---
try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localMsi = Join-Path $StageDir $MsiFileName
    $localMst = Join-Path $StageDir $MstFileName
    Write-Log "Staging files to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $MsiFileName) -Destination $localMsi -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir $MstFileName) -Destination $localMst -Force
} catch {
    Write-Log "Failed to copy install files from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

# --- If this is a repair (ghost state from an earlier run), clear it out first ---
if ($serviceExists -and -not $fullyRegistered) {
    Uninstall-CWAgentForRepair -LocalMsi $localMsi
}

# --- Initial (or post-repair-cleanup) install attempt ---
$finalCode = Install-CWAgentOnce -LocalMsi $localMsi -LocalMst $localMst -AttemptLabel 'primary'

if ($finalCode -eq 3010 -or $finalCode -eq 1641) {
    Write-Log "Install succeeded; a reboot is required to complete." 'WARN'
} elseif ($finalCode -eq 0) {
    Write-Log "Install succeeded."
} else {
    Write-Log "Install FAILED (msiexec exit $finalCode). See $MsiLogPath." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}

if (-not (Test-CWAgentServiceExists)) {
    Write-Log "msiexec reported success but LTService was not found afterward." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}

Write-Log "LTService confirmed present. Waiting up to 90 seconds for the agent to finish registering with the Automate server (checked via its Programs & Features entry) before declaring final success."
if (Wait-ForCWAgentRegistration) {
    Write-Log "Confirmed fully registered (Programs & Features entry now present)."
    Write-Log "=== Install-CWAgent finished. Overall success: True ==="
    exit 0
}

Write-Log "Still not fully registered after waiting -- this matches the known 'ghost agent' issue. Attempting an automatic repair: uninstall, then reinstall fresh (the same fix this has needed manually before)." 'WARN'
Uninstall-CWAgentForRepair -LocalMsi $localMsi

$repairCode = Install-CWAgentOnce -LocalMsi $localMsi -LocalMst $localMst -AttemptLabel 'repair-retry'

if ($repairCode -notin @(0, 1641, 3010)) {
    Write-Log "Repair reinstall FAILED (msiexec exit $repairCode). See $MsiLogPath." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}

if (-not (Test-CWAgentServiceExists)) {
    Write-Log "Repair reinstall reported success but LTService is still missing." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}

Write-Log "Waiting again for registration after the repair reinstall."
if (Wait-ForCWAgentRegistration) {
    Write-Log "Repair succeeded -- agent now fully registered."
    Write-Log "=== Install-CWAgent finished. Overall success: True (required an automatic repair cycle -- see warnings above) ==="
    exit 0
} else {
    Write-Log "Still not fully registered even after the automatic repair cycle. This may need the same manual fix as before, or a check of the Automate console for a stale/conflicting device record for this machine." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}
