#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Microsoft 365 (O365) Apps via the Office Deployment Tool,
    using the pre-built configuration XML on the private network share.
    Designed to run elevated on a single box (RWW WorkstationDeployment
    project -- see Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/OfficeO365Inst.ps1

    Source files (on the private share; not hosted in this public repo):

        \\svazdfs001\systems$\Software\Microsoft\Office\MSOffice\setup.exe
        \\svazdfs001\systems$\Software\Microsoft\Office\MSOffice\configuration-Office365-x64.xml
        (falls back to \\10.1.0.5\... if the hostname doesn't resolve)

    Uses the standard, well-documented ODT command: setup.exe /configure
    <xml>. Defaults to the x64 config -- the x86 variant
    (configuration-Office365-x86.xml) also exists on the share if a
    32-bit install is ever needed for a specific legacy add-in; this
    script doesn't cover that case.

    NOTE ON THINGS THAT COULDN'T BE VERIFIED REMOTELY: this script can't
    inspect the contents of configuration-Office365-x64.xml (it lives on
    a private share this environment has no access to), so two things are
    unconfirmed until real testing:
      - Whether the XML points at a local/network SourcePath (fast,
        offline-capable) or pulls fresh from Microsoft's CDN each run
        (works, but slower and needs internet access at install time).
      - The exact resulting Programs & Features DisplayName, which
        varies by SKU/branding (e.g. "Microsoft 365 Apps for enterprise"
        vs "...for business"). Detection below uses a broad "Microsoft
        365" match as a reasonable starting guess.
    ODT installs can legitimately take 10-20+ minutes depending on
    connection speed and whether it's a fresh CDN download.

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- Office was actually installed this run
    1 = setup.exe reported a non-zero exit code
    2 = could not reach/copy setup.exe or the config XML from the share
    3 = not running elevated
    4 = nothing to do -- a matching Office install was already present
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\OfficeO365Inst.log"
)

$ErrorActionPreference = 'Stop'

$StageDir   = "$env:ProgramData\Dev\AppsDeploy\OfficeO365"
$SharePaths = @(
    '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
    '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
)
$SetupFileName  = 'setup.exe'
$ConfigFileName = 'configuration-Office365-x64.xml'

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

function Test-OfficeO365Installed {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Microsoft 365*' }
        if ($match) { return $true }
    }
    return $false
}

Write-Log "=== Install-OfficeO365 starting on $env:COMPUTERNAME ==="

if (Test-OfficeO365Installed) {
    Write-Log "A Microsoft 365 Apps install is already present (matched on DisplayName). Skipping."
    Write-Log "Nothing was installed -- Office O365 was already present." 'WARN'
    exit 4
}

$sourceDir = $null
foreach ($candidate in $SharePaths) {
    $setupCandidate  = Join-Path $candidate $SetupFileName
    $configCandidate = Join-Path $candidate $ConfigFileName
    Write-Log "Checking share path: $candidate"
    if ((Test-Path $setupCandidate -ErrorAction SilentlyContinue) -and (Test-Path $configCandidate -ErrorAction SilentlyContinue)) {
        $sourceDir = $candidate
        Write-Log "Found setup.exe and $ConfigFileName at: $candidate"
        break
    }
}

if (-not $sourceDir) {
    Write-Log "Could not reach setup.exe and/or $ConfigFileName on any known share path. Checked: $($SharePaths -join ', ')" 'ERROR'
    exit 2
}

try {
    if (-not (Test-Path $StageDir)) { New-Item -Path $StageDir -ItemType Directory -Force | Out-Null }
    $localSetup  = Join-Path $StageDir $SetupFileName
    $localConfig = Join-Path $StageDir $ConfigFileName
    Write-Log "Staging files to $StageDir"
    Copy-Item -LiteralPath (Join-Path $sourceDir $SetupFileName) -Destination $localSetup -Force
    Copy-Item -LiteralPath (Join-Path $sourceDir $ConfigFileName) -Destination $localConfig -Force
} catch {
    Write-Log "Failed to copy install files from $sourceDir : $($_.Exception.Message)" 'ERROR'
    exit 2
}

Write-Log "Running: $localSetup /configure $localConfig (this can take 10-20+ minutes)"
$proc = Start-Process -FilePath $localSetup -ArgumentList "/configure `"$localConfig`"" -Wait -PassThru -NoNewWindow
$finalCode = $proc.ExitCode
Write-Log "setup.exe exit code: $finalCode"

if ($finalCode -ne 0) {
    Write-Log "Install FAILED (exit code $finalCode)." 'ERROR'
    Write-Log "=== Install-OfficeO365 finished. Overall success: False ==="
    exit 1
}

if (Test-OfficeO365Installed) {
    Write-Log "Office O365 confirmed present after install."
    Write-Log "=== Install-OfficeO365 finished. Overall success: True ==="
    exit 0
} else {
    Write-Log "setup.exe exited 0 but no matching install was found in the uninstall registry afterward -- detection pattern may need adjusting once the real DisplayName is known." 'WARN'
    Write-Log "=== Install-OfficeO365 finished. Overall success: True (unverified by registry) ==="
    exit 0
}
