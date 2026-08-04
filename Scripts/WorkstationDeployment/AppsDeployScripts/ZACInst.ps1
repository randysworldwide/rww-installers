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

function Get-MsiUncompressedFileRelativePaths {
    # Queries the MSI's own internal Windows Installer database for files
    # explicitly marked "noncompressed" (msidbFileAttributesNoncompressed,
    # bit 0x2000 in the File table's Attributes column) -- exactly the
    # category of file that gets left as a loose, uncompressed file
    # alongside the MSI rather than packed into its compressed cabinet.
    # register_x64.vbs, check_vc_x64.vbs, and PlantronicsDevices.xml were
    # ALL discovered this same way, one at a time, through three separate
    # real msiexec 1308 errors across three separate test cycles -- this
    # exists so a fourth such file doesn't need the same slow discovery
    # cycle, by asking the MSI directly for the complete, authoritative
    # list instead of relying on a manually-maintained one.
    #
    # UNVERIFIED IN LIVE TESTING: this uses the Windows Installer COM
    # automation API (WindowsInstaller.Installer), which can't be
    # exercised from this development environment the way plain
    # PowerShell logic can -- flagging that honestly. Wrapped so ANY
    # failure here (a COM interop detail, a DefaultDir parsing edge case,
    # etc.) falls back silently to the known $criticalSiblingFiles list
    # in Main rather than breaking the install over an enhancement that
    # was meant to help.
    param([string]$MsiPath)

    $NoncompressedBit = 0x2000
    $installer = $null
    $db = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.OpenDatabase($MsiPath, 0)

        # Directory table lookup: DirectoryId -> @{ Parent; Name }
        $dirLookup = @{}
        $dirView = $db.OpenView("SELECT Directory, Directory_Parent, DefaultDir FROM Directory")
        $dirView.Execute()
        while ($rec = $dirView.Fetch()) {
            $dirId      = $rec.StringData(1)
            $parentId   = $rec.StringData(2)
            $defaultDir = $rec.StringData(3)
            # DefaultDir is "8.3SHORT|LongName", or just one name with no pipe.
            $longName = $defaultDir
            if ($defaultDir -and $defaultDir.Contains('|')) {
                $longName = $defaultDir.Split('|')[1]
            }
            $dirLookup[$dirId] = @{ Parent = $parentId; Name = $longName }
        }

        function Resolve-MsiDirRelativePath {
            param([string]$DirId, [hashtable]$Lookup)
            $parts = @()
            $current = $DirId
            $seen = @{}
            while ($current -and $Lookup.ContainsKey($current) -and -not $seen.ContainsKey($current)) {
                $seen[$current] = $true
                $entry = $Lookup[$current]
                # '.' means "same folder as parent" -- no path segment of
                # its own. Root markers contribute nothing either, since
                # they represent the root itself, not a real subfolder.
                if ($entry.Name -and $entry.Name -ne '.' -and $entry.Name -notin @('TARGETDIR', 'SourceDir')) {
                    $parts = @($entry.Name) + $parts
                }
                $current = $entry.Parent
            }
            return ($parts -join '\')
        }

        $results = @()
        $fileView = $db.OpenView("SELECT File.FileName, File.Attributes, Component.Directory_ FROM File, Component WHERE File.Component_ = Component.Component")
        $fileView.Execute()
        while ($rec = $fileView.Fetch()) {
            $fileNameRaw = $rec.StringData(1)
            $attributes  = $rec.IntegerData(2)
            $dirId       = $rec.StringData(3)

            if (($attributes -band $NoncompressedBit) -ne 0) {
                $longFileName = $fileNameRaw
                if ($fileNameRaw -and $fileNameRaw.Contains('|')) {
                    $longFileName = $fileNameRaw.Split('|')[1]
                }
                $dirRelative = Resolve-MsiDirRelativePath -DirId $dirId -Lookup $dirLookup
                if ($dirRelative) {
                    $results += Join-Path $dirRelative $longFileName
                } else {
                    $results += $longFileName
                }
            }
        }

        return $results
    } catch {
        Write-Log "Dynamic MSI uncompressed-file query failed (this is a best-effort enhancement -- falling back to the known baseline list): $($_.Exception.Message)" 'WARN'
        return @()
    } finally {
        # Explicit COM cleanup -- these can hold a file lock on the MSI
        # otherwise, rather than waiting on .NET garbage collection.
        if ($db) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
        if ($installer) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }
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
    'program files\Zultys\ZAC\PlantronicsDevices.xml'
)

Write-Log "Querying ZAC.msi's own internal database for the complete, authoritative list of uncompressed sibling files (in addition to the three already known from previous testing)."
$dynamicSiblingFiles = Get-MsiUncompressedFileRelativePaths -MsiPath (Join-Path $sourceDir $MsiFileName)
if ($dynamicSiblingFiles.Count -gt 0) {
    Write-Log "MSI database query found $($dynamicSiblingFiles.Count) uncompressed file(s): $($dynamicSiblingFiles -join ', ')"
    foreach ($df in $dynamicSiblingFiles) {
        if ($criticalSiblingFiles -notcontains $df) {
            Write-Log "Adding newly-discovered uncompressed file to the check list: $df"
            $criticalSiblingFiles += $df
        }
    }
} else {
    Write-Log "Dynamic MSI query found nothing (or the query itself failed -- see any warning above) -- proceeding with the known baseline list only: $($criticalSiblingFiles -join ', ')" 'WARN'
}

$stagingAttempts = 3
$stagedOk = $false

for ($stageAttempt = 1; $stageAttempt -le $stagingAttempts; $stageAttempt++) {
    try {
        if (Test-Path $StageDir) { Remove-Item -Path $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $StageDir -ItemType Directory -Force | Out-Null

        # ZAC.msi is a "compressed MSI" that also relies on files stored
        # UNCOMPRESSED alongside it (confirmed to be at least TWO such
        # files -- register_x64.vbs AND check_vc_x64.vbs, both under a
        # "program files\Zultys\ZAC\" subfolder relative to the MSI's own
        # location -- there may be others neither of these two rounds of
        # testing happened to exercise) -- copying only ZAC.msi itself
        # fails with a 1308/1309/1603 error because those sibling files
        # are missing. Stage the whole source folder as a unit instead,
        # same reasoning as AcroProInst.ps1.
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
