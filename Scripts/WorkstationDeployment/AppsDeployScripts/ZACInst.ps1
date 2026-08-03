#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Zultys ZAC (softphone) via the MSI on the private network share.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ZACInst.ps1

    Source folder (on the private share; not hosted in this public repo,
    entire folder is staged as a unit -- see below for why):

        \\svazdfs001\systems$\Software\Zultys\ZAC\ZAC_x64-10.0.10\
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    CONFIRMED IN TESTING: ZAC.msi is a "compressed MSI" that also relies on
    files stored UNCOMPRESSED alongside it on the share -- e.g.
    register_x64.vbs, expected under a "program files\Zultys\ZAC\"
    subfolder relative to wherever ZAC.msi itself is run from. An earlier
    version of this script copied only the bare ZAC.msi file, which failed
    with msiexec error 1603 (root cause: Windows Installer error 1309,
    "Error reading from file: ...\register_x64.vbs. System error 3.",
    because that sibling file was never staged). Fixed by staging the
    entire source folder recursively, same approach as AcroProInst.ps1.

    ASSUMPTION WORTH FLAGGING: the share folder also contains
    ZAC_x64-10.0.10.exe. This script uses the MSI, not the EXE, on the
    assumption the EXE is just a bootstrapper wrapping the same MSI --
    matching the pattern already proven for ConnectWise Agent and Cisco
    Secure Client. If testing shows the (now correctly-staged) MSI is
    still missing something the EXE bundles, this will need to switch to
    running the EXE instead -- flag it if the install completes
    without error but ZAC doesn't actually work.

    Steps:
      1. Skip if a ZAC install is already detected.
      2. Copy the entire source folder from the network share to local
         staging as a unit (not just the MSI -- see above), so a flaky
         share connection can't interrupt an in-progress install).
      3. msiexec /i <msi> /quiet /norestart, with retry/backoff on exit
         code 1618 (installer mutex held), same pattern as
         Scripts/SecureConnect/Install-SecureClient-Automate.ps1 and
         CWAgentInst.ps1.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- ZAC was actually installed this run
    1 = msiexec install failed
    2 = could not reach/copy the MSI from the network share
    3 = not running elevated
    4 = nothing to do -- ZAC was already installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\ZACInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir    = "$env:ProgramData\Dev\AppsDeploy\ZACSoftphone"
$MsiLogPath  = "$env:ProgramData\Dev\AppsDeploy\Logs\ZACInst-msi.log"
$SharePaths  = @(
    '\\svazdfs001\systems$\Software\Zultys\ZAC\ZAC_x64-10.0.10',
    '\\10.1.0.5\systems$\Software\Zultys\ZAC\ZAC_x64-10.0.10'
)
$MsiFileName = 'ZAC.msi'

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

function Test-ZACInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*ZAC*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-ZAC starting on $env:COMPUTERNAME ==="

if (Test-ZACInstalled) {
    Write-Log "ZAC already installed (matched on DisplayName). Skipping."
    Write-Log "Nothing was installed -- ZAC was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $msiCandidate = Join-Path $candidate $MsiFileName
    Write-Log "Checking share path: $candidate"
    if (Test-Path $msiCandidate -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found ZAC.msi at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach ZAC.msi on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

$criticalSiblingFile = 'program files\Zultys\ZAC\register_x64.vbs'
$stagingAttempts = 3
$stagedOk = $false

for ($stageAttempt = 1; $stageAttempt -le $stagingAttempts; $stageAttempt++) {
    try {
        if (Test-Path $StageDir) { Remove-Item -Path $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $StageDir -ItemType Directory -Force | Out-Null

        # ZAC.msi is a "compressed MSI" that also relies on some files
        # stored UNCOMPRESSED alongside it (e.g. register_x64.vbs, under a
        # "program files\Zultys\ZAC\" subfolder relative to the MSI's own
        # location) -- copying only ZAC.msi itself fails with a 1309/1603
        # error because those sibling files are missing. Stage the whole
        # source folder as a unit instead, same reasoning as
        # AcroProInst.ps1.
        Write-Log "Staging entire ZAC source folder to $StageDir (attempt $stageAttempt/$stagingAttempts) -- ZAC.msi relies on sibling uncompressed files, not just the bare MSI"

        # -ErrorAction Stop on BOTH calls below is deliberate: confirmed in
        # testing that Get-ChildItem/Copy-Item can silently skip an
        # individual file or subfolder they have trouble reading (a
        # non-terminating error that our try/catch would never see
        # otherwise), leaving an INCOMPLETE local copy with no warning at
        # all -- the install then fails later with an opaque msiexec 1603
        # that gives no hint the real problem was an incomplete copy.
        # Forcing these to Stop means any such problem becomes a real,
        # caught, retriable error instead of a silent gap.
        Get-ChildItem -LiteralPath $sourceDir -Recurse -ErrorAction Stop | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourceDir.Length).TrimStart('\')
            $destPath = Join-Path $StageDir $relativePath
            if ($_.PSIsContainer) {
                if (-not (Test-Path $destPath)) { New-Item -Path $destPath -ItemType Directory -Force | Out-Null }
            } else {
                $destParent = Split-Path -Path $destPath -Parent
                if (-not (Test-Path $destParent)) { New-Item -Path $destParent -ItemType Directory -Force | Out-Null }
                Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force -ErrorAction Stop
            }
        }

        # Explicit sanity check: confirmed in testing that the copy loop
        # above can complete with no exception at all, yet this specific
        # file still be missing locally afterward -- verify it directly
        # rather than assuming "no exception" means "complete copy".
        $localSiblingCheck = Join-Path $StageDir $criticalSiblingFile
        if (-not (Test-Path -LiteralPath $localSiblingCheck)) {
            throw "Staging completed without error, but $criticalSiblingFile is still missing locally afterward."
        }

        $localMsi = Join-Path $StageDir $MsiFileName
        $stagedOk = $true
        break
    } catch {
        Write-Log "Staging attempt $stageAttempt/$stagingAttempts failed: $($_.Exception.Message)" 'WARN'
        if ($stageAttempt -lt $stagingAttempts) {
            Start-Sleep -Seconds 5
        }
    }
}

if (-not $stagedOk) {
    Write-Log "Failed to stage a complete ZAC source folder from $sourceDir after $stagingAttempts attempts -- giving up before attempting msiexec (an incomplete copy would just fail with an opaque error anyway)." 'ERROR'
    exit 2
}

$msiArgs = '/i "{0}" /quiet /norestart /lvx* "{1}"' -f $localMsi, $MsiLogPath

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
    Write-Log "=== Install-ZAC finished. Overall success: False ==="
    exit 1
}

if (Test-ZACInstalled) {
    Write-Log "ZAC confirmed present after install."
    Write-Log "=== Install-ZAC finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "msiexec reported success but ZAC was not found in the uninstall registry afterward." 'ERROR'
    Write-Log "=== Install-ZAC finished. Overall success: False ==="
    exit 1
}
