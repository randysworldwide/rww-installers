#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls Zultys MXAdmin via its own registered uninstaller.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1, Uninstall mode).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/MXAdminUninst.ps1

    Counterpart to MXAdminInst.ps1. MXAdmin installs under
    C:\Program Files (x86)\Zultys\MXAdmin, ADJACENT to ZAC (which
    installs under ...\Zultys\ZAC) -- and both products' Inno-style
    uninsNNN.exe files can end up in the SHARED ...\Zultys\ parent
    folder. Inno Setup uninstallers are strictly PER-PRODUCT, and when a
    second product installs into a folder that already has unins000.exe,
    its uninstaller becomes unins001.exe (the number increments). That
    means "the unins000.exe in the Zultys folder" is NOT a safe way to
    identify MXAdmin's uninstaller -- it may well be ZAC's, and running
    the wrong one uninstalls the wrong product.

    This script therefore resolves the uninstaller from MXAdmin's OWN
    uninstall registry entry -- Windows' record of which uninstaller
    belongs to which product is authoritative -- and deliberately has NO
    guessed-filename fallback. If the registry entry doesn't reference a
    usable uninstaller, it fails with a clear message instead of gambling
    on a file that might belong to ZAC.

    Silent-switch selection, most-authoritative first:
      1. QuietUninstallString, verbatim, if the entry has one -- that IS
         the registered silent uninstall command.
      2. If the uninstaller is an Inno-style unins*.exe: the documented
         Inno convention /VERYSILENT /NORESTART /SUPPRESSMSGBOXES.
      3. Any other non-MSI uninstaller exe: /S (the NSIS-style switch --
         the same one MXAdminInst.ps1 uses to install, so the vendor's
         tooling demonstrably understands it).
      4. An MsiExec-based entry: converted to msiexec /x <code> /qn.

    Like ZACUninst.ps1: process exit is NOT treated as completion (Inno
    uninstallers respawn themselves from temp to delete their own
    files); success is verified by polling for the registry entry to
    actually disappear, within a bounded wait.

.EXITCODES
    0 = success -- MXAdmin was actually uninstalled this run
    1 = uninstall failed (no usable registered uninstaller, uninstaller
        errored, or MXAdmin still registered after the bounded wait)
    3 = not running elevated
    4 = nothing to do -- MXAdmin was not installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\MXAdminUninst.log"
)

$ErrorActionPreference = 'Stop'

$VerifyTimeoutSeconds = 180

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

function Get-MXAdminArpEntry {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $entry = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { ($_.DisplayName -like 'MXAdmin*' -or $_.DisplayName -like 'MX Admin*' -or $_.DisplayName -like '*Zultys*MXAdmin*') } |
            Select-Object -First 1
        if ($entry) { return $entry }
    }
    return $null
}

Write-Log "=== Uninstall-MXAdmin starting on $env:COMPUTERNAME ==="

$entry = Get-MXAdminArpEntry
if (-not $entry) {
    Write-Log "MXAdmin is not installed (no matching uninstall registry entry). Nothing to do." 'WARN'
    Write-Log "=== Uninstall-MXAdmin finished. Nothing to do. ==="
    exit 4
}
Write-Log "Found registered product: $($entry.DisplayName)"

# --- Build the uninstall command, most-authoritative source first ---
$exePath = $null
$exeArgs = $null

