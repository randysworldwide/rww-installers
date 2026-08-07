#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Microsoft Outlook Classic (the standalone per-app C2R
    product) via the Office Deployment Tool. Designed to run elevated on
    a single box (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1, Uninstall mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/OutlookClassicUninst.ps1

    Counterpart to OutlookClassicInst.ps1. Same proven ODT mechanism as
    the Office/Project/Visio uninstall scripts, with one difference: the
    exact Click-to-Run product ID the per-app Outlook installer
    registers isn't documented reliably enough to hardcode -- so instead
    of guessing, this script READS the machine's own ClickToRun
    ProductReleaseIds value at runtime and targets whichever registered
    product ID(s) contain 'Outlook'. Self-adapting, no guessed IDs.

    SCOPE SAFETY: a machine with the full O365/2021 suite installed does
    NOT register a separate Outlook product ID (Outlook is inside the
    suite's own ID) -- so this only ever matches the STANDALONE Outlook
    Classic product, and can't accidentally target a suite.

    setup.exe comes from the same private share location the installers
    use (share credentials required in Uninstall mode -- flagged in the
    manifest).

.EXITCODES
    0 = success -- the standalone Outlook product was removed this run
    1 = uninstall failed (setup.exe error, or the product remained)
    2 = could not reach setup.exe on the network share
    3 = not running elevated
    4 = nothing to do -- no standalone Outlook C2R product is registered
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\OutlookClassicUninst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\OutlookClassicUninstall"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
    '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
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

function Get-OutlookProductIds {
    $config = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if (-not $config -or -not $config.ProductReleaseIds) { return @() }
    return @(($config.ProductReleaseIds -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '*Outlook*' })
}

Write-Log "=== Uninstall-OutlookClassic starting on $env:COMPUTERNAME ==="

$outlookIds = Get-OutlookProductIds
if ($outlookIds.Count -eq 0) {
    Write-Log "No standalone Outlook C2R product is registered in ClickToRun ProductReleaseIds. Nothing to do. (A full Office suite's built-in Outlook does NOT register a separate ID and is deliberately out of scope here.)" 'WARN'
    Write-Log "=== Uninstall-OutlookClassic finished. Nothing to do. ==="
    exit 4
}
Write-Log "Found standalone Outlook product ID(s) registered on this machine: $($outlookIds -join ', ')"

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

# --- Stage + generate the targeted Remove config from the DISCOVERED IDs ---
try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localSetup = Join-Path $StageDir 'setup.exe'
    Write-Log "Staging setup.exe to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir 'setup.exe') -Destination $localSetup -Force

    $productBlocks = ($outlookIds | ForEach-Object { "    <Product ID=`"$_`">`r`n      <Language ID=`"en-us`" />`r`n    </Product>" }) -join "`r`n"
    $configXml = @"
<Configuration>
  <Remove>
$productBlocks
  </Remove>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@
    $configPath = Join-Path $StageDir 'configuration-Remove-OutlookClassic.xml'
    Write-Log "Writing generated targeted-Remove config to $configPath (product IDs discovered from this machine's own registry, not guessed)"
    Set-Content -Path $configPath -Value $configXml -Encoding UTF8
} catch {
    Write-Log "Failed to stage setup.exe / write config: $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localSetup /configure $configPath (silent; FORCEAPPSHUTDOWN closes any open Office apps first)"
$proc = Start-Process -FilePath $localSetup -ArgumentList "/configure `"$configPath`"" -Wait -PassThru -NoNewWindow
Write-Log "setup.exe exit code: $($proc.ExitCode)"

# Cheap insurance against the confirmed Restart Manager explorer-kill
# behavior (see the 7-Zip incident notes in the winget-based uninstall
# scripts).
$explorerCheck = Get-Process -Name explorer -ErrorAction SilentlyContinue
if (-not $explorerCheck) {
    Write-Log "explorer.exe is not running after the removal -- relaunching it." 'WARN'
    try { Start-Process 'explorer.exe' } catch {}
}

# Verify by re-reading the registry -- same standard as everywhere else.
if ((Get-OutlookProductIds).Count -gt 0) {
    Write-Log "A standalone Outlook product ID is STILL registered after setup.exe finished -- treating as a failure regardless of the exit code above." 'ERROR'
    Write-Log "=== Uninstall-OutlookClassic finished. Overall success: False ==="
    exit 1
}

Write-Log "Confirmed no standalone Outlook product remains registered."
Write-Log "=== Uninstall-OutlookClassic finished. Overall success: True ==="
exit 0
