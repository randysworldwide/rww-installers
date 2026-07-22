<#
.SYNOPSIS
    Installs VS Code and/or Windows Terminal machine-wide via winget.
    Designed to run unattended as SYSTEM via ConnectWise Automate, but also
    works fine run manually (elevated) on a single box.

.DESCRIPTION
    Wrike: "Install VS Code and Windows Terminal on all employee machines"
    Repo:  randysworldwide/tools

    Handles the SYSTEM-context gotchas:
      - winget.exe is not on PATH for SYSTEM (App Installer registers per-user),
        so we resolve the full path under WindowsApps.
      - VS Code's winget package defaults to a *user-scope* install. Under
        SYSTEM that installs into the SYSTEM profile, which is useless to the
        real user. We force --scope machine.
      - Windows Terminal is MSIX-only and winget under SYSTEM has no Store
        auth token, so it can fail to fully provision. If winget doesn't
        result in a machine-wide provisioned package, we fall back to
        downloading the latest .msixbundle from the Terminal GitHub releases
        and running Add-AppxProvisionedPackage -SkipLicense (same pattern
        used for the Windows App / RDP client rollout).

    Idempotent: checks registry / Appx state before doing anything, so
    re-running on a machine that already has these installed is a no-op.

.PARAMETER Apps
    Which apps to ensure are installed. Default: both.

.PARAMETER LogPath
    Where to write the log file. Defaults under ProgramData so it's readable
    without a user profile loaded.

.EXITCODES
    0 = success -- at least one app was actually installed this run
    1 = one or more apps failed to install
    2 = winget could not be resolved and no fallback available
    3 = not running elevated
    4 = nothing to do -- every requested app was already installed (no
        install action was taken). Use this to flag Automate as a failure
        when a "nothing changed" run should be treated as noteworthy.
#>

[CmdletBinding()]
param(
    [ValidateSet('VSCode', 'Terminal')]
    [string[]]$Apps = @('VSCode', 'Terminal'),

    [string]$LogPath = "$env:ProgramData\Dev\Logs\Install-DevTools.log"
)

$ErrorActionPreference = 'Stop'
$overallSuccess = $true
$skippedCount = 0   # apps that were already installed -- no action taken

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # IMPORTANT: use Console::WriteLine, not Write-Output/Write-Host. Write-Output
    # inside a function leaks into that function's *return value*, silently
    # corrupting values like $code/$removed in the calling code (this caused the
    # garbled "exit code" messages and false success/failure logic seen in testing).
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
# winget resolution (SYSTEM context doesn't have it on PATH by default)
# ---------------------------------------------------------------------------
function Resolve-WinGetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidate = Get-ChildItem "$env:ProgramFiles\WindowsApps" `
        -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' `
        -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1

    if ($candidate) {
        $exe = Join-Path $candidate.FullName 'winget.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Detection (registry-based, not winget list -- faster/more reliable as SYSTEM)
# ---------------------------------------------------------------------------
function Test-AppInstalledByRegistry {
    param([Parameter(Mandatory)][string]$NameLike)

    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    # VS Code's default winget package is user-scope, so also sweep any
    # loaded user hives in case a prior install landed per-user.
    $hives += Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
        ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" }

    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$NameLike*" }
        if ($match) { return $true }
    }
    return $false
}

function Test-TerminalInstalled {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -AllUsers -ErrorAction SilentlyContinue
    return [bool]$pkg
}

# ---------------------------------------------------------------------------
# Install helpers
# ---------------------------------------------------------------------------
function Install-WithWinget {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Scope = 'machine'
    )
    $argList = @(
        'install', '--id', $PackageId, '-e', '--silent', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity', '--scope', $Scope
    )
    Write-Log "Running: winget $($argList -join ' ')"
    $proc = Start-Process -FilePath $WingetPath -ArgumentList $argList -NoNewWindow -PassThru -Wait
    return $proc.ExitCode
}

function Install-TerminalFallback {
    # winget under SYSTEM has no Store auth token, so if it didn't result in
    # a machine-wide provisioned package, pull the msixbundle directly and
    # provision it -- same approach used for the Windows App/RDP rollout.
    Write-Log "Falling back to direct MSIX provisioning for Windows Terminal."
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/terminal/releases/latest' -UseBasicParsing
        $asset = $release.assets |
            Where-Object { $_.name -match '\.msixbundle$' -and $_.name -notmatch 'Preview' } |
            Select-Object -First 1
        if (-not $asset) { throw "No .msixbundle asset found in latest Terminal release." }

        $dest = Join-Path $env:TEMP $asset.name
        Write-Log "Downloading $($asset.name)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing

        Write-Log "Provisioning package machine-wide via DISM"
        Add-AppxProvisionedPackage -Online -PackagePath $dest -SkipLicense -ErrorAction Stop | Out-Null
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Log "Fallback install failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Install-DevTools starting on $env:COMPUTERNAME (Apps: $($Apps -join ', ')) ==="

$wingetPath = Resolve-WinGetPath
if (-not $wingetPath) {
    Write-Log "winget.exe could not be resolved on this machine." 'ERROR'
    if ($Apps -notcontains 'Terminal') {
        Write-Log "No fallback available for VS Code without winget. Aborting." 'ERROR'
        exit 2
    }
} else {
    Write-Log "Using winget at: $wingetPath"
}

if ($Apps -contains 'VSCode') {
    if (Test-AppInstalledByRegistry -NameLike 'Visual Studio Code') {
        Write-Log "VS Code already installed. Skipping."
        $skippedCount++
    } elseif (-not $wingetPath) {
        Write-Log "Cannot install VS Code -- winget unavailable and no fallback exists for it." 'ERROR'
        $overallSuccess = $false
    } else {
        $code = Install-WithWinget -WingetPath $wingetPath -PackageId 'Microsoft.VisualStudioCode' -Scope 'machine'
        if ($code -eq 0 -or (Test-AppInstalledByRegistry -NameLike 'Visual Studio Code')) {
            Write-Log "VS Code installed successfully."
        } else {
            Write-Log "VS Code install failed (winget exit code $code)." 'ERROR'
            $overallSuccess = $false
        }
    }
}

if ($Apps -contains 'Terminal') {
    if (Test-TerminalInstalled) {
        Write-Log "Windows Terminal already installed. Skipping."
        $skippedCount++
    } else {
        $installedOk = $false
        if ($wingetPath) {
            $code = Install-WithWinget -WingetPath $wingetPath -PackageId 'Microsoft.WindowsTerminal' -Scope 'machine'
            if ($code -eq 0 -and (Test-TerminalInstalled)) {
                Write-Log "Windows Terminal installed successfully via winget."
                $installedOk = $true
            } else {
                Write-Log "winget install for Terminal did not result in a verified install (exit code $code)." 'WARN'
            }
        }
        if (-not $installedOk) {
            $installedOk = Install-TerminalFallback
            if ($installedOk) {
                Write-Log "Windows Terminal provisioned successfully via fallback."
            }
        }
        if (-not $installedOk) {
            Write-Log "Windows Terminal install failed via both winget and fallback." 'ERROR'
            $overallSuccess = $false
        }
    }
}

Write-Log "=== Install-DevTools finished. Overall success: $overallSuccess ==="
if (-not $overallSuccess) {
    exit 1
} elseif ($skippedCount -eq $Apps.Count) {
    Write-Log "Nothing was installed -- all requested apps were already present." 'WARN'
    exit 4
} else {
    exit 0
}
