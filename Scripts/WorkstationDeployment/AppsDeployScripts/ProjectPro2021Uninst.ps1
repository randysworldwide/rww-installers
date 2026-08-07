#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Project Professional 2021 (volume) via the Office Deployment Tool (ODT).
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1, Uninstall mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ProjectPro2021Uninst.ps1

    Counterpart to ProjectPro2021Inst.ps1 -- same ODT mechanism, inverse
    operation. Uses the exact same setup.exe + generated-config approach
    already CONFIRMED WORKING in real testing by DebloatOEMInst.ps1's
    Office Remove-All step -- the only difference is the generated XML
    targets ONLY this one product (ProjectPro2021Volume) instead of removing
    everything, so a machine with a different Office product installed
    alongside is left alone.

    setup.exe is pulled from the private share (same location the
    installer uses):

        \\svazdfs001\systems$\Software\Microsoft\Office\MSOffice\setup.exe
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    Language note: the generated Remove config specifies en-us, matching
    what ProjectPro2021Inst.ps1 installs. If a copy of this product was somehow
    installed with additional languages outside this deployment system,
    those language packs may be left behind -- acceptable for the
    intended use (undoing this system's own installs).

    Detection: the Click-to-Run Configuration registry key's
    ProductReleaseIds value -- a comma-separated list of installed C2R
    product IDs -- checked for ProjectPro2021Volume specifically. Same check is
    re-run after setup.exe finishes to confirm the removal actually took,
    rather than trusting the exit code alone (the same
    verify-after-acting standard used across this project).

.EXITCODES
    0 = success -- Project Professional 2021 (volume) was actually uninstalled this run
    1 = uninstall failed (setup.exe error, or the product was still
        present afterward)
    2 = could not reach setup.exe on the network share
    3 = not running elevated
    4 = nothing to do -- Project Professional 2021 (volume) was not installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\Office2021Uninst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir    = "$env:ProgramData\Dev\AppsDeploy\ProjectPro2021Uninstall"
$SharePaths  = @(
    '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
    '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
)
$ProductId   = 'ProjectPro2021Volume'

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

function Test-ProductInstalled {
    $config = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if (-not $config -or -not $config.ProductReleaseIds) { return $false }
    $ids = $config.ProductReleaseIds -split ','
    return [bool]($ids | Where-Object { $_.Trim() -eq $ProductId })
}

Write-Log "=== Uninstall-ProjectPro2021 starting on $env:COMPUTERNAME ==="

if (-not (Test-ProductInstalled)) {
    Write-Log "Project Professional 2021 (volume) ($ProductId) is not installed (not present in ClickToRun ProductReleaseIds). Nothing to do." 'WARN'
    Write-Log "=== Uninstall-ProjectPro2021 finished. Nothing to do. ==="
    exit 4
}

# --- Locate setup.exe on the share ---
$sourceDir = $null
foreach ($candidate in $SharePaths) {
    Write-Log "Checking share path: $candidate"
    if (Test-Path (Join-Path $candidate 'setup.exe') -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found setup.exe at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach setup.exe on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

# --- Stage locally + generate the targeted Remove config ---
try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localSetup = Join-Path $StageDir 'setup.exe'
    Write-Log "Staging setup.exe to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir 'setup.exe') -Destination $localSetup -Force

    $configPath = Join-Path $StageDir 'configuration-Remove-ProjectPro2021Volume.xml'
    $configXml = @"
<Configuration>
  <Remove>
    <Product ID="$ProductId">
      <Language ID="en-us" />
    </Product>
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@
    Write-Log "Writing generated targeted-Remove config to $configPath"
    Set-Content -Path $configPath -Value $configXml -Encoding UTF8
} catch {
    Write-Log "Failed to stage setup.exe / write config: $($_.Exception.Message)" 'ERROR'
    exit 2
}

# --- Run the removal ---
Write-Log "Running: $localSetup /configure $configPath (silent, may take a few minutes; FORCEAPPSHUTDOWN closes any open Office apps first)"
$proc = Start-Process -FilePath $localSetup -ArgumentList "/configure `"$configPath`"" -Wait -PassThru -NoNewWindow
Write-Log "setup.exe exit code: $($proc.ExitCode)"

# Cheap insurance against the confirmed Restart Manager explorer-kill
# behavior (see the 7-Zip incident notes in the winget-based uninstall
# scripts): if anything in the removal shut Explorer down and failed to
# restart it, bring it back rather than leaving a black desktop.
$explorerCheck = Get-Process -Name explorer -ErrorAction SilentlyContinue
if (-not $explorerCheck) {
    Write-Log "explorer.exe is not running after the removal -- relaunching it." 'WARN'
    try { Start-Process 'explorer.exe' } catch {}
}

# Verify by re-checking the registry rather than trusting the exit code
# alone -- same standard as everywhere else in this project.
if (Test-ProductInstalled) {
    Write-Log "$ProductId is STILL PRESENT in ClickToRun ProductReleaseIds after setup.exe finished -- treating as a failure regardless of the exit code above." 'ERROR'
    Write-Log "=== Uninstall-ProjectPro2021 finished. Overall success: False ==="
    exit 1
}

Write-Log "Confirmed $ProductId no longer present."
Write-Log "=== Uninstall-ProjectPro2021 finished. Overall success: True ==="
exit 0
