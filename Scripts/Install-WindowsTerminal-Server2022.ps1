<#
.SYNOPSIS
    Installs Windows Terminal on Windows Server 2022 (Desktop Experience) for all users.

.DESCRIPTION
    Designed to run unattended from ConnectWise Automate as SYSTEM.
    - Downloads VCLibs, Microsoft.UI.Xaml 2.8, and the Windows Terminal msixbundle
    - Provisions all three with Add-AppxProvisionedPackage so every user gets it at next sign-in
    - Exits non-zero on any failure so Automate can flag it

    Nothing is installed per-user (Add-AppxPackage is useless under SYSTEM); provisioning
    with -DependencyPackagePath stages the dependencies alongside the main package.

.PARAMETER TerminalVersion
    Pin a specific Windows Terminal release (e.g. 1.25.2733.0). Default: latest stable from GitHub.

.PARAMETER WorkDir
    Scratch folder for downloads. Default: C:\Temp\WindowsTerminal

.NOTES
    Automate: run with the 64-bit PowerShell host. The agent is 32-bit, so either call
    %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File <path>
    or rely on the relaunch guard at the top of this script.

    Exit codes:
      0  = success (or already installed)
      1  = unsupported OS (build < 20348 or Server Core)
      2  = download failure
      3  = provisioning failure
#>

[CmdletBinding()]
param(
    [string]$TerminalVersion = '',
    [string]$WorkDir = 'C:\Temp\WindowsTerminal'
)

# --- Relaunch in 64-bit PowerShell if we were started 32-bit (Automate agent is x86) ---
if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    $ps64 = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    $argList = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', "`"$PSCommandPath`"")
    if ($TerminalVersion) { $argList += @('-TerminalVersion', $TerminalVersion) }
    $argList += @('-WorkDir', "`"$WorkDir`"")
    $p = Start-Process -FilePath $ps64 -ArgumentList $argList -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try { Add-Content -Path (Join-Path $WorkDir 'install.log') -Value $line -ErrorAction SilentlyContinue } catch {}
}

# --- OS checks ---
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
Write-Log "Starting Windows Terminal provisioning on $env:COMPUTERNAME (build $build, $installType)"

if ($build -lt 20348) {
    Write-Log "Build $build is below 20348 (Server 2022). Windows Terminal is not supported on this OS." 'ERROR'
    exit 1
}
if ($installType -eq 'Server Core') {
    Write-Log 'Server Core detected. Windows Terminal requires Desktop Experience.' 'ERROR'
    exit 1
}

# --- Resolve Terminal download URL ---
$ghHeaders = @{ 'User-Agent' = 'Automate-WT-Installer' }
try {
    if ($TerminalVersion) {
        $releaseUri = "https://api.github.com/repos/microsoft/terminal/releases/tags/v$TerminalVersion"
    } else {
        $releaseUri = 'https://api.github.com/repos/microsoft/terminal/releases/latest'
    }
    $release = Invoke-RestMethod -Uri $releaseUri -Headers $ghHeaders
    $asset = $release.assets | Where-Object { $_.name -like 'Microsoft.WindowsTerminal_*_8wekyb3d8bbwe.msixbundle' } | Select-Object -First 1
    if (-not $asset) { throw "No msixbundle asset found in release $($release.tag_name)" }
    $resolvedVersion = ($asset.name -replace '^Microsoft\.WindowsTerminal_([\d\.]+)_.*$', '$1')
    Write-Log "Target Windows Terminal version: $resolvedVersion"
} catch {
    Write-Log "Failed to resolve Terminal release: $($_.Exception.Message)" 'ERROR'
    exit 2
}

# --- Idempotency: skip if this version (or newer) is already provisioned ---
$existing = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'Microsoft.WindowsTerminal' }
if ($existing -and [version]$existing.Version -ge [version]$resolvedVersion) {
    Write-Log "Windows Terminal $($existing.Version) already provisioned. Nothing to do."
    exit 0
}

# --- Downloads ---
$downloads = @(
    @{ Name = 'VCLibs';   Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx';                                                     File = 'Microsoft.VCLibs.x64.14.00.Desktop.appx' }
    @{ Name = 'UI.Xaml';  Url = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx';     File = 'Microsoft.UI.Xaml.2.8.x64.appx' }
    @{ Name = 'Terminal'; Url = $asset.browser_download_url;                                                                                   File = $asset.name }
)

foreach ($d in $downloads) {
    $dest = Join-Path $WorkDir $d.File
    if (Test-Path $dest) {
        Write-Log "$($d.Name): already downloaded, reusing $dest"
        continue
    }
    try {
        Write-Log "$($d.Name): downloading $($d.Url)"
        Invoke-WebRequest -Uri $d.Url -OutFile $dest -UseBasicParsing
        if ((Get-Item $dest).Length -lt 100KB) { throw 'Downloaded file is suspiciously small' }
    } catch {
        Write-Log "$($d.Name): download failed - $($_.Exception.Message)" 'ERROR'
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        exit 2
    }
}

# --- Provision for all users ---
$bundlePath = Join-Path $WorkDir $asset.name
$depPaths   = @(
    (Join-Path $WorkDir 'Microsoft.VCLibs.x64.14.00.Desktop.appx'),
    (Join-Path $WorkDir 'Microsoft.UI.Xaml.2.8.x64.appx')
)

try {
    Write-Log 'Provisioning Windows Terminal with dependencies (all users)...'
    Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -DependencyPackagePath $depPaths -SkipLicense | Out-Null
} catch {
    Write-Log "Provisioning failed: $($_.Exception.Message)" 'ERROR'
    Write-Log 'Check C:\Windows\Logs\DISM\dism.log for details.' 'ERROR'
    exit 3
}

# --- Verify ---
$prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq 'Microsoft.WindowsTerminal' }
if ($prov) {
    Write-Log "SUCCESS: Windows Terminal $($prov.Version) provisioned. Users will see it at next sign-in."
    exit 0
} else {
    Write-Log 'Provisioning command completed but package is not listed. Investigate.' 'ERROR'
    exit 3
}
