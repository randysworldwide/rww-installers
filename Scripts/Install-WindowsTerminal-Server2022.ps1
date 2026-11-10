<#
.SYNOPSIS
    Installs Windows Terminal on Windows Server 2022 variants.

.DESCRIPTION
    Designed to be run as a PowerShell "Execute Script" function in ConnectWise
    Automate Control Center. Runs in the SYSTEM context under the LTAgent.

    Windows Terminal is distributed as an MSIX bundle and is NOT natively
    provisioned on Windows Server. This script downloads Terminal plus its
    framework dependencies (VCLibs + UI.Xaml) from the official Microsoft
    GitHub release and provisions the package for ALL users via
    Add-AppxProvisionedPackage -Online (the correct method under SYSTEM).

    Exit codes (parse these in Automate):
        0   = Success (installed or already present)
        10  = Not a supported OS (requires Server 2022 / build 20348+)
        20  = Download failure
        30  = Dependency install failure
        40  = Windows Terminal install failure
        50  = Post-install verification failure

.NOTES
    Target     : Windows Server 2022 (Standard, Datacenter, Core, Azure Edition)
    Context    : SYSTEM (LTSvc / LTAgent)
    Author     : Randy's Worldwide IT
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    # Pin a specific Terminal version tag (e.g. 'v1.21.3231.0'). Leave blank for latest stable.
    [string]$TerminalVersionTag = '',

    # Force reinstall even if already present.
    [switch]$Force
)

# ----------------------------------------------------------------------------
# Environment / safety
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # massively speeds up Invoke-WebRequest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$WorkDir = Join-Path $env:TEMP ("WTInstall_{0}" -f ([guid]::NewGuid().ToString('N')))
$script:ExitCode = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$ts] [$Level] $Message"
}

function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    Write-Log "Downloading: $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
        throw "Download produced an empty file: $OutFile"
    }
}

# ----------------------------------------------------------------------------
# 1. Validate OS — Server 2022 is build 20348
# ----------------------------------------------------------------------------
try {
    $os        = Get-CimInstance -ClassName Win32_OperatingSystem
    $buildNum  = [int]($os.BuildNumber)
    $caption   = $os.Caption
    Write-Log "Detected OS: $caption (Build $buildNum)"

    $isServer = ($os.ProductType -ne 1)   # 1 = Workstation, 2 = DC, 3 = Server
    if (-not $isServer -or $buildNum -lt 20348) {
        Write-Log "This script targets Windows Server 2022 (build 20348+). Aborting." 'ERROR'
        exit 10
    }
}
catch {
    Write-Log "OS detection failed: $($_.Exception.Message)" 'ERROR'
    exit 10
}

# ----------------------------------------------------------------------------
# 2. Already installed?
# ----------------------------------------------------------------------------
$existing = Get-AppxProvisionedPackage -Online |
            Where-Object { $_.DisplayName -eq 'Microsoft.WindowsTerminal' }

if ($existing -and -not $Force) {
    Write-Log "Windows Terminal is already provisioned (v$($existing.Version)). Use -Force to reinstall."
    exit 0
}

# ----------------------------------------------------------------------------
# 3. Resolve download assets from GitHub releases
# ----------------------------------------------------------------------------
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

try {
    if ([string]::IsNullOrWhiteSpace($TerminalVersionTag)) {
        $apiUrl = 'https://api.github.com/repos/microsoft/terminal/releases/latest'
    } else {
        $apiUrl = "https://api.github.com/repos/microsoft/terminal/releases/tags/$TerminalVersionTag"
    }

    Write-Log "Querying release metadata: $apiUrl"
    $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -Headers @{ 'User-Agent' = 'RandysWW-Automate' }

    # The release ships a single .msixbundle that already contains x64/arm64.
    $bundleAsset = $release.assets |
        Where-Object { $_.name -like '*.msixbundle' -and $_.name -notlike '*PreinstallKit*' } |
        Select-Object -First 1

    if (-not $bundleAsset) {
        throw "Could not locate a .msixbundle asset in release $($release.tag_name)."
    }

    Write-Log "Selected Terminal package: $($bundleAsset.name) ($($release.tag_name))"
    $bundlePath = Join-Path $WorkDir $bundleAsset.name
    Invoke-Download -Uri $bundleAsset.browser_download_url -OutFile $bundlePath
}
catch {
    Write-Log "Failed to resolve/download Windows Terminal: $($_.Exception.Message)" 'ERROR'
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 20
}

# ----------------------------------------------------------------------------
# 4. Download framework dependencies
#    Terminal needs VCLibs Desktop + Microsoft.UI.Xaml 2.8 (x64).
# ----------------------------------------------------------------------------
$dependencies = @(
    @{
        Name = 'Microsoft.VCLibs.140.00.UWPDesktop'
        Uri  = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
        File = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
    },
    @{
        Name = 'Microsoft.UI.Xaml.2.8'
        Uri  = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'
        File = 'Microsoft.UI.Xaml.2.8.x64.appx'
    }
)

$depPaths = @()
try {
    foreach ($dep in $dependencies) {
        $out = Join-Path $WorkDir $dep.File
        Invoke-Download -Uri $dep.Uri -OutFile $out
        $depPaths += $out
    }
}
catch {
    Write-Log "Failed to download dependencies: $($_.Exception.Message)" 'ERROR'
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 20
}

# ----------------------------------------------------------------------------
# 5. Install dependencies (provision for all users)
# ----------------------------------------------------------------------------
foreach ($depPath in $depPaths) {
    try {
        Write-Log "Provisioning dependency: $(Split-Path $depPath -Leaf)"
        Add-AppxProvisionedPackage -Online -PackagePath $depPath -SkipLicense | Out-Null
    }
    catch {
        # A dependency already present at an equal/newer version is non-fatal.
        if ($_.Exception.Message -match '0x80073D06|already installed|higher version') {
            Write-Log "Dependency already present (newer/equal version) — continuing." 'WARN'
        }
        else {
            Write-Log "Dependency provisioning failed: $($_.Exception.Message)" 'ERROR'
            Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
            exit 30
        }
    }
}

# ----------------------------------------------------------------------------
# 6. Install Windows Terminal
# ----------------------------------------------------------------------------
try {
    Write-Log "Provisioning Windows Terminal for all users..."
    $wtParams = @{
        Online                = $true
        PackagePath           = $bundlePath
        DependencyPackagePath = $depPaths
        SkipLicense           = $true
    }
    Add-AppxProvisionedPackage @wtParams | Out-Null
}
catch {
    Write-Log "Windows Terminal provisioning failed: $($_.Exception.Message)" 'ERROR'
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 40
}

# ----------------------------------------------------------------------------
# 7. Verify
# ----------------------------------------------------------------------------
Start-Sleep -Seconds 3
$verify = Get-AppxProvisionedPackage -Online |
          Where-Object { $_.DisplayName -eq 'Microsoft.WindowsTerminal' }

Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

if ($verify) {
    Write-Log "SUCCESS: Windows Terminal v$($verify.Version) provisioned. Available after next user logon."
    exit 0
}
else {
    Write-Log "Verification failed: Windows Terminal not found after install." 'ERROR'
    exit 50
}
