#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Google Chrome via winget. Designed to run elevated on a
    single box (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1, Uninstall mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/GChromeUninst.ps1

    Counterpart to GChromeInst.ps1 -- same winget package ID(s), inverse
    operation. Part of the Uninstall mode added to Apps-Deploy-Menu.ps1:
    only apps with a dedicated, safe uninstall script get one of these;
    apps whose removal is risky or needs extra inputs (e.g. SentinelOne's
    passphrase, Office's ODT flow) deliberately don't have one yet and
    show as unavailable in Uninstall mode instead of guessing at a
    destructive operation.

    winget exit code 0x8A150014 (-1978335212, NO_APPLICATIONS_FOUND) is
    treated as "not installed -- nothing to do" (exit 4), not a failure.

.EXITCODES
    0 = success -- Google Chrome was actually uninstalled this run
    1 = uninstall failed
    3 = not running elevated
    4 = nothing to do -- Google Chrome was not installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\GChromeUninst.log"
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

function Resolve-WinGetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidates) { return $candidates.FullName }
    return $null
}

# CONFIRMED VIA A REAL INCIDENT (7-Zip uninstall, Event Viewer
# RestartManager events 10010 + 10006): apps with shell extensions
# (context-menu handlers etc.) have DLLs loaded inside explorer.exe.
# A silent MSI uninstall's Restart Manager step can decide it must shut
# down Explorer to release that in-use DLL -- and then FAIL to restart
# it ("Application SID does not match Conductor SID" from the elevated
# session), leaving the tech staring at a black desktop with no taskbar
# until they manually restart explorer.exe via Task Manager. This
# watchdog runs right after each uninstall command: if Explorer is gone,
# relaunch it immediately, bounding the black-screen window to seconds
# instead of requiring manual recovery.
function Restore-ExplorerIfKilled {
    $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue
    if (-not $explorer) {
        Write-Log "explorer.exe is not running -- an uninstaller's Restart Manager step likely shut it down and failed to restart it (a confirmed real behavior for apps with shell extensions). Relaunching it." 'WARN'
        try {
            Start-Process 'explorer.exe'
        } catch {
            Write-Log "Failed to relaunch explorer.exe: $($_.Exception.Message)" 'WARN'
        }
    }
}

Write-Log "=== Uninstall-GChrome starting on $env:COMPUTERNAME ==="

$winget = Resolve-WinGetPath
if (-not $winget) {
    Write-Log "Could not locate winget.exe on this machine." 'ERROR'
    exit 1
}
Write-Log "Using winget at: $winget"

$NotFoundCode = -1978335212  # 0x8A150014 NO_APPLICATIONS_FOUND
$packageIds = @('Google.Chrome')

$anyRemoved = $false
$anyFailed  = $false
$allMissing = $true

foreach ($id in $packageIds) {
    $args = @('uninstall', '--id', $id, '-e', '--silent', '--accept-source-agreements', '--disable-interactivity')
    Write-Log "Running: winget $($args -join ' ')"
    $proc = Start-Process -FilePath $winget -ArgumentList $args -Wait -PassThru -NoNewWindow
    $code = $proc.ExitCode
    Write-Log "winget exit code: $code"

    Restore-ExplorerIfKilled

    if ($code -eq 0) {
        $anyRemoved = $true
        $allMissing = $false
        Write-Log "Uninstalled $id successfully."
    } elseif ($code -eq $NotFoundCode) {
        Write-Log "$id was not installed -- nothing to do for this ID." 'WARN'
    } else {
        $anyFailed  = $true
        $allMissing = $false
        Write-Log "Uninstall of $id FAILED (winget exit $code)." 'ERROR'
    }
}

# FALLBACK: GChromeInst.ps1 no longer installs via winget -- it uses
# Google's Enterprise MSI directly (see that script's header for why).
# winget uninstall usually still matches it via the Programs & Features
# entry, but that correlation isn't guaranteed, so if winget couldn't
# find or remove it, fall back to the MSI uninstall string from the
# registry directly. MSIRESTARTMANAGERCONTROL=Disable prevents the
# Restart Manager explorer-kill behavior entirely on this path (see the
# watchdog's comment above) -- any in-use file just gets scheduled for
# cleanup at next reboot instead.
if ($anyFailed -or $allMissing) {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = $null
    foreach ($hive in $hives) {
        $entry = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Google Chrome*' -and $_.UninstallString } |
            Select-Object -First 1
        if ($entry) { break }
    }
    if ($entry -and $entry.UninstallString -match '\{[0-9A-Fa-f\-]+\}') {
        $productCode = $Matches[0]
        Write-Log "winget path didn't remove it -- falling back to direct MSI uninstall of product code $productCode"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart MSIRESTARTMANAGERCONTROL=Disable" -Wait -PassThru -NoNewWindow
        Write-Log "msiexec exit code: $($proc.ExitCode)"
        Restore-ExplorerIfKilled
        if ($proc.ExitCode -in @(0, 3010, 1641)) {
            $anyFailed = $false; $anyRemoved = $true; $allMissing = $false
        }
    }
}

if ($anyFailed) {
    Write-Log "=== Uninstall-GChrome finished. Overall success: False ==="
    exit 1
} elseif ($allMissing) {
    Write-Log "Nothing was uninstalled -- Google Chrome was not installed." 'WARN'
    Write-Log "=== Uninstall-GChrome finished. Nothing to do. ==="
    exit 4
} else {
    Write-Log "=== Uninstall-GChrome finished. Overall success: True ==="
    exit 0
}
