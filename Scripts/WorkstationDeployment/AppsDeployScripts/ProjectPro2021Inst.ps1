#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Project Professional 2021 (volume-licensed) via the Office
    Deployment Tool, using a self-generated config XML. Designed to run
    elevated on a single box (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ProjectPro2021Inst.ps1

    Source file (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Microsoft\Office\MSOffice\setup.exe
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    Split out as its own standalone install because the share's original
    configuration-Office2021Enterprise.xml bundled Project, Visio, and
    Office together -- installing all three whenever any one was selected.
    This script generates its own minimal config requesting ONLY Project,
    independent of Office2021Inst.ps1 and VisioPro2021Inst.ps1. Per
    Microsoft, Project and Visio are separate products from Office and
    install cleanly alongside it (or alongside Office O365) with no known
    conflict -- unlike Adobe Reader/Pro or the two Office tracks, this one
    doesn't need mutual exclusion with anything else in the menu.

    Confirmed product ID / channel (Microsoft Learn, "Product IDs
    supported by the Office Deployment Tool for Click-to-Run"):
    ProjectPro2021Volume under Channel="PerpetualVL2021".

    ODT installs can legitimately take several minutes depending on
    connection speed (this config doesn't specify a SourcePath, so it
    pulls from Microsoft's CDN).

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- Project was actually installed this run
    1 = setup.exe reported a non-zero exit code
    2 = could not reach setup.exe on the share, or couldn't write the local config
    3 = not running elevated
    4 = nothing to do -- a matching Project install was already present
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\ProjectPro2021Inst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\ProjectPro2021"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
    '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
)
$SetupFileName = 'setup.exe'
$ConfigXml = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="PerpetualVL2021">
    <Product ID="ProjectPro2021Volume">
      <Language ID="en-us" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@

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

function Test-ProjectInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Microsoft Project*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-ProjectPro2021 starting on $env:COMPUTERNAME ==="

if (Test-ProjectInstalled) {
    Write-Log "A matching Project install is already present (matched on DisplayName). Skipping."
    Write-Log "Nothing was installed -- Project was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $setupCandidate = Join-Path $candidate $SetupFileName
    Write-Log "Checking share path: $candidate"
    if (Test-Path $setupCandidate -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found setup.exe at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach setup.exe on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localSetup  = Join-Path $StageDir $SetupFileName
    $localConfig = Join-Path $StageDir 'configuration-ProjectPro2021.xml'
    Write-Log "Staging setup.exe to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $SetupFileName) -Destination $localSetup -Force
    Write-Log "Writing generated Project-only config to $localConfig"
    Set-Content -LiteralPath $localConfig -Value $ConfigXml -Encoding UTF8
} catch {
    Write-Log "Failed to stage setup.exe or write the config from/to $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localSetup /configure $localConfig (this can take several minutes)"
$proc = Start-Process -FilePath $localSetup -ArgumentList "/configure `"$localConfig`"" -Wait -PassThru -NoNewWindow
$finalCode = $proc.ExitCode
Write-Log "setup.exe exit code: $finalCode"

if ($finalCode -ne 0) {
    Write-Log "Install FAILED (exit code $finalCode)." 'ERROR'
    Write-Log "=== Install-ProjectPro2021 finished. Overall success: False ==="
    exit 1
}

if (Test-ProjectInstalled) {
    Write-Log "Project confirmed present after install."
    Write-Log "=== Install-ProjectPro2021 finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "setup.exe exited 0 but no matching install was found in the uninstall registry afterward." 'WARN'
    Write-Log "=== Install-ProjectPro2021 finished. Overall success: True (unverified by registry) ==="
    exit 0
}
