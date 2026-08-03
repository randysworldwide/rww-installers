<#
.SYNOPSIS
    Installs Java (Eclipse Temurin 21 LTS) machine-wide via winget.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/JavaInst.ps1

    Installs Eclipse Temurin (OpenJDK build), not Oracle's JDK/JRE --
    Oracle's Java SE now requires a paid subscription for most business use,
    Temurin is the same OpenJDK under a fully free license. Pinned to 21
    (current LTS) rather than a rolling 'latest' id; bump the winget id here
    if a different major version is needed for a specific business app.

    Standard winget machine-wide install. No repo-hosted download needed.

    Idempotent: checks the uninstall registry keys (including loaded user
    hives) before doing anything, so re-running on a machine that already
    has it is a no-op.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's readable
    without a user profile loaded.

.EXITCODES
    0 = success -- Java (Eclipse Temurin 21 LTS) was actually installed this run
    1 = install failed
    2 = winget could not be resolved on this machine
    3 = not running elevated
    4 = nothing to do -- Java (Eclipse Temurin 21 LTS) was already installed (no install action taken)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\JavaInst.log"
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
    Write-Log "Not running elevated. Re-run as administrator." 'ERROR'
    exit 3
}

# ---------------------------------------------------------------------------
# winget resolution (not guaranteed on PATH in every context)
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
# Detection (registry-based, not winget list -- faster/more reliable)
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
# Install
# ---------------------------------------------------------------------------
function Install-WithWinget {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [string[]]$ExtraArgs = @()
    )
    $argList = @(
        'install', '--id', $PackageId, '-e', '--silent', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    ) + $ExtraArgs
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-Java starting on $env:COMPUTERNAME ==="

if (Test-AppInstalledByRegistry -NameLike 'Eclipse Temurin JDK') {
    Write-Log "Java (Eclipse Temurin 21 LTS) already installed. Skipping."
    Write-Log "Nothing was installed -- Java (Eclipse Temurin 21 LTS) was already present." 'WARN'
    exit 4
}

$wingetPath = Resolve-WinGetPath
if (-not $wingetPath) {
    Write-Log "winget.exe could not be resolved on this machine." 'ERROR'
    exit 2
}
Write-Log "Using winget at: $wingetPath"


$code = Install-WithWinget -WingetPath $wingetPath -PackageId 'EclipseAdoptium.Temurin.21.JDK' -ExtraArgs @('--scope','machine')
if ($code -eq 0 -or $code -eq -1978335189 -or (Test-AppInstalledByRegistry -NameLike 'Eclipse Temurin JDK')) {
    Write-Log "Java (Eclipse Temurin 21 LTS) installed successfully."
    Write-Log "=== Install-Java finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Java (Eclipse Temurin 21 LTS) install failed (winget exit code $code)." 'ERROR'
    Write-Log "=== Install-Java finished. Overall success: False ==="
    exit 1
}
