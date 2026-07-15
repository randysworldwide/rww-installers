<#
.SYNOPSIS
    Uninstalls VS Code and/or Windows Terminal machine-wide.
    Mirrors Install-DevTools.ps1 -- same logging pattern, exit codes, and
    idempotency approach. Intended for SYSTEM-context execution via
    ConnectWise Automate, but also works run manually (elevated).

.DESCRIPTION
    Repo:  randysworldwide/tools

    VS Code: tries `winget uninstall` first. If winget is unavailable or the
    uninstall doesn't take, falls back to the QuietUninstallString /
    UninstallString recorded in the Uninstall registry key.

    Windows Terminal: removes the provisioned package machine-wide via
    Remove-AppxProvisionedPackage (so new profiles won't get it either),
    then removes it for any currently-loaded user profiles via
    Remove-AppxPackage -AllUsers.

.PARAMETER Apps
    Which apps to remove. Default: both.

.PARAMETER LogPath
    Where to write the log file.

.EXITCODES
    0 = success -- at least one app was actually removed this run
    1 = one or more apps failed to uninstall
    3 = not running elevated
    4 = nothing to do -- none of the requested apps were installed (no
        uninstall action was taken).
#>

[CmdletBinding()]
param(
    [ValidateSet('VSCode', 'Terminal')]
    [string[]]$Apps = @('VSCode', 'Terminal'),

    [string]$LogPath = "$env:ProgramData\RPS\Logs\Uninstall-DevTools.log"
)

$ErrorActionPreference = 'Stop'
$overallSuccess = $true
$skippedCount = 0   # apps that were already absent -- no action taken

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # IMPORTANT: use Console::WriteLine, not Write-Output/Write-Host. Write-Output
    # inside a function leaks into that function's *return value*, silently
    # corrupting values like $removed in the calling code (this caused the
    # contradictory "uninstalled successfully" message seen right after a logged
    # uninstall error in testing).
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

# ---------------------------------------------------------------------------
# winget resolution (same as install script)
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
# Detection (same checks as install script, used here to confirm removal)
# ---------------------------------------------------------------------------
function Get-VSCodeUninstallEntry {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $hives += Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' } |
        ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" }

    foreach ($hive in $hives) {
        $match = Get-ItemProperty -Path $hive -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Visual Studio Code*' }
        if ($match) { return $match | Select-Object -First 1 }
    }
    return $null
}

function Test-TerminalInstalled {
    $pkg = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -AllUsers -ErrorAction SilentlyContinue
    return [bool]$pkg
}

# ---------------------------------------------------------------------------
# Uninstall helpers
# ---------------------------------------------------------------------------
function Uninstall-VSCodeViaWinget {
    param([Parameter(Mandatory)][string]$WingetPath)
    $argList = @(
        'uninstall', '--id', 'Microsoft.VisualStudioCode', '-e', '--silent',
        '--accept-source-agreements', '--disable-interactivity'
    )
    Write-Log "Running: winget $($argList -join ' ')"
    $proc = Start-Process -FilePath $WingetPath -ArgumentList $argList -NoNewWindow -PassThru -Wait
    return $proc.ExitCode
}

function Uninstall-VSCodeViaRegistry {
    param([Parameter(Mandatory)]$UninstallEntry)
    $cmd = $UninstallEntry.QuietUninstallString
    if (-not $cmd) { $cmd = $UninstallEntry.UninstallString }
    if (-not $cmd) {
        Write-Log "No UninstallString found on the registry entry." 'ERROR'
        return $false
    }

    Write-Log "Falling back to registry uninstall string: $cmd"
    try {
        if ($cmd -match '^"([^"]+)"\s*(.*)$') {
            $exe = $Matches[1]
            $exeArgs = $Matches[2]
        } else {
            $parts = $cmd -split ' ', 2
            $exe = $parts[0]
            $exeArgs = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        }
        # VS Code's NSIS uninstaller supports /S for silent; add it if not already present
        if ($exeArgs -notmatch '/S\b') { $exeArgs = "$exeArgs /S".Trim() }

        $proc = Start-Process -FilePath $exe -ArgumentList $exeArgs -NoNewWindow -PassThru -Wait
        return ($proc.ExitCode -eq 0)
    } catch {
        Write-Log "Registry-based uninstall failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Uninstall-Terminal {
    $success = $true

    # Remove the machine-wide provisioned package so new profiles don't get it
    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq 'Microsoft.WindowsTerminal' }
        if ($provisioned) {
            foreach ($p in $provisioned) {
                Write-Log "Removing provisioned package: $($p.PackageName)"
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
            }
        } else {
            Write-Log "No machine-wide provisioned package found for Windows Terminal."
        }
    } catch {
        Write-Log "Failed to remove provisioned package: $($_.Exception.Message)" 'ERROR'
        $success = $false
    }

    # Remove for any currently-loaded user profiles
    try {
        $pkgs = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -AllUsers -ErrorAction SilentlyContinue
        foreach ($pkg in $pkgs) {
            Write-Log "Removing installed package for all users: $($pkg.PackageFullName)"
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        }
    } catch {
        Write-Log "Failed to remove installed package: $($_.Exception.Message)" 'ERROR'
        $success = $false
    }

    return $success
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Uninstall-DevTools starting on $env:COMPUTERNAME (Apps: $($Apps -join ', ')) ==="

$wingetPath = Resolve-WinGetPath
if ($wingetPath) {
    Write-Log "Using winget at: $wingetPath"
} else {
    Write-Log "winget.exe could not be resolved. Will rely on registry/DISM fallback only." 'WARN'
}

if ($Apps -contains 'VSCode') {
    $entry = Get-VSCodeUninstallEntry
    if (-not $entry) {
        Write-Log "VS Code not installed. Skipping."
        $skippedCount++
    } else {
        $removed = $false
        if ($wingetPath) {
            $code = Uninstall-VSCodeViaWinget -WingetPath $wingetPath
            if ($code -eq 0 -and -not (Get-VSCodeUninstallEntry)) {
                Write-Log "VS Code uninstalled successfully via winget."
                $removed = $true
            } else {
                Write-Log "winget uninstall did not fully remove VS Code (exit code $code)." 'WARN'
            }
        }
        if (-not $removed) {
            $removed = Uninstall-VSCodeViaRegistry -UninstallEntry $entry
            if ($removed -and -not (Get-VSCodeUninstallEntry)) {
                Write-Log "VS Code uninstalled successfully via registry uninstall string."
            } else {
                $removed = $false
            }
        }
        if (-not $removed) {
            Write-Log "VS Code uninstall failed via both winget and registry fallback." 'ERROR'
            $overallSuccess = $false
        }
    }
}

if ($Apps -contains 'Terminal') {
    if (-not (Test-TerminalInstalled)) {
        Write-Log "Windows Terminal not installed. Skipping."
        $skippedCount++
    } else {
        if (Uninstall-Terminal) {
            if (-not (Test-TerminalInstalled)) {
                Write-Log "Windows Terminal uninstalled successfully."
            } else {
                Write-Log "Uninstall ran but Windows Terminal is still detected." 'ERROR'
                $overallSuccess = $false
            }
        } else {
            Write-Log "Windows Terminal uninstall failed." 'ERROR'
            $overallSuccess = $false
        }
    }
}

Write-Log "=== Uninstall-DevTools finished. Overall success: $overallSuccess ==="
if (-not $overallSuccess) {
    exit 1
} elseif ($skippedCount -eq $Apps.Count) {
    Write-Log "Nothing was uninstalled -- none of the requested apps were present." 'WARN'
    exit 4
} else {
    exit 0
}
