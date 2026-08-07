#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the RPS Reporting Center .rdp shortcuts from the public
    desktop. Designed to run elevated on a single box (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1, Uninstall
    mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ReportingCenterUninst.ps1

    Counterpart to ReportingCenterInst.ps1, which is not a software
    install at all -- just a copy of two .rdp shortcuts onto
    C:\Users\Public\Desktop. This deletes those same two files (exact
    same names the installer uses). Fully local; no share access needed.

.EXITCODES
    0 = success -- at least one shortcut existed and all present ones
        were removed
    1 = one or more shortcuts existed but could not be deleted
    3 = not running elevated
    4 = nothing to do -- neither shortcut was present
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\ReportingCenterUninst.log"
)

$ErrorActionPreference = 'Stop'

$DestDir  = 'C:\Users\Public\Desktop'
$RdpFiles = @(
    'Reporting Center - SVAZTSS001 - Redirect All Local Drives.rdp',
    'RPS - SVAZTSS001.rdp'
)

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

Write-Log "=== Uninstall-ReportingCenter starting on $env:COMPUTERNAME ==="

$anyFound  = $false
$anyFailed = $false

foreach ($name in $RdpFiles) {
    $path = Join-Path $DestDir $name
    if (Test-Path -LiteralPath $path) {
        $anyFound = $true
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Write-Log "Removed: $path"
        } catch {
            $anyFailed = $true
            Write-Log "Failed to remove $path : $($_.Exception.Message)" 'ERROR'
        }
    } else {
        Write-Log "Not present (nothing to remove): $path" 'WARN'
    }
}

if ($anyFailed) {
    Write-Log "=== Uninstall-ReportingCenter finished. Overall success: False ==="
    exit 1
} elseif (-not $anyFound) {
    Write-Log "Neither shortcut was present. Nothing to do." 'WARN'
    Write-Log "=== Uninstall-ReportingCenter finished. Nothing to do. ==="
    exit 4
} else {
    Write-Log "=== Uninstall-ReportingCenter finished. Overall success: True ==="
    exit 0
}
