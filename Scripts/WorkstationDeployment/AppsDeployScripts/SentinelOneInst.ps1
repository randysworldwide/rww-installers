#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the SentinelOne Windows Agent via the MSI on the private
    network share, passing the site token as an MSI property.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/SentinelOneInst.ps1

    Source files (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\SentinelOne EDR\Windows EDR Installer\
            SentinelInstaller_windows_64bit_v22_3_5_887.msi
            Site Token.txt
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    IMPORTANT -- same category of secret as ConnectWise Agent's SERVERPASS:
    the site token is what determines which SentinelOne tenant/site this
    agent enrolls into. SentinelOne's own documentation confirms the token
    is passed as the SITE_TOKEN MSI property (e.g.
    "msiexec /i SentinelInstaller.msi /q SITE_TOKEN=..."). The MSI itself
    doesn't contain the secret (unlike ConnectWise's MST, which had
    SERVERPASS baked in), but this script still reads the token from the
    private share at runtime and never writes its value to the log or
    prints it to the console -- only whether it was successfully read.

    "Site Token.docx" and "Windows EDR install.docx" on the share are
    human-readable reference copies, not needed for automation -- this
    script reads only "Site Token.txt".

    Steps:
      1. Skip if the SentinelOne agent is already detected.
      2. Copy the MSI from the network share to local staging, and read
         the site token text (not copied to disk anywhere outside the
         staging folder's own use in the msiexec command).
      3. msiexec /i <msi> /quiet /norestart SITE_TOKEN="<token>", with
         retry/backoff on exit code 1618, same pattern as
         Scripts/SecureConnect/Install-SecureClient-Automate.ps1 and
         CWAgentInst.ps1.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- the agent was actually installed this run
    1 = msiexec install failed
    2 = could not reach/copy the MSI or read the site token from the share
    3 = not running elevated
    4 = nothing to do -- the agent was already installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\SentinelOneInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir     = "$env:ProgramData\Dev\AppsDeploy\SentinelOne"
$MsiLogPath   = "$env:ProgramData\Dev\AppsDeploy\Logs\SentinelOneInst-msi.log"
$SharePaths   = @(
    '\\svazdfs001\systems$\Software\SentinelOne EDR\Windows EDR Installer',
    '\\10.1.0.5\systems$\Software\SentinelOne EDR\Windows EDR Installer'
)
$MsiFileName   = 'SentinelInstaller_windows_64bit_v22_3_5_887.msi'
$TokenFileName = 'Site Token.txt'

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

function Test-SentinelOneInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Sentinel*' }
        if ($match) { return $true }
    }
    # Also check for the agent service directly -- more stable across
    # versions than relying on an exact DisplayName string.
    return [bool](Get-Service -Name 'SentinelAgent*' -ErrorAction SilentlyContinue)
}

Write-Log "=== Install-SentinelOne starting on $env:COMPUTERNAME ==="

if (Test-SentinelOneInstalled) {
    Write-Log "SentinelOne agent already installed. Skipping."
    Write-Log "Nothing was installed -- agent was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $msiCandidate   = Join-Path $candidate $MsiFileName
    $tokenCandidate = Join-Path $candidate $TokenFileName
    Write-Log "Checking share path: $candidate"
    if ((Test-Path $msiCandidate -ErrorAction SilentlyContinue) -and (Test-Path $tokenCandidate -ErrorAction SilentlyContinue)) {
        $sourceDir = $candidate
        Write-Log "Found MSI and site token at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach the MSI and/or Site Token.txt on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

$siteToken = $null
try {
    $siteToken = (Get-Content -LiteralPath (Join-Path $sourceDir $TokenFileName) -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($siteToken)) { throw "Site Token.txt was empty." }
    Write-Log "Site token read successfully (not logging its value)."
} catch {
    Write-Log "Failed to read the site token: $($_.Exception.Message)" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localMsi = Join-Path $StageDir $MsiFileName
    Write-Log "Staging MSI to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $MsiFileName) -Destination $localMsi -Force
} catch {
    Write-Log "Failed to copy the MSI from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

# SITE_TOKEN is passed as an MSI property, not logged in the command line
# echo below -- only a redacted placeholder is written to the log.
$msiArgsForLog = '/i "{0}" /quiet /norestart SITE_TOKEN="***REDACTED***" /lvx* "{1}"' -f $localMsi, $MsiLogPath
$msiArgs       = '/i "{0}" /quiet /norestart SITE_TOKEN="{1}" /lvx* "{2}"' -f $localMsi, $siteToken, $MsiLogPath

$maxAttempts = 6; $delay = 15; $finalCode = -1
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Log "msiexec attempt $attempt/$maxAttempts : msiexec $msiArgsForLog"
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
    Write-Log "=== Install-SentinelOne finished. Overall success: False ==="
    exit 1
}

if (Test-SentinelOneInstalled) {
    Write-Log "SentinelOne agent confirmed present after install."
    Write-Log "=== Install-SentinelOne finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "msiexec reported success but the agent was not detected afterward." 'ERROR'
    Write-Log "=== Install-SentinelOne finished. Overall success: False ==="
    exit 1
}
