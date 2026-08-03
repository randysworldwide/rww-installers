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
        this project installs -- OfficeO365Inst.ps1's own English-only
        config fix was a red herring for the original multi-language
        symptom, confirmed after the fact; that fix is still kept since
        requesting English-only explicitly is correct practice regardless).
        REMOVED ENTIRELY, INCLUDING en-us: the pre-installed Office is a
        DIFFERENT product from what OfficeO365Inst.ps1 explicitly installs
        (Microsoft 365 Apps for business, en-us) -- leaving the OEM
        pre-installed copy in place, even the English one, would mean two
        different Office installs/licenses on the same machine. Both
        entries are in Initial Setup and Conditional respectively, and
        Initial Setup always runs before Conditional in the manifest
        array, so this always clears out the pre-installed copy BEFORE
        OfficeO365Inst.ps1 (if selected) installs the correct one fresh.

    DELIBERATELY NOT TOUCHED, even though it also showed up in the same
    Programs & Features list -- reasoning, not an oversight:
      - Dell Command | Update for Windows Universal -- a genuinely useful
        Dell tool, not bloat
      - Microsoft Edge -- deeply integrated into Windows; uninstalling it
        is unsupported and can break other things system-wide
      - Microsoft OneDrive -- a legitimate Microsoft 365 business tool,
        not OEM junk, and not something explicitly asked to be removed
      - Microsoft ASP.NET Core Shared Framework, VC++ Redistributable,
        Windows Desktop Runtime (6.0 and 8.0) -- these are runtime
        DEPENDENCIES some other installed software may need. Removing a
        shared runtime blindly risks breaking whatever depends on it,
        with no easy way to know what that is from here -- too risky to
        include in an automatic removal list
      - Remote Desktop Connection -- a core Windows component (mstsc.exe),
        not a real removable app

    Reuses the same registry-based uninstall approach already proven in
    Apps-Deploy-Menu-Uninstall.ps1's Uninstall-ByRegistryMatch: finds the
    Programs & Features entry matching a given DisplayName pattern, and
    either converts a plain MsiExec call to a silent /X, or -- for
    anything else (increasingly common for modern Dell utilities, which
    are often packaged as MSIX/AppX rather than classic MSI) -- runs
    whatever's already registered as the uninstall command, verbatim.
    That's the exact same action Windows itself would take if someone
    clicked "Uninstall" on that entry in Programs & Features, so it
    should work reasonably reliably regardless of packaging format.

    SAME PROTECTED-NAME GUARD as the test uninstaller, carried over as
    defense in depth even though none of the narrow patterns below would
    ever plausibly match it: ScreenConnect Client (or anything else
    providing remote access to the machine) is never touched, regardless
    of what any pattern matches.

    Anything not found is silently skipped, not treated as an error --
    Dell's bundled software mix (or which Office languages ship
    preloaded) could change in a future OEM image revision.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- ran through the full list; anything found was removed
        (or was already absent, which isn't a failure)
    1 = one or more removal attempts were found but failed
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

function Uninstall-ByRegistryMatch {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string[]]$NamePatterns
    )
    Write-Log "--- $DisplayName ---"

    # Finds ALL matches, not just the first -- some patterns here (e.g.
    # "Microsoft 365 - *") are deliberately broad enough to match multiple
    # distinct entries at once (one per pre-installed language), and all
    # of them need to actually be removed, not just whichever one the
    # registry query happens to return first.
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
        Write-Log "Not found -- nothing to remove." 'WARN'
        return $true
    }

    Write-Log "Found $($allMatches.Count) matching entr$(if ($allMatches.Count -eq 1) {'y'} else {'ies'}): $(($allMatches | ForEach-Object { $_.DisplayName }) -join ', ')"

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
        Write-Log "Removing '$($uninstallKey.DisplayName)'. Uninstall string: $uninstallString"

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
            Write-Log "Not a recognizable MsiExec call -- running the registered uninstall string as-is (best effort)." 'WARN'
            try {
                Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$uninstallString`"" -Wait -NoNewWindow -ErrorAction Stop
                Write-Log "Uninstall command completed."
            } catch {
                Write-Log "Uninstall command failed: $($_.Exception.Message)" 'ERROR'
                $overallOk = $false
            }
        }
    }

    return $overallOk
}

Write-Log "=== Install-DebloatOEM starting on $env:COMPUTERNAME ==="

$targets = @(
    @{ DisplayName = 'Dell Core Services';                              NamePatterns = @('Dell Core Services') }
    @{ DisplayName = 'Dell Optimizer';                                  NamePatterns = @('Dell Optimizer*') }
    @{ DisplayName = 'Dell SupportAssist (and related entries)';        NamePatterns = @('Dell SupportAssist*') }
    @{ DisplayName = 'Dell Trusted Device';                             NamePatterns = @('Dell Trusted Device') }
    @{ DisplayName = 'Dell Watchdog Timer';                             NamePatterns = @('Dell Watchdog Timer*') }
    @{ DisplayName = 'Microsoft 365 (all pre-installed languages, including en-us)';   NamePatterns = @('Microsoft 365 - *') }
    @{ DisplayName = 'Microsoft OneNote (all pre-installed languages, including en-us)'; NamePatterns = @('Microsoft OneNote - *') }
)

$anyFailed = $false
foreach ($t in $targets) {
    $ok = Uninstall-ByRegistryMatch -DisplayName $t.DisplayName -NamePatterns $t.NamePatterns
    if (-not $ok) { $anyFailed = $true }
}

if ($anyFailed) {
    Write-Log "One or more removals failed. See errors above." 'ERROR'
    Write-Log "=== Install-DebloatOEM finished. Overall success: False ==="
    exit 1
} else {
    Write-Log "=== Install-DebloatOEM finished. Overall success: True ==="
    exit 0
}
