#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Google Chrome machine-wide via Google's own official
    Enterprise MSI, downloaded directly. Designed to run elevated on a
    single box (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/GChromeInst.ps1

    CHANGED FROM AN EARLIER VERSION, CONFIRMED VIA REAL TESTING: this used
    to install via winget (Google.Chrome). It failed consistently, every
    time, with "Installer hash does not match" -- and running elevated,
    winget has no interactive override for a hash mismatch, so this was a
    hard, unconditional failure. The actual winget diagnostic log showed
    the real cause precisely: a completely fresh download (not a stale
    cache) still didn't match the hash winget's own community-maintained
    manifest expected for Google.Chrome. That means Google had already
    updated the actual installer being served, but winget's manifest
    hadn't caught up yet -- a known, recurring category of issue for
    "evergreen" auto-updating installers like Chrome, which can happen
    again any time Chrome updates faster than the community manifest does.

    FIXED by bypassing winget's manifest/hash dependency entirely: this
    downloads Google's own official Enterprise MSI directly from Google
    (not a community-maintained package source), and installs it with
    msiexec directly -- the same officially-documented method Google
    itself publishes for enterprise deployment.

        https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi

    This URL doesn't involve a separate manifest/hash-verification layer
    the way winget does -- msiexec just installs whatever Google is
    currently serving at Google's own official enterprise download
    endpoint, so there's no equivalent "manifest lagged behind the real
    file" failure mode possible here.

    Idempotent: checks the uninstall registry keys (including loaded user
    hives) before doing anything, so re-running on a machine that already
    has it is a no-op.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's
    readable without a user profile loaded.

.EXITCODES
    0 = success -- Google Chrome was actually installed this run
    1 = install failed
    2 = could not download the installer from Google
    3 = not running elevated
    4 = nothing to do -- Google Chrome was already installed (no install action taken)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\GChromeInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir       = "$env:ProgramData\Dev\AppsDeploy\GoogleChrome"
$DownloadUrl    = 'https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi'
$LocalMsiName   = 'GoogleChromeStandaloneEnterprise64.msi'

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
# Detection (registry-based, including loaded user hives)
# ---------------------------------------------------------------------------
function Test-AppInstalledByRegistry {
    param([Parameter(Mandatory)][string]$NameLike)

    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $hives += Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
        ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" }

    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$NameLike*" }
        if ($match) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-GChrome starting on $env:COMPUTERNAME ==="

if (Test-AppInstalledByRegistry -NameLike 'Google Chrome') {
    Write-Log "Google Chrome already installed. Skipping."
    Write-Log "Nothing was installed -- Google Chrome was already present." 'WARN'
    exit 4
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localMsi = Join-Path $StageDir $LocalMsiName
    Write-Log "Downloading $DownloadUrl to $localMsi"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $localMsi -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Log "Failed to download the Chrome Enterprise MSI from Google: $($_.Exception.Message)" 'ERROR'
    exit 2
}

$msiArgs = "/i `"$localMsi`" /qn /norestart ALLUSERS=1"
Write-Log "Running: msiexec.exe $msiArgs"
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
$exitCode = $proc.ExitCode
Write-Log "msiexec exit code: $exitCode"

if ($exitCode -in @(0, 3010, 1641) -or (Test-AppInstalledByRegistry -NameLike 'Google Chrome')) {
    Write-Log "Google Chrome installed successfully."
    Write-Log "=== Install-GChrome finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Google Chrome install failed (msiexec exit code $exitCode)." 'ERROR'
    Write-Log "=== Install-GChrome finished. Overall success: False ==="
    exit 1
}
