#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Adobe Acrobat Pro via the enterprise deployment package on the
    private network share. Designed to run elevated on a single box (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/AcroProInst.ps1

    Source folder (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Adobe\Adobe Acrobat\
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    This is a classic Adobe enterprise deployment package: AcroPro.msi is a
    "compressed" MSI that depends on the .cab files sitting alongside it
    (Core.cab, Languages.cab, etc) -- it will NOT install correctly if only
    AcroPro.msi is copied without the rest of the folder. setup.exe reads
    setup.ini to orchestrate the base MSI, the version-update MSP
    (AcrobatDCx64Upd*.msp), and any MST in the Transforms\ subfolder, all
    in one pass -- that's why this script runs setup.exe rather than
    calling msiexec directly against AcroPro.msi (which would install only
    the old base version with none of the update or customization applied).

    The whole folder is staged locally as a unit (recursive copy), except
    for WindowsInstaller-KB893803-v2-x86.exe, a legacy Windows Installer
    3.1 redistributable for Windows XP/Server 2003 -- irrelevant on any
    currently-supported Windows version and deliberately skipped.

    Command used: setup.exe /sAll /rs /msi EULA_ACCEPT=YES /qn -- this is
    Adobe's own documented silent-install command line for this exact
    package layout (base MSI + CABs + setup.exe/setup.ini). Whatever
    setup.ini and the Transforms\ MST already have configured (if
    anything) still applies -- these flags supplement it to force full
    silence regardless.

    NOT VERIFIED (couldn't inspect setup.ini or the MST from this
    environment): whether additional customization is already baked in
    beyond what these command-line flags provide. If the install completes
    but Acrobat prompts for anything on first launch, that's the setup.ini/
    MST customization to look at, not this script.

    MUTUAL EXCLUSION WITH ACROBAT READER: modern, 64-bit-unified Acrobat
    Reader and Acrobat Pro cannot coexist on the same machine -- installing
    one replaces the other. The deployment menu enforces this at the GUI
    level (selecting one deselects and disables the other). This script's
    own detection also matches broadly on "Adobe Acrobat" (not "...Pro"
    specifically) so it correctly treats an existing Reader install as
    "something's already here" rather than trying to install over it.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- Acrobat Pro was actually installed this run
    1 = setup.exe reported a non-zero exit code
    2 = could not reach/copy the install folder from the network share
    3 = not running elevated
    4 = nothing to do -- a matching Adobe Acrobat product was already present
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\AcroProInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\AdobeAcrobatPro"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Adobe\Adobe Acrobat',
    '\\10.1.0.5\systems$\Software\Adobe\Adobe Acrobat'
)
$SetupFileName = 'setup.exe'
$SkipFileName  = 'WindowsInstaller-KB893803-v2-x86.exe'

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

function Test-AdobeAcrobatInstalled {
    # Deliberately broad -- see MUTUAL EXCLUSION note in the header.
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Adobe Acrobat*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-AcrobatPro starting on $env:COMPUTERNAME ==="

if (Test-AdobeAcrobatInstalled) {
    Write-Log "An Adobe Acrobat product is already installed (Reader and Pro can't coexist -- treating any match as satisfied). Skipping."
    Write-Log "Nothing was installed -- an Adobe Acrobat product was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $setupCandidate = Join-Path $candidate $SetupFileName
    Write-Log "Checking share path: $candidate"
    if (Test-Path $setupCandidate -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found $SetupFileName at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach $SetupFileName on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (Test-Path $StageDir) { Remove-Item -Path $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $StageDir -ItemType Directory -Force | Out-Null

    Write-Log "Staging entire install folder to $StageDir (this package needs the CAB files alongside the MSI, so the whole folder is copied as a unit)"
    Get-ChildItem -LiteralPath $sourceDir -Recurse | ForEach-Object {
        if ($_.Name -eq $SkipFileName) {
            Write-Log "Skipping $($_.Name) -- legacy Windows Installer 3.1 redistributable, not needed on any supported Windows version."
            return
        }
        $relativePath = $_.FullName.Substring($sourceDir.Length).TrimStart('\')
        $destPath = Join-Path $StageDir $relativePath
        if ($_.PSIsContainer) {
            if (-not (Test-Path $destPath)) { New-Item -Path $destPath -ItemType Directory -Force | Out-Null }
        } else {
            $destParent = Split-Path -Path $destPath -Parent
            if (-not (Test-Path $destParent)) { New-Item -Path $destParent -ItemType Directory -Force | Out-Null }
            Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
        }
    }
} catch {
    Write-Log "Failed to stage the install folder from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

$localSetup = Join-Path $StageDir $SetupFileName
Write-Log "Running: $localSetup /sAll /rs /msi EULA_ACCEPT=YES /qn (can take several minutes)"
$proc = Start-Process -FilePath $localSetup -ArgumentList '/sAll /rs /msi EULA_ACCEPT=YES /qn' `
    -WorkingDirectory $StageDir -Wait -PassThru -NoNewWindow
$finalCode = $proc.ExitCode
Write-Log "setup.exe exit code: $finalCode"

if ($finalCode -ne 0) {
    Write-Log "Install FAILED (exit code $finalCode)." 'ERROR'
    Write-Log "=== Install-AcrobatPro finished. Overall success: False ==="
    exit 1
}

if (Test-AdobeAcrobatInstalled) {
    Write-Log "Adobe Acrobat Pro confirmed present after install."
    Write-Log "=== Install-AcrobatPro finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "setup.exe exited 0 but no Adobe Acrobat product was found in the uninstall registry afterward." 'ERROR'
    Write-Log "=== Install-AcrobatPro finished. Overall success: False ==="
    exit 1
}