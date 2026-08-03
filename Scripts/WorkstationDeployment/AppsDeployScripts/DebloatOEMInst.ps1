#Requires -Version 5.1
<#
.SYNOPSIS
    Removes OEM bloatware that ships pre-installed on these Dell machines,
    plus ALL pre-installed Office/OneNote (every language, including
    en-us -- see below for why). Designed to run elevated (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/DebloatOEMInst.ps1

    CONFIRMED VIA A REAL PROGRAMS & FEATURES LIST from one of these
    machines -- this targets exactly what showed up there, not a guess:
      - Dell Core Services, Dell Optimizer, Dell SupportAssist (and its
        OS Recovery Plugin / Remediation sub-entries), Dell Trusted
        Device, Dell Watchdog Timer
      - Microsoft 365 / OneNote, ALL languages including en-us -- these
        come bundled on the machine itself (NOT something any script in
        this project installs). REMOVED ENTIRELY, INCLUDING en-us: the
        pre-installed Office is a DIFFERENT product from what
        OfficeO365Inst.ps1 explicitly installs (Microsoft 365 Apps for
        business, en-us) -- leaving even the English OEM copy in place
        would mean two different Office installs/licenses on the same
        machine. Both entries are in Initial Setup and Conditional
        respectively, and Initial Setup always runs before Conditional
        in the manifest array, so this always clears the pre-installed
        copy out BEFORE OfficeO365Inst.ps1 (if selected) installs fresh.

    DELIBERATELY NOT TOUCHED, even though it also showed up in the same
    Programs & Features list -- reasoning, not an oversight:
      - Dell Command | Update for Windows Universal -- a genuinely useful
        Dell tool, not bloat (also explicitly excluded from the Appx
        substring matching below, as an extra safety net)
      - Microsoft Edge -- deeply integrated into Windows; uninstalling it
        is unsupported and can break other things system-wide
      - Microsoft OneDrive -- a legitimate Microsoft 365 business tool,
        not OEM junk, and not something explicitly asked to be removed
      - Microsoft ASP.NET Core Shared Framework, VC++ Redistributable,
        Windows Desktop Runtime (6.0 and 8.0) -- runtime DEPENDENCIES
        some other installed software may need; removing a shared
        runtime blindly risks breaking whatever depends on it
      - Remote Desktop Connection -- a core Windows component (mstsc.exe),
        not a real removable app

    CONFIRMED IN TESTING, TWO SEPARATE ISSUES FOUND AND FIXED:
      1. The Dell apps: an earlier version only tried the registry
         UninstallString approach, which resulted in an interactive
         confirmation window needing a manual click on every machine --
         not actually silent. Root cause: Dell's modern OOBE utilities
         (SupportAssist, Optimizer, Core Services, Trusted Device,
         Watchdog Timer) are commonly packaged as MSIX/AppX apps, and
         their registered Programs & Features "Uninstall" command often
         just launches a small GUI wrapper that shows its own
         confirmation dialog regardless of switches passed to it. Fixed
         by trying Appx removal FIRST (Uninstall-AppxIfPresent, using
         Get-AppxPackage/Remove-AppxPackage and
         Get-AppxProvisionedPackage/Remove-AppxProvisionedPackage) --
         genuinely silent/headless by design, no window ever shown --
         falling back to the registry approach (Uninstall-ByRegistryMatch)
         only if nothing matches as Appx.
      2. Office/OneNote: ALSO confirmed NOT silent -- invoking the
         registered OfficeC2RClient.exe uninstall command directly showed
         an interactive "Uninstall" button, and another confirmation
         click after each one finished, for every language variant. The
         original assumption that Office's own registered uninstall
         command is silent by design was WRONG. Fixed by moving
         Office/OneNote removal entirely off the registry approach and
         onto the Office Deployment Tool itself (Remove-AllOfficeViaODT,
         below) -- the same setup.exe already used by OfficeO365Inst.ps1
         and Office2021Inst.ps1 -- using a <Remove All="True" />
         configuration. Genuinely silent (Display Level="None"), and
         conveniently removes every installed Office language/product in
         ONE pass rather than needing to enumerate each one separately.

    Because of fix #2, this now needs access to the same private share
    setup.exe as the Office install scripts -- see NeedsShareCredentials
    in the manifest entry for this app.

    SAFETY: "Dell Command Update" is explicitly excluded from the Appx
    substring matching (on top of already not appearing in the
    NamePatterns list at all), so it can never be accidentally caught
    even by a loose substring match. Same PROTECTED-NAME guard as the
    test uninstaller is carried over for the registry fallback path too
    (ScreenConnect Client, or anything else providing remote access, is
    never touched regardless of what any pattern matches).

    Anything not found (via any of the strategies above) is silently
    skipped, not treated as an error -- Dell's bundled software mix (or
    which Office languages ship preloaded, or whether a given app is
    Appx-packaged at all) could change in a future OEM image revision.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- ran through the full list; anything found was removed
        (or was already absent, which isn't a failure)
    1 = one or more removal attempts were found but failed -- this now
        also covers the Office ODT step if setup.exe couldn't be reached
        on the share, or if setup.exe ran but Office/OneNote entries were
        still present in the registry afterward
    3 = not running elevated
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\DebloatOEMInst.log"
)

