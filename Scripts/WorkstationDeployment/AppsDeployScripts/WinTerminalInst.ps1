<#
.SYNOPSIS
    Installs Windows Terminal machine-wide via winget, falling back to direct
    MSIX provisioning if winget can't complete it under SYSTEM.
    Designed to run unattended as SYSTEM via ConnectWise Automate, but also
    works fine run manually (elevated) on a single box.

.DESCRIPTION
    Split out from the original combined VSCWinTerminalInst.ps1 (Wrike:
    "Install VS Code and Windows Terminal on all employee machines") so VS
    Code and Windows Terminal can be deployed/selected independently (e.g.
    from the DeployMenu).

    Handles the SYSTEM-context gotchas:
      - winget.exe is not on PATH for SYSTEM (App Installer registers per-user),
        so we resolve the full path under WindowsApps.
      - Windows Terminal is MSIX-only and winget under SYSTEM has no Store
        auth token, so it can fail to fully provision. If winget doesn't
        result in a machine-wide provisioned package, we fall back to
        downloading the latest .msixbundle from the Terminal GitHub releases
        and running Add-AppxProvisionedPackage -SkipLicense (same pattern
        used for the Windows App / RDP client rollout).

    Idempotent: checks Appx state before doing anything, so re-running on a
    machine that already has it is a no-op.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's readable
    without a user profile loaded.

.EXITCODES
    0 = success -- Windows Terminal was actually installed this run
    1 = install failed via both winget and the MSIX fallback
    3 = not running elevated
    4 = nothing to do -- Windows Terminal was already installed (no install action taken)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\WinTerminalInst.log"
)

$ErrorActionPreference = 'Stop'

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
    Write-Log "Not running elevated / as SYSTEM. Re-run as admin or deploy via Automate." 'ERROR'
    exit 3
}

# ---------------------------------------------------------------------------
# winget resolution (SYSTEM context doesn't have it on PATH by default)
# ---------------------------------------------------------------------------
function Resolve-WinGetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidate = Get-ChildItem "$env:ProgramFiles\WindowsApps" `
        -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' `
        -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1

    if ($candidate) {
        $exe = Join-Path $candidate.FullName 'winget.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
function Test-TerminalInstalled {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -AllUsers -ErrorAction SilentlyContinue
    return [bool]$pkg
}

# ---------------------------------------------------------------------------
# Install helpers
# ---------------------------------------------------------------------------
function Install-WithWinget {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Scope = 'machine'
    )
    $argList = @(
        'install', '--id', $PackageId, '-e', '--silent', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity', '--scope', $Scope
    )
    # Retry on APPINSTALLER_CLI_ERROR_INSTALL_INSTALL_IN_PROGRESS (-1978334974 /
    # 0x8A150102) -- observed in testing when winget calls run back-to-back
    # with no gap between them; winget's own installer coordination can
    # briefly report another install in progress even though nothing else
    # is actually running. Same retry/backoff shape as the msiexec 1618
    # handling elsewhere in this project (Cisco Secure Client, ConnectWise
    # Agent).
    $maxAttempts = 4
    $delay = 20
    $exitCode = -1
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Log "Running (attempt $attempt/$maxAttempts): winget $($argList -join ' ')"
        $proc = Start-Process -FilePath $WingetPath -ArgumentList $argList -NoNewWindow -PassThru -Wait
        $exitCode = $proc.ExitCode
        if ($exitCode -ne -1978334974) { break }
        if ($attempt -lt $maxAttempts) {
            Write-Log "winget reported another install already in progress. Waiting ${delay}s then retrying." 'WARN'
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay + 15, 60)
        }
    }
    return $exitCode
}

function Install-TerminalFallback {
    # winget under SYSTEM has no Store auth token, so if it didn't result in
    # a machine-wide provisioned package, pull the msixbundle directly and
    # provision it -- same approach used for the Windows App/RDP rollout.
    Write-Log "Falling back to direct MSIX provisioning for Windows Terminal."
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/terminal/releases/latest' -UseBasicParsing
        $asset = $release.assets |
            Where-Object { $_.name -match '\.msixbundle$' -and $_.name -notmatch 'Preview' } |
            Select-Object -First 1
        if (-not $asset) { throw "No .msixbundle asset found in latest Terminal release." }

        $dest = Join-Path $env:TEMP $asset.name
        Write-Log "Downloading $($asset.name)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing

        Write-Log "Provisioning package machine-wide via DISM"
        Add-AppxProvisionedPackage -Online -PackagePath $dest -SkipLicense -ErrorAction Stop | Out-Null
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Log "Fallback install failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-WindowsTerminal starting on $env:COMPUTERNAME ==="

if (Test-TerminalInstalled) {
    Write-Log "Windows Terminal already installed. Skipping."
    Write-Log "Nothing was installed -- Windows Terminal was already present." 'WARN'
    exit 4
}

$wingetPath = Resolve-WinGetPath
if ($wingetPath) {
    Write-Log "Using winget at: $wingetPath"
} else {
    Write-Log "winget.exe could not be resolved on this machine. Will go straight to the MSIX fallback." 'WARN'
}

$installedOk = $false
if ($wingetPath) {
    $code = Install-WithWinget -WingetPath $wingetPath -PackageId 'Microsoft.WindowsTerminal' -Scope 'machine'
    if ($code -eq 0 -and (Test-TerminalInstalled)) {
        Write-Log "Windows Terminal installed successfully via winget."
        $installedOk = $true
    } else {
        Write-Log "winget install for Terminal did not result in a verified install (exit code $code)." 'WARN'
    }
}

if (-not $installedOk) {
    $installedOk = Install-TerminalFallback
    if ($installedOk) {
        Write-Log "Windows Terminal provisioned successfully via fallback."
    }
}

if ($installedOk) {
    Write-Log "=== Install-WindowsTerminal finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Windows Terminal install failed via both winget and fallback." 'ERROR'
    Write-Log "=== Install-WindowsTerminal finished. Overall success: False ==="
    exit 1
}
