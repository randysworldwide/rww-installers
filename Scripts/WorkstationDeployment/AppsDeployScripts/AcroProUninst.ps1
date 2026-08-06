#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Adobe Acrobat Pro via its locally-registered MSI product
    code. Designed to run elevated on a single box (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1, Uninstall
    mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/AcroProUninst.ps1

    Counterpart to AcroProInst.ps1. The INSTALL needs the full enterprise
    package folder from the private share (base MSI + CABs + setup.exe),
    but the UNINSTALL deliberately does not touch the share at all:
    Windows Installer keeps its own cached copy of the registered MSI
    under C:\Windows\Installer, so a standard "msiexec /x {ProductCode}"
    works entirely locally. No share credentials needed in Uninstall mode
    for this app.

    SHARED-IDENTITY CAVEAT (confirmed in earlier testing on the install
    side): modern unified 64-bit builds of Acrobat Pro and Reader both
    register in Programs & Features as "Adobe Acrobat (64-bit)" -- they
    are literally the same binary, differing only in licensing. Since the
    two are mutually exclusive on a machine anyway (enforced by this
    project's own menu), whichever unified Acrobat is present is the one
    this removes.

    Mechanism: finds the ARP entry matching 'Adobe Acrobat*' whose
    uninstall string is an MsiExec call, extracts the {ProductCode}, and
    runs msiexec /x <code> /qn /norestart. Verifies afterward by
    re-checking the registry rather than trusting the exit code alone --
    the same verify-after-acting standard used across this project.

.EXITCODES
    0 = success -- Adobe Acrobat was actually uninstalled this run
    1 = uninstall failed (msiexec error, or still present afterward, or
        the registered entry wasn't an MSI-based install)
    3 = not running elevated
    4 = nothing to do -- no Adobe Acrobat product was installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\AcroProUninst.log"
)

$ErrorActionPreference = 'Stop'

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

function Get-AcrobatArpEntry {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $entry = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Adobe Acrobat*' -and $_.UninstallString } |
            Select-Object -First 1
        if ($entry) { return $entry }
    }
    return $null
}

Write-Log "=== Uninstall-AcroPro starting on $env:COMPUTERNAME ==="

$entry = Get-AcrobatArpEntry
if (-not $entry) {
    Write-Log "No Adobe Acrobat product found in the uninstall registry. Nothing to do." 'WARN'
    Write-Log "=== Uninstall-AcroPro finished. Nothing to do. ==="
    exit 4
}

Write-Log "Found registered product: $($entry.DisplayName)"

if ($entry.UninstallString -notmatch '\{[0-9A-Fa-f\-]+\}') {
    Write-Log "The registered uninstall string doesn't contain an MSI product code -- can't uninstall this variant silently with confidence: $($entry.UninstallString)" 'ERROR'
    Write-Log "=== Uninstall-AcroPro finished. Overall success: False ==="
    exit 1
}

$productCode = $Matches[0]
# MSIRESTARTMANAGERCONTROL=Disable: Acrobat has shell extensions loaded
# inside explorer.exe, and a silent MSI uninstall's Restart Manager step
# can otherwise shut Explorer down and then FAIL to restart it, leaving
# a black desktop -- a confirmed real incident with 7-Zip's uninstall
# (RestartManager events 10010 + 10006). Disabling Restart Manager here
# means any in-use shell-extension DLL just gets scheduled for cleanup
# at next reboot instead of Explorer being killed mid-run.
Write-Log "Running: msiexec /x $productCode /qn /norestart MSIRESTARTMANAGERCONTROL=Disable"
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart MSIRESTARTMANAGERCONTROL=Disable" -Wait -PassThru -NoNewWindow
Write-Log "msiexec exit code: $($proc.ExitCode)"

# Belt-and-suspenders even with Restart Manager disabled above.
$explorerCheck = Get-Process -Name explorer -ErrorAction SilentlyContinue
if (-not $explorerCheck) {
    Write-Log "explorer.exe is not running after the uninstall -- relaunching it." 'WARN'
    try { Start-Process 'explorer.exe' } catch {}
}

if ($proc.ExitCode -notin @(0, 3010, 1641)) {
    Write-Log "Uninstall FAILED (msiexec exit $($proc.ExitCode))." 'ERROR'
    Write-Log "=== Uninstall-AcroPro finished. Overall success: False ==="
    exit 1
}

# Verify by re-checking the registry rather than trusting the exit code
# alone -- same standard as everywhere else in this project.
if (Get-AcrobatArpEntry) {
    Write-Log "An Adobe Acrobat entry is STILL PRESENT in the uninstall registry after msiexec finished -- treating as a failure regardless of the exit code above." 'ERROR'
    Write-Log "=== Uninstall-AcroPro finished. Overall success: False ==="
    exit 1
}

Write-Log "Confirmed no Adobe Acrobat entry remains."
Write-Log "=== Uninstall-AcroPro finished. Overall success: True ==="
exit 0
