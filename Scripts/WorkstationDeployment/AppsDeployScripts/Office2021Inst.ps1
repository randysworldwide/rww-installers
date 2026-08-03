#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Office Suite 2021 (volume-licensed, LTSC) via the Office
    Deployment Tool, using a self-generated config XML that requests ONLY
    Office (no Project, no Visio). Designed to run elevated on a single
    box (RWW WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/Office2021Inst.ps1

    Source file (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Microsoft\Office\MSOffice\setup.exe
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    CHANGED FROM AN EARLIER VERSION: this script used to copy the share's
    own configuration-Office2021Enterprise.xml, which turned out (per
    testing) to bundle Project Professional 2021 and Visio LTSC
    Professional 2021 alongside Office -- all three installed together
    whether you wanted them or not. Project and Visio are now their own
    separate, independently-selectable menu entries (ProjectPro2021Inst.ps1,
    VisioPro2021Inst.ps1). This script now generates its own minimal
    config XML at runtime requesting ONLY ProPlus2021Volume, so the three
    can genuinely be selected independently. Only setup.exe itself still
    comes from the share -- the config content no longer does.

    Confirmed product ID / channel (Microsoft Learn, "Product IDs
    supported by the Office Deployment Tool for Click-to-Run"):
    ProPlus2021Volume under Channel="PerpetualVL2021".

    ODT installs can legitimately take 10-20+ minutes depending on
    connection speed and whether it's a fresh CDN download (this config
    doesn't specify a SourcePath, so it pulls from Microsoft's CDN).

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- Office was actually installed this run
    1 = setup.exe reported a non-zero exit code
    2 = could not reach setup.exe on the share, or couldn't write the local config
    3 = not running elevated
    4 = nothing to do -- a matching Office install was already present
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\Office2021Inst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\Office2021"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
    '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
)
$SetupFileName = 'setup.exe'
$ConfigXml = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="PerpetualVL2021">
    <Product ID="ProPlus2021Volume">
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

function Test-Office2021Installed {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Office LTSC 2021*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-Office2021 starting on $env:COMPUTERNAME ==="

if (Test-Office2021Installed) {
    Write-Log "A matching Office 2021 install is already present (matched on DisplayName). Skipping."
    Write-Log "Nothing was installed -- Office 2021 was already present." 'WARN'
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
    $localConfig = Join-Path $StageDir 'configuration-Office2021Only.xml'
    Write-Log "Staging setup.exe to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $SetupFileName) -Destination $localSetup -Force
    Write-Log "Writing generated Office-only config to $localConfig"
    Set-Content -LiteralPath $localConfig -Value $ConfigXml -Encoding UTF8
} catch {
    Write-Log "Failed to stage setup.exe or write the config from/to $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localSetup /configure $localConfig (this can take 10-20+ minutes)"
$proc = Start-Process -FilePath $localSetup -ArgumentList "/configure `"$localConfig`"" -Wait -PassThru -NoNewWindow
$finalCode = $proc.ExitCode
Write-Log "setup.exe exit code: $finalCode"

if ($finalCode -ne 0) {
    Write-Log "Install FAILED (exit code $finalCode)." 'ERROR'
    Write-Log "=== Install-Office2021 finished. Overall success: False ==="
    exit 1
}

if (Test-Office2021Installed) {
    Write-Log "Office 2021 confirmed present after install."
    Write-Log "=== Install-Office2021 finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "setup.exe exited 0 but no matching install was found in the uninstall registry afterward." 'WARN'
    Write-Log "=== Install-Office2021 finished. Overall success: True (unverified by registry) ==="
    exit 0
}
