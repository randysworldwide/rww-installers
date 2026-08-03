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

    CONFIRMED IN TESTING: this used to call Get-Credential, which failed
    with "the host program... does not support user interaction." This
    script runs inside the background install runspace (created via
    [runspacefactory]::CreateRunspace() in Show-ProgressGui), which gets
    a minimal default PowerShell host with no credential-prompting
    support -- Get-Credential depends on $Host implementing that, so it
    can never work here regardless of the OS-level dialog underneath.
    Fixed by building a small custom WinForms username/password dialog
    (Show-CredentialDialog, below) instead, which doesn't depend on
    $Host at all -- same reason ChangeComputerNameInst.ps1's InputBox
    already worked fine from this same runspace without needing a fix.

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

    COORDINATION WITH CHANGE COMPUTER NAME: if that entry is ALSO
    selected in the same run, ChangeComputerNameInst.ps1 defers the
    actual rename to this script instead of applying it directly (see
    its own header for why -- renaming needs a restart to take effect,
    and joining before that restart would create the AD computer object
    under the OLD name). This script checks for that deferred name at
    C:\ProgramData\Dev\AppsDeploy\PendingComputerName.txt and, if
    present, passes it to Add-Computer's own -NewName parameter so both
    happen together in one call -- the Microsoft-documented correct way
    to rename and join at once. If the join itself then fails for any
    other reason (bad credentials, unreachable DC, etc.), this still
    falls back to applying the plain rename on its own before exiting,
    so a failed join doesn't silently swallow the rename that was
    actually requested.

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

$pendingNamePath = "$env:ProgramData\Dev\AppsDeploy\PendingComputerName.txt"
$pendingName = $null
if (Test-Path -LiteralPath $pendingNamePath -ErrorAction SilentlyContinue) {
    try {
        $pendingName = (Get-Content -LiteralPath $pendingNamePath -Raw -ErrorAction Stop).Trim()
        if ([string]::IsNullOrWhiteSpace($pendingName)) { $pendingName = $null }
    } catch {
        Write-Log "Found a pending-name file but couldn't read it: $($_.Exception.Message)" 'WARN'
    }
}
if ($pendingName) {
    Write-Log "Found a pending computer name from Change Computer Name: '$pendingName'."
}

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
if ($cs.PartOfDomain) {
    if ($cs.Domain -eq $TargetDomain) {
        Write-Log "Already joined to $TargetDomain. Skipping the join itself."
        if ($pendingName) {
            Write-Log "A rename to '$pendingName' was still pending -- applying it on its own since there's no join to combine it with." 'WARN'
            try {
                Rename-Computer -NewName $pendingName -Force -ErrorAction Stop
                Write-Log "Rename to '$pendingName' succeeded (requires a restart to take effect)."
                Remove-Item -LiteralPath $pendingNamePath -Force -ErrorAction SilentlyContinue
                Write-Log "=== Install-DomainJoin finished. Overall success: True (rename applied, restart pending) ==="
                exit 0
            } catch {
                Write-Log "Rename failed: $($_.Exception.Message)" 'ERROR'
                Write-Log "=== Install-DomainJoin finished. Overall success: False ==="
                exit 1
            }
        }
        Write-Log "Nothing was done -- domain join was already present." 'WARN'
        exit 4
    } else {
        Write-Log "Machine is joined to a DIFFERENT domain ($($cs.Domain)), not $TargetDomain." 'ERROR'
        Write-Log "Refusing to attempt an automatic domain migration -- this needs manual handling (unjoin, then rejoin, or a deliberate migration process)." 'ERROR'
        if ($pendingName) {
            Write-Log "A rename to '$pendingName' is also still pending -- left untouched given the domain mismatch above needs manual handling anyway." 'WARN'
        }
        exit 5
    }
}

Write-Log "Machine is currently in workgroup '$($cs.Domain)'. Requesting AD credentials to join $TargetDomain."
if ($pendingName) {
    Write-Log "Will rename to '$pendingName' and join together in one step."
}

