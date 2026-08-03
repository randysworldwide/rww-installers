#Requires -Version 5.1
<#
.SYNOPSIS
    Sets plugged-in (AC) screen-off and sleep timeouts on the active power
    plan, so the machine doesn't dim/sleep mid-deployment. Designed to run
    elevated (RWW WorkstationDeployment project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/PowerPluggedInInst.ps1

    Values: screen off after 20 minutes, sleep after 60 minutes, while
    plugged in. Applies to whichever power plan is currently active
    (Windows default is usually "Balanced") via powercfg /change, which
    only affects the active plan -- no plan GUID needs to be targeted
    explicitly.

    This is idempotent by nature (setting the same value twice is a
    harmless no-op), so there's no "already applied" detection here --
    it just always (re)applies the values.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success
    1 = one or more powercfg calls failed
    3 = not running elevated
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\PowerPluggedInInst.log"
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

Write-Log "=== Install-PowerPluggedIn starting on $env:COMPUTERNAME ==="

$settings = @(
    @{ Setting = 'monitor-timeout-ac'; Minutes = 20; Label = 'Screen off (plugged in)' }
    @{ Setting = 'standby-timeout-ac'; Minutes = 60; Label = 'Sleep (plugged in)' }
)

$anyFailed = $false
foreach ($s in $settings) {
    Write-Log "Setting $($s.Label) to $($s.Minutes) minutes (powercfg /change $($s.Setting) $($s.Minutes))"
    $proc = Start-Process -FilePath 'powercfg.exe' -ArgumentList @('/change', $s.Setting, $s.Minutes) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Log "powercfg /change $($s.Setting) failed (exit $($proc.ExitCode))." 'ERROR'
        $anyFailed = $true
    }
}

if ($anyFailed) {
    Write-Log "=== Install-PowerPluggedIn finished. Overall success: False ==="
    exit 1
} else {
    Write-Log "=== Install-PowerPluggedIn finished. Overall success: True ==="
    exit 0
}