$ErrorActionPreference = 'Continue'   # one target's failure shouldn't stop the rest

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

$script:ProtectedNamePatterns = @('*ScreenConnect*')

# ---------------------------------------------------------------------------
# Strategy 1: Appx removal -- genuinely silent, no window ever shown.
# Returns @{ Found = <bool>; Ok = <bool> } so the caller knows both
# whether anything matched AND whether removal actually succeeded.
# ---------------------------------------------------------------------------
function Uninstall-AppxIfPresent {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string[]]$AppxSubstrings
    )

    $foundAny  = $false
    $failedAny = $false

    foreach ($substring in $AppxSubstrings) {
        $pkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$substring*" -and $_.Name -notlike '*CommandUpdate*' }
        foreach ($pkg in $pkgs) {
            $foundAny = $true
            Write-Log "Found Appx package for '$DisplayName': $($pkg.PackageFullName)"
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log "Removed Appx package: $($pkg.PackageFullName)"
            } catch {
                Write-Log "Failed to remove Appx package $($pkg.PackageFullName): $($_.Exception.Message)" 'ERROR'
                $failedAny = $true
            }
        }

        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -like "*$substring*" -and $_.PackageName -notlike '*CommandUpdate*' }
        foreach ($prov in $provisioned) {
            $foundAny = $true
            Write-Log "Found provisioned Appx package for '$DisplayName': $($prov.PackageName)"
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                Write-Log "Removed provisioned Appx package (so it won't reappear for a future user profile): $($prov.PackageName)"
            } catch {
                Write-Log "Failed to remove provisioned Appx package $($prov.PackageName): $($_.Exception.Message)" 'ERROR'
                $failedAny = $true
            }
        }
    }

    return @{ Found = $foundAny; Ok = (-not $failedAny) }
}