function Show-CredentialDialog {
    # Get-Credential depends on $Host implementing credential-prompting
    # support. The background runspace this script actually runs in
    # (created via [runspacefactory]::CreateRunspace() in
    # Show-ProgressGui) gets a minimal default host that does NOT
    # implement that -- confirmed in testing: Get-Credential threw "the
    # host program... does not support user interaction" here, even
    # though the identical Get-Credential call works fine elsewhere in
    # this project (Request-ShareAccessIfNeeded runs in the ORIGINAL
    # runspace, before Show-ProgressGui ever creates the background one,
    # so it never hits this). This dialog sidesteps the problem entirely
    # by using plain WinForms, which doesn't depend on $Host at all --
    # same reason ChangeComputerNameInst.ps1's InputBox already works
    # fine from this same background runspace.
    param(
        [string]$Message,
        [string]$DefaultUserName = 'RPSINC\'
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Domain Join Credentials'
    $form.Size = New-Object System.Drawing.Size(430, 230)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $lblMessage = New-Object System.Windows.Forms.Label
    $lblMessage.Text = $Message
    $lblMessage.Location = New-Object System.Drawing.Point(15, 15)
    $lblMessage.Size = New-Object System.Drawing.Size(390, 55)
    $form.Controls.Add($lblMessage)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = 'User name:'
    $lblUser.Location = New-Object System.Drawing.Point(15, 80)
    $lblUser.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Text = $DefaultUserName
    $txtUser.Location = New-Object System.Drawing.Point(120, 77)
    $txtUser.Size = New-Object System.Drawing.Size(280, 20)
    $form.Controls.Add($txtUser)

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = 'Password:'
    $lblPass.Location = New-Object System.Drawing.Point(15, 110)
    $lblPass.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(120, 107)
    $txtPass.Size = New-Object System.Drawing.Size(280, 20)
    $txtPass.UseSystemPasswordChar = $true
    $form.Controls.Add($txtPass)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = 'OK'
    $btnOK.Location = New-Object System.Drawing.Point(225, 155)
    $btnOK.Size = New-Object System.Drawing.Size(85, 28)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(320, 155)
    $btnCancel.Size = New-Object System.Drawing.Size(85, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    $userText = $txtUser.Text
    $passText = $txtPass.Text
    $form.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($userText) -or $passText.Length -eq 0) {
        return $null
    }

    $securePass = ConvertTo-SecureString -String $passText -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($userText, $securePass)
}

$cred = Show-CredentialDialog -DefaultUserName 'RPSINC\' -Message "Enter AD credentials with rights to join this computer to $TargetDomain (e.g. DOMAIN\username). This is a SEPARATE credential from the file-share prompt -- domain-join rights are not the same as share-read rights."

if (-not $cred) {
    Write-Log "Credential prompt was cancelled. Domain join not attempted." 'ERROR'
    exit 2
}

try {
    if ($pendingName) {
        Write-Log "Running Add-Computer -DomainName $TargetDomain -NewName $pendingName (combined rename+join, no auto-restart -- see script header for why)"
        Add-Computer -DomainName $TargetDomain -NewName $pendingName -Credential $cred -Force -ErrorAction Stop
    } else {
        Write-Log "Running Add-Computer -DomainName $TargetDomain (no auto-restart -- see script header for why)"
        Add-Computer -DomainName $TargetDomain -Credential $cred -Force -ErrorAction Stop
    }
} catch {
    Write-Log "Domain join FAILED: $($_.Exception.Message)" 'ERROR'

    if ($pendingName) {
        Write-Log "A rename to '$pendingName' was also pending as part of this combined step. Falling back to applying just the rename on its own, so it isn't silently lost." 'WARN'
        try {
            Rename-Computer -NewName $pendingName -Force -ErrorAction Stop
            Write-Log "Fallback rename to '$pendingName' succeeded (still requires a restart to take effect)."
            Remove-Item -LiteralPath $pendingNamePath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Fallback rename also failed: $($_.Exception.Message)" 'ERROR'
        }
    }

    Write-Log "=== Install-DomainJoin finished. Overall success: False ==="
    exit 1
}

if ($pendingName) {
    Remove-Item -LiteralPath $pendingNamePath -Force -ErrorAction SilentlyContinue
    Write-Log "Domain join and rename to '$pendingName' both succeeded together."
} else {
    Write-Log "Domain join succeeded."
}
Write-Log "A RESTART IS REQUIRED for this to fully take effect (Kerberos, GPO, new name, etc.) -- not done automatically here so the rest of this deployment run can continue. Restart this machine when convenient." 'WARN'
Write-Log "=== Install-DomainJoin finished. Overall success: True (restart pending) ==="
exit 0
