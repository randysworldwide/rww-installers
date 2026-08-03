#Requires -Version 5.1
<#
.SYNOPSIS
    Enables the built-in local Administrator account and sets its
    password -- a safety-net fallback admin account. Designed to run
    elevated (RWW WorkstationDeployment project -- see
    Apps-Deploy-Menu.ps1).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/AppsDeployScripts/EnableAdminAccountInst.ps1

    Targets the built-in Administrator account by its well-known SID
    suffix (-500), not by the literal name "Administrator" -- the
    built-in account can be renamed in some environments, and matching
    on the SID is reliable regardless of what it's currently called.

    Prompts for the password via a custom WinForms dialog (password +
    confirm fields, masked input, inline "passwords don't match"
    validation) rather than Get-Credential, for the same reason
    DomainJoinInst.ps1 does: this runs inside the background install
    runspace, which lacks the $Host support Get-Credential depends on.

    ORDERING: positioned first in Initial Setup, ahead of both Change
    Computer Name and Join Domain. This is a
    safety net independent of domain membership -- having a known-good
    local admin fallback matters MORE once Remove Throwaway Setup Account
    has run, since that removes what would otherwise be the only local
    admin on the machine.

    Always re-applies both the enable and the password, even if the
    account is already enabled -- re-running this is meant to guarantee a
    known-current password, not just "enabled or not."

.PARAMETER LogPath
    Where to write this script's own log file.

.EXITCODES
    0 = success -- account enabled and password set this run
    1 = Enable-LocalUser or Set-LocalUser failed
    2 = password prompt was cancelled
    3 = not running elevated
    4 = nothing to do -- no account with the built-in Administrator SID
        (-500) was found, which should not normally happen
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\EnableAdminAccountInst.log"
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

Write-Log "=== Install-EnableAdminAccount starting on $env:COMPUTERNAME ==="

$adminAccount = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID -like '*-500' } | Select-Object -First 1
if (-not $adminAccount) {
    Write-Log "No local account with the built-in Administrator SID (-500) was found -- this shouldn't normally happen." 'ERROR'
    exit 4
}

Write-Log "Found built-in Administrator account: '$($adminAccount.Name)' (SID: $($adminAccount.SID))"

function Show-PasswordDialog {
    param([string]$Message)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Set Administrator Password'
    $form.Size = New-Object System.Drawing.Size(430, 260)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true

    $lblMessage = New-Object System.Windows.Forms.Label
    $lblMessage.Text = $Message
    $lblMessage.Location = New-Object System.Drawing.Point(15, 15)
    $lblMessage.Size = New-Object System.Drawing.Size(390, 40)
    $form.Controls.Add($lblMessage)

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = 'Password:'
    $lblPass.Location = New-Object System.Drawing.Point(15, 65)
    $lblPass.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = New-Object System.Drawing.Point(120, 62)
    $txtPass.Size = New-Object System.Drawing.Size(280, 20)
    $txtPass.UseSystemPasswordChar = $true
    $form.Controls.Add($txtPass)

    $lblConfirm = New-Object System.Windows.Forms.Label
    $lblConfirm.Text = 'Confirm:'
    $lblConfirm.Location = New-Object System.Drawing.Point(15, 95)
    $lblConfirm.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblConfirm)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(120, 92)
    $txtConfirm.Size = New-Object System.Drawing.Size(280, 20)
    $txtConfirm.UseSystemPasswordChar = $true
    $form.Controls.Add($txtConfirm)

    $lblError = New-Object System.Windows.Forms.Label
    $lblError.Text = ''
    $lblError.ForeColor = [System.Drawing.Color]::Firebrick
    $lblError.Location = New-Object System.Drawing.Point(15, 118)
    $lblError.Size = New-Object System.Drawing.Size(390, 20)
    $form.Controls.Add($lblError)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = 'OK'
    $btnOK.Location = New-Object System.Drawing.Point(225, 175)
    $btnOK.Size = New-Object System.Drawing.Size(85, 28)
    $form.Controls.Add($btnOK)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(320, 175)
    $btnCancel.Size = New-Object System.Drawing.Size(85, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    # Deliberately no AcceptButton wired to Enter -- OK's own Click handler
    # validates (non-blank, passwords match) before allowing the dialog to
    # actually close, so a typo can be corrected in place instead of
    # silently closing with mismatched input.
    $form.CancelButton = $btnCancel

    $btnOK.Add_Click({
        if ($txtPass.Text.Length -eq 0) {
            $lblError.Text = 'Password cannot be blank.'
            return
        }
        if ($txtPass.Text -ne $txtConfirm.Text) {
            $lblError.Text = 'Passwords do not match -- try again.'
            $txtConfirm.Text = ''
            return
        }
        $form.Tag = 'OK'
        $form.Close()
    })

    [void]$form.ShowDialog()
    $passText = $txtPass.Text
    $accepted = ($form.Tag -eq 'OK')
    $form.Dispose()

    if (-not $accepted) {
        return $null
    }
    return (ConvertTo-SecureString -String $passText -AsPlainText -Force)
}

$securePassword = Show-PasswordDialog -Message "Set a password for the built-in Administrator account ('$($adminAccount.Name)'). This is a safety-net fallback account."

if (-not $securePassword) {
    Write-Log "Password prompt was cancelled. Account not modified." 'ERROR'
    exit 2
}

try {
    if (-not $adminAccount.Enabled) {
        Enable-LocalUser -Name $adminAccount.Name -ErrorAction Stop
        Write-Log "Enabled the '$($adminAccount.Name)' account."
    } else {
        Write-Log "'$($adminAccount.Name)' was already enabled."
    }
    Set-LocalUser -Name $adminAccount.Name -Password $securePassword -ErrorAction Stop
    Write-Log "Password set on '$($adminAccount.Name)'."
} catch {
    Write-Log "Failed to enable the account or set its password: $($_.Exception.Message)" 'ERROR'
    Write-Log "=== Install-EnableAdminAccount finished. Overall success: False ==="
    exit 1
}

Write-Log "=== Install-EnableAdminAccount finished. Overall success: True ==="
exit 0
