#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Cisco Secure Client (all installed modules) via their MSI
    product codes. Designed to run elevated on a single box (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1, Uninstall
    mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/CiscoSecureClientUninst.ps1

    Counterpart to CiscoSecureClientInst.ps1. WHY NOT WINGET, despite a
    listing appearing there: the listing's ID form ("ARP\Machine\X86\
    Cisco Secure Client - AnyConnect VPN") is winget's notation for a
    bare Programs & Features CORRELATION -- there is no actual winget
    package/manifest behind it, so nothing is gained (no known-good
    switches; winget would just shell the registered uninstall string
    for that ONE entry). And Cisco Secure Client installs as MULTIPLE
    MSI modules (core VPN, DART, and others depending on the bundle) --
    removing one module by name leaves the rest behind. This script
    instead sweeps EVERY "Cisco Secure Client*" uninstall registry entry
    and removes each via its MSI product code, silently
    (MSIRESTARTMANAGERCONTROL=Disable prevents the confirmed Restart
    Manager explorer-kill behavior).

    Verification: the sweep is re-run afterward -- success means no
    "Cisco Secure Client*" entries remain.

.EXITCODES
    0 = success -- all Cisco Secure Client modules removed this run
    1 = one or more modules failed to remove (or remained afterward)
    3 = not running elevated
    4 = nothing to do -- no Cisco Secure Client modules were installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\CiscoSecureClientUninst.log"
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

function Get-CiscoModules {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = @()
    foreach ($hive in $hives) {
        $found += @(Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Cisco Secure Client*' -and $_.UninstallString })
    }
    return $found
}

Write-Log "=== Uninstall-CiscoSecureClient starting on $env:COMPUTERNAME ==="

$modules = Get-CiscoModules
if ($modules.Count -eq 0) {
    Write-Log "No Cisco Secure Client modules are installed. Nothing to do." 'WARN'
    Write-Log "=== Uninstall-CiscoSecureClient finished. Nothing to do. ==="
    exit 4
}

Write-Log "Found $($modules.Count) installed module(s): $(($modules | ForEach-Object { $_.DisplayName }) -join '; ')"

$anyFailed = $false
foreach ($m in $modules) {
    if ($m.UninstallString -match '\{[0-9A-Fa-f\-]+\}') {
        $code = $Matches[0]
        Write-Log "Removing '$($m.DisplayName)' via msiexec /x $code /qn /norestart MSIRESTARTMANAGERCONTROL=Disable"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $code /qn /norestart MSIRESTARTMANAGERCONTROL=Disable" -Wait -PassThru -NoNewWindow
        Write-Log "msiexec exit code: $($proc.ExitCode)"
        if ($proc.ExitCode -notin @(0, 3010, 1641)) { $anyFailed = $true }
    } else {
        Write-Log "'$($m.DisplayName)' has no MSI product code in its uninstall string ('$($m.UninstallString)') -- skipping this module rather than guessing." 'ERROR'
        $anyFailed = $true
    }
}

$remaining = Get-CiscoModules
if ($remaining.Count -gt 0) {
    Write-Log "STILL PRESENT after removal attempts: $(($remaining | ForEach-Object { $_.DisplayName }) -join '; ')" 'ERROR'
    Write-Log "=== Uninstall-CiscoSecureClient finished. Overall success: False ==="
    exit 1
}

if ($anyFailed) {
    # Nothing remains, but something errored along the way -- registry is
    # the ground truth, so treat as success with a note.
    Write-Log "All modules are gone despite one or more non-zero exit codes above -- treating as success (registry is the ground truth)." 'WARN'
}
Write-Log "Confirmed no Cisco Secure Client modules remain."
Write-Log "=== Uninstall-CiscoSecureClient finished. Overall success: True ==="
exit 0
