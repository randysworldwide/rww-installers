#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the SentinelOne EDR agent via its bundled uninstall.exe.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1, Uninstall mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/SentinelOneUninst.ps1

    Counterpart to SentinelOneInst.ps1. Uses the uninstaller the agent
    itself ships with, confirmed on a real machine at:

        C:\Program Files\SentinelOne\Sentinel Agent <version>\uninstall.exe

    (located via a version-agnostic search, so agent upgrades don't
    break the path.)

    THE ANTI-TAMPER COMPLICATION, stated plainly: SentinelOne agents are
    normally protected by anti-tamper, and while it's enabled a local
    uninstall requires the site/agent PASSPHRASE (the "verification
    key" from the S1 management console). This script prompts for it at
    runtime via a masked WinForms dialog -- the same runtime-secret
    pattern SentinelOneInst.ps1 uses for the site token, and like the
    token, the passphrase is NEVER written to any log. Leaving the
    prompt blank attempts the uninstall WITHOUT a passphrase, which only
    works if anti-tamper is disabled for this agent/site (or was never
    enabled). If the uninstall is rejected, the realistic alternatives
    are console-side: disable anti-tamper for the machine first, or
    trigger the uninstall from the S1 console itself.

    Switches used: /uninstall /norestart /q [/k "<passphrase>"] -- the
    commonly documented convention for this uninstaller. FLAGGING
    HONESTLY: not yet verified against this specific agent version in a
    live run; the bounded wait + service/registry verification below is
    what actually decides success, not the switch convention.

    Verification: SentinelOne's agent runs as the "SentinelAgent"
    service. Success = that service AND the ARP entry are both gone
    within the bounded wait (agent removal can legitimately take several
    minutes).

.EXITCODES
    0 = success -- the agent was actually uninstalled this run
    1 = uninstall failed (uninstaller missing/errored, or the agent was
        still present after the bounded wait -- with anti-tamper enabled
        and a wrong/missing passphrase, this is the expected outcome)
    3 = not running elevated
    4 = nothing to do -- the agent was not installed
    6 = user cancelled the passphrase prompt
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\SentinelOneUninst.log"
)

$ErrorActionPreference = 'Stop'

$VerifyTimeoutSeconds = 600   # agent removal can legitimately take several minutes

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

function Test-S1Installed {
    if (Get-Service -Name 'SentinelAgent' -ErrorAction SilentlyContinue) { return $true }
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Sentinel*Agent*' -or $_.DisplayName -like 'SentinelOne*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Uninstall-SentinelOne starting on $env:COMPUTERNAME ==="

if (-not (Test-S1Installed)) {
    Write-Log "SentinelOne agent is not installed (no service, no registry entry). Nothing to do." 'WARN'
    Write-Log "=== Uninstall-SentinelOne finished. Nothing to do. ==="
    exit 4
}

# --- Locate uninstall.exe, version-agnostically ---
$uninstaller = Get-ChildItem -Path "$env:ProgramFiles\SentinelOne\Sentinel Agent *\uninstall.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1

if (-not $uninstaller) {
    Write-Log "The agent is installed, but no uninstall.exe was found under $env:ProgramFiles\SentinelOne\Sentinel Agent *\ -- cannot proceed locally." 'ERROR'
    Write-Log "=== Uninstall-SentinelOne finished. Overall success: False ==="
    exit 1
}
Write-Log "Found uninstaller: $($uninstaller.FullName)"

# --- Prompt for the anti-tamper passphrase (masked; NEVER logged) ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SentinelOne - Anti-Tamper Passphrase'
$form.Size = New-Object System.Drawing.Size(470, 200)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = "Enter this agent's anti-tamper passphrase (verification key from the S1 console).`r`nLeave BLANK to attempt without one (only works if anti-tamper is disabled)."
$lbl.Location = New-Object System.Drawing.Point(15, 15)
$lbl.Size = New-Object System.Drawing.Size(430, 50)
$form.Controls.Add($lbl)

$txt = New-Object System.Windows.Forms.TextBox
$txt.Location = New-Object System.Drawing.Point(15, 75)
$txt.Size = New-Object System.Drawing.Size(430, 20)
$txt.UseSystemPasswordChar = $true
$form.Controls.Add($txt)

$btnOK = New-Object System.Windows.Forms.Button
$btnOK.Text = 'Uninstall'
$btnOK.Location = New-Object System.Drawing.Point(255, 120)
$btnOK.Size = New-Object System.Drawing.Size(90, 28)
$btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($btnOK)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(355, 120)
$btnCancel.Size = New-Object System.Drawing.Size(90, 28)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($btnCancel)

$form.AcceptButton = $btnOK
$form.CancelButton = $btnCancel

$result = $form.ShowDialog()
$passphrase = $txt.Text
$form.Dispose()

if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Log "Passphrase prompt was cancelled -- not attempting the uninstall." 'WARN'
    Write-Log "=== Uninstall-SentinelOne finished. User cancelled. ==="
    exit 6
}

# --- Run the uninstaller (passphrase, if any, is never logged) ---
$argList = @('/uninstall', '/norestart', '/q')
if (-not [string]::IsNullOrWhiteSpace($passphrase)) {
    $argList += @('/k', "`"$passphrase`"")
    Write-Log "Running: $($uninstaller.FullName) /uninstall /norestart /q /k `"(passphrase not logged)`""
} else {
    Write-Log "Running WITHOUT a passphrase (blank entered -- only works if anti-tamper is disabled): $($uninstaller.FullName) /uninstall /norestart /q" 'WARN'
}

$proc = Start-Process -FilePath $uninstaller.FullName -ArgumentList $argList -PassThru -NoNewWindow
$null = $proc.Handle   # cache the handle so ExitCode stays readable (known -PassThru-without--Wait gotcha)
$proc.WaitForExit()
Write-Log "Uninstaller process exited with code $($proc.ExitCode) -- verifying via the service and registry rather than trusting the exit code alone."

# --- Poll for the agent to actually be gone ---
$elapsed = 0
$pollSeconds = 10
while ($elapsed -lt $VerifyTimeoutSeconds) {
    if (-not (Test-S1Installed)) { break }
    Start-Sleep -Seconds $pollSeconds
    $elapsed += $pollSeconds
}

if (Test-S1Installed) {
    Write-Log "The SentinelOne agent is STILL present after waiting ${VerifyTimeoutSeconds}s. With anti-tamper enabled, a missing/wrong passphrase is the most likely cause -- the alternatives are disabling anti-tamper for this machine in the S1 console first, or triggering the uninstall from the console itself." 'ERROR'
    Write-Log "=== Uninstall-SentinelOne finished. Overall success: False ==="
    exit 1
}

Write-Log "Confirmed the SentinelOne agent is no longer present (service and registry both clear)."
Write-Log "=== Uninstall-SentinelOne finished. Overall success: True ==="
exit 0
