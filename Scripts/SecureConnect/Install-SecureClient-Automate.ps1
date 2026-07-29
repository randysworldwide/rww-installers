#Requires -Version 5.1
<#
.SYNOPSIS
    Cisco Secure Client (VPN) mass-deploy for ConnectWise Automate.
    Installs the core-vpn predeploy MSI silently and deploys the RWW VPN profile.

.DESCRIPTION
    Designed to run under the Automate agent (LTService = LocalSystem), headless,
    non-interactive, idempotent. Stripped of all self-elevation / UAC / interactive
    / URL-download scaffolding. Automate stages the files; this just installs.

    Expected working folder layout (all three staged into the SAME directory):
        Install-SecureClient-Automate.ps1
        cisco-secure-client-win-<ver>-core-vpn-predeploy-k9.msi
        RWW-SecureConnect-VpnProfile.xml

    Steps:
      1. Skip if Cisco Secure Client >= -MinimumVersion already installed (idempotent).
      2. msiexec /i <msi> /quiet /norestart REBOOT=ReallySuppress /lvx* <log>
         with retry/backoff on 1618 (installer mutex held by patching, etc).
      3. Copy RWW-SecureConnect-VpnProfile.xml into the Secure Client Profile folder.
      4. Restart csc_vpnagent so the profile loads immediately.

.PARAMETER InstallerPath
    Explicit MSI path. Default: auto-find the predeploy MSI next to this script.

.PARAMETER ProfilePath
    Explicit profile XML path. Default: RWW-SecureConnect-VpnProfile.xml next to this script.

.PARAMETER MinimumVersion
    Version that counts as "already installed" (default 5.1.0.0).

.NOTES
    EXIT CODES (read these in Automate):
        0  = success (installed or already present; reboot-required cases mapped to 0)
        2  = no MSI found
        3  = no profile XML found (install still ran; profile not deployed)
        4  = 64-bit Windows required
        <other> = raw msiexec failure code (see MSI log)

    LOGS:
        C:\Windows\Logs\RWW-SecureClient-deploy.log       (this script)
        C:\Windows\Logs\RWW-SecureClient-msi.log          (msiexec verbose)
#>
[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$ProfilePath,
    [string]$MinimumVersion = '5.1.0.0'
)

$ErrorActionPreference = 'Stop'
$LOG_FILE        = 'C:\Windows\Logs\RWW-SecureClient-deploy.log'
$MSI_LOG_FILE    = 'C:\Windows\Logs\RWW-SecureClient-msi.log'
$PROFILE_DIR     = 'C:\ProgramData\Cisco\Cisco Secure Client\VPN\Profile'
$PROFILE_FILE    = 'RWW-SecureConnect-VpnProfile.xml'
$MSI_PATTERN     = 'cisco-secure-client-win-*core-vpn-predeploy-k9.msi'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8 } catch {}
    Write-Output $line
}

# Resolve the folder this script lives in (Automate runs it from the staged dir).
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Write-Log "=== RWW Secure Client deploy: begin on $env:COMPUTERNAME ==="
Write-Log "Script dir: $here | Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Log "64-bit Windows required. Aborting." 'ERROR'
    exit 4
}

# --- Idempotency: already installed at required version? ---
$installedVersion = $null
foreach ($p in @('HKLM:\SOFTWARE\Cisco\Cisco Secure Client',
                 'HKLM:\SOFTWARE\WOW6432Node\Cisco\Cisco Secure Client')) {
    if (Test-Path $p) {
        $ver = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).ProductVersion
        if ($ver) { try { $installedVersion = [version]$ver } catch {}; break }
    }
}
$needsInstall = -not ($installedVersion -and $installedVersion -ge [version]$MinimumVersion)

if (-not $needsInstall) {
    Write-Log "Cisco Secure Client $installedVersion already present (>= $MinimumVersion). Skipping MSI."
} else {
    Write-Log "Not at $MinimumVersion+ (installed: $installedVersion). Installing."

    # --- Resolve MSI ---
    if (-not $InstallerPath) {
        $InstallerPath = Get-ChildItem -Path $here -Filter $MSI_PATTERN -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'arm64' } |
            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
        Write-Log "No installer MSI found (pattern: $MSI_PATTERN) in $here." 'ERROR'
        exit 2
    }
    Write-Log "Using MSI: $InstallerPath"

    # Stage to a stable path so a transient source (Automate temp dir) can't vanish mid-install.
    $stableMsi = Join-Path $env:TEMP ("csc-{0}.msi" -f ([guid]::NewGuid().Guid.Substring(0,8)))
    Copy-Item -LiteralPath $InstallerPath -Destination $stableMsi -Force

    $msiArgs = '/i "{0}" /quiet /norestart REBOOT=ReallySuppress /lvx* "{1}"' -f $stableMsi, $MSI_LOG_FILE

    $maxAttempts = 6; $delay = 15; $finalCode = -1
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Log "msiexec attempt $attempt/$maxAttempts"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        $finalCode = $proc.ExitCode
        Write-Log "msiexec exit code: $finalCode"
        if ($finalCode -in @(0,1641,3010)) { break }
        if ($finalCode -eq 1618 -and $attempt -lt $maxAttempts) {
            Write-Log "Installer busy (1618). Waiting ${delay}s then retrying." 'WARN'
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay + 15, 60)
            continue
        }
        break
    }
    try { Remove-Item -LiteralPath $stableMsi -Force -ErrorAction SilentlyContinue } catch {}

    if ($finalCode -eq 3010 -or $finalCode -eq 1641) {
        Write-Log "Install succeeded; a reboot is required to complete. (mapped to exit 0)" 'WARN'
    } elseif ($finalCode -eq 0) {
        Write-Log "Install succeeded."
    } else {
        Write-Log "Install FAILED (exit $finalCode). See $MSI_LOG_FILE." 'ERROR'
        exit $finalCode
    }
}

# --- Deploy VPN profile ---
if (-not $ProfilePath) { $ProfilePath = Join-Path $here $PROFILE_FILE }
if (-not (Test-Path $ProfilePath)) {
    Write-Log "Profile XML not found: $ProfilePath. Install OK but profile NOT deployed." 'ERROR'
    exit 3
}
try {
    if (-not (Test-Path $PROFILE_DIR)) { New-Item -ItemType Directory -Path $PROFILE_DIR -Force | Out-Null }
    $dest = Join-Path $PROFILE_DIR $PROFILE_FILE
    Copy-Item -LiteralPath $ProfilePath -Destination $dest -Force
    Write-Log "VPN profile deployed: $dest"
} catch {
    Write-Log "Failed to deploy profile: $_" 'ERROR'
    exit 3
}

# --- Restart VPN agent so profile loads now ---
try {
    if (Get-Service csc_vpnagent -ErrorAction SilentlyContinue) {
        Restart-Service -Name csc_vpnagent -Force -ErrorAction SilentlyContinue
        Write-Log "csc_vpnagent restarted; profile is live."
    } else {
        Write-Log "csc_vpnagent not present yet; profile loads on first launch." 'WARN'
    }
} catch {
    Write-Log "Service restart non-fatal: $_" 'WARN'
}

Write-Log "=== RWW Secure Client deploy: done ==="
exit 0
