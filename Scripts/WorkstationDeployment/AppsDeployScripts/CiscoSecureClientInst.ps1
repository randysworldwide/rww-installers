#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Cisco Secure Client + the RWW VPN profile by running the
    pre-built SFX bundle from the private network share. Designed to run
    elevated on a single box (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/CiscoSecureClientInst.ps1

    Source file (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\CiscoSecureClient\SecureConnect-VPN-Install.exe
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    This is NOT a from-scratch install script -- it's a thin wrapper around
    an already-built, already-documented artifact from the separate
    randysworldwide/SecureConnect repo (screenconnect/ folder), originally
    built for one-click deployment via the ConnectWise ScreenConnect Shared
    Toolbox. That repo is private, so this project can't reference it over
    GitHub the way it does for everything else -- instead, the built .exe
    (not the source, not the raw predeploy ZIPs, not the profile editor
    tool -- see chat for why those aren't needed here) lives on the same
    private share as the other secret-adjacent installers (ConnectWise
    Agent, SentinelOne).

    The SFX bundle already does everything internally, so this wrapper is
    intentionally simple -- there's no separate msiexec call, no MST, no
    profile-drop logic here, because the .exe already contains all of that
    (per the SecureConnect repo's own README):
      - Self-extracts silently to %TEMP%, no UI
      - Runs msiexec /quiet with its own retry/backoff on exit 1618
      - Skips reinstalling if Cisco Secure Client 5.1+ is already present
        (this script's own pre-check below is for THIS project's logging/
        exit-code consistency, not because the exe needs it)
      - Drops the RWW VPN profile XML and restarts csc_vpnagent

    Verification uses the exact same check the SecureConnect repo's own
    README documents for post-deploy validation, for consistency with that
    project rather than inventing a separate one:
        Test-Path '...\RWW-SecureConnect-VpnProfile.xml' AND
        (Get-Service csc_vpnagent).Status -eq 'Running'

.PARAMETER LogPath
    Where to write this script's own log file. The SFX bundle also writes
    its own detailed logs to C:\Windows\Logs\SecureConnect-OnDemand.log and
    SecureConnect-OnDemand-msi.log -- check those for anything beyond a
    plain pass/fail here.

.EXITCODES
    0 = success -- Cisco Secure Client was actually installed this run
    1 = the SFX bundle ran but post-install verification didn't pass
    2 = could not reach/copy the .exe from the network share
    3 = not running elevated
    4 = nothing to do -- Cisco Secure Client (with the RWW profile) was already present
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\CiscoSecureClientInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir    = "$env:ProgramData\Dev\AppsDeploy\CiscoSecureClient"
$SharePaths  = @(
    '\\svazdfs001\systems$\Software\CiscoSecureClient',
    '\\10.1.0.5\systems$\Software\CiscoSecureClient'
)
$ExeFileName    = 'SecureConnect-VPN-Install.exe'
$ProfilePath    = 'C:\ProgramData\Cisco\Cisco Secure Client\VPN\Profile\RWW-SecureConnect-VpnProfile.xml'
$ServiceName    = 'csc_vpnagent'
$TimeoutSeconds = 300   # the SFX itself only claims 30-90s end-to-end; generous margin for a slow disk/first run

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

function Test-SecureConnectReady {
    # Same check the SecureConnect repo's own README uses for post-wave
    # verification -- reused here rather than inventing a separate one.
    $profileExists = Test-Path -LiteralPath $ProfilePath -ErrorAction SilentlyContinue
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return [bool]($profileExists -and $svc -and $svc.Status -eq 'Running')
}

Write-Log "=== Install-CiscoSecureClient starting on $env:COMPUTERNAME ==="

if (Test-SecureConnectReady) {
    Write-Log "Cisco Secure Client + RWW VPN profile already present and $ServiceName is running. Skipping."
    Write-Log "Nothing was installed -- Cisco Secure Client was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $exeCandidate = Join-Path $candidate $ExeFileName
    Write-Log "Checking share path: $candidate"
    if (Test-Path $exeCandidate -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found $ExeFileName at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach $ExeFileName on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localExe = Join-Path $StageDir $ExeFileName
    Write-Log "Staging file to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $ExeFileName) -Destination $localExe -Force
} catch {
    Write-Log "Failed to copy $ExeFileName from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localExe (self-extracting bundle -- handles msiexec, retries, and the VPN profile drop internally)"
$proc = Start-Process -FilePath $localExe -PassThru -NoNewWindow
# CONFIRMED VIA A REAL FAILURE (ZAC reported FAILED with an EMPTY exit
# code while the install actually succeeded): Start-Process -PassThru
# WITHOUT -Wait doesn't cache the process handle, and without it,
# .ExitCode can come back $null once the process has exited -- a known
# PowerShell gotcha. The old blocking WaitForExit() call implicitly
# initialized the handle; the polling-loop replacement (the freeze fix)
# removed that side effect. Touching .Handle immediately after launch is
# the canonical fix -- it forces the handle to be cached while the
# process is guaranteed to still exist.
$null = $proc.Handle

# Polling instead of a blocking WaitForExit() call -- confirmed via real
# testing on ZACInst.ps1 that raw Process.WaitForExit() on an STA thread
# (the background install runspace is correctly STA) can freeze that
# thread's own message pump if the launched process creates any window,
# even a hidden/silent one, that communicates back via window messages.
# This bundle is exactly that kind of process. Start-Sleep doesn't carry
# the same message-pump requirement.
$elapsedSeconds = 0
$pollIntervalSeconds = 2
while (-not $proc.HasExited -and $elapsedSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Seconds $pollIntervalSeconds
    $elapsedSeconds += $pollIntervalSeconds
}

if (-not $proc.HasExited) {
    Write-Log "Bundle did not finish within $TimeoutSeconds seconds. Killing it." 'ERROR'
    try { $proc.Kill() } catch {}
    Write-Log "=== Install-CiscoSecureClient finished. Overall success: False (timeout) ==="
    exit 1
}

Write-Log "Bundle process exited (code $($proc.ExitCode)). Verifying via profile + service check..."
Write-Log "See C:\Windows\Logs\SecureConnect-OnDemand.log and SecureConnect-OnDemand-msi.log on this machine for the bundle's own detailed log."

if (Test-SecureConnectReady) {
    Write-Log "Verified: profile present and $ServiceName running."
    Write-Log "=== Install-CiscoSecureClient finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Bundle ran but verification failed (profile missing and/or $ServiceName not running). Check the bundle's own logs above for details." 'ERROR'
    Write-Log "=== Install-CiscoSecureClient finished. Overall success: False ==="
    exit 1
}