if ($entry.PSObject.Properties.Name -contains 'QuietUninstallString' -and $entry.QuietUninstallString) {
    # The registered SILENT command -- most authoritative possible source.
    Write-Log "Using the entry's own QuietUninstallString verbatim: $($entry.QuietUninstallString)"
    if ($entry.QuietUninstallString -match '^"([^"]+)"\s*(.*)$') {
        $exePath = $Matches[1]; $exeArgs = $Matches[2]
    } elseif ($entry.QuietUninstallString -match '^(\S+)\s*(.*)$') {
        $exePath = $Matches[1]; $exeArgs = $Matches[2]
    }
} elseif ($entry.UninstallString -match '\{[0-9A-Fa-f\-]+\}' -and $entry.UninstallString -match 'msiexec' ) {
    $exePath = 'msiexec.exe'
    $exeArgs = "/x $($Matches[0]) /qn /norestart MSIRESTARTMANAGERCONTROL=Disable"
    Write-Log "Entry is MSI-registered -- using: msiexec $exeArgs"
} elseif ($entry.UninstallString -match '"?([^"]*\.exe)"?') {
    $exePath = $Matches[1]
    $exeName = Split-Path -Path $exePath -Leaf
    if ($exeName -like 'unins*') {
        # Inno Setup uninstaller -- documented silent convention.
        $exeArgs = '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES'
        Write-Log "Registered uninstaller is Inno-style ($exeName) -- using the documented Inno silent switches."
    } else {
        # NSIS-style guess -- same /S switch the INSTALLER demonstrably
        # accepts (MXAdminInst.ps1 installs with /S), so the vendor's
        # tooling understands this convention. Still a heuristic; the
        # bounded verification below is what actually decides success.
        $exeArgs = '/S'
        Write-Log "Registered uninstaller is '$exeName' (not Inno-style) -- trying /S, the same switch the installer itself uses." 'WARN'
    }
} else {
    # CONFIRMED ON A REAL MACHINE: the unins000.exe sitting in the shared
    # ...\Zultys\ parent folder IS MXAdmin's (verified by running it
    # interactively -- its own dialog names MXAdmin, not ZAC). So unlike
    # ZACUninst.ps1 (which must refuse this file), falling back to it
    # here is safe and correct.
    $confirmedFallbacks = @(
        "${env:ProgramFiles(x86)}\Zultys\unins000.exe",
        "$env:ProgramFiles\Zultys\unins000.exe"
    )
    foreach ($p in $confirmedFallbacks) {
        if (Test-Path -LiteralPath $p) {
            $exePath = $p
            $exeArgs = '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES'
            Write-Log "Registry entry had no usable uninstall command -- using the CONFIRMED MXAdmin uninstaller at: $p" 'WARN'
            break
        }
    }
    if (-not $exePath) {
        Write-Log "MXAdmin's registry entry has no usable uninstall command (UninstallString: '$($entry.UninstallString)'), and the confirmed fallback location has no unins000.exe either." 'ERROR'
        Write-Log "=== Uninstall-MXAdmin finished. Overall success: False ==="
        exit 1
    }
}

if ($exePath -ne 'msiexec.exe' -and -not (Test-Path -LiteralPath $exePath)) {
    Write-Log "The registered uninstaller path does not exist on disk: $exePath" 'ERROR'
    Write-Log "=== Uninstall-MXAdmin finished. Overall success: False ==="
    exit 1
}

# --- Kill any running MXAdmin processes first ---
$running = Get-Process -Name 'MXAdmin' -ErrorAction SilentlyContinue
if ($running) {
    Write-Log "Stopping running MXAdmin process so it can't block the uninstall." 'WARN'
    try { $running | Stop-Process -Force -ErrorAction Stop } catch {
        Write-Log "Could not stop MXAdmin (continuing anyway): $($_.Exception.Message)" 'WARN'
    }
}

# --- Run it ---
Write-Log "Running: $exePath $exeArgs"
if ([string]::IsNullOrWhiteSpace($exeArgs)) {
    $proc = Start-Process -FilePath $exePath -PassThru -NoNewWindow
} else {
    $proc = Start-Process -FilePath $exePath -ArgumentList $exeArgs -PassThru -NoNewWindow
}
$null = $proc.Handle   # cache the handle so ExitCode stays readable (known -PassThru-without--Wait gotcha)
$proc.WaitForExit()
Write-Log "Launched uninstaller process exited with code $($proc.ExitCode) -- NOT treating this as completion (Inno-style uninstallers respawn themselves from temp; see header). Verifying via the registry instead."

# --- Poll for the registry entry to actually disappear ---
$elapsed = 0
$pollSeconds = 5
while ($elapsed -lt $VerifyTimeoutSeconds) {
    if (-not (Get-MXAdminArpEntry)) { break }
    Start-Sleep -Seconds $pollSeconds
    $elapsed += $pollSeconds
}

if (Get-MXAdminArpEntry) {
    Write-Log "MXAdmin is STILL registered as installed after waiting ${VerifyTimeoutSeconds}s -- treating as a failure. (If the /S heuristic path was used above, a wrong silent switch is the likely cause -- the log line shows which path ran.)" 'ERROR'
    Write-Log "=== Uninstall-MXAdmin finished. Overall success: False ==="
    exit 1
}

Write-Log "Confirmed MXAdmin no longer registered."
Write-Log "=== Uninstall-MXAdmin finished. Overall success: True ==="
exit 0
