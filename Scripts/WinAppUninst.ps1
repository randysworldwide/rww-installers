<#
.SYNOPSIS
    Removes the Windows App (Remote Desktop client) machine-wide provisioning
    and immediately strips it from any currently logged-in user sessions,
    force-closing the app first if it's running.

.DESCRIPTION
    Repo: randysworldwide/rww-installers

    Deprovisioning (Remove-AppxProvisionedPackage) stops the app from being
    added to *new* profiles going forward. Remove-AppxPackage -AllUsers then
    strips it from every profile that currently has it, including sessions
    that are logged in right now.

    Note: there is no "-ForceApplicationShutdown" parameter on
    Remove-AppxPackage (that flag belongs to Add-AppxPackage, used during
    install/update conflicts). The equivalent here for removal is closing
    any running instance of the app ourselves immediately before the
    Remove-AppxPackage call, so nothing blocks the removal and no
    half-torn-down state is left behind in an active session. This does
    NOT log the user out of Windows -- it force-closes the app itself, then
    removes it from their profile while they stay logged in.

.PARAMETER LogPath
    Where to write the log file.

.PARAMETER RemoveStagingFiles
    If set, also deletes C:\ProgramData\Dev\WindowsApp (the install source
    files). Off by default -- files are kept around for easy re-install/repair.

.EXITCODES
    0 = success -- deprovisioned and/or per-user copies removed
    1 = one or more steps failed
    3 = not running elevated
    4 = nothing to do -- app was not present anywhere on this machine
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\Logs\WinAppUninst.log",
    [switch]$RemoveStagingFiles
)

$ErrorActionPreference = 'Stop'
$overallSuccess = $true

$PackageFamilyLike = 'MicrosoftCorporationII.Windows365*'
$StagingPath = "$env:ProgramData\Dev\WindowsApp"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # IMPORTANT: use Console::WriteLine, not Write-Output/Write-Host -- Write-Output
    # inside a function leaks into that function's *return value*, silently
    # corrupting the calling code's success/failure logic.
    [Console]::WriteLine($line)
    try {
        $dir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line
    } catch {
        # Logging failures shouldn't kill the uninstall
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
           $identity.IsSystem
}

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated / as SYSTEM. Re-run as admin or deploy via Automate." 'ERROR'
    exit 3
}

Write-Log "=== Uninstall-WindowsApp starting on $env:COMPUTERNAME ==="

# ---------------------------------------------------------------------------
# Step 1: Deprovision (stops future/new profiles from getting it)
# ---------------------------------------------------------------------------
$provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.PackageName -like $PackageFamilyLike }

$didDeprovision = $false
if ($provisioned) {
    try {
        foreach ($p in $provisioned) {
            Write-Log "Deprovisioning $($p.PackageName)"
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
        }
        $didDeprovision = $true
    } catch {
        Write-Log "Deprovisioning failed: $($_.Exception.Message)" 'ERROR'
        $overallSuccess = $false
    }
} else {
    Write-Log "No machine-wide provisioned package found."
}

# ---------------------------------------------------------------------------
# Step 2: Force-close and remove from every profile that currently has it,
# including sessions logged in right now.
# ---------------------------------------------------------------------------
$pkg = Get-AppxPackage -AllUsers -Name $PackageFamilyLike -ErrorAction SilentlyContinue

$didRemovePerUser = $false
if ($pkg) {
    foreach ($p in $pkg) {
        # Force-close any running instance first so removal doesn't get
        # blocked and doesn't leave a half-torn-down state in an active session.
        try {
            $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and $_.Path -like "*\WindowsApps\$($p.PackageFamilyName)_*"
            }
            foreach ($proc in $procs) {
                Write-Log "Force-closing running process '$($proc.ProcessName)' (PID $($proc.Id)) before removal."
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Log "Could not enumerate/stop running processes for $($p.PackageFullName): $($_.Exception.Message)" 'WARN'
        }

        try {
            Write-Log "Removing $($p.PackageFullName) for all users."
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
            $didRemovePerUser = $true
        } catch {
            Write-Log "Failed to remove $($p.PackageFullName): $($_.Exception.Message)" 'ERROR'
            $overallSuccess = $false
        }
    }
} else {
    Write-Log "No per-user installed copies found."
}

# ---------------------------------------------------------------------------
# Step 3: Optional staging file cleanup
# ---------------------------------------------------------------------------
if ($RemoveStagingFiles -and (Test-Path $StagingPath)) {
    try {
        Remove-Item -Path $StagingPath -Recurse -Force -ErrorAction Stop
        Write-Log "Removed staging files at $StagingPath"
    } catch {
        Write-Log "Failed to remove staging files: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Wrap up
# ---------------------------------------------------------------------------
if (-not $provisioned -and -not $pkg) {
    Write-Log "Nothing was uninstalled -- Windows App was not present on this machine." 'WARN'
    exit 4
}

Write-Log "=== Uninstall-WindowsApp finished. Deprovisioned: $didDeprovision. Per-user removed: $didRemovePerUser. Overall success: $overallSuccess ==="
if (-not $overallSuccess) {
    exit 1
} else {
    exit 0
}