# ---------------------------------------------------------------------------
# Strategy 2 (fallback): registry UninstallString approach, same as the
# test uninstaller's Uninstall-ByRegistryMatch, with best-effort silent
# switches appended for anything that isn't a recognizable MsiExec call.
# ---------------------------------------------------------------------------
function Uninstall-ByRegistryMatch {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string[]]$NamePatterns
    )

    $allMatches = @(Get-ItemProperty -Path @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object {
            $dn = $_.DisplayName
            if (-not $dn) { return $false }
            foreach ($pattern in $NamePatterns) { if ($dn -like $pattern) { return $true } }
            return $false
        })

    if ($allMatches.Count -eq 0) {
        Write-Log "Not found in the uninstall registry either -- nothing to remove." 'WARN'
        return $true
    }

    Write-Log "Found $($allMatches.Count) matching registry entr$(if ($allMatches.Count -eq 1) {'y'} else {'ies'}): $(($allMatches | ForEach-Object { $_.DisplayName }) -join ', ')"

    $overallOk = $true
    foreach ($uninstallKey in $allMatches) {
        if (-not $uninstallKey.UninstallString) {
            Write-Log "'$($uninstallKey.DisplayName)' has no UninstallString -- skipping." 'WARN'
            continue
        }

        $isProtected = $false
        foreach ($protectedPattern in $script:ProtectedNamePatterns) {
            if ($uninstallKey.DisplayName -like $protectedPattern) {
                Write-Log "PROTECTED: matched entry '$($uninstallKey.DisplayName)' also matches a protected pattern ($protectedPattern) -- refusing to touch it." 'ERROR'
                $isProtected = $true
                $overallOk = $false
                break
            }
        }
        if ($isProtected) { continue }

        $uninstallString = $uninstallKey.UninstallString
        Write-Log "Removing '$($uninstallKey.DisplayName)' via registry. Uninstall string: $uninstallString"

        if ($uninstallString -match 'MsiExec\.exe\s*/[IX]\{([0-9A-Fa-f\-]+)\}') {
            $productCode = "{$($Matches[1])}"
            Write-Log "Running: msiexec /X $productCode /quiet /norestart"
            $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/X $productCode /quiet /norestart" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -in @(0, 1605, 3010, 1641)) {
                # 1605 = "not installed" (already gone), 3010/1641 = reboot pending -- both fine
                Write-Log "Removed successfully (exit $($proc.ExitCode))."
            } else {
                Write-Log "msiexec exit $($proc.ExitCode) -- treating as failure." 'ERROR'
                $overallOk = $false
            }
        } else {
            # UNVERIFIED best-effort: appending common silent-switch
            # conventions since the vendor's actual switch (if any) isn't
            # known. Most installers ignore switches they don't
            # recognize, but that's not guaranteed for every tool. Office
            # doesn't go through this path at all anymore -- see
            # Remove-AllOfficeViaODT below, since this registry approach
            # turned out NOT to be silent for Office in real testing.
            $silentAttempt = "$uninstallString /S /silent /quiet /norestart"
            Write-Log "Not a recognizable MsiExec call -- trying with common silent switches appended (unverified, best effort): $silentAttempt" 'WARN'
            try {
                Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$silentAttempt`"" -Wait -NoNewWindow -ErrorAction Stop
                Write-Log "Uninstall command completed."
            } catch {
                Write-Log "Uninstall command failed: $($_.Exception.Message)" 'ERROR'
                $overallOk = $false
            }
        }
    }

    return $overallOk
}

# ---------------------------------------------------------------------------
# Office/OneNote removal: NOT via the registry approach above. Confirmed
# in real testing that invoking the registered OfficeC2RClient.exe
# uninstall command directly (Strategy 2's original approach) is NOT
# silent -- it shows an interactive "Uninstall" button, and another
# confirmation click after it finishes, on every single language variant.
# The actual Microsoft-documented way to silently remove Click-to-Run
# Office is through the Office Deployment Tool itself (the same setup.exe
# already used by OfficeO365Inst.ps1 and Office2021Inst.ps1), using a
# <Remove All="True" /> configuration -- this also conveniently removes
# every installed language/product in ONE pass, rather than needing to
# enumerate each one separately.
# ---------------------------------------------------------------------------
function Test-AnyOfficeClickToRunInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Microsoft 365 - *' -or $_.DisplayName -like 'Microsoft OneNote - *' }
        if ($match) { return $true }
    }
    return $false
}

function Remove-AllOfficeViaODT {
    Write-Log "--- Microsoft 365 / OneNote (all pre-installed languages, via ODT) ---"

    if (-not (Test-AnyOfficeClickToRunInstalled)) {
        Write-Log "No pre-installed Office/OneNote Click-to-Run entries found -- nothing to remove." 'WARN'
        return $true
    }

    $stageDir   = "$env:ProgramData\Dev\AppsDeploy\DebloatOfficeRemoval"
    $sharePaths = @(
        '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
        '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
    )
    $setupFileName = 'setup.exe'
    $configXml = @'
<Configuration>
  <Remove All="True" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@

    $sourceDir = $null
    foreach ($candidate in $sharePaths) {
        $setupCandidate = Join-Path $candidate $setupFileName
        Write-Log "Checking share path: $candidate"
        if (Test-Path $setupCandidate -ErrorAction SilentlyContinue) {
            $sourceDir = $candidate
            Write-Log "Found setup.exe at: $candidate"
            break
        }
    }

    if (-not $sourceDir) {
        Write-Log "Could not reach setup.exe on any known share path. Checked: $($sharePaths -join ', ')" 'ERROR'
        return $false
    }

    try {
        if (-not (Test-Path $stageDir)) { New-Item -Path $stageDir -ItemType Directory -Force | Out-Null }
        $localSetup  = Join-Path $stageDir $setupFileName
        $localConfig = Join-Path $stageDir 'configuration-RemoveAllOffice.xml'
        Write-Log "Staging setup.exe to $stageDir"
        Copy-Item -LiteralPath (Join-Path $sourceDir $setupFileName) -Destination $localSetup -Force
        Write-Log "Writing generated Remove-All config to $localConfig"
        Set-Content -LiteralPath $localConfig -Value $configXml -Encoding UTF8
    } catch {
        Write-Log "Failed to stage setup.exe or write the config from/to ${sourceDir}: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    Write-Log "Running: $localSetup /configure $localConfig (silent, may take a few minutes)"
    $proc = Start-Process -FilePath $localSetup -ArgumentList "/configure `"$localConfig`"" -Wait -PassThru -NoNewWindow
    Write-Log "setup.exe exit code: $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0) {
        Write-Log "ODT remove-all FAILED (exit code $($proc.ExitCode))." 'ERROR'
        return $false
    }

    if (Test-AnyOfficeClickToRunInstalled) {
        Write-Log "setup.exe exited 0 but an Office/OneNote entry is still present in the registry afterward." 'WARN'
        return $false
    }

    Write-Log "Confirmed no Office/OneNote Click-to-Run entries remain."
    return $true
}

