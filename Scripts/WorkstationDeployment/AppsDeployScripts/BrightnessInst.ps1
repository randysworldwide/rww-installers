#Requires -Version 5.1
<#
.SYNOPSIS
    Sets display brightness to 50%. Designed to run elevated (RWW
    WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/BrightnessInst.ps1

    Uses WmiMonitorBrightnessMethods, the standard built-in Windows WMI
    class for controlling display brightness. This only works for
    displays exposing brightness control through ACPI -- in practice,
    laptop-integrated panels. Most external desktop monitors (VGA/DVI/
    HDMI/DisplayPort) don't expose brightness this way at all, so on a
    typical desktop this WMI class simply won't have an instance to act
    on. That's treated as an expected, harmless "nothing to do" case
    (exit 4), not a failure -- no laptop/desktop detection needed, this
    naturally only does something where it's actually supported.

    Idempotent by nature (setting the same value twice is a no-op), so
    there's no separate "already at 50%" check -- it just always
    (re)applies the value where a controllable display exists.

.PARAMETER LogPath
    Where to write this script's own log file.

.PARAMETER TargetPercent
    Brightness level to set, 0-100. Defaults to 50.

.EXITCODES
    0 = success -- brightness was set on at least one display
    1 = the WMI call itself failed unexpectedly
    3 = not running elevated
    4 = nothing to do -- no WMI-controllable display found (typically a
        desktop with an external monitor, which doesn't support this)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\BrightnessInst.log",
    [ValidateRange(0, 100)]
    [int]$TargetPercent = 50
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

Write-Log "=== Install-Brightness starting on $env:COMPUTERNAME ==="

$brightnessMethods = Get-CimInstance -Namespace 'root/WMI' -ClassName 'WmiMonitorBrightnessMethods' -ErrorAction SilentlyContinue

if (-not $brightnessMethods) {
    Write-Log "No WMI-controllable display found -- likely a desktop with an external monitor, which doesn't expose brightness this way. Nothing to do." 'WARN'
    exit 4
}

try {
    $anySet = $false
    foreach ($method in $brightnessMethods) {
        Write-Log "Setting brightness to $TargetPercent% on a detected display"
        Invoke-CimMethod -InputObject $method -MethodName 'WmiSetBrightness' -Arguments @{ Timeout = 1; Brightness = $TargetPercent } | Out-Null
        $anySet = $true
    }
    if ($anySet) {
        Write-Log "=== Install-Brightness finished. Overall success: True ==="
        exit 0
    } else {
        Write-Log "No displays were actually set. Nothing to do." 'WARN'
        exit 4
    }
} catch {
    Write-Log "Setting brightness failed: $($_.Exception.Message)" 'ERROR'
    Write-Log "=== Install-Brightness finished. Overall success: False ==="
    exit 1
}
