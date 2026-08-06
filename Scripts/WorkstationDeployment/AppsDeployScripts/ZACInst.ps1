#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Zultys ZAC (softphone) by running the original InstallShield
    bootstrapper EXE locally, rather than driving ZAC.msi directly.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/ZACInst.ps1

    Source folder (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Zultys\ZAC\ZAC_x64-10.0.10\
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    Only needs two files there now: ZAC.msi and ZAC_x64-10.0.10.exe.

    WHY THIS APPROACH, AFTER SIX ROUNDS OF A DIFFERENT ONE: ZAC.msi is a
    "compressed MSI" that also needs files stored UNCOMPRESSED alongside
    it (an administrative-install source layout). An earlier version of
    this script tried to reconstruct that layout on the share -- first by
    staging a few specific known files, then by mirroring the entire
    source tree into a nested "program files\Zultys\ZAC\" folder. Six
    separate real msiexec 1308/1309 errors later (register_x64.vbs,
    check_vc_x64.vbs, PlantronicsDevices.xml, qt.conf, zac.ico, and
    finally a QtWebEngine locale file, translations\qtwebengine_locales\
    en-GB.pak), it became clear the ROOT problem wasn't fixable by
    copying more cleverly: the share was populated from an
    ALREADY-INSTALLED machine's ZAC folder, and installed copies of
    Qt/Chromium-based apps commonly only RETAIN the locale files actually
    in use, not the complete original set -- en-GB.pak was never present
    anywhere we had access to, no matter how the copy was structured.

    FIXED by sidestepping the whole problem: rather than reconstruct an
    administrative-install layout by hand, this runs the original
    Zultys-provided bootstrapper (ZAC_x64-10.0.10.exe) directly. That EXE
    is confirmed to be an InstallShield-generated setup (the install
    wizard's own title bar reads "ZAC - InstallShield Wizard"), and it
    embeds the COMPLETE original package -- every locale file included --
    since it's the pristine vendor deliverable, not a reconstructed copy.
    It extracts its own payload internally and drives its own msiexec
    call, so there's no longer any need to know or maintain a list of
    which sibling files ZAC.msi expects.

    Uses InstallShield's own standard, documented silent-install
    convention for a generic bootstrapper: /s (silent) /v"..." (pass
    arguments through to the wrapped msiexec call). This is InstallShield's
    OWN generic convention, not a vendor-specific guess the way Dell's
    various custom wrapper switches turned out to be -- meaningfully
    higher confidence than most "guessed switch" situations elsewhere in
    this project, but still not something that's been confirmed against
    this SPECIFIC bootstrapper in a live test, so flagging that honestly.
    A bounded timeout guards against the case where the switches don't
    achieve full silence and a wizard window ends up waiting for input
    that will never come -- without a timeout, that would hang the whole
    deployment run indefinitely instead of failing cleanly.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- ZAC was actually installed this run
    1 = the installer reported failure, or timed out (see the log for which)
    2 = could not reach ZAC.msi/ZAC_x64-10.0.10.exe on the network share
    3 = not running elevated
    4 = nothing to do -- ZAC was already installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\ZACInst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir      = "$env:ProgramData\Dev\AppsDeploy\ZACSoftphone"
$SharePaths    = @(
    '\\svazdfs001\systems$\Software\Zultys\ZAC\ZAC_x64-10.0.10',
    '\\10.1.0.5\systems$\Software\Zultys\ZAC\ZAC_x64-10.0.10'
)
$MsiFileName   = 'ZAC.msi'
$ExeFileName   = 'ZAC_x64-10.0.10.exe'
$InstallTimeoutSeconds = 600   # 10 minutes -- generous but bounded, see header

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

function Test-ZACInstalled {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*ZAC*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-ZAC starting on $env:COMPUTERNAME ==="

if (Test-ZACInstalled) {
    Write-Log "ZAC already installed. Skipping."
    Write-Log "Nothing was installed -- ZAC was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $msiCandidate = Join-Path $candidate $MsiFileName
    $exeCandidate = Join-Path $candidate $ExeFileName
    Write-Log "Checking share path: $candidate"
    if ((Test-Path $msiCandidate -ErrorAction SilentlyContinue) -and (Test-Path $exeCandidate -ErrorAction SilentlyContinue)) {
        $sourceDir = $candidate
        Write-Log "Found both ZAC.msi and $ExeFileName at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach ZAC.msi and $ExeFileName together on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localMsi = Join-Path $StageDir $MsiFileName
    $localExe = Join-Path $StageDir $ExeFileName
    Write-Log "Staging both files to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $MsiFileName) -Destination $localMsi -Force -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $sourceDir $ExeFileName) -Destination $localExe -Force -ErrorAction Stop
} catch {
    Write-Log "Failed to copy install files from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

# InstallShield's standard generic-bootstrapper silent convention: /s
# (silent) /v"..." (pass everything in quotes through to the wrapped
# msiexec call). REBOOT=ReallySuppress and /norestart mirror the same
# no-surprise-reboot behavior used by every other MSI-based install in
# this project.
$exeArgs = '/s /v"/qn REBOOT=ReallySuppress /norestart"'
Write-Log "Running: $localExe $exeArgs (timeout ${InstallTimeoutSeconds}s)"

# CONCRETE STRUCTURAL DIFFERENCE, FOUND VIA COMPARISON: this used to use
# -WindowStyle Hidden, which is the ONLY thing that was actually different
# between this script and the three others with a similar timeout-guarded
# Start-Process call (CiscoSecureClientInst.ps1, MXAdminInst.ps1,
# OutlookClassicInst.ps1) -- all three of THOSE use -NoNewWindow instead,
# and none of them exhibited this freeze. -WindowStyle Hidden (without
# -NoNewWindow) makes Start-Process use ShellExecuteEx internally -- a
# COM-based, shell-level API with its own STA threading and message-
# pumping requirements during the launch itself, not just while waiting
# afterward. -NoNewWindow instead uses CreateProcess directly, with no
# COM/shell involvement at all. Switched to match the other three scripts
# exactly, removing this COM-based code path as a possible contributor to
# a real, confirmed freeze that happens specifically at this exact point.
$proc = Start-Process -FilePath $localExe -ArgumentList $exeArgs -PassThru -NoNewWindow
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

# CONFIRMED IN TESTING: this used to call $proc.WaitForExit(ms) directly
# -- a blocking .NET call. This is the ONLY script in the whole project
# that waited this way instead of Start-Process's own -Wait switch
# (used everywhere else), and it's the one that caused a real, confirmed
# GUI freeze: the background worker kept executing fine underneath
# (confirmed via the log -- everything after ZAC kept installing
# normally), but the main progress window's own display froze solid,
# only at the point ZAC ran. Root cause: calling raw
# Process.WaitForExit() from an STA thread (the background runspace is
# correctly STA, per an earlier fix) is a well-documented source of
# exactly this symptom if the launched process creates ANY window --
# even a hidden one, which -WindowStyle Hidden still does -- and that
# window communicates back to the parent via window messages.
# WaitForExit() can starve the calling thread's own message pump while
# blocking, freezing that thread's responsiveness even though the actual
# wait itself completes normally. ZAC's InstallShield bootstrapper is
# exactly the kind of GUI-capable process that does this internally even
# when run silently. Fixed by polling instead of blocking -- Start-Sleep
# doesn't carry the same message-pump requirement that
# Process.WaitForExit() does on an STA thread.
$elapsedSeconds = 0
$pollIntervalSeconds = 2
while (-not $proc.HasExited -and $elapsedSeconds -lt $InstallTimeoutSeconds) {
    Start-Sleep -Seconds $pollIntervalSeconds
    $elapsedSeconds += $pollIntervalSeconds
}

if (-not $proc.HasExited) {
    Write-Log "Installer did not finish within ${InstallTimeoutSeconds}s -- likely means the silent switches didn't achieve full silence and a wizard window is waiting for input that will never come. Killing it rather than hanging the whole deployment run." 'ERROR'
    try { $proc.Kill() } catch {}
    Write-Log "=== Install-ZAC finished. Overall success: False ==="
    exit 1
}

$exitCode = $proc.ExitCode
Write-Log "Installer exit code: $exitCode"

# Defensive fallback for the same null-ExitCode gotcha the .Handle fix
# above addresses: if the exit code STILL can't be read for some reason,
# don't fail a possibly-successful install over an unreadable number --
# fall through to the registry detection below, which is the actual
# ground truth for whether ZAC ended up installed.
if ($null -eq $exitCode) {
    Write-Log "Exit code could not be read from the installer process -- falling back to registry detection as the ground truth instead of treating the unreadable code as a failure." 'WARN'
    if (Test-ZACInstalled) {
        Write-Log "ZAC confirmed present via registry."
        Write-Log "=== Install-ZAC finished. Overall success: True (exit code unreadable, verified via registry) ==="
        exit 0
    } else {
        Write-Log "ZAC not found in the registry either -- treating as a failure." 'ERROR'
        Write-Log "=== Install-ZAC finished. Overall success: False ==="
        exit 1
    }
}

if ($exitCode -notin @(0, 3010, 1641)) {
    Write-Log "Install FAILED (exit code $exitCode)." 'ERROR'
    Write-Log "=== Install-ZAC finished. Overall success: False ==="
    exit 1
}

if ($exitCode -in @(3010, 1641)) {
    Write-Log "Install succeeded; a reboot is required to complete." 'WARN'
}

if (Test-ZACInstalled) {
    Write-Log "ZAC confirmed present after install."
    Write-Log "=== Install-ZAC finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Installer reported success but no matching ZAC entry was found in the registry afterward." 'ERROR'
    Write-Log "=== Install-ZAC finished. Overall success: False ==="
    exit 1
}
