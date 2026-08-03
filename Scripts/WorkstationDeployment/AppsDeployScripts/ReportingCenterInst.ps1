#Requires -Version 5.1
<#
.SYNOPSIS
    Copies the two RPS Reporting Center RDP shortcut files from the private
    network share to the Public user's desktop (visible to all users on
    the machine). Designed to run elevated on a single box (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ReportingCenterInst.ps1

    Source files (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\RPS-ReportingCenter\Reporting Center - SVAZTSS001 - Redirect All Local Drives.rdp
        \\svazdfs001\systems$\Software\RPS-ReportingCenter\RPS - SVAZTSS001.rdp
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    Not a software install -- just a file copy of two .rdp shortcuts to
    C:\Users\Public\Desktop, where every user on the machine will see them.

    Idempotent: if BOTH destination files already exist, skips entirely
    (no duplicate set gets created). If only one is missing (a partial
    prior copy, or one was manually deleted), copies just the missing one
    rather than skipping or re-copying both.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- at least one file was actually copied this run
    1 = one or more file copies failed
    2 = could not reach the source files on the network share
    3 = not running elevated
    4 = nothing to do -- both files were already present on the Public desktop
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\ReportingCenterInst.log"
)

$ErrorActionPreference = 'Stop'

$DestDir    = 'C:\Users\Public\Desktop'
$SharePaths = @(
    '\\svazdfs001\systems$\Software\RPS-ReportingCenter',
    '\\10.1.0.5\systems$\Software\RPS-ReportingCenter'
)
$FileNames = @(
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

Write-Log "=== Install-ReportingCenter starting on $env:COMPUTERNAME ==="

$missingFiles = $FileNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $DestDir $_) -ErrorAction SilentlyContinue) }

if ($missingFiles.Count -eq 0) {
    Write-Log "Both RDP shortcuts already present on the Public desktop. Skipping."
    Write-Log "Nothing was copied -- both files were already present." 'WARN'
    exit 4
}

Write-Log "Missing on Public desktop: $($missingFiles -join ', ')"

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    Write-Log "Checking share path: $candidate"
    $allReachable = $true
    foreach ($fileName in $missingFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $candidate $fileName) -ErrorAction SilentlyContinue)) {
            $allReachable = $false
            break
        }
    }
    if ($allReachable) {
        $sourceDir = $candidate
        Write-Log "Found the needed file(s) at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach the needed RDP shortcut(s) on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $DestDir)) { New-Item -Path $DestDir -ItemType Directory -Force | Out-Null }
    foreach ($fileName in $missingFiles) {
        $src  = Join-Path $sourceDir $fileName
        $dest = Join-Path $DestDir $fileName
        Write-Log "Copying $fileName to $DestDir"
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
} catch {
    Write-Log "Failed to copy RDP shortcut(s) from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 1
}

$stillMissing = $FileNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $DestDir $_) -ErrorAction SilentlyContinue) }
if ($stillMissing.Count -eq 0) {
    Write-Log "Both RDP shortcuts confirmed present on the Public desktop."
    Write-Log "=== Install-ReportingCenter finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Copy commands ran but these are still missing afterward: $($stillMissing -join ', ')" 'ERROR'
    Write-Log "=== Install-ReportingCenter finished. Overall success: False ==="
    exit 1
}
