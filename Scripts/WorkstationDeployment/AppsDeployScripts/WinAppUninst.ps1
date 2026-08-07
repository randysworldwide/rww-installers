#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the Windows App (Remote Desktop client) -- both the
    machine-wide provisioning and every user's installed copy. Designed
    to run elevated on a single box (RWW WorkstationDeployment project --
    see Apps-Deploy-Menu.ps1, Uninstall mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/WinAppUninst.ps1

    Counterpart to WinAppInst.ps1. WHY NOT WINGET, despite
    Microsoft.WindowsApp being a real winget catalog entry: our
    installer PROVISIONS the app machine-wide (DISM/MSIX provisioning),
    and winget uninstall only removes the CURRENT USER's copy -- the
    machine-wide provisioning would remain, silently reinstalling the
    app for every new user profile. The correct inverse of how this
    project installs it is the Appx machinery itself:
      1. Remove-AppxPackage -AllUsers  (every user's installed copy)
      2. Remove-AppxProvisionedPackage (the machine-wide template)
    Package identity: MicrosoftCorporationII.Windows365* -- the same
    match WinAppInst.ps1 itself uses.

.EXITCODES
    0 = success -- the app was actually removed this run
    1 = removal failed (or the package was still present afterward)
    3 = not running elevated
    4 = nothing to do -- the app was not installed or provisioned
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\WinAppUninst.log"
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

$PackagePattern = 'MicrosoftCorporationII.Windows365*'

function Test-WinAppPresent {
    $installed = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $PackagePattern }
    if ($installed) { return $true }
    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like $PackagePattern }
    return [bool]$provisioned
}

Write-Log "=== Uninstall-WindowsApp starting on $env:COMPUTERNAME ==="

if (-not (Test-WinAppPresent)) {
    Write-Log "Windows App is neither installed for any user nor provisioned machine-wide. Nothing to do." 'WARN'
    Write-Log "=== Uninstall-WindowsApp finished. Nothing to do. ==="
    exit 4
}

# 1. Every user's installed copy
try {
    $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $PackagePattern })
    foreach ($pkg in $installed) {
        Write-Log "Removing installed package for all users: $($pkg.PackageFullName)"
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
    }
    if ($installed.Count -eq 0) { Write-Log "No per-user installed copies found (provisioning-only state)." 'WARN' }
} catch {
    Write-Log "Error removing installed copies: $($_.Exception.Message)" 'ERROR'
}

# 2. The machine-wide provisioning
try {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like $PackagePattern })
    foreach ($prov in $provisioned) {
        Write-Log "Removing machine-wide provisioning: $($prov.PackageName)"
        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
    }
    if ($provisioned.Count -eq 0) { Write-Log "No machine-wide provisioning found." 'WARN' }
} catch {
    Write-Log "Error removing provisioning: $($_.Exception.Message)" 'ERROR'
}

# Verify -- presence check is the ground truth, not the absence of errors.
if (Test-WinAppPresent) {
    Write-Log "Windows App is STILL present (installed or provisioned) after the removal attempts above." 'ERROR'
    Write-Log "=== Uninstall-WindowsApp finished. Overall success: False ==="
    exit 1
}

Write-Log "Confirmed Windows App fully removed (no installed copies, no provisioning)."
Write-Log "=== Uninstall-WindowsApp finished. Overall success: True ==="
exit 0
