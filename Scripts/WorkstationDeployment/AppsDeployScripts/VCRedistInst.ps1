<#
.SYNOPSIS
    Installs both the x64 and x86 Microsoft Visual C++ 2015-2022
    Redistributables machine-wide via winget.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/VCRedistInst.ps1

    Installs both architectures since some third-party apps expect the x86
    redistributable even on a 64-bit machine. Each is checked and installed
    independently, so this is safe to re-run if only one is missing.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's readable
    without a user profile loaded.

.EXITCODES
    0 = success -- at least one redistributable was actually installed this run
    1 = one or more redistributables failed to install
    2 = winget could not be resolved on this machine
    3 = not running elevated
    4 = nothing to do -- both redistributables were already installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\VCRedistInst.log"
)

$ErrorActionPreference = 'Stop'
$overallSuccess = $true
$skippedCount = 0

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

function Test-AppInstalledByRegistry {
    param([Parameter(Mandatory)][string]$NameLike)
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$NameLike*" }
        if ($match) { return $true }
    }
    return $false
}

function Install-WithWinget {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId
    )
    $argList = @(
        'install', '--id', $PackageId, '-e', '--silent', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity', '--scope', 'machine'
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

Write-Log "=== Install-VCRedist starting on $env:COMPUTERNAME ==="

$wingetPath = Resolve-WinGetPath
if (-not $wingetPath) {
    Write-Log "winget.exe could not be resolved on this machine." 'ERROR'
    exit 2
}
Write-Log "Using winget at: $wingetPath"

$targets = @(
    @{ Arch = 'x64'; PackageId = 'Microsoft.VCRedist.2015+.x64'; NameLike = 'Visual C++ 2015-2022 Redistributable (x64)' }
    @{ Arch = 'x86'; PackageId = 'Microsoft.VCRedist.2015+.x86'; NameLike = 'Visual C++ 2015-2022 Redistributable (x86)' }
)

foreach ($t in $targets) {
    if (Test-AppInstalledByRegistry -NameLike $t.NameLike) {
        Write-Log "VC++ Redistributable ($($t.Arch)) already installed. Skipping."
        $skippedCount++
        continue
    }
    $code = Install-WithWinget -WingetPath $wingetPath -PackageId $t.PackageId
    if ($code -eq 0 -or $code -eq -1978335189 -or (Test-AppInstalledByRegistry -NameLike $t.NameLike)) {
        Write-Log "VC++ Redistributable ($($t.Arch)) installed successfully."
    } else {
        Write-Log "VC++ Redistributable ($($t.Arch)) install failed (winget exit code $code)." 'ERROR'
        $overallSuccess = $false
    }
}

Write-Log "=== Install-VCRedist finished. Overall success: $overallSuccess ==="
if (-not $overallSuccess) {
    exit 1
} elseif ($skippedCount -eq $targets.Count) {
    Write-Log "Nothing was installed -- both redistributables were already present." 'WARN'
    exit 4
} else {
    exit 0
}
