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

    Steps:
      1. Skip if the Automate agent is already installed (checks for the
         LTService service -- the actual Automate/LabTech agent service
         name, more reliable than guessing the exact Programs & Features
         display string).
      2. Copy both files from the network share to a local staging folder
         (so a flaky share connection can't interrupt an in-progress
         install, same reasoning as the Cisco Secure Client script staging
         to $env:TEMP).
      3. msiexec /i <msi> TRANSFORMS=<mst> /quiet /norestart
         REBOOT=ReallySuppress /lvx* <log>, with retry/backoff on exit code
         1618 (installer mutex held), same pattern as
         Scripts/SecureConnect/Install-SecureClient-Automate.ps1.

.PARAMETER LogPath
    Where to write this script's own log file. Defaults under ProgramData
    so it's readable without a user profile loaded.

.EXITCODES
    0 = success -- agent was actually installed this run
    1 = msiexec install failed (see the msiexec log referenced in the output)
    2 = could not reach/copy the MSI or MST from the network share
    3 = not running elevated
    4 = nothing to do -- agent was already installed (no install action taken)
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
# Detection -- LTService is the actual Automate/LabTech agent service name,
# stable across agent versions, unlike the exact Programs & Features string.
# ---------------------------------------------------------------------------
function Test-CWAgentInstalled {
    return [bool](Get-Service -Name 'LTService' -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-CWAgent starting on $env:COMPUTERNAME ==="

if (Test-CWAgentInstalled) {
    Write-Log "ConnectWise Automate agent (LTService) already installed. Skipping."
    Write-Log "Nothing was installed -- agent was already present." 'WARN'
    exit 4
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

# --- Install with retry/backoff on 1618 (installer busy) ---
$msiArgs = '/i "{0}" TRANSFORMS="{1}" /quiet /norestart REBOOT=ReallySuppress /lvx* "{2}"' -f $localMsi, $localMst, $MsiLogPath

$maxAttempts = 6; $delay = 15; $finalCode = -1
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Log "msiexec attempt $attempt/$maxAttempts"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    $finalCode = $proc.ExitCode
    Write-Log "msiexec exit code: $finalCode"
    if ($finalCode -in @(0, 1641, 3010)) { break }
    if ($finalCode -eq 1618 -and $attempt -lt $maxAttempts) {
        Write-Log "Installer busy (1618). Waiting ${delay}s then retrying." 'WARN'
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay + 15, 60)
        continue
    }
    break
}

if ($finalCode -eq 3010 -or $finalCode -eq 1641) {
    Write-Log "Install succeeded; a reboot is required to complete." 'WARN'
} elseif ($finalCode -eq 0) {
    Write-Log "Install succeeded."
} else {
    Write-Log "Install FAILED (msiexec exit $finalCode). See $MsiLogPath." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}

if (Test-CWAgentInstalled) {
    Write-Log "LTService confirmed present after install."
    Write-Log "=== Install-CWAgent finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "msiexec reported success but LTService was not found afterward." 'ERROR'
    Write-Log "=== Install-CWAgent finished. Overall success: False ==="
    exit 1
}