Write-Log "=== Install-DebloatOEM starting on $env:COMPUTERNAME ==="

$targets = @(
    @{ DisplayName = 'Dell Core Services';        NamePatterns = @('Dell Core Services');       AppxSubstrings = @('CoreServices') }
    @{ DisplayName = 'Dell Optimizer';             NamePatterns = @('Dell Optimizer*');           AppxSubstrings = @('Optimizer') }
    @{ DisplayName = 'Dell SupportAssist (and related entries)'; NamePatterns = @('Dell SupportAssist*'); AppxSubstrings = @('SupportAssist') }
    @{ DisplayName = 'Dell Trusted Device';        NamePatterns = @('Dell Trusted Device');       AppxSubstrings = @('TrustedDevice') }
    @{ DisplayName = 'Dell Watchdog Timer';        NamePatterns = @('Dell Watchdog Timer*');      AppxSubstrings = @('Watchdog') }
)

# Checks whether a target is STILL present (via either Appx or registry)
# after a removal was attempted. Added because "the uninstall command
# didn't throw an error" turned out to be a much weaker guarantee than it
# looked -- confirmed in real testing where every Dell target logged as
# "removed successfully" but the apps were still present afterward.
# Office already had this kind of real confirmation (it re-checks the
# registry after running ODT); this brings the Dell targets up to the
# same standard instead of just trusting that the command ran cleanly.
function Test-TargetStillPresent {
    param(
        [Parameter(Mandatory)][string[]]$NamePatterns,
        [Parameter(Mandatory)][string[]]$AppxSubstrings
    )

    foreach ($substring in $AppxSubstrings) {
        $appxStillThere = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$substring*" -and $_.Name -notlike '*CommandUpdate*' }
        if ($appxStillThere) { return $true }

        $provStillThere = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -like "*$substring*" -and $_.PackageName -notlike '*CommandUpdate*' }
        if ($provStillThere) { return $true }
    }

    $registryStillThere = Get-ItemProperty -Path @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object {
            $dn = $_.DisplayName
            if (-not $dn) { return $false }
            foreach ($pattern in $NamePatterns) { if ($dn -like $pattern) { return $true } }
            return $false
        }

    return [bool]$registryStillThere
}

$anyFailed = $false
foreach ($t in $targets) {
    Write-Log "--- $($t.DisplayName) ---"

    $appxResult = @{ Found = $false; Ok = $true }
    if ($t.AppxSubstrings.Count -gt 0) {
        $appxResult = Uninstall-AppxIfPresent -DisplayName $t.DisplayName -AppxSubstrings $t.AppxSubstrings
        if (-not $appxResult.Ok) { $anyFailed = $true }
    }

    if ($appxResult.Found) {
        Write-Log "Removed via Appx -- skipping the registry-based fallback for this one."
    } else {
        # Either not Appx-packaged at all, or the Appx check found
        # nothing -- fall back to the registry approach.
        $ok = Uninstall-ByRegistryMatch -DisplayName $t.DisplayName -NamePatterns $t.NamePatterns
        if (-not $ok) { $anyFailed = $true }
    }

    if (Test-TargetStillPresent -NamePatterns $t.NamePatterns -AppxSubstrings $t.AppxSubstrings) {
        Write-Log "STILL PRESENT after the removal attempt above -- treating as a failure despite the uninstall command completing without an error." 'ERROR'
        $anyFailed = $true
    } else {
        Write-Log "Confirmed gone."
    }
}

$officeOk = Remove-AllOfficeViaODT
if (-not $officeOk) { $anyFailed = $true }

if ($anyFailed) {
    Write-Log "One or more removals failed. See errors above." 'ERROR'
    Write-Log "=== Install-DebloatOEM finished. Overall success: False ==="
    exit 1
} else {
    Write-Log "=== Install-DebloatOEM finished. Overall success: True ==="
    exit 0
}
