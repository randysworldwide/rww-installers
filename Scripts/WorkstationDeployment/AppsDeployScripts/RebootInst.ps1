#Requires -Version 5.1
<#
.SYNOPSIS
    Reboots the computer. MUST be the last entry in Apps-Deploy-Menu.ps1's
    manifest -- see ordering note below. Designed to run elevated (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/RebootInst.ps1

    CRITICAL ORDERING REQUIREMENT: this must be the absolute last entry
    in $script:AppManifest in Apps-Deploy-Menu.ps1 -- if anything else in
    the manifest came after it, that item would never get to run, since
    the machine would already be restarting. Apps-Deploy-Menu.ps1 builds
    its selection list by walking the manifest array in order (not by
    Dictionary enumeration, which isn't order-guaranteed), so as long as
    this stays the last array entry, it's guaranteed to run last whenever
    it's selected, regardless of what else is checked alongside it.

    Uses Start-Sleep followed by Restart-Computer -Force, rather than
    shelling out to shutdown.exe /r /t <N>. An earlier version used
    shutdown.exe and it failed with a bare exit code 1 and no readable
    error text -- Start-Process only captures the exit code, not
    shutdown.exe's own stderr, so there was nothing to actually debug.
    Restart-Computer is a real PowerShell cmdlet: if it fails (e.g. a
    privilege restriction on this specific machine), it throws a normal,
    readable .NET exception that gets logged -- a real diagnosable
    message instead of an opaque number. This also removes the
    shutdown.exe dependency entirely, in case whatever caused that
    specific failure was tied to that binary rather than to restarting in
    general.

    The delay still serves the same purpose: Start-Sleep blocks for
    $DelaySeconds before the actual restart call, during which time the
    progress window keeps showing this as the active/marquee step rather
    than jumping straight to a cutoff -- giving the tech a visible
    countdown instead of an instant restart.

.PARAMETER LogPath
    Where to write this script's own log file.

.PARAMETER DelaySeconds
    Seconds before the restart actually happens. Defaults to 20.

.EXITCODES
    0 = success -- the restart was initiated (the machine will actually
        restart shortly after this script returns)
    1 = Restart-Computer failed (see the logged exception message for why)
    3 = not running elevated
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\RebootInst.log",
    [int]$DelaySeconds = 20
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

Write-Log "=== Install-Reboot starting on $env:COMPUTERNAME ==="
Write-Log "Waiting $DelaySeconds seconds before restarting -- deliberately delayed, not immediate, so the progress window shows this as the active step for a moment rather than cutting off instantly." 'WARN'

Start-Sleep -Seconds $DelaySeconds

try {
    Write-Log "Calling Restart-Computer -Force"
    Restart-Computer -Force -ErrorAction Stop
} catch {
    Write-Log "Restart-Computer failed: $($_.Exception.Message)" 'ERROR'
    Write-Log "=== Install-Reboot finished. Overall success: False ==="
    exit 1
}

Write-Log "Restart initiated successfully. The machine will restart shortly."
Write-Log "=== Install-Reboot finished. Overall success: True ==="
exit 0
