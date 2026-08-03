#Requires -Version 5.1
<#
.SYNOPSIS
    Prompts for and sets a new computer name. Designed to run elevated
    (RWW WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ChangeComputerNameInst.ps1

    Prompts for the new name via a simple VB InputBox
    (Microsoft.VisualBasic.Interaction.InputBox) -- a standard, stable
    .NET dialog, not custom-built COM interop like MuteInst.ps1. Low risk.

    ORDERING: positioned before Join Domain in Initial Setup on purpose.
    Renaming a machine BEFORE it's domain-joined only needs local admin
    rights; renaming an already-domain-joined machine needs domain
    permissions to update the AD computer object's name too. Doing this
    first avoids that extra requirement entirely.

    NO AUTOMATIC REBOOT: Rename-Computer is called without -Restart, same
    reasoning as DomainJoinInst.ps1 and RebootInst.ps1 -- the rename is
    accepted immediately but doesn't take full effect (new name showing
    everywhere, network re-registration, etc.) until a restart, which
    isn't forced here so the rest of a deployment run can continue.

    Validates the entered name against Windows computer-naming rules
    before attempting anything: 1-15 characters (the NetBIOS length
    limit, which Rename-Computer still enforces even for pure DNS
    purposes), letters/digits/hyphens only, can't start or end with a
    hyphen, and can't be all-digits.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- name was changed this run (restart still needed to
        fully take effect, but that's expected, not a failure)
    1 = Rename-Computer failed
    2 = the entered name failed validation
    3 = not running elevated
    4 = nothing to do -- prompt was cancelled/left blank, or the entered
        name matches the current computer name already
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\ChangeComputerNameInst.log"
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

Write-Log "=== Install-ChangeComputerName starting on $env:COMPUTERNAME ==="

Add-Type -AssemblyName Microsoft.VisualBasic
$newName = [Microsoft.VisualBasic.Interaction]::InputBox(
    "Enter the new computer name (1-15 characters, letters/numbers/hyphens only, can't be all digits):",
    "Change Computer Name",
    $env:COMPUTERNAME
)

if ([string]::IsNullOrWhiteSpace($newName)) {
    Write-Log "Prompt was cancelled or left blank. Nothing to do." 'WARN'
    exit 4
}

$newName = $newName.Trim()

if ($newName -eq $env:COMPUTERNAME) {
    Write-Log "Entered name matches the current computer name ($env:COMPUTERNAME already). Nothing to do." 'WARN'
    exit 4
}

$isValid = ($newName -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$') -and ($newName -notmatch '^\d+$')
if (-not $isValid) {
    Write-Log "'$newName' failed validation -- must be 1-15 characters, letters/digits/hyphens only, can't start/end with a hyphen, can't be all digits." 'ERROR'
    exit 2
}

try {
    Write-Log "Renaming computer from $env:COMPUTERNAME to $newName"
    Rename-Computer -NewName $newName -Force -ErrorAction Stop
} catch {
    Write-Log "Rename-Computer failed: $($_.Exception.Message)" 'ERROR'
    Write-Log "=== Install-ChangeComputerName finished. Overall success: False ==="
    exit 1
}

Write-Log "Rename accepted."
Write-Log "A RESTART IS REQUIRED for the new name to fully take effect -- not done automatically here so the rest of this deployment run can continue. Restart this machine when convenient." 'WARN'
Write-Log "=== Install-ChangeComputerName finished. Overall success: True (restart pending) ==="
exit 0
