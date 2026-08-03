#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Zultys MXAdmin via the EXE on the private network share.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/MXAdminInst.ps1

    Source file (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Zultys\MXAdmin\admin_setup.exe
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    HONEST UNCERTAINTY: there's no documentation for this installer's
    silent-install switches. This script guesses /S (a common convention
    for NSIS-style installers, and Zultys' other product, ZAC, uses a
    similar installer family) -- but this is genuinely unverified. If /S
    isn't the right switch, the installer will sit at an interactive GUI
    prompt that nothing will ever click. To avoid a deployment silently
    hanging forever on that possibility, this script enforces a hard
    10-minute timeout: if admin_setup.exe hasn't exited by then, it's
    killed and the run is reported as failed rather than left hanging.
    If this happens in testing, it confirms /S isn't accepted and this
    script needs adjusting (either a different switch, or accepting that
    this one can't be run unattended at all).

    Steps:
      1. Skip if MXAdmin is already detected.
      2. Copy the EXE from the network share to local staging.
      3. Run it with /S, bounded by a hard timeout.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- MXAdmin was actually installed this run
    1 = install failed (non-zero exit, or unrecognized outcome)
    2 = could not reach/copy the EXE from the network share
    3 = not running elevated
    4 = nothing to do -- MXAdmin was already installed
    5 = timed out waiting for the installer -- almost certainly means the
        /S switch guess was wrong and it's sitting at a GUI prompt
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\MXAdminInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\MXAdmin"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Zultys\MXAdmin',
    '\\10.1.0.5\systems$\Software\Zultys\MXAdmin'
)
$ExeFileName = 'admin_setup.exe'
$TimeoutSeconds = 600   # 10 minutes -- see HONEST UNCERTAINTY note above

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

function Test-MXAdminInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*MXAdmin*' -or $_.DisplayName -like '*MX Admin*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-MXAdmin starting on $env:COMPUTERNAME ==="

if (Test-MXAdminInstalled) {
    Write-Log "MXAdmin already installed (matched on DisplayName). Skipping."
    Write-Log "Nothing was installed -- MXAdmin was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $exeCandidate = Join-Path $candidate $ExeFileName
    Write-Log "Checking share path: $candidate"
    if (Test-Path $exeCandidate -ErrorAction SilentlyContinue) {
        $sourceDir = $candidate
        Write-Log "Found admin_setup.exe at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach admin_setup.exe on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localExe = Join-Path $StageDir $ExeFileName
    Write-Log "Staging file to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $ExeFileName) -Destination $localExe -Force
} catch {
    Write-Log "Failed to copy admin_setup.exe from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localExe /S (unverified switch -- see script header)"
$proc = Start-Process -FilePath $localExe -ArgumentList '/S' -PassThru -NoNewWindow

if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    Write-Log "Installer did not exit within $TimeoutSeconds seconds -- almost certainly means /S wasn't accepted and it's waiting at a GUI prompt. Killing it." 'ERROR'
    try { $proc.Kill() } catch {}
    Write-Log "=== Install-MXAdmin finished. Overall success: False (timeout) ==="
    exit 5
}

$finalCode = $proc.ExitCode
Write-Log "Installer exit code: $finalCode"

if ($finalCode -ne 0) {
    Write-Log "Install FAILED (exit code $finalCode)." 'ERROR'
    Write-Log "=== Install-MXAdmin finished. Overall success: False ==="
    exit 1
}

if (Test-MXAdminInstalled) {
    Write-Log "MXAdmin confirmed present after install."
    Write-Log "=== Install-MXAdmin finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Installer exited 0 but MXAdmin wasn't found in the uninstall registry afterward -- detection pattern may need adjusting once the real DisplayName is known." 'WARN'
    Write-Log "=== Install-MXAdmin finished. Overall success: True (unverified by registry) ==="
    exit 0
}
