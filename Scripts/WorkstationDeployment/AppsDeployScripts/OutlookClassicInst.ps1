#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Outlook Classic via the standalone Click-to-Run installer on
    the private network share. Designed to run elevated on a single box
    (RWW WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/OutlookClassicInst.ps1

    Source file (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Microsoft\Office\Outlook Classic\OutlookClassicSetup.exe
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    This file is Microsoft's standard per-app Click-to-Run web installer
    (originally named OfficeSetup.exe, renamed on the share to avoid
    confusion with the other Office setup.exe under the MSOffice folder --
    that one is the generic ODT bootstrap driven by a config XML, this one
    is a self-contained, product-specific installer). These per-app
    installers are silent by design with no flags needed -- reasonably
    confident here, but not 100% verified, so this script still applies
    the same hard-timeout safety net as MXAdminInst.ps1 in case that
    assumption is wrong on this particular build of the installer.

    Steps:
      1. Skip if Outlook is already detected.
      2. Copy the EXE from the network share to local staging.
      3. Run it with no flags, bounded by a generous timeout (Office C2R
         installs can legitimately take several minutes on a slow link).

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- Outlook was actually installed this run
    1 = install failed (non-zero exit, or unrecognized outcome)
    2 = could not reach/copy the EXE from the network share
    3 = not running elevated
    4 = nothing to do -- Outlook was already installed
    5 = timed out waiting for the installer
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\OutlookClassicInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\OutlookClassic"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Microsoft\Office\Outlook Classic',
    '\\10.1.0.5\systems$\Software\Microsoft\Office\Outlook Classic'
)
$ExeFileName    = 'OutlookClassicSetup.exe'
$TimeoutSeconds = 1800   # 30 minutes -- Office C2R installs can be slow

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

function Test-OutlookInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Microsoft Outlook*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-OutlookClassic starting on $env:COMPUTERNAME ==="

if (Test-OutlookInstalled) {
    Write-Log "Outlook already installed (matched on DisplayName). Skipping."
    Write-Log "Nothing was installed -- Outlook was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $exeCandidate = Join-Path $candidate $ExeFileName
    Write-Log "Checking share path: $candidate"
    if (Test-Path $exeCandidate -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found $ExeFileName at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach $ExeFileName on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localExe = Join-Path $StageDir $ExeFileName
    Write-Log "Staging file to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $ExeFileName) -Destination $localExe -Force
} catch {
    Write-Log "Failed to copy $ExeFileName from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localExe (Microsoft's standard silent-by-default per-app C2R installer, no flags needed)"
$proc = Start-Process -FilePath $localExe -PassThru -NoNewWindow
# CONFIRMED VIA A REAL FAILURE (ZAC reported FAILED with an EMPTY exit
# code while the install actually succeeded): Start-Process -PassThru
# WITHOUT -Wait doesn't cache the process handle, and without it,
# .ExitCode can come back $null once the process has exited -- a known
# PowerShell gotcha. The old blocking WaitForExit() call implicitly
# initialized the handle; the polling-loop replacement (the freeze fix)
# removed that side effect. Touching .Handle immediately after launch is
# the canonical fix -- it forces the handle to be cached while the
# process is guaranteed to still exist.
$null = $proc.Handle

# Polling instead of a blocking WaitForExit() call -- confirmed via real
# testing on ZACInst.ps1 that raw Process.WaitForExit() on an STA thread
# (the background install runspace is correctly STA) can freeze that
# thread's own message pump if the launched process creates any window,
# even a hidden/silent one, that communicates back via window messages.
# Start-Sleep doesn't carry the same message-pump requirement.
$elapsedSeconds = 0
$pollIntervalSeconds = 2
while (-not $proc.HasExited -and $elapsedSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Seconds $pollIntervalSeconds
    $elapsedSeconds += $pollIntervalSeconds
}

if (-not $proc.HasExited) {
    Write-Log "Installer did not exit within $TimeoutSeconds seconds. Killing it." 'ERROR'
    try { $proc.Kill() } catch {}
    Write-Log "=== Install-OutlookClassic finished. Overall success: False (timeout) ==="
    exit 5
}

$finalCode = $proc.ExitCode
Write-Log "Installer exit code: $finalCode"

if ($finalCode -ne 0) {
    Write-Log "Install FAILED (exit code $finalCode)." 'ERROR'
    Write-Log "=== Install-OutlookClassic finished. Overall success: False ==="
    exit 1
}

if (Test-OutlookInstalled) {
    Write-Log "Outlook confirmed present after install."
    Write-Log "=== Install-OutlookClassic finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Installer exited 0 but Outlook wasn't found in the uninstall registry afterward." 'WARN'
    Write-Log "=== Install-OutlookClassic finished. Overall success: True (unverified by registry) ==="
    exit 0
}
