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

$criticalSiblingFiles = @(
    'program files\Zultys\ZAC\register_x64.vbs',
    'program files\Zultys\ZAC\check_vc_x64.vbs',
    'program files\Zultys\ZAC\PlantronicsDevices.xml',
    'program files\Zultys\ZAC\qt.conf',
    'program files\Zultys\ZAC\zac.ico'
)
$nestedSiblingDir = 'program files\Zultys\ZAC'

$stagingAttempts = 3
$stagedOk = $false

for ($stageAttempt = 1; $stageAttempt -le $stagingAttempts; $stageAttempt++) {
    try {
        if (Test-Path $StageDir) { Remove-Item -Path $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $StageDir -ItemType Directory -Force | Out-Null

        # ZAC.msi is a "compressed MSI" that also relies on files stored
        # UNCOMPRESSED alongside it -- confirmed to be AT LEAST five such
        # files (register_x64.vbs, check_vc_x64.vbs,
        # PlantronicsDevices.xml, qt.conf, zac.ico), each discovered one
        # at a time through five separate real msiexec 1308 errors across
        # five separate test cycles, all needed at the same nested
        # "program files\Zultys\ZAC\" destination path. Copying only
        # ZAC.msi itself fails with a 1308/1309/1603 error because these
        # sibling files are missing. Stage the whole source folder as a
        # unit instead, same reasoning as AcroProInst.ps1 -- and see the
        # proactive top-level mirror step below the copy loop, which
        # exists specifically so a SIXTH such file doesn't need the same
        # slow one-at-a-time discovery cycle.
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

        # CONFIRMED PATTERN across six separate real msiexec 1308/1309
        # errors, each found one at a time: register_x64.vbs,
        # check_vc_x64.vbs, PlantronicsDevices.xml, qt.conf, and zac.ico
        # were all flat top-level files, but the SIXTH
        # (translations\qtwebengine_locales\en-GB.pak, almost certainly
        # one of many QtWebEngine locale .pak files) revealed the pattern
        # is actually broader: the user's share layout was populated by
        # copying an already-INSTALLED ZAC folder's contents directly
        # (so "translations\qtwebengine_locales\..." sits at the TOP of
        # the source tree), but the MSI's own directory table expects
        # EVERYTHING -- files AND subfolders, at any depth -- to ALSO
        # exist nested one level deeper, under
        # "program files\Zultys\ZAC\". A top-level-only mirror (an
        # earlier version of this fix) covered the first five files but
        # missed this one, since it's nested two levels deep, not flat.
        # Fixed by mirroring the ENTIRE source tree recursively into the
        # nested destination, not just its top level -- this covers any
        # file at any depth the MSI might expect there, without needing
        # to know in advance which ones matter or maintain a per-file
        # list that needs another round-trip every time the MSI turns
        # out to need one more file than the last test found.
        $nestedDestDir = Join-Path $StageDir $nestedSiblingDir
        if (-not (Test-Path $nestedDestDir)) { New-Item -Path $nestedDestDir -ItemType Directory -Force | Out-Null }
        Get-ChildItem -LiteralPath $sourceDir -Recurse -ErrorAction Stop | ForEach-Object {
            $relativeToSource = $_.FullName.Substring($sourceDir.Length).TrimStart('\')
            $nestedDest = Join-Path $nestedDestDir $relativeToSource
            if ($_.PSIsContainer) {
                if (-not (Test-Path $nestedDest)) { New-Item -Path $nestedDest -ItemType Directory -Force | Out-Null }
            } elseif (-not (Test-Path -LiteralPath $nestedDest)) {
                $nestedDestParent = Split-Path -Path $nestedDest -Parent
                if (-not (Test-Path $nestedDestParent)) { New-Item -Path $nestedDestParent -ItemType Directory -Force | Out-Null }
                Copy-Item -LiteralPath $_.FullName -Destination $nestedDest -Force -ErrorAction Stop
            }
        }

        # Explicit sanity check for EACH critical sibling file: confirmed
        # in testing that the copy loop above can complete with no
        # exception at all, yet a specific expected file still be missing
        # locally afterward -- verify each one directly rather than
        # assuming "no exception" means "complete copy".
        $stillMissing = @()
        foreach ($criticalFile in $criticalSiblingFiles) {
            $localCheck = Join-Path $StageDir $criticalFile
            if (-not (Test-Path -LiteralPath $localCheck)) {
                # FALLBACK: confirmed in practice that the share can end up
                # with a needed file present but NOT at the nested path the
                # MSI's own directory table expects -- e.g. if the share
                # gets re-populated by copying an already-INSTALLED ZAC
                # folder (C:\Program Files (x86)\Zultys\ZAC, a flat
                # destination layout) rather than the original
                # administrative-install source package (which has these
                # nested under "program files\Zultys\ZAC\"). Rather than
                # require the share's layout to exactly match what the MSI
                # wants, search the whole source tree for a file with this
                # exact name and, if found anywhere, place it at the
                # correct nested path ourselves.
                $fileName = Split-Path -Path $criticalFile -Leaf
                $fallbackMatch = Get-ChildItem -LiteralPath $sourceDir -Recurse -Filter $fileName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($fallbackMatch) {
                    Write-Log "'$fileName' wasn't at the expected nested path ($criticalFile), but was found elsewhere on the source ($($fallbackMatch.FullName)) -- copying it into the location the MSI actually expects."
                    $destParent = Split-Path -Path $localCheck -Parent
                    if (-not (Test-Path $destParent)) { New-Item -Path $destParent -ItemType Directory -Force | Out-Null }
                    Copy-Item -LiteralPath $fallbackMatch.FullName -Destination $localCheck -Force -ErrorAction Stop
                }
            }
            if (-not (Test-Path -LiteralPath $localCheck)) {
                $stillMissing += $criticalFile
            }
        }

        if ($stillMissing.Count -gt 0) {
            throw "Staging completed without error, but still missing locally afterward (also not found anywhere else on the source under a different layout): $($stillMissing -join ', ')"
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
