<#
.SYNOPSIS
    Installs the .NET 8 Desktop Runtime machine-wide via winget.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/DotNet8Inst.ps1

    Standard winget machine-wide install. No repo-hosted download needed.

    Worth knowing: this is a common silent dependency for other Windows
    apps -- Dell Command | Update is one example we've already hit in
    testing (it failed with APPINSTALLER_CLI_ERROR_INSTALL_MISSING_DEPENDENCY,
    0x8A150104, until this runtime was present). Keeping this Default ON in
    Initial Setup and ordered before apps that need it avoids that class of
    failure.

    Idempotent: checks the uninstall registry keys (including loaded user
    hives) before doing anything, so re-running on a machine that already
    has it is a no-op. Matches on "Windows Desktop Runtime - 8" so any
    8.0.x patch version already installed counts as present -- these
    entries are versioned per patch release, so an exact-version match
    would never work across normal patching.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's readable
    without a user profile loaded.

.EXITCODES
    0 = success -- .NET 8 Desktop Runtime was actually installed this run
    1 = install failed
    2 = winget could not be resolved on this machine
    3 = not running elevated
    4 = nothing to do -- a matching runtime was already installed (no install action taken)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\DotNet8Inst.log"
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-DotNet8Desktop starting on $env:COMPUTERNAME ==="

if (Test-AppInstalledByRegistry -NameLike 'Windows Desktop Runtime - 8') {
    Write-Log ".NET 8 Desktop Runtime already installed. Skipping."
    Write-Log "Nothing was installed -- a matching runtime was already present." 'WARN'
    exit 4
}

$wingetPath = Resolve-WinGetPath
if (-not $wingetPath) {
    Write-Log "winget.exe could not be resolved on this machine." 'ERROR'
    exit 2
}
Write-Log "Using winget at: $wingetPath"

$code = Install-WithWinget -WingetPath $wingetPath -PackageId 'Microsoft.DotNet.DesktopRuntime.8' -Scope 'machine'
if ($code -eq 0 -or $code -eq -1978335189 -or (Test-AppInstalledByRegistry -NameLike 'Windows Desktop Runtime - 8')) {
    Write-Log ".NET 8 Desktop Runtime installed successfully."
    Write-Log "=== Install-DotNet8Desktop finished. Overall success: True ==="
    exit 0
} else {
    Write-Log ".NET 8 Desktop Runtime install failed (winget exit code $code)." 'ERROR'
    Write-Log "=== Install-DotNet8Desktop finished. Overall success: False ==="
    exit 1
}
