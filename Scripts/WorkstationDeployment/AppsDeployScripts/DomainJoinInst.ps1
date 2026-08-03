#Requires -Version 5.1
<#
.SYNOPSIS
    Joins this machine to the rpsinc.ringpinion.com AD domain. Designed to
    run elevated on a single box (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/DomainJoinInst.ps1

    Prompts for its OWN AD credentials, separate from the network-share
    credential prompt that other scripts in this project trigger
    (Request-ShareAccessIfNeeded in Apps-Deploy-Menu.ps1). These are
    deliberately different authorization scopes -- an account with
    read access to \\svazdfs001\systems$ is not necessarily delegated
    rights to join computers to the domain, so this doesn't assume the
    share credential is reusable here.

    NO AUTOMATIC REBOOT: Add-Computer is called without -Restart. Domain
    join needs a restart to fully take effect (Kerberos, GPO application,
    etc.), but forcing an immediate reboot here would kill the rest of
    whatever else was selected in the same deployment run. Instead this
    logs a clear "restart needed" warning and lets the run continue --
    same pattern already used for msiexec's reboot-pending codes (3010/
    1641) elsewhere in this project (CWAgentInst.ps1, ZACInst.ps1,
    SentinelOneInst.ps1).

    SAFETY GUARD: if the machine is already joined to a DIFFERENT domain
    than rpsinc.ringpinion.com, this refuses to do anything automatically.
    Migrating a machine from one domain to another is a much bigger,
    riskier operation than a fresh join and isn't attempted here -- it
    fails loudly (exit 5) instead, requiring manual handling.

    Because of the ordering note in Apps-Deploy-Menu.ps1's manifest
    ("apps run in the order listed, so a dependency should be listed
    before anything that needs it"), this is deliberately the FIRST
    entry in the Initial Setup category if selected.

.PARAMETER LogPath
    Where to write this script's own log file.

.PARAMETER TargetDomain
    The AD domain to join. Defaults to rpsinc.ringpinion.com.

.EXITCODES
    0 = success -- domain join completed this run (a restart is still
        needed for it to fully take effect, but that's expected, not a failure)
    1 = Add-Computer failed (bad credentials, unreachable DC, naming
        conflict, etc. -- see the error text in the log)
    2 = credential prompt was cancelled
    3 = not running elevated
    4 = nothing to do -- already joined to the target domain
    5 = already joined to a DIFFERENT domain -- refusing to attempt an
        automatic migration; needs manual handling
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\DomainJoinInst.log",
    [string]$TargetDomain = 'rpsinc.ringpinion.com'
)

$ErrorActionPreference = 'Stop'

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

Write-Log "=== Install-DomainJoin starting on $env:COMPUTERNAME ==="

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
if ($cs.PartOfDomain) {
    if ($cs.Domain -eq $TargetDomain) {
        Write-Log "Already joined to $TargetDomain. Skipping."
        Write-Log "Nothing was done -- domain join was already present." 'WARN'
        exit 4
    } else {
        Write-Log "Machine is joined to a DIFFERENT domain ($($cs.Domain)), not $TargetDomain." 'ERROR'
        Write-Log "Refusing to attempt an automatic domain migration -- this needs manual handling (unjoin, then rejoin, or a deliberate migration process)." 'ERROR'
        exit 5
    }
}

Write-Log "Machine is currently in workgroup '$($cs.Domain)'. Requesting AD credentials to join $TargetDomain."
$cred = Get-Credential -UserName 'RPSINC\' -Message "Enter AD credentials with rights to join this computer to $TargetDomain (e.g. DOMAIN\username). This is a SEPARATE credential from the file-share prompt -- domain-join rights are not the same as share-read rights."

if (-not $cred) {
    Write-Log "Credential prompt was cancelled. Domain join not attempted." 'ERROR'
    exit 2
}

try {
    Write-Log "Running Add-Computer -DomainName $TargetDomain (no auto-restart -- see script header for why)"
    Add-Computer -DomainName $TargetDomain -Credential $cred -Force -ErrorAction Stop
} catch {
    Write-Log "Domain join FAILED: $($_.Exception.Message)" 'ERROR'
    Write-Log "=== Install-DomainJoin finished. Overall success: False ==="
    exit 1
}

Write-Log "Domain join succeeded."
Write-Log "A RESTART IS REQUIRED for this to fully take effect (Kerberos, GPO, etc.) -- not done automatically here so the rest of this deployment run can continue. Restart this machine when convenient." 'WARN'
Write-Log "=== Install-DomainJoin finished. Overall success: True (restart pending) ==="
exit 0
