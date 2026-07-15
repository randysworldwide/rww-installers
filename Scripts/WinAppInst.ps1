<#
.SYNOPSIS
    Installs the Windows App (Remote Desktop client, MicrosoftCorporationII.Windows365)
    machine-wide via a provisioned MSIX package.
    Designed to run unattended as SYSTEM via ConnectWise Automate, but also
    works fine run manually (elevated) on a single box.

.DESCRIPTION
    Repo: randysworldwide/rww-installers (Release tag: "Release")

    winget's msstore source requires an interactive Store auth token that
    SYSTEM doesn't have, and this environment's TLS inspection proxy blocks
    the Store source outright -- so we sideload the package files directly
    from a GitHub Release instead of relying on winget.

    Files are staged in C:\ProgramData\Dev\WindowsApp (Dev is a hidden
    folder so nothing new shows up at the root of C:\) and left in place
    after install for easy repair/re-runs.

    Idempotent: checks Appx provisioning state before doing anything, so
    re-running on a machine that already has it is a no-op.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's readable
    without a user profile loaded.

.EXITCODES
    0 = success -- app was actually provisioned this run
    1 = install failed
    2 = one or more required files failed to download
    3 = not running elevated
    4 = nothing to do -- already provisioned (no install action was taken)
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\Logs\WinAppInst.log"
)

$ErrorActionPreference = 'Stop'

$DestDir     = "$env:ProgramData\Dev\WindowsApp"
$ReleaseBase = 'https://github.com/randysworldwide/rww-installers/releases/download/Release'

$Files = @(
    @{ Name = 'MicrosoftCorporationII.Windows365_2.0.1071.0_x64.Msix' }
    @{ Name = 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.Appx' }
    @{ Name = 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.Appx' }
)

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
        # Logging failures shouldn't kill the install
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

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
function Test-WindowsAppProvisioned {
    $pkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like 'MicrosoftCorporationII.Windows365*' }
    return [bool]$pkg
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-WindowsApp starting on $env:COMPUTERNAME ==="

if (Test-WindowsAppProvisioned) {
    Write-Log "Windows App already provisioned machine-wide. Skipping."
    Write-Log "Nothing was installed -- Windows App was already present." 'WARN'
    exit 4
}

if (-not (Test-Path $DestDir)) {
    New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
}

# Dev is the hidden staging folder -- make sure it's actually hidden
$devFolder = Get-Item "$env:ProgramData\Dev" -Force
if (-not ($devFolder.Attributes -band [IO.FileAttributes]::Hidden)) {
    $devFolder.Attributes = $devFolder.Attributes -bor [IO.FileAttributes]::Hidden
}

$downloadOk = $true
foreach ($file in $Files) {
    $dest = Join-Path $DestDir $file.Name
    $url  = "$ReleaseBase/$($file.Name)"
    try {
        Write-Log "Downloading $($file.Name)"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Log "Failed to download $($file.Name): $($_.Exception.Message)" 'ERROR'
        $downloadOk = $false
    }
}

if (-not $downloadOk) {
    Write-Log "One or more required files failed to download. Aborting." 'ERROR'
    exit 2
}

$mainPackage  = Join-Path $DestDir 'MicrosoftCorporationII.Windows365_2.0.1071.0_x64.Msix'
$dependencies = @(
    (Join-Path $DestDir 'Microsoft.VCLibs.140.00_14.0.33519.0_x64.Appx'),
    (Join-Path $DestDir 'Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.Appx')
)

try {
    Write-Log "Provisioning Windows App machine-wide via DISM"
    Add-AppxProvisionedPackage -Online `
        -PackagePath $mainPackage `
        -DependencyPackagePath $dependencies `
        -SkipLicense -ErrorAction Stop | Out-Null
} catch {
    Write-Log "Add-AppxProvisionedPackage failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

if (Test-WindowsAppProvisioned) {
    Write-Log "Windows App installed successfully."
    Write-Log "=== Install-WindowsApp finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "Provisioning command completed without error but package not found afterward." 'ERROR'
    Write-Log "=== Install-WindowsApp finished. Overall success: False ==="
    exit 1
}
