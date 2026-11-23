#Requires -Version 5.1
<#
.SYNOPSIS
    AppsDeploy v2 -- UI process (WPF). Selection window + Progress
    window. Does NO install work itself: it builds a job plan, launches
    AppsDeploy-Worker.ps1 as a SEPARATE process, and tails the run log.

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/AppsDeploy2/AppsDeploy-UI.ps1

    ARCHITECTURE (the point of the redesign): the v1 progress window
    froze under install load and four separate fixes never fully cured
    it. Here the UI and the work live in different PROCESSES, connected
    only by a log file -- no shared thread, message pump, apartment, or
    priority class, so that whole failure class is impossible by
    construction.

    WINDOW MODEL (requirement: both windows stay up together): the
    Selection window stays OPEN the whole session. When a run starts,
    the Progress window opens MODELESS with the Selection window as its
    owner (so it always sits above it), and the Selection window dims
    (opacity drop) with its CONTENT disabled -- its title bar stays
    live, so it can still be moved and resized, just not clicked. A
    dispatcher frame pumps messages until the Progress window closes;
    then the Selection window re-enables and RE-SCANS, so its
    checkboxes always reflect what is actually installed now. This is
    deliberately modeless: a modal child would disable the owner's
    chrome and make it immovable.

    DESIRED-STATE SELECTION: installed apps start CHECKED, so the
    opening state means "no changes". Proceed shows a diff (install X,
    uninstall Y, N unchanged) before anything runs -- without that, a
    tech adding one app would silently uninstall everything unchecked.

    CANCEL: closing the Progress window (X / Alt+F4) mid-run asks "Are
    you sure you want to cancel the install?". On Yes it kills the
    worker's whole process tree (taskkill /T /F -- which also takes
    down a wedged msiexec/vendor child, something v1 never could), lets
    MSI's transactional rollback clean the in-flight MSI, then runs a
    best-effort cleanup sweep of that ONE app in the background while
    the window keeps streaming the sweep's log. Completed steps are
    final by design. When the sweep finishes, you land back on the
    (re-scanned) Selection window.

    SYSTEM / BACKSTAGE: when running as SYSTEM with other users
    actively logged on, a plan that includes uninstalls gets an extra
    confirmation naming those users first.
#>

[CmdletBinding()]
param(
    # Default resolved in the body, NOT here: $PSScriptRoot is not
    # reliably populated while param() default expressions are being
    # evaluated (confirmed on a real machine -- powershell -File launch
    # hit 'Cannot bind argument... empty string'). In the script body it
    # is always valid.
    [string]$ManifestPath,
    # LOCAL TEST MODE is purely a LABEL: v2 always runs whatever files sit
    # next to this script -- there is no runtime GitHub fetching to bypass
    # (unlike v1). The switch just stamps the windows, dialogs and log so
    # a test run can never be mistaken for a production one in logs or
    # screenshots. AppsDeploy-Test.bat passes it; the production
    # AppsDeploy.bat (which downloads the latest files from the repo
    # first) does not.
    [switch]$LocalTest,
    # Force the text-menu front-end (it also engages automatically on
    # desktops that cannot display WPF windows, such as Backstage).
    [switch]$ConsoleMode
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework

# Software rendering, unconditionally: WPF's default hardware pipeline
# paints NOTHING on desktops without real DWM composition -- the whole
# window renders black in ConnectWise Backstage (CONFIRMED on a real
# Backstage session). Software mode costs nothing perceptible for a
# form like this and also survives flaky RDP/virtual-desktop rendering.
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
# And keep WPF's render loop ALIVE on desktops that report no display
# device (hidden/headless sessions): without this switch WPF silently
# stops rendering there even in software mode.
try {
    [System.AppContext]::SetSwitch('Switch.System.Windows.Media.ShouldRenderEvenWhenNoDisplayDevicesAreAvailable', $true)
} catch {}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Resolve our own folder here, where automatic variables are dependable.
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $script:AppRoot 'AppsDeploy-Manifest.ps1' }

. $ManifestPath

$script:TitleSuffix = if ($LocalTest) { ' (LOCAL TEST MODE)' } else { '' }
$script:LogDir     = if ($LocalTest) { "$env:ProgramData\RWW\AppsDeployTest\Logs" } else { "$env:ProgramData\RWW\AppsDeploy\Logs" }
$script:WorkerPath = Join-Path $script:AppRoot 'AppsDeploy-Worker.ps1'
$script:PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $script:LogDir)) { New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null }

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $id.IsSystem
}
function Test-IsSystem { [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem }

function Get-ActiveUserSessions {
    # Other humans logged on (matters for SYSTEM/Backstage uninstalls).
    $users = @()
    try {
        $raw = (& quser.exe 2>$null)
        if ($raw) {
            $users = @($raw | Select-Object -Skip 1 | ForEach-Object {
                ($_ -replace '^[>\s]+', '') -split '\s+' | Select-Object -First 1
            } | Where-Object { $_ })
        }
    } catch {}
    return $users
}

function Wait-WindowClosed {
    # Shows a window MODELESS and pumps a dispatcher frame until it
    # closes. DispatcherTimers keep ticking inside the frame, and the
    # owner window's chrome stays alive (unlike ShowDialog).
    param([System.Windows.Window]$Window)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $Window.Add_Closed({ $frame.Continue = $false }.GetNewClosure())
    $Window.Show()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# ------------------------- Frutiger Aero chrome -------------------------
# Shared XAML resource block: sky/aqua gradients, glossy buttons with a
# white top highlight, soft rounded corners. Vista-era optimism, 2026
# rendering. Colors live here once so the look stays consistent.
$script:AeroResources = @'
    <Window.Resources>
        <LinearGradientBrush x:Key="AeroSky" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#FFEAF6FF" Offset="0"/>
            <GradientStop Color="#FFCFE9FB" Offset="0.45"/>
            <GradientStop Color="#FFB7DDF6" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="AeroBanner" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#FF6FBDEB" Offset="0"/>
            <GradientStop Color="#FF2E8BCB" Offset="0.5"/>
            <GradientStop Color="#FF1C6FAE" Offset="1"/>
        </LinearGradientBrush>
        <LinearGradientBrush x:Key="AeroGloss" StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#A8FFFFFF" Offset="0"/>
            <GradientStop Color="#22FFFFFF" Offset="0.5"/>
            <GradientStop Color="#00FFFFFF" Offset="0.52"/>
        </LinearGradientBrush>
        <Style x:Key="AeroButton" TargetType="Button">
            <Setter Property="Foreground" Value="#FF0B3B5E"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="18,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="bg" CornerRadius="6" BorderThickness="1" BorderBrush="#FF5A9FD0">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                        <GradientStop Color="#FFF4FBFF" Offset="0"/>
                                        <GradientStop Color="#FFD3ECFB" Offset="0.5"/>
                                        <GradientStop Color="#FFA9D8F3" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                            </Border>
                            <Border CornerRadius="6,6,3,3" Margin="1,1,1,0" VerticalAlignment="Top" Height="14" Background="#90FFFFFF" IsHitTestVisible="False"/>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bg" Property="BorderBrush" Value="#FF2E8BCB"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="AeroPrimaryButton" TargetType="Button" BasedOn="{StaticResource AeroButton}">
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="AeroToggle" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="#FF0B3B5E"/>
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="12,5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="bg" CornerRadius="6" BorderThickness="1" BorderBrush="#FF5A9FD0" Background="#FFEAF6FF"/>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="bg" Property="Background" Value="#FF8BD08B"/>
                                <Setter TargetName="bg" Property="BorderBrush" Value="#FF3E8E3E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
'@

function New-WindowFromXaml {
    param([string]$Xaml)
    [Windows.Markup.XamlReader]::Parse($Xaml)
}

function Show-AeroDialog {
    # Styled Yes/No or OK dialog. Returns $true for Yes/OK.
    # -CountdownSeconds: live countdown; expiry = No.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('YesNo','OK')][string]$Buttons = 'YesNo',
        [int]$CountdownSeconds = 0,
        [System.Windows.Window]$Owner
    )
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" SizeToContent="Height" Width="470" MinWidth="380"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        FontFamily="Segoe UI" Topmost="True">
$script:AeroResources
    <Border Background="{StaticResource AeroSky}">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{StaticResource AeroBanner}" Padding="16,10">
                <Grid>
                    <TextBlock x:Name="TitleText" Foreground="White" FontSize="15" FontWeight="SemiBold"/>
                    <Border Background="{StaticResource AeroGloss}" IsHitTestVisible="False"/>
                </Grid>
            </Border>
            <TextBlock Grid.Row="1" x:Name="MsgText" Margin="18,14,18,4" TextWrapping="Wrap" FontSize="13" Foreground="#FF10324C"/>
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="14,10,14,14">
                <TextBlock x:Name="CountdownText" VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#FF1C6FAE" FontSize="12"/>
                <Button x:Name="BtnYes" Style="{StaticResource AeroPrimaryButton}" MinWidth="92" Margin="0,0,10,0"/>
                <Button x:Name="BtnNo"  Style="{StaticResource AeroButton}" MinWidth="92"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@
    $win = New-WindowFromXaml $xaml
    if ($Owner) { $win.Owner = $Owner; $win.Topmost = $false }
    $win.FindName('TitleText').Text = $Title
    $win.FindName('MsgText').Text = $Message
    $btnYes = $win.FindName('BtnYes'); $btnNo = $win.FindName('BtnNo')
    $cd = $win.FindName('CountdownText')
    if ($Buttons -eq 'OK') {
        $btnYes.Content = 'OK'; $btnNo.Visibility = 'Collapsed'
    } else {
        $btnYes.Content = 'Yes'; $btnNo.Content = 'No'
    }
    $btnYes.Add_Click({ $win.DialogResult = $true }.GetNewClosure())
    $btnNo.Add_Click({ $win.DialogResult = $false }.GetNewClosure())

    $timer = $null
    if ($CountdownSeconds -gt 0) {
        $state = @{ Remaining = $CountdownSeconds }
        $cd.Text = "Auto-closing in $($state.Remaining)s"
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(1)
        $timer.Add_Tick({
            $state.Remaining--
            if ($state.Remaining -le 0) {
                $timer.Stop()
                try { $win.DialogResult = $false } catch {}
            } else {
                $cd.Text = "Auto-closing in $($state.Remaining)s"
            }
        }.GetNewClosure())
        $timer.Start()
    }
    $result = $win.ShowDialog()
    if ($timer) { $timer.Stop() }
    return [bool]$result
}

function Invoke-HiddenExe {
    # The UI detached from its console (so Windows Terminal's lifecycle
    # cannot touch it) -- which means a plain call to a console program
    # (net.exe, taskkill.exe) makes Windows allocate a brand-new console
    # WINDOW for that child (CONFIRMED: a stray window popped up when the
    # share gate ran net.exe at the start of an Office install). Run all
    # native exes windowless instead. Returns the exit code, -1 on
    # failure to start.
    param([string]$FilePath, [string]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.Handle
        [void]$p.StandardOutput.ReadToEnd()
        [void]$p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return $p.ExitCode
    } catch { return -1 }
}

# -------------------- Installer-share access gate --------------------
# Some apps (the Office family via the Odt engine; later share-based
# ports can declare NeedsShare in their specs) install from the private
# share. The gate is PLAN-DRIVEN and just-in-time: winget-only plans
# never see it; a share-touching plan first silently checks for access
# (a domain-joined tech sails through with zero prompts) and only asks
# for credentials when access is genuinely missing. Established with
# 'net use' (non-persistent), which the worker process inherits because
# it shares this logon session; dropped again when the app exits.
$script:ShareServerHosts = @('svazdfs001', '10.1.0.5')
$script:ShareMappedTo = @()

function Get-AppVariantChoices {
    # Choices for an app's Variants dropdown (e.g. the Automate agent's
    # per-site installers): the manifest Default first, then the share
    # folder's subdirectory names -- so adding a site is just adding a
    # folder, no manifest edit. A quick TCP guard keeps an unreachable
    # share from hanging menu open; unreachable just means the dropdown
    # shows the default until the share is available.
    param([hashtable]$App)
    $v = $App.Variants
    $choices = @($v.Default)
    # Seed: manifest-listed names shown even with no share access yet.
    foreach ($s in @($v.Seed)) {
        if ($s -and $s -notin $choices) { $choices += $s }
    }
    try {
        $base = [string]$v.DiscoverFrom
        if ($base -match '^\\\\([^\\]+)\\') {
            $srv = $Matches[1]
            $t = New-Object System.Net.Sockets.TcpClient
            $iar = $t.BeginConnect($srv, 445, $null, $null)
            $up = ($iar.AsyncWaitHandle.WaitOne(1500) -and $t.Connected)
            $t.Close()
            if ($up -and (Test-Path -LiteralPath $base -ErrorAction SilentlyContinue)) {
                foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
                    if ($d.Name -notin $choices -and $d.Name -notin @($v.Exclude)) { $choices += $d.Name }
                }
            }
        }
    } catch {}
    return $choices
}

function Test-AppNeedsShare {
    param([hashtable]$App)
    foreach ($k in @('Install', 'Uninstall', 'Update')) {
        $spec = $App[$k]
        if ($spec -is [hashtable] -and ($spec.Engine -eq 'Odt' -or $spec.NeedsShare)) { return $true }
    }
    return $false
}

function Show-AeroCredentialDialog {
    param([System.Windows.Window]$Owner, [string]$Share)
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network share credentials" SizeToContent="Height" Width="470" MinWidth="380"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        FontFamily="Segoe UI" Topmost="True">
$script:AeroResources
    <Border Background="{StaticResource AeroSky}">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{StaticResource AeroBanner}" Padding="16,10">
                <Grid>
                    <TextBlock x:Name="TitleText" Foreground="White" FontSize="15" FontWeight="SemiBold" Text="Network share credentials"/>
                    <Border Background="{StaticResource AeroGloss}" IsHitTestVisible="False"/>
                </Grid>
            </Border>
            <TextBlock Grid.Row="1" x:Name="MsgText" Margin="18,14,18,4" TextWrapping="Wrap" FontSize="13" Foreground="#FF10324C"/>
            <StackPanel Grid.Row="2" Margin="18,8,18,0">
                <TextBlock Text="Username (DOMAIN\username):" FontSize="12" Foreground="#FF10324C" Margin="0,0,0,3"/>
                <TextBox x:Name="UserBox" FontSize="13" Padding="4,3"/>
            </StackPanel>
            <StackPanel Grid.Row="3" Margin="18,10,18,0">
                <TextBlock Text="Password:" FontSize="12" Foreground="#FF10324C" Margin="0,0,0,3"/>
                <PasswordBox x:Name="PassBox" FontSize="13" Padding="4,3"/>
            </StackPanel>
            <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="14,16,14,14">
                <Button x:Name="BtnOk" Style="{StaticResource AeroPrimaryButton}" Content="Connect" MinWidth="100" Margin="0,0,10,0" IsDefault="True"/>
                <Button x:Name="BtnCancel" Style="{StaticResource AeroButton}" Content="Cancel" MinWidth="92" IsCancel="True"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@
    $win = New-WindowFromXaml $xaml
    if ($Owner) { $win.Owner = $Owner; $win.Topmost = $false }
    $win.FindName('MsgText').Text = "One or more selected apps install from the private share ($Share), and this machine does not currently have access to it. Enter credentials that can read the share."
    $userBox = $win.FindName('UserBox'); $passBox = $win.FindName('PassBox')
    $userBox.Text = 'RPSINC\'   # the domain, pre-entered; caret lands after it
    $userBox.CaretIndex = $userBox.Text.Length
    $win.FindName('BtnOk').Add_Click({ $win.DialogResult = $true }.GetNewClosure())
    $win.FindName('BtnCancel').Add_Click({ $win.DialogResult = $false }.GetNewClosure())
    [void]$userBox.Focus()
    if ($win.ShowDialog()) {
        return @{ User = $userBox.Text; Password = $passBox.Password }
    }
    return $null
}

function Ensure-ShareAccess {
    # Returns $true when the installer share is reachable AND readable
    # (establishing a session connection with prompted credentials if
    # needed), $false when the tech cancels or the server is plain
    # unreachable. Called only for plans that actually touch the share.
    param([System.Windows.Window]$Owner)

    # Reachability first, with a 2s TCP cap per host: a bare Test-Path
    # against a dead host can hang this UI thread for 10-30 seconds.
    $srv = $null
    foreach ($h in $script:ShareServerHosts) {
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $iar = $t.BeginConnect($h, 445, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000) -and $t.Connected) { $t.Close(); $srv = $h; break }
            $t.Close()
        } catch {}
    }
    if (-not $srv) {
        [void](Show-AeroDialog -Title 'Network share unreachable' -Buttons OK -Owner $Owner -Message ("The installer share server is not reachable from this machine at all (checked {0} on the file-sharing port). The selected apps that install from the share cannot run right now -- check the network and try again." -f ($script:ShareServerHosts -join ' and ')))
        return $false
    }
    $unc = "\\$srv\systems$"
    if (Test-Path "$unc\Software" -ErrorAction SilentlyContinue) { return $true }

    while ($true) {
        $cred = Show-AeroCredentialDialog -Owner $Owner -Share $unc
        if (-not $cred -or [string]::IsNullOrWhiteSpace($cred.User)) { return $false }
        $rc = Invoke-HiddenExe -FilePath 'net.exe' -Arguments ('use "{0}" "{1}" /user:{2} /persistent:no' -f $unc, $cred.Password, $cred.User)
        if ($rc -eq 0 -and (Test-Path "$unc\Software" -ErrorAction SilentlyContinue)) {
            $script:ShareMappedTo += $unc
            return $true
        }
        [void](Invoke-HiddenExe -FilePath 'net.exe' -Arguments ('use "{0}" /delete /y' -f $unc))
        if (-not (Show-AeroDialog -Title 'Could not connect' -Owner $Owner -Message "Connecting to $unc with those credentials did not work. Try again?")) { return $false }
    }
}

# ----------------------------- Progress -----------------------------
$script:LevelBrushes = @{
    'INFO'    = '#FFE8EEF2'   # near-white
    'WARN'    = '#FFFFB347'   # amber
    'ERROR'   = '#FFFF6B6B'   # bright-but-not-blinding red
    'SUCCESS' = '#FF6FE89B'   # bright-but-not-blinding green
    'CMD'     = '#FF7FC8F8'   # light blue: commands being executed
}

function Show-ProgressWindow {
    # Launches the worker, tails + colorizes the log, handles cancel and
    # the completion prompt. Blocks (via dispatcher frame) until the
    # window closes. Returns 'repeat' (back to selection) or 'exit'.
    param(
        [array]$Plan,
        [bool]$Interactive,
        [System.Windows.Window]$OwnerWindow
    )

    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile  = Join-Path $script:LogDir "AppsDeploy_$runStamp.log"
    $jobFile  = Join-Path $script:LogDir "AppsDeploy_$runStamp.job.json"
    @{ Interactive = $Interactive; Steps = $Plan } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobFile -Encoding UTF8
    $modeNote = if ($LocalTest) { ' -- LOCAL TEST MODE (running the files in ' + $script:AppRoot + ', no GitHub involved)' } else { '' }
    Set-Content -LiteralPath $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Log file: $logFile$modeNote" -Encoding UTF8

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RWW Apps Deploy -- Working" Width="980" Height="620" MinWidth="620" MinHeight="400"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
$script:AeroResources
    <Border Background="{StaticResource AeroSky}">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{StaticResource AeroBanner}" Padding="20,12">
                <Grid>
                    <StackPanel>
                        <TextBlock x:Name="HeaderText" Text="Starting..." Foreground="White" FontSize="17" FontWeight="SemiBold"/>
                        <TextBlock x:Name="SubHeaderText" Foreground="#E6F4FF" FontSize="12" Margin="0,2,0,0" Text=""/>
                    </StackPanel>
                    <Border Background="{StaticResource AeroGloss}" IsHitTestVisible="False"/>
                </Grid>
            </Border>
            <Border Grid.Row="1" Margin="12,10,12,4" CornerRadius="8" Background="#FF0C1B26" BorderBrush="#FF2E4A5E" BorderThickness="1" Padding="6">
                <RichTextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                             FontFamily="Consolas" FontSize="12.5" Foreground="#FFE8EEF2" IsUndoEnabled="False"/>
            </Border>
            <Border Grid.Row="2" Padding="14,8">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" x:Name="FooterText" FontSize="12" Foreground="#FF1C6FAE" TextWrapping="Wrap" VerticalAlignment="Center"
                               Text="Closing this window (X or Alt+F4) cancels the step currently running."/>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
                        <Grid Width="17" Height="17" VerticalAlignment="Center" Margin="0,0,7,0">
                            <Ellipse x:Name="PulseHalo" Opacity="0.5"/>
                            <Ellipse x:Name="PulseDot" Width="11" Height="11"/>
                        </Grid>
                        <TextBlock x:Name="StatusText" FontSize="12" Foreground="#FF1C6FAE" VerticalAlignment="Center"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2" x:Name="CompletePanel" Orientation="Horizontal" Visibility="Collapsed" VerticalAlignment="Center" Margin="14,0,0,0">
                        <TextBlock x:Name="CdText" FontSize="12" Foreground="#FF1C6FAE" VerticalAlignment="Center" Margin="0,0,12,0"/>
                        <TextBlock Text="Install or uninstall anything else?" FontSize="13" FontWeight="SemiBold" Foreground="#FF0B3B5E" VerticalAlignment="Center" Margin="0,0,10,0"/>
                        <Button x:Name="BtnMoreYes" Style="{StaticResource AeroPrimaryButton}" Content="Yes" MinWidth="80" Margin="0,0,10,0"/>
                        <Button x:Name="BtnMoreNo" Style="{StaticResource AeroButton}" Content="No" MinWidth="80"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@
    $win = New-WindowFromXaml $xaml
    $win.Title += $script:TitleSuffix
    # Local copies for use inside GetNewClosure'd handlers below --
    # $script: variables resolve to the closure's own module scope (i.e.
    # $null) inside those, same bug as the Selection window's Proceed
    # handler. Locals are captured reliably.
    $psExe = $script:PsExe
    $workerPath = $script:WorkerPath
    $header = $win.FindName('HeaderText'); $sub = $win.FindName('SubHeaderText')
    $logBox = $win.FindName('LogBox');     $footer = $win.FindName('FooterText')
    $doc = New-Object System.Windows.Documents.FlowDocument
    # PageWidth left at its NaN default ON PURPOSE: that makes the
    # FlowDocument wrap long lines to the control's current width and
    # re-flow live as the window is resized. (A fixed PageWidth was what
    # forced the horizontal scrollbar techs had to chase.)
    $para = New-Object System.Windows.Documents.Paragraph
    $para.Margin = '0'; $para.LineHeight = 17
    $doc.Blocks.Add($para)
    $logBox.Document = $doc

    # --- Launch the worker: its own process, hidden window, no ties. ---
    $workerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -JobFile `"$jobFile`" -LogFile `"$logFile`" -ManifestPath `"$ManifestPath`""
    # CreateNoWindow, NOT -WindowStyle Hidden: a hidden console is still
    # hosted (by Windows Terminal on Win11), which tied the worker's fate
    # to Terminal's own install/uninstall. CREATE_NO_WINDOW allocates a
    # console with no window at all -- no host, no tie.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = $workerArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $worker = [System.Diagnostics.Process]::Start($psi)
    $null = $worker.Handle

    $completePanel = $win.FindName('CompletePanel')
    $cdText        = $win.FindName('CdText')
    $btnMoreYes    = $win.FindName('BtnMoreYes')
    $btnMoreNo     = $win.FindName('BtnMoreNo')
    $statusText    = $win.FindName('StatusText')
    $pulseDot      = $win.FindName('PulseDot')

    # Liveness dot: cycles blue/grey/green while the run is active, solid
    # green on success, solid red on failure. This is a pure UI-process
    # animation -- the UI does no install work, so install load cannot
    # starve it (the v1 freeze class). And if the UI itself ever hung,
    # the dot stopping is an honest signal, not a lie.
    # Crisp dot + a separate blurred halo ellipse BEHIND it: a glow
    # effect applied to the dot itself blurred its edge (real tech
    # feedback); a stand-alone halo keeps the dot razor sharp.
    $pulseHalo  = $win.FindName('PulseHalo')
    $pulseBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#FF5FA8E8'))
    $haloBrush  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#FF5FA8E8'))
    $haloBlur   = New-Object System.Windows.Media.Effects.BlurEffect
    $haloBlur.Radius = 5
    $pulseDot.Fill    = $pulseBrush
    $pulseHalo.Fill   = $haloBrush
    $pulseHalo.Effect = $haloBlur
    $setDot = {
        param([string]$Mode)
        $fillProp = [System.Windows.Media.SolidColorBrush]::ColorProperty
        if ($Mode -eq 'working') {
            $anim = New-Object System.Windows.Media.Animation.ColorAnimationUsingKeyFrames
            foreach ($kf in @(@('#FF5FA8E8', 0.0), @('#FF9FB6C4', 1.0), @('#FF6FE89B', 2.0), @('#FF9FB6C4', 3.0), @('#FF5FA8E8', 4.0))) {
                $col = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($kf[0])
                $kt  = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($kf[1]))
                [void]$anim.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearColorKeyFrame($col, $kt)))
            }
            $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $pulseBrush.BeginAnimation($fillProp, $anim)
            $haloBrush.BeginAnimation($fillProp, $anim)
        } else {
            $hex = if ($Mode -eq 'ok') { '#FF2FBE60' } else { '#FFE04848' }
            $col = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
            $pulseBrush.BeginAnimation($fillProp, $null)
            $haloBrush.BeginAnimation($fillProp, $null)
            $pulseBrush.Color = $col
            $haloBrush.Color = $col
        }
    }
    & $setDot 'working'

    $state = @{
        Done          = $false
        CdRemaining   = 0
        DoneCode      = 0
        CurrentApp    = ''
        CurrentAction = 'Install'
        ReadPos       = 0
        TailBuffer    = ''
        Cancelled     = $false
        SweepProc     = $null
        SweepDeadline = $null
        AllowClose    = $false
        Outcome       = 'exit'
        OkCount       = 0
        FailCount     = 0
        Finished      = $false
        ExitSeenAt    = $null
        RunStart      = (Get-Date)
        LastOutputAt  = (Get-Date)
    }

    $appendLine = {
        param([string]$line)
        if ($line -match '^::STEP::(\d+)/(\d+)::(.+?)::(Install|Uninstall|Update|Repair)$') {
            $verb = switch ($Matches[4]) { 'Install' { 'Installing' } 'Update' { 'Updating' } 'Repair' { 'Repairing' } default { 'Uninstalling' } }
            $state.CurrentApp = $Matches[3]
            $state.CurrentAction = $Matches[4]
            $header.Text = "${verb}: $($Matches[3])"
            $sub.Text = "Step $($Matches[1]) of $($Matches[2])"
            return
        }
        if ($line -match '^::RESULT::(.+?)::(OK|FAILED)$') {
            if ($Matches[2] -eq 'OK') { $state.OkCount++ } else { $state.FailCount++ }
            return
        }
        if ($line -match '^::DONE::(\d+)$') {
            $state.Done = $true
            $state.DoneCode = [int]$Matches[1]
            return
        }
        $brushKey = 'INFO'
        if     ($line -match '\[ERROR\]')   { $brushKey = 'ERROR' }
        elseif ($line -match '\[WARN\]')    { $brushKey = 'WARN' }
        elseif ($line -match '\[SUCCESS\]') { $brushKey = 'SUCCESS' }
        elseif ($line -match '\[CMD\]')     { $brushKey = 'CMD' }
        $run = New-Object System.Windows.Documents.Run($line)
        $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($script:LevelBrushes[$brushKey]))
        if ($brushKey -in @('ERROR','SUCCESS')) { $run.FontWeight = 'SemiBold' }
        $para.Inlines.Add($run)
        $para.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
        $logBox.ScrollToEnd()
    }

    $uiLog = {
        # UI-originated events go to the SAME file, so the on-disk log is
        # the complete record, then render via the normal pipeline.
        param([string]$Message, [string]$Level)
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { & $appendLine $line }
    }

    $pumpLog = {
        try {
            if (-not (Test-Path -LiteralPath $logFile)) { return }
            $fs = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -le $state.ReadPos) { return }
                $fs.Position = $state.ReadPos
                $buf = New-Object byte[] ($fs.Length - $state.ReadPos)
                [void]$fs.Read($buf, 0, $buf.Length)
                $state.ReadPos = $fs.Length
            } finally { $fs.Close() }
            $state.LastOutputAt = Get-Date
            $text = $state.TailBuffer + [System.Text.Encoding]::UTF8.GetString($buf)
            $parts = $text -split "`r?`n", -1
            $state.TailBuffer = $parts[-1]   # keep any partial last line
            for ($k = 0; $k -lt $parts.Count - 1; $k++) {
                if ($parts[$k].Length -gt 0) { & $appendLine $parts[$k] }
            }
        } catch {}
    }

    # Countdown for the inline completion bar. Deliberately NOT a modal
    # dialog: a modal child blocks its owner, which made the log pane
    # unselectable until the prompt was answered (real tech complaint --
    # they could not copy the error text out). Ten minutes of no answer
    # counts as YES (back to the menu); the menu's own 30-minute idle
    # timer is the final cleanup for a forgotten session.
    $cdTimer = New-Object System.Windows.Threading.DispatcherTimer
    $cdTimer.Interval = [TimeSpan]::FromSeconds(1)
    $cdTimer.Add_Tick({
        $state.CdRemaining--
        if ($state.CdRemaining -le 0) {
            $cdTimer.Stop()
            # No answer counts as YES: return to the menu. The menu's own
            # 30-minute idle timer is what finally closes a forgotten app.
            $state.Outcome = 'repeat'
            $state.AllowClose = $true
            $win.Close()
        } else {
            $cdText.Text = ('Returning to the menu in {0}:{1:00}' -f [int][math]::Floor($state.CdRemaining / 60), ($state.CdRemaining % 60))
        }
    }.GetNewClosure())

    $btnMoreYes.Add_Click({
        $cdTimer.Stop()
        $state.Outcome = 'repeat'
        $state.AllowClose = $true
        $win.Close()
    }.GetNewClosure())
    $btnMoreNo.Add_Click({
        $cdTimer.Stop()
        $state.Outcome = 'exit'
        $state.AllowClose = $true
        $win.Close()
    }.GetNewClosure())

    $finishUp = {
        # Normal completion path (::DONE:: seen, or worker died).
        if ($state.Finished) { return }
        $state.Finished = $true
        $header.Text = if ($state.DoneCode -eq 0) { 'All changes completed successfully.' } else { 'Finished with failures -- review the log above.' }
        $sub.Text = "$($state.OkCount) succeeded, $($state.FailCount) failed"
        $footer.Text = "Full log: $logFile"
        & $setDot ($(if ($state.DoneCode -eq 0 -and $state.FailCount -eq 0) { 'ok' } else { 'fail' }))
        $el = (Get-Date) - $state.RunStart
        $statusText.Text = ('Finished in {0}:{1:00}' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds)
        $state.CdRemaining = 600
        $cdText.Text = ('Returning to the menu in {0}:{1:00}' -f [int][math]::Floor($state.CdRemaining / 60), ($state.CdRemaining % 60))
        $completePanel.Visibility = 'Visible'
        $cdTimer.Start()
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if (-not $state.Finished) {
            $el  = (Get-Date) - $state.RunStart
            $ago = ((Get-Date) - $state.LastOutputAt).TotalSeconds
            $agoTxt = if ($ago -lt 3) { 'just now' }
                      elseif ($ago -lt 60) { ('{0}s ago' -f [int]$ago) }
                      else { ('{0}m {1:00}s ago' -f [int][math]::Floor($ago / 60), ([int]$ago % 60)) }
            $statusText.Text = ('{0}:{1:00} elapsed   |   last output {2}' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds, $agoTxt)
        }
        & $pumpLog

        if ($state.Cancelled) {
            # Cancel path: waiting (non-blocking) for the cleanup sweep.
            $sweep = $state.SweepProc
            $sweepDone = (-not $sweep) -or $sweep.HasExited -or ((Get-Date) -gt $state.SweepDeadline)
            if ($sweepDone) {
                if ($sweep -and -not $sweep.HasExited) {
                    [void](Invoke-HiddenExe -FilePath 'taskkill.exe' -Arguments "/PID $($sweep.Id) /T /F")
                    & $uiLog "Cleanup sweep exceeded its 5-minute budget and was stopped." 'WARN'
                }
                $timer.Stop()
                & $pumpLog
                $state.Outcome = 'repeat'
                $state.AllowClose = $true
                $win.Close()
            }
            return
        }

        if ($state.Done) {
            $timer.Stop()
            & $finishUp
            return
        }
        if ($worker.HasExited) {
            # Grace window before declaring the worker dead: its final
            # ::DONE:: write and its process exit race our 200ms ticks
            # (CONFIRMED: a fully successful run got flagged 'ended
            # unexpectedly' because the exit was observed one tick before
            # the DONE line was read). Keep pumping briefly; the Done
            # branch above wins the moment the line arrives.
            if (-not $state.ExitSeenAt) { $state.ExitSeenAt = Get-Date; return }
            if (((Get-Date) - $state.ExitSeenAt).TotalSeconds -lt 3) { return }
            # Worker genuinely died without finishing -- surface it honestly.
            $timer.Stop()
            & $uiLog "The worker process ended unexpectedly (exit $($worker.ExitCode)) without finishing the run." 'ERROR'
            & $pumpLog
            $state.Done = $true; $state.DoneCode = 1
            & $finishUp
        }
    }.GetNewClosure())

    $win.Add_Closing({
        param($s, $e)
        if ($state.AllowClose) { return }
        $e.Cancel = $true
        if ($state.Cancelled) { return }   # sweep in progress; closes itself when done
        if ($state.Done -or $state.Finished) {
            # Run already over, completion bar showing: X means No.
            $cdTimer.Stop()
            $state.Outcome = 'exit'
            $e.Cancel = $false
            return
        }

        # Mid-run close (X / Alt+F4): confirm, then cancel.
        $inflight = if ($state.CurrentApp) { "'$($state.CurrentApp)'" } else { 'the current step' }
        $sure = Show-AeroDialog -Title 'Cancel the install?' -Owner $win -Message "Are you sure you want to cancel the install?`n`n$inflight will be stopped and cleaned up. Finished steps stay as they are."
        if (-not $sure) { return }

        $state.Cancelled = $true
        $header.Text = 'Cancelling...'
        $sub.Text = 'Stopping the current step and cleaning up'
        $footer.Text = "Full log: $logFile"
        & $uiLog "CANCELLED by the user during $inflight -- stopping the worker and its child processes." 'WARN'
        [void](Invoke-HiddenExe -FilePath 'taskkill.exe' -Arguments "/PID $($worker.Id) /T /F")

        if ($state.CurrentApp) {
            & $uiLog "Starting best-effort cleanup sweep for '$($state.CurrentApp)' (an interrupted MSI already rolled itself back; this catches the rest)." 'INFO'
            # A cancelled Update or Repair can't be rolled back -- the
            # sweep re-runs the installer instead (repair by reinstall).
            $sweepAct = if ($state.CurrentAction -in @('Update', 'Repair')) { 'Install' } else { 'Uninstall' }
            $sweepArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -CleanupApp `"$($state.CurrentApp)`" -CleanupAction $sweepAct -LogFile `"$logFile`" -ManifestPath `"$ManifestPath`""
            $spsi = New-Object System.Diagnostics.ProcessStartInfo
            $spsi.FileName = $psExe
            $spsi.Arguments = $sweepArgs
            $spsi.UseShellExecute = $false
            $spsi.CreateNoWindow = $true   # no hosted console (see worker launch)
            $state.SweepProc = [System.Diagnostics.Process]::Start($spsi)
            $null = $state.SweepProc.Handle
            $state.SweepDeadline = (Get-Date).AddMinutes(5)
        } else {
            $state.SweepDeadline = Get-Date   # nothing in flight: close on next tick
        }
        # Window stays open, timer keeps streaming the sweep's log lines;
        # the tick handler closes us when the sweep finishes.
    }.GetNewClosure())

    # Dim + freeze the Selection window's CONTENT (title bar stays live,
    # so it can still be moved/resized -- the reason this is modeless).
    if ($OwnerWindow) {
        $win.Owner = $OwnerWindow
        $OwnerWindow.Opacity = 0.55
        if ($OwnerWindow.Content) { $OwnerWindow.Content.IsEnabled = $false }
    }

    $timer.Start()
    Wait-WindowClosed -Window $win
    $timer.Stop()

    if ($OwnerWindow) {
        $OwnerWindow.Opacity = 1.0
        if ($OwnerWindow.Content) { $OwnerWindow.Content.IsEnabled = $true }
        try { [void]$OwnerWindow.Activate() } catch {}
    }
    if (-not $worker.HasExited) { [void](Invoke-HiddenExe -FilePath 'taskkill.exe' -Arguments "/PID $($worker.Id) /T /F") }
    return $state.Outcome
}

# ----------------------------- Selection -----------------------------
function Show-SelectionWindow {
    # The app's main loop lives INSIDE this window: Proceed opens the
    # modeless Progress window over it; on 'repeat' the checkboxes are
    # re-scanned in place and the same window carries on. Returns when
    # the app should exit.

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="RWW Apps Deploy" Width="760" Height="640" MinWidth="560" MinHeight="420"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI">
$script:AeroResources
    <Border Background="{StaticResource AeroSky}">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="{StaticResource AeroBanner}" Padding="20,14">
                <Grid>
                    <StackPanel Margin="0,0,350,0">
                        <TextBlock Text="RWW Apps Deploy" Foreground="White" FontSize="21" FontWeight="SemiBold"/>
                        <TextBlock Foreground="#E6F4FF" FontSize="12.5" Margin="0,3,0,0" TextWrapping="Wrap"
                                   Text="Checked = installed (or will be). Unchecked = not installed (or will be removed). Boxes start matching this machine's current state."/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
                        <TextBlock Text="Profile:" Foreground="White" FontSize="12" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <ComboBox x:Name="ProfileCombo" MinWidth="150" FontSize="12" VerticalAlignment="Center" Margin="0,0,10,0"
                                  ToolTip="Pre-selects the apps that make up a machine type. It only CHECKS boxes -- nothing is unchecked, and you can still adjust before Proceed."/>
                        <Button x:Name="BtnRescan" Style="{StaticResource AeroButton}" Content="Rescan" MinWidth="84"
                                ToolTip="Re-runs every app's detection right now and resets the checkboxes to this machine's current state (clears any pending selections and the profile)."/>
                    </StackPanel>
                    <Border Background="{StaticResource AeroGloss}" IsHitTestVisible="False"/>
                </Grid>
            </Border>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="14,12,14,6">
                <StackPanel x:Name="CategoryPanel"/>
            </ScrollViewer>
            <Border Grid.Row="2" BorderThickness="0,1,0,0" BorderBrush="#FF9CC9E8" Padding="14,10" Background="#80FFFFFF">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button Grid.Column="1" x:Name="BtnUpdate" Style="{StaticResource AeroButton}" Content="Update installed apps"
                            ToolTip="Checks every installed, winget-managed app in this menu for a newer version and applies any found. Apps that manage their own updates (e.g. Chrome) are skipped."/>
                    <TextBlock Grid.Column="2" x:Name="IdleText" FontSize="12" Foreground="#FF1C6FAE" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,14,0"/>
                    <Button Grid.Column="3" x:Name="BtnQuit" Style="{StaticResource AeroButton}" Content="Cancel" MinWidth="100" Margin="0,0,10,0"/>
                    <Button Grid.Column="4" x:Name="BtnProceed" Style="{StaticResource AeroPrimaryButton}" Content="Proceed" MinWidth="130"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@
    $win = New-WindowFromXaml $xaml
    $win.Title += $script:TitleSuffix
    $panel  = $win.FindName('CategoryPanel')
    # The old global 'Interactive installers' toggle is gone: per-row
    # wrench buttons carry interactivity now, one app at a time.

    # 30-minute idle timer for the whole app: if nobody clicks Proceed
    # for this long, the menu was forgotten -- close completely. The
    # countdown is VISIBLE in the bottom bar (same style as the Progress
    # window's), ticking every second. Touching any checkbox restarts it,
    # so it cannot fire under an actively-working tech. Stopped during a
    # run; restarted on every return to the menu.
    $idleText  = $win.FindName('IdleText')
    $idleState = @{ Remaining = 1800 }
    $idleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $idleTimer.Interval = [TimeSpan]::FromSeconds(1)
    $idleTimer.Add_Tick({
        $idleState.Remaining--
        if ($idleState.Remaining -le 0) {
            $idleTimer.Stop()
            $win.Close()
        } else {
            $idleText.Text = ('Auto-closing in {0}:{1:00}' -f [int][math]::Floor($idleState.Remaining / 60), ($idleState.Remaining % 60))
        }
    }.GetNewClosure())
    # Plain scriptblock (runs in this function's scope): reset + restart
    # the countdown and refresh the bar text immediately.
    $restartIdle = {
        $idleState.Remaining = 1800
        $idleText.Text = ('Auto-closing in {0}:{1:00}' -f [int][math]::Floor($idleState.Remaining / 60), ($idleState.Remaining % 60))
        $idleTimer.Stop()
        $idleTimer.Start()
    }

    $checkboxes    = @{}
    $variantSelections = @{}
    $variantCombos = @{}
    # Early local copies of manifest data for scriptblocks invoked from
    # closures ($script: resolves to $null there -- closure rule).
    $appsAll = @($script:AppManifest)
    $profilesAll = @($script:Profiles)

    $profileCombo = $win.FindName('ProfileCombo')
    [void]$profileCombo.Items.Add('(no profile)')
    foreach ($p in $profilesAll) { [void]$profileCombo.Items.Add([string]$p.Name) }
    $profileCombo.SelectedIndex = 0
    $baseline      = @{}
    $stateLabels   = @{}
    $pendingLabels = @{}
    $wrenchQueue   = @{}   # app name -> $true while the row's wrench is lit (run interactively / repair)
    $wrenchButtons = @{}
    # The wrench-and-gear icon, as WPF Path geometry (same grammar as SVG
    # path data; F1 = nonzero fill so the ring and jaw cutout subpaths,
    # wound the other way, read as holes while the wrench may overlap).
    $wrenchIconData = 'F1 M 21.40,12.00 L 21.16,14.12 L 22.88,15.07 L 21.86,17.52 L 19.98,16.97 L 18.65,18.65 L 16.97,19.98 L 17.52,21.86 L 15.07,22.88 L 14.12,21.16 L 12.00,21.40 L 9.88,21.16 L 8.93,22.88 L 6.48,21.86 L 7.03,19.98 L 5.35,18.65 L 4.02,16.97 L 2.14,17.52 L 1.12,15.07 L 2.84,14.12 L 2.60,12.00 L 2.84,9.88 L 1.12,8.93 L 2.14,6.48 L 4.02,7.03 L 5.35,5.35 L 7.03,4.02 L 6.48,2.14 L 8.93,1.12 L 9.88,2.84 L 12.00,2.60 L 14.12,2.84 L 15.07,1.12 L 17.52,2.14 L 16.97,4.02 L 18.65,5.35 L 19.98,7.03 L 21.86,6.48 L 22.88,8.93 L 21.16,9.88 Z M 18.90,12.00 L 18.82,10.92 L 18.56,9.87 L 18.15,8.87 L 17.58,7.94 L 16.88,7.12 L 16.06,6.42 L 15.13,5.85 L 14.13,5.44 L 13.08,5.18 L 12.00,5.10 L 10.92,5.18 L 9.87,5.44 L 8.87,5.85 L 7.94,6.42 L 7.12,7.12 L 6.42,7.94 L 5.85,8.87 L 5.44,9.87 L 5.18,10.92 L 5.10,12.00 L 5.18,13.08 L 5.44,14.13 L 5.85,15.13 L 6.42,16.06 L 7.12,16.88 L 7.94,17.58 L 8.87,18.15 L 9.87,18.56 L 10.92,18.82 L 12.00,18.90 L 13.08,18.82 L 14.13,18.56 L 15.13,18.15 L 16.06,17.58 L 16.88,16.88 L 17.58,16.06 L 18.15,15.13 L 18.56,14.13 L 18.82,13.08 Z M 14.38,17.07 L 10.78,13.47 L 10.78,13.47 L 10.33,13.57 L 9.88,13.62 L 9.42,13.61 L 8.97,13.55 L 8.53,13.44 L 8.10,13.28 L 7.70,13.07 L 7.32,12.82 L 6.97,12.52 L 6.67,12.18 L 6.40,11.81 L 6.18,11.41 L 6.00,10.99 L 5.88,10.55 L 5.80,10.10 L 5.78,9.65 L 5.82,9.19 L 5.90,8.74 L 6.04,8.31 L 6.23,7.89 L 8.40,10.06 L 8.40,10.06 L 8.50,10.15 L 8.62,10.23 L 8.75,10.30 L 8.88,10.35 L 9.02,10.38 L 9.16,10.40 L 9.30,10.40 L 9.44,10.38 L 9.58,10.35 L 9.71,10.30 L 9.84,10.23 L 9.95,10.15 L 10.06,10.06 L 10.15,9.95 L 10.23,9.84 L 10.30,9.71 L 10.35,9.58 L 10.38,9.44 L 10.40,9.30 L 10.40,9.16 L 10.38,9.02 L 10.35,8.88 L 10.30,8.75 L 10.23,8.62 L 10.15,8.50 L 10.06,8.40 L 7.89,6.23 L 7.89,6.23 L 8.31,6.04 L 8.74,5.90 L 9.19,5.82 L 9.65,5.78 L 10.10,5.80 L 10.55,5.88 L 10.99,6.00 L 11.41,6.18 L 11.81,6.40 L 12.18,6.67 L 12.52,6.97 L 12.82,7.32 L 13.07,7.70 L 13.28,8.10 L 13.44,8.53 L 13.55,8.97 L 13.61,9.42 L 13.62,9.88 L 13.57,10.33 L 13.47,10.78 L 17.07,14.38 L 17.07,14.38 L 17.22,14.55 L 17.35,14.74 L 17.46,14.94 L 17.54,15.16 L 17.60,15.38 L 17.62,15.61 L 17.62,15.84 L 17.60,16.07 L 17.54,16.29 L 17.46,16.50 L 17.35,16.71 L 17.22,16.90 L 17.07,17.07 L 16.90,17.22 L 16.71,17.35 L 16.50,17.46 L 16.29,17.54 L 16.07,17.60 L 15.84,17.62 L 15.61,17.62 L 15.38,17.60 L 15.16,17.54 L 14.94,17.46 L 14.74,17.35 L 14.55,17.22 L 14.38,17.07 Z'

    # Build the category cards once; detection fills them (and refills on
    # every return from a run).
    # Category cards follow the manifest's declared display order;
    # anything not listed there falls to the end alphabetically. Apps
    # inside each card sort by name -- the manifest's own entry order
    # (which follows porting history) never shows to techs.
    $present = @($script:AppManifest | ForEach-Object { $_.Category } | Select-Object -Unique)
    $categories = @()
    foreach ($cat in @($script:CategoryOrder)) {
        if ($cat -in $present) { $categories += $cat }
    }
    foreach ($cat in ($present | Where-Object { $_ -notin $categories } | Sort-Object)) {
        $categories += $cat
    }
    foreach ($cat in $categories) {
        $headerTb = New-Object System.Windows.Controls.TextBlock
        $headerTb.Text = $cat
        $headerTb.FontSize = 14; $headerTb.FontWeight = 'SemiBold'
        $headerTb.Foreground = '#FF1C6FAE'
        $headerTb.Margin = '2,10,0,4'
        [void]$panel.Children.Add($headerTb)

        $card = New-Object System.Windows.Controls.Border
        $card.Background = '#B0FFFFFF'; $card.CornerRadius = '8'
        $card.BorderBrush = '#FF9CC9E8'; $card.BorderThickness = '1'
        $card.Padding = '12,8'
        $inner = New-Object System.Windows.Controls.StackPanel
        $card.Child = $inner
        [void]$panel.Children.Add($card)

        # Scriptblock sort key on purpose: manifest entries are
        # hashtables, whose keys are NOT properties -- '-Property Name'
        # saw only nulls, and PS 5.1's UNSTABLE sort then scrambled the
        # order arbitrarily (confirmed on screen).
        foreach ($app in ($script:AppManifest | Where-Object { $_.Category -eq $cat } | Sort-Object { $_.Name })) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Margin = '2,5'
            $cb.FontSize = 13
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'
            $nameTb = New-Object System.Windows.Controls.TextBlock
            $nameTb.Text = $app.Name
            $stateTb = New-Object System.Windows.Controls.TextBlock
            $stateTb.FontSize = 11.5
            $stateTb.VerticalAlignment = 'Center'
            # Pending-change label: fills in the moment a checkbox
            # disagrees with the machine's current state, so a tech can
            # see at a glance exactly what Proceed is going to do.
            $pendingTb = New-Object System.Windows.Controls.TextBlock
            $pendingTb.FontSize = 11.5
            $pendingTb.FontWeight = 'SemiBold'
            $pendingTb.VerticalAlignment = 'Center'
            [void]$sp.Children.Add($nameTb)
            if (Test-AppNeedsShare $app) {
                $shareTb = New-Object System.Windows.Controls.TextBlock
                $shareTb.Text = '  (uses network share)'
                $shareTb.FontSize = 11
                $shareTb.Foreground = '#FF7A8FA3'
                $shareTb.VerticalAlignment = 'Center'
                [void]$sp.Children.Add($shareTb)
            }
            [void]$sp.Children.Add($stateTb); [void]$sp.Children.Add($pendingTb)
            $cb.Content = $sp
            if ($app.Notes) { $cb.ToolTip = $app.Notes }
            # Every row is a grid: the checkbox stretches, a small Repair
            # toggle sits at the right edge, and apps with Variants get
            # their dropdown on the far right.
            $rowGrid = New-Object System.Windows.Controls.Grid
            foreach ($w in @('*', 'Auto', 'Auto')) {
                $cd = New-Object System.Windows.Controls.ColumnDefinition
                $cd.Width = $w
                [void]$rowGrid.ColumnDefinitions.Add($cd)
            }
            $cb.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($cb, 0)
            [void]$rowGrid.Children.Add($cb)

            # The wrench (Aaron's design): ONE per-row control that
            # replaces the old global 'Interactive installers' toggle.
            # Lit, it means 'show the vendor's own installer window for
            # this app': an interactive install or uninstall when the
            # row has a pending change, and a REPAIR (the vendor's
            # Repair/Modify wizard) when the app is installed and
            # staying. It shows on any row that has an installer to
            # show -- installed now, or checked to be installed.
            $repBtn = New-Object System.Windows.Controls.Primitives.ToggleButton
            $repIcon = New-Object System.Windows.Shapes.Path
            $repIcon.Data = [System.Windows.Media.Geometry]::Parse($wrenchIconData)
            $repIcon.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString('#FF2B3A46'))
            $repIcon.Stretch = 'Uniform'
            $repIcon.Width = 16
            $repIcon.Height = 16
            $repBtn.Content = $repIcon
            $repBtn.Style = $win.FindResource('AeroToggle')   # lit = green, same language as the old toggle
            $repBtn.Padding = '6,3'
            $repBtn.Margin = '10,2,2,2'
            $repBtn.VerticalAlignment = 'Center'
            $repBtn.Visibility = 'Collapsed'
            $repBtn.ToolTip = "Use the vendor's own installer window for this app instead of running silently. On an app that is installed and staying installed, this queues a REPAIR -- the vendor's setup opens so you can choose Repair/Modify."
            # The wrench always sits at the FAR RIGHT edge of the row
            # (Aaron's layout call); any variant dropdown goes inboard
            # of it, in the middle Auto column.
            [System.Windows.Controls.Grid]::SetColumn($repBtn, 2)
            [void]$rowGrid.Children.Add($repBtn)

            if ($app.ContainsKey('Variants')) {
                # Variant dropdown (e.g. which Automate SITE installer to
                # use). The selection rides the job file to the worker as
                # the step's Variant, for installs and repairs alike.
                $combo = New-Object System.Windows.Controls.ComboBox
                $combo.MinWidth = 150
                $combo.Margin = '10,2,2,2'
                $combo.FontSize = 12
                $combo.ToolTip = ('{0} used when installing {1}.' -f $app.Variants.Label, $app.Name)
                foreach ($choice in (Get-AppVariantChoices $app)) { [void]$combo.Items.Add($choice) }
                $combo.SelectedIndex = 0
                $variantSelections[$app.Name] = [string]$combo.SelectedItem
                $comboName = $app.Name
                $combo.Add_SelectionChanged({
                    $variantSelections[$comboName] = [string]$combo.SelectedItem
                    & $restartIdle
                }.GetNewClosure())
                [System.Windows.Controls.Grid]::SetColumn($combo, 1)
                [void]$rowGrid.Children.Add($combo)
                $variantCombos[$app.Name] = $combo
            }
            [void]$inner.Children.Add($rowGrid)
            $checkboxes[$app.Name]    = $cb
            $stateLabels[$app.Name]   = $stateTb
            $pendingLabels[$app.Name] = $pendingTb
            $wrenchButtons[$app.Name] = $repBtn

            # Locals for the closure (GetNewClosure captures per-iteration
            # copies -- exactly what a loop needs; and no $script: refs,
            # per this file's closure-scoping rule).
            $appName = $app.Name
            $pendingHandler = {
                & $restartIdle   # activity resets the idle countdown
                $have = [bool]$baseline[$appName]
                $want = [bool]$cb.IsChecked
                # The wrench shows wherever there is an installer to
                # show: the app is installed now, or checked to become
                # installed. A row that is absent and staying absent has
                # nothing to run, so the wrench hides and clears.
                if ($have -or $want) {
                    $repBtn.Visibility = 'Visible'
                } else {
                    $repBtn.Visibility = 'Collapsed'
                    $wrenchQueue[$appName] = $false
                    if ($repBtn.IsChecked) { $repBtn.IsChecked = $false }   # re-fires this handler once, harmlessly
                }
                $wrench = [bool]$wrenchQueue[$appName]
                if ($want -and -not $have) {
                    $pendingTb.Text = if ($wrench) { '  (will be INSTALLED - vendor window shown)' } else { '  (will be INSTALLED)' }
                    $pendingTb.Foreground = '#FF1565C0'
                } elseif (-not $want -and $have) {
                    $pendingTb.Text = if ($wrench) { '  (will be UNINSTALLED - vendor window shown)' } else { '  (will be UNINSTALLED)' }
                    $pendingTb.Foreground = '#FFC62828'
                } elseif ($want -and $have -and $wrench) {
                    $pendingTb.Text = '  (will be REPAIRED - vendor window shown)'
                    $pendingTb.Foreground = '#FFB26A00'
                } else {
                    $pendingTb.Text = ''
                }
            }.GetNewClosure()
            $cb.Add_Checked($pendingHandler)
            $cb.Add_Unchecked($pendingHandler)
            $repBtn.Add_Checked({
                $wrenchQueue[$appName] = $true
                & $pendingHandler
            }.GetNewClosure())
            $repBtn.Add_Unchecked({
                $wrenchQueue[$appName] = $false
                & $pendingHandler
            }.GetNewClosure())
        }
    }

    $refreshVariants = {
        # Re-discover variant choices and merge NEW names into each
        # dropdown without disturbing the current selection. Called when
        # the share may have just become reachable: right after the
        # credential gate connects, on Rescan, and on returns to the menu.
        foreach ($name in @($variantCombos.Keys)) {
            $combo = $variantCombos[$name]
            $app = $appsAll | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $app) { continue }
            foreach ($choice in (Get-AppVariantChoices $app)) {
                if (-not $combo.Items.Contains($choice)) { [void]$combo.Items.Add($choice) }
            }
        }
    }

    $rescan = {
        # A rescan reflects the machine's real state, so any profile
        # pre-selection is stale -- reset the selector (its handler then
        # re-baselines the boxes, which the scan below re-fills anyway).
        if ($profileCombo.SelectedIndex -ne 0) { $profileCombo.SelectedIndex = 0 }
        foreach ($app in $script:AppManifest) {
            $installed = $false
            try { $installed = [bool](& $app.Detect) } catch {}
            $baseline[$app.Name] = $installed
            $checkboxes[$app.Name].IsChecked = $installed
            $lbl = $stateLabels[$app.Name]
            $lbl.Text = if ($installed) { '  (installed)' } else { '  (not installed)' }
            $lbl.Foreground = if ($installed) { '#FF2E7D32' } else { '#FF8A8A8A' }
            # A rescan clears every lit wrench (the world just changed
            # under them). The wrench shows wherever something could run
            # interactively; after a rescan box state = installed state,
            # so that is simply the installed rows.
            $wrenchQueue[$app.Name] = $false
            $rb = $wrenchButtons[$app.Name]
            if ($rb.IsChecked) { $rb.IsChecked = $false }
            $rb.Visibility = if ($installed) { 'Visible' } else { 'Collapsed' }
            # Clear the pending label explicitly: setting IsChecked to a
            # value it already has fires no event, so a stale pending tag
            # from before the run could otherwise survive a rescan.
            $pendingLabels[$app.Name].Text = ''
        }
    }
    & $rescan
    & $restartIdle

    # Rescan with visible feedback, timer-phased: the click handler only
    # dims the list and swaps the button text, then RETURNS so WPF paints
    # that state naturally; the timer's first tick does the actual scan
    # and its second restores the visuals. (The first version forced a
    # render pump inside the handler, which crashed the whole app --
    # CONFIRMED. No dispatcher pumping in handlers, ever.)
    $profileCombo.Add_SelectionChanged({
        & $restartIdle
        # Reset to the machine's REAL state first, then layer the
        # profile's pre-selections on top; '(no profile)' is just the
        # reset. Nothing is ever unchecked below the machine state.
        foreach ($name in @($checkboxes.Keys)) {
            $checkboxes[$name].IsChecked = [bool]$baseline[$name]
        }
        $sel = [string]$profileCombo.SelectedItem
        if ($sel -and $sel -ne '(no profile)') {
            $prof = $profilesAll | Where-Object { $_.Name -eq $sel } | Select-Object -First 1
            if ($prof) {
                $unknown = @()
                foreach ($n in @($prof.Apps)) {
                    if ($checkboxes.ContainsKey($n)) {
                        $checkboxes[$n].IsChecked = $true
                    } else {
                        $unknown += $n
                    }
                }
                if ($unknown.Count -gt 0) {
                    [void](Show-AeroDialog -Title 'Profile name mismatch' -Buttons OK -Owner $win -Message ("The '$sel' profile lists app names that are not in the manifest (fix the profile or the app Name): " + ($unknown -join ', ')))
                }
            }
        }
    }.GetNewClosure())

    $btnRescan = $win.FindName('BtnRescan')
    $rsTimer = New-Object System.Windows.Threading.DispatcherTimer
    $rsTimer.Interval = [TimeSpan]::FromMilliseconds(80)
    $rsTimer.Add_Tick({
        if ($rsTimer.Tag -eq 0) {
            $rsTimer.Tag = 1
            try {
                & $rescan
                & $refreshVariants
                & $restartIdle
            } catch {
                [void][System.Windows.MessageBox]::Show("Rescan failed: $($_.Exception.Message)", 'RWW Apps Deploy', 'OK', 'Warning')
            }
            $rsTimer.Interval = [TimeSpan]::FromMilliseconds(400)
            return
        }
        $rsTimer.Stop()
        $rsTimer.Interval = [TimeSpan]::FromMilliseconds(80)
        $panel.Opacity = 1.0
        $btnRescan.Content = 'Rescan'
        $btnRescan.IsEnabled = $true
    }.GetNewClosure())
    $btnRescan.Add_Click({
        if (-not $btnRescan.IsEnabled) { return }
        $btnRescan.IsEnabled = $false
        $btnRescan.Content = 'Rescanning...'
        $panel.Opacity = 0.45
        $rsTimer.Tag = 0
        $rsTimer.Start()
    }.GetNewClosure())

    $win.FindName('BtnQuit').Add_Click({ $win.Close() }.GetNewClosure())

    # Copied into a LOCAL on purpose: inside a GetNewClosure'd handler,
    # $script: refers to the closure's own dynamic-module scope, NOT this
    # script's -- $script:AppManifest resolves to $null there, so the
    # diff loop below would iterate zero times and every Proceed click
    # would report "Nothing to do" (confirmed on a real machine).
    # GetNewClosure captures LOCALS reliably, so a local copy is the fix.
    $apps = @($script:AppManifest)

    $win.FindName('BtnProceed').Add_Click({
        $installs = @(); $uninstalls = @(); $repairs = @(); $unchanged = 0
        foreach ($app in $apps) {
            $want = [bool]$checkboxes[$app.Name].IsChecked
            $have = [bool]$baseline[$app.Name]
            if ($want -and -not $have)      { $installs   += $app.Name }
            elseif (-not $want -and $have)  { $uninstalls += $app.Name }
            elseif ($want -and $have -and $wrenchQueue[$app.Name]) { $repairs += $app.Name }
            else                            { $unchanged++ }
        }
        if ($installs.Count -eq 0 -and $uninstalls.Count -eq 0 -and $repairs.Count -eq 0) {
            [void](Show-AeroDialog -Title 'Nothing to do' -Buttons OK -Owner $win -Message "Every checkbox already matches this machine's current state and nothing is queued. Change a checkbox, or click an installed row's wrench to repair it with the vendor's own installer.")
            return
        }

        # SYSTEM/Backstage guard: uninstalling under other active users.
        if ($uninstalls.Count -gt 0 -and (Test-IsSystem)) {
            $others = Get-ActiveUserSessions
            if ($others.Count -gt 0) {
                $okUsers = Show-AeroDialog -Title 'Users are logged on' -Owner $win -Message ("You are running as SYSTEM (Backstage) and these users are actively logged on:`n`n  " + ($others -join ', ') + "`n`nThe plan removes: " + ($uninstalls -join ', ') + ". Removing apps someone may be using right now can close their work. Continue anyway?")
                if (-not $okUsers) { return }
            }
        }

        $planNames = @($installs + $uninstalls + $repairs)
        $shareNames = @()
        $odtCached = Test-Path -LiteralPath (Join-Path $env:ProgramData 'RWW\AppsDeploy\Stage\odt-setup.exe')
        foreach ($app in $apps) {
            if ($app.Name -notin $planNames) { continue }
            # A repair runs the app's INSTALL method again, so it shares
            # the install spec's share needs (an Office repair pulls the
            # ODT from the share like an install does).
            $action = if ($app.Name -in $uninstalls) { 'Uninstall' } else { 'Install' }
            $spec = $app[$action]
            if (-not ($spec -is [hashtable] -and ($spec.Engine -eq 'Odt' -or $spec.NeedsShare))) { continue }
            # ODT uninstalls run from the locally cached setup.exe when
            # one exists -- no share, no credential prompt.
            if ($action -eq 'Uninstall' -and $spec.Engine -eq 'Odt' -and $odtCached) { continue }
            # Generic form of the same idea: a spec can name the local
            # file that makes the share unnecessary (e.g. the Automate
            # agent's cached generic uninstaller).
            if ($spec.SkipShareIfPresent -and (Test-Path -LiteralPath $spec.SkipShareIfPresent -ErrorAction SilentlyContinue)) { continue }
            $shareNames += $app.Name
        }

        # Default-variant guard (Aaron's ask): an install still carrying a
        # flagged variant's DEFAULT choice (the Automate agent on 'New
        # PCs') gets an explicit confirm; No backs out untouched so the
        # tech can pick the right one.
        foreach ($app in $apps) {
            if (($app.Name -in $installs -or $app.Name -in $repairs) -and $app.ContainsKey('Variants') -and $app.Variants.WarnOnDefault) {
                $sel = [string]$variantSelections[$app.Name]
                if ($sel -eq [string]$app.Variants.Default) {
                    $actWord = if ($app.Name -in $repairs) { 'repair (reinstall)' } else { 'install' }
                    $q = "$($app.Name) is about to $actWord with the DEFAULT $($app.Variants.Label): '$sel'.`n`nIs that the right $($app.Variants.Label) for this machine? (No returns to the menu so you can pick a different one.)"
                    if (-not (Show-AeroDialog -Title ('Default {0} selected' -f $app.Variants.Label) -Owner $win -Message $q)) { return }
                }
            }
        }

        $installsDisplay = @(foreach ($n in $installs) {
            $d = if ($variantSelections.ContainsKey($n)) { '{0} ({1})' -f $n, $variantSelections[$n] } else { $n }
            if ($wrenchQueue[$n]) { $d + ' [vendor window]' } else { $d }
        })
        $uninstallsDisplay = @(foreach ($n in $uninstalls) {
            if ($wrenchQueue[$n]) { $n + ' [vendor window]' } else { $n }
        })
        $repairsDisplay = @(foreach ($n in $repairs) {
            if ($variantSelections.ContainsKey($n)) { '{0} ({1})' -f $n, $variantSelections[$n] } else { $n }
        })
        $msg = "The following changes will be made:`n"
        if ($installs.Count   -gt 0) { $msg += "`nINSTALL:   " + ($installsDisplay -join ', ') }
        if ($uninstalls.Count -gt 0) { $msg += "`nUNINSTALL: " + ($uninstallsDisplay -join ', ') }
        if ($repairs.Count    -gt 0) { $msg += "`nREPAIR:    " + ($repairsDisplay -join ', ') + ' (vendor window)' }
        $msg += "`n`nUnchanged: $unchanged app(s)."
        if ($shareNames.Count -gt 0) { $msg += "`n`nUses the installer share (may ask for credentials): " + ($shareNames -join ', ') }
        $msg += "`n`nProceed?"
        if (-not (Show-AeroDialog -Title 'Confirm changes' -Owner $win -Message $msg)) { return }

        # Share gate: just-in-time, only for plans that touch the share,
        # and silent when access already exists (domain-joined tech).
        if ($shareNames.Count -gt 0 -and -not (Ensure-ShareAccess -Owner $win)) { return }
        # The share is reachable now -- fill in any dropdown choices the
        # menu could not discover before credentials existed.
        if ($shareNames.Count -gt 0) { & $refreshVariants }

        # Interactivity rides per step now (the row's wrench), not as a
        # global job flag: a lit wrench on a pending change makes THAT
        # install/uninstall show its vendor window; a repair exists only
        # via the wrench, so repairs are always interactive here.
        $steps = @()
        foreach ($n in $uninstalls) {
            $step = @{ Name = $n; Action = 'Uninstall' }
            if ($wrenchQueue[$n]) { $step.Interactive = $true }
            $steps += $step
        }
        foreach ($n in $installs) {
            $step = @{ Name = $n; Action = 'Install' }
            if ($variantSelections.ContainsKey($n)) { $step.Variant = $variantSelections[$n] }
            if ($wrenchQueue[$n]) { $step.Interactive = $true }
            $steps += $step
        }
        foreach ($n in $repairs) {
            $step = @{ Name = $n; Action = 'Repair'; Interactive = $true }
            if ($variantSelections.ContainsKey($n)) { $step.Variant = $variantSelections[$n] }
            $steps += $step
        }

        $idleTimer.Stop()
        $idleText.Text = ''
        $outcome = Show-ProgressWindow -Plan $steps -OwnerWindow $win
        if ($outcome -eq 'repeat') {
            & $rescan   # the world changed; reflect it before the next pass
            & $refreshVariants
            & $restartIdle
        } else {
            $win.Close()
        }
    }.GetNewClosure())

    $win.FindName('BtnUpdate').Add_Click({
        # Update plan: every app that is currently installed AND is
        # update-managed (an explicit Update spec, or a plain Winget
        # install, which updates via 'winget upgrade' with the same Id).
        $targets = @(); $skipped = @()
        foreach ($app in $apps) {
            if (-not [bool]$baseline[$app.Name]) { continue }
            $updatable = $app.ContainsKey('Update') -or ($app.Install -and $app.Install.Engine -eq 'Winget')
            if ($updatable) { $targets += $app.Name } else { $skipped += $app.Name }
        }
        if ($targets.Count -eq 0) {
            [void](Show-AeroDialog -Title 'Nothing to update' -Buttons OK -Owner $win -Message 'No installed app in this menu is update-managed by this tool.')
            return
        }
        $msg = "Check these installed apps for updates and apply any found?`n`n" + ($targets -join ', ')
        if ($skipped.Count -gt 0) { $msg += "`n`nSkipped (they manage their own updates or are not winget-managed): " + ($skipped -join ', ') }
        if (-not (Show-AeroDialog -Title 'Update installed apps' -Owner $win -Message $msg)) { return }
        $steps = @()
        foreach ($n in $targets) { $steps += @{ Name = $n; Action = 'Update' } }
        $idleTimer.Stop()
        $idleText.Text = ''
        $outcome = Show-ProgressWindow -Plan $steps -OwnerWindow $win
        if ($outcome -eq 'repeat') {
            & $rescan
            & $refreshVariants
            & $restartIdle
        } else {
            $win.Close()
        }
    }.GetNewClosure())

    Wait-WindowClosed -Window $win
}

# =============================== Main ===============================
if (-not (Test-IsElevated)) {
    [void][System.Windows.MessageBox]::Show('Apps Deploy must run elevated. Launch it from AppsDeploy.bat (or an elevated prompt).', 'RWW Apps Deploy', 'OK', 'Warning')
    exit 3
}
if (-not (Test-Path $script:WorkerPath)) {
    [void][System.Windows.MessageBox]::Show("AppsDeploy-Worker.ps1 was not found next to this script:`n$script:WorkerPath", 'RWW Apps Deploy', 'OK', 'Error')
    exit 2
}

# DETACH from this process's own console window (it only exists because
# powershell -File needs a host; the WPF windows are the real interface).
# Detaching -- not minimizing -- matters on Windows 11, where Windows
# Terminal is the default console host: with a minimized console, this
# process LIVED INSIDE a Terminal window, so uninstalling Windows
# Terminal through this very tool killed the whole app mid-run, and
# reinstalling it surfaced a stray Terminal window (CONFIRMED on
# WSTEST001). After FreeConsole there is no console for any host to own.
# Done after the checks above so an elevation/missing-file error still
# shows a normal console.
# ------------------- Console mode (Backstage fallback) -------------------
# WPF cannot composite on hidden desktops: in ConnectWise Backstage the
# whole window renders BLACK (confirmed; software rendering and the
# no-display-device switch do not help -- WPF's presentation REQUIRES
# DWM composition, which such desktops lack). The two-process design
# makes the fallback cheap: same manifest, same worker, same job file
# and log -- only the face is a text menu.

function Get-CurrentDesktopName {
    try {
        Add-Type -Name DesktopUtil -Namespace RWW -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint dwThreadId);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformationW(IntPtr hObj, int nIndex, System.Text.StringBuilder pvInfo, uint nLength, out uint lpnLengthNeeded);
'@ -ErrorAction Stop
    } catch {}
    try {
        $sb = New-Object System.Text.StringBuilder 256
        $needed = [uint32]0
        $h = [RWW.DesktopUtil]::GetThreadDesktop([RWW.DesktopUtil]::GetCurrentThreadId())
        if ([RWW.DesktopUtil]::GetUserObjectInformationW($h, 2, $sb, 256, [ref]$needed)) { return $sb.ToString() }
    } catch {}
    return 'Default'
}

function Write-Con {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
}

function Ensure-ShareAccessConsole {
    # Console twin of Ensure-ShareAccess: same probe, Read-Host prompts.
    $srv = $null
    foreach ($h in $script:ShareServerHosts) {
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $iar = $t.BeginConnect($h, 445, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000) -and $t.Connected) { $t.Close(); $srv = $h; break }
            $t.Close()
        } catch {}
    }
    if (-not $srv) {
        Write-Con "The installer share server is not reachable at all (TCP 445) -- share-based steps cannot run right now." Red
        return $false
    }
    $unc = "\\$srv\systems$"
    if (Test-Path "$unc\Software" -ErrorAction SilentlyContinue) { return $true }
    while ($true) {
        Write-Con "This plan needs the installer share ($unc) and this session has no access to it." Yellow
        $user = Read-Host "  Username (RPSINC\username; blank cancels)"
        if ([string]::IsNullOrWhiteSpace($user)) { return $false }
        $sec = Read-Host "  Password" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $rc = Invoke-HiddenExe -FilePath 'net.exe' -Arguments ('use "{0}" "{1}" /user:{2} /persistent:no' -f $unc, $plain, $user)
        $plain = $null
        if ($rc -eq 0 -and (Test-Path "$unc\Software" -ErrorAction SilentlyContinue)) {
            $script:ShareMappedTo += $unc
            return $true
        }
        [void](Invoke-HiddenExe -FilePath 'net.exe' -Arguments ('use "{0}" /delete /y' -f $unc))
        Write-Con "  Could not connect with those credentials. Try again or leave the username blank to cancel." Red
    }
}

function Invoke-ConsoleRun {
    # Console twin of Show-ProgressWindow: same job file, same worker,
    # the log tailed into the console with the same color coding. No
    # cancel path here: closing the console abandons the MENU only; the
    # worker finishes its current work on its own.
    param([array]$Plan)
    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile  = Join-Path $script:LogDir "AppsDeploy_$runStamp.log"
    $jobFile  = Join-Path $script:LogDir "AppsDeploy_$runStamp.job.json"
    @{ Interactive = $false; Steps = $Plan } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobFile -Encoding UTF8
    $modeNote = if ($LocalTest) { ' -- LOCAL TEST MODE (running the files in ' + $script:AppRoot + ', no GitHub involved)' } else { '' }
    Set-Content -LiteralPath $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Log file: $logFile$modeNote (console mode)" -Encoding UTF8

    $workerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:WorkerPath)`" -JobFile `"$jobFile`" -LogFile `"$logFile`" -ManifestPath `"$ManifestPath`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PsExe
    $psi.Arguments = $workerArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $worker = [System.Diagnostics.Process]::Start($psi)
    $null = $worker.Handle

    $colors = @{
        INFO    = [ConsoleColor]::Gray
        WARN    = [ConsoleColor]::Yellow
        ERROR   = [ConsoleColor]::Red
        SUCCESS = [ConsoleColor]::Green
        CMD     = [ConsoleColor]::Cyan
    }
    $pos = 0; $tailBuf = ''; $done = $false; $doneCode = 1; $exitSeen = $null
    while ($true) {
        Start-Sleep -Milliseconds 300
        $buf = $null
        try {
            $fs = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -gt $pos) {
                    $fs.Position = $pos
                    $buf = New-Object byte[] ($fs.Length - $pos)
                    [void]$fs.Read($buf, 0, $buf.Length)
                    $pos = $fs.Length
                }
            } finally { $fs.Close() }
        } catch {}
        if ($buf) {
            $text = $tailBuf + [System.Text.Encoding]::UTF8.GetString($buf)
            $parts = $text -split "`r?`n", -1
            $tailBuf = $parts[-1]
            for ($k = 0; $k -lt $parts.Count - 1; $k++) {
                $line = $parts[$k]
                if (-not $line) { continue }
                if ($line -match '^::STEP::(\d+)/(\d+)::(.+?)::(Install|Uninstall|Update|Repair)$') {
                    Write-Con ("--- Step {0} of {1}: {2} {3} ---" -f $Matches[1], $Matches[2], $Matches[4], $Matches[3]) White
                    continue
                }
                if ($line -match '^::RESULT::') { continue }
                if ($line -match '^::DONE::(\d+)$') { $done = $true; $doneCode = [int]$Matches[1]; continue }
                $color = [ConsoleColor]::Gray
                if ($line -match '^\[[^\]]+\]\s+\[(\w+)\]') {
                    $lvl = $Matches[1]
                    if ($colors.ContainsKey($lvl)) { $color = $colors[$lvl] }
                }
                Write-Con $line $color
            }
        }
        if ($done) { break }
        if ($worker.HasExited) {
            # Same 3-second DONE-vs-exit grace the GUI uses.
            if (-not $exitSeen) { $exitSeen = Get-Date; continue }
            if (((Get-Date) - $exitSeen).TotalSeconds -lt 3) { continue }
            Write-Con "The worker process ended unexpectedly (exit $($worker.ExitCode)) without finishing the run." Red
            break
        }
    }
    if ($doneCode -eq 0) { Write-Con "Run complete. Full log: $logFile" Green }
    else { Write-Con "Run finished with FAILURES -- see above. Full log: $logFile" Red }
}

function Show-ConsoleMenu {
    Write-Con ""
    Write-Con ("=== RWW Apps Deploy{0} -- CONSOLE MODE ===" -f $script:TitleSuffix) Cyan
    Write-Con "This desktop cannot display the normal windows, so here is the same tool as a text menu." DarkGray

    $apps = @($script:AppManifest)
    $baseline = @{}; $selected = @{}; $variantSel = @{}; $repairSel = @{}
    foreach ($app in $apps) {
        if ($app.ContainsKey('Variants')) { $variantSel[$app.Name] = [string]$app.Variants.Default }
    }

    # Same display order as the GUI: declared category order, apps A-Z.
    $present = @($apps | ForEach-Object { $_.Category } | Select-Object -Unique)
    $catOrder = @()
    foreach ($cat in @($script:CategoryOrder)) { if ($cat -in $present) { $catOrder += $cat } }
    foreach ($cat in ($present | Where-Object { $_ -notin $catOrder } | Sort-Object)) { $catOrder += $cat }
    $ordered = @()
    foreach ($cat in $catOrder) {
        $ordered += @($apps | Where-Object { $_.Category -eq $cat } | Sort-Object { $_.Name })
    }

    $rescanState = {
        Write-Con "Scanning installed state..." Cyan
        foreach ($app in $apps) {
            $inst = $false
            try { $inst = [bool](& $app.Detect) } catch {}
            $baseline[$app.Name] = $inst
            $selected[$app.Name] = $inst
            $repairSel[$app.Name] = $false
        }
    }
    & $rescanState

    while ($true) {
        Write-Con ""
        $i = 0
        $lastCat = ''
        foreach ($app in $ordered) {
            $i++
            if ($app.Category -ne $lastCat) {
                $lastCat = $app.Category
                Write-Con ("  -- {0} --" -f $lastCat) Cyan
            }
            $mark  = if ($selected[$app.Name]) { '[X]' } else { '[ ]' }
            $state = if ($baseline[$app.Name]) { '(installed)' } else { '(not installed)' }
            $extra = ''
            if ($variantSel.ContainsKey($app.Name)) { $extra = ('  [{0}: {1}]' -f $app.Variants.Label, $variantSel[$app.Name]) }
            $pend = ''
            $col = [ConsoleColor]::Gray
            if ($selected[$app.Name] -and -not $baseline[$app.Name]) { $pend = '  << will be INSTALLED'; $col = [ConsoleColor]::Green }
            elseif (-not $selected[$app.Name] -and $baseline[$app.Name]) { $pend = '  << will be UNINSTALLED'; $col = [ConsoleColor]::Yellow }
            elseif ($repairSel[$app.Name]) { $pend = '  << will be REPAIRED'; $col = [ConsoleColor]::Cyan }
            Write-Con ("  {0,3}. {1} {2} {3}{4}{5}" -f $i, $mark, $app.Name, $state, $extra, $pend) $col
        }
        Write-Con ""
        Write-Con "  Toggle: numbers (e.g. 3 or 3,7,12) | V <num> = choose an app's option (e.g. Automate site)" DarkGray
        Write-Con "  E <num> = queue a repair (re-run an installed app's installer)" DarkGray
        Write-Con "  F = apply a profile | U = update all installed apps | R = rescan | P = proceed | Q = quit" DarkGray
        $cmd = (Read-Host 'Command').Trim()

        if ($cmd -match '^[Qq]$') { return }
        elseif ($cmd -match '^[Rr]$') { & $rescanState; continue }
        elseif ($cmd -match '^[Uu]$') {
            # Console twin of the GUI's 'Update installed apps' button:
            # every installed app that is update-managed (an explicit
            # Update spec, or a plain Winget install, which updates via
            # 'winget upgrade' with the same Id).
            $targets = @(); $skipped = @()
            foreach ($app in $ordered) {
                if (-not [bool]$baseline[$app.Name]) { continue }
                $updatable = $app.ContainsKey('Update') -or ($app.Install -and $app.Install.Engine -eq 'Winget')
                if ($updatable) { $targets += $app.Name } else { $skipped += $app.Name }
            }
            if ($targets.Count -eq 0) {
                Write-Con "  No installed app in this menu is update-managed by this tool." Yellow
                continue
            }
            Write-Con ("  UPDATE: " + ($targets -join ', ')) Green
            if ($skipped.Count -gt 0) { Write-Con ("  Skipped (they manage their own updates or are not winget-managed): " + ($skipped -join ', ')) DarkGray }
            if (Test-IsSystem) {
                Write-Con "  Note: this session runs as SYSTEM, where winget is usually unavailable -- these updates will likely fail with clear messages rather than run." Yellow
            }
            $ans = Read-Host '  Check these for updates and apply any found? (y/N)'
            if ($ans -notmatch '^[Yy]') { continue }
            $steps = @()
            foreach ($n2 in $targets) { $steps += @{ Name = $n2; Action = 'Update' } }
            Invoke-ConsoleRun -Plan $steps
            & $rescanState
            continue
        }
        elseif ($cmd -match '^[Ff]$') {
            $profiles = @($script:Profiles)
            if ($profiles.Count -eq 0) { Write-Con "  No profiles are defined." Yellow; continue }
            for ($p = 0; $p -lt $profiles.Count; $p++) { Write-Con ("  {0}. {1}" -f ($p + 1), $profiles[$p].Name) }
            $pick = (Read-Host '  Profile number (blank cancels)').Trim()
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $profiles.Count) {
                foreach ($app in $apps) { $selected[$app.Name] = [bool]$baseline[$app.Name] }
                $unknown = @()
                foreach ($n in @($profiles[[int]$pick - 1].Apps)) {
                    if ($selected.ContainsKey($n)) { $selected[$n] = $true } else { $unknown += $n }
                }
                if ($unknown.Count -gt 0) { Write-Con ("  Profile names not in the manifest: " + ($unknown -join ', ')) Yellow }
            }
            continue
        }
        elseif ($cmd -match '^[Ee]\s*(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -lt 1 -or $n -gt $ordered.Count) { Write-Con "  No such entry." Yellow; continue }
            $name = $ordered[$n - 1].Name
            if (-not $baseline[$name]) { Write-Con "  $name is not installed -- there is nothing to repair (toggle it to install instead)." Yellow; continue }
            if (-not $selected[$name]) { Write-Con "  $name is set to be UNINSTALLED -- toggle it back on first if you meant to repair it." Yellow; continue }
            $repairSel[$name] = -not $repairSel[$name]
            continue
        }
        elseif ($cmd -match '^[Vv]\s*(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -lt 1 -or $n -gt $ordered.Count) { Write-Con "  No such entry." Yellow; continue }
            $app = $ordered[$n - 1]
            if (-not $app.ContainsKey('Variants')) { Write-Con "  That app has no options to choose." Yellow; continue }
            $choices = @(Get-AppVariantChoices $app)
            for ($p = 0; $p -lt $choices.Count; $p++) { Write-Con ("  {0}. {1}" -f ($p + 1), $choices[$p]) }
            $pick = (Read-Host ("  {0} number (blank cancels)" -f $app.Variants.Label)).Trim()
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $choices.Count) {
                $variantSel[$app.Name] = [string]$choices[[int]$pick - 1]
            }
            continue
        }
        elseif ($cmd -match '^\d[\d,\s]*$') {
            foreach ($tok in ($cmd -split '[,\s]+' | Where-Object { $_ })) {
                $n = [int]$tok
                if ($n -ge 1 -and $n -le $ordered.Count) {
                    $name = $ordered[$n - 1].Name
                    $selected[$name] = -not $selected[$name]
                    # Turning a row into an uninstall clears any queued
                    # repair -- the two are mutually exclusive.
                    if (-not $selected[$name]) { $repairSel[$name] = $false }
                }
            }
            continue
        }
        elseif ($cmd -match '^[Pp]$') {
            $installs = @(); $uninstalls = @(); $repairs = @()
            foreach ($app in $ordered) {
                $want = [bool]$selected[$app.Name]; $have = [bool]$baseline[$app.Name]
                if ($want -and -not $have) { $installs += $app.Name }
                elseif (-not $want -and $have) { $uninstalls += $app.Name }
                elseif ($want -and $have -and $repairSel[$app.Name]) { $repairs += $app.Name }
            }
            if ($installs.Count -eq 0 -and $uninstalls.Count -eq 0 -and $repairs.Count -eq 0) {
                Write-Con "  Nothing to do -- every selection already matches this machine and no repairs are queued." Yellow
                continue
            }
            $abort = $false
            foreach ($app in $ordered) {
                if (($app.Name -in $installs -or $app.Name -in $repairs) -and $app.ContainsKey('Variants') -and $app.Variants.WarnOnDefault -and
                    [string]$variantSel[$app.Name] -eq [string]$app.Variants.Default) {
                    $actWord = if ($app.Name -in $repairs) { 'repair (reinstall)' } else { 'install' }
                    $ans = Read-Host ("  {0} will {1} with the DEFAULT {2} '{3}'. Is that right? (y/N)" -f $app.Name, $actWord, $app.Variants.Label, $variantSel[$app.Name])
                    if ($ans -notmatch '^[Yy]') { $abort = $true; break }
                }
            }
            if ($abort) { continue }
            if ($installs.Count -gt 0)   { Write-Con ("  INSTALL:   " + ($installs -join ', ')) Green }
            if ($uninstalls.Count -gt 0) { Write-Con ("  UNINSTALL: " + ($uninstalls -join ', ')) Yellow }
            if ($repairs.Count -gt 0)    { Write-Con ("  REPAIR:    " + ($repairs -join ', ')) Cyan }
            $ans = Read-Host '  Proceed? (y/N)'
            if ($ans -notmatch '^[Yy]') { continue }

            $needShare = $false
            $odtCached = Test-Path -LiteralPath (Join-Path $env:ProgramData 'RWW\AppsDeploy\Stage\odt-setup.exe')
            foreach ($app in $ordered) {
                if ($app.Name -notin @($installs + $uninstalls + $repairs)) { continue }
                # Repairs re-run the INSTALL spec, so they share its needs.
                $action = if ($app.Name -in $uninstalls) { 'Uninstall' } else { 'Install' }
                $spec = $app[$action]
                if (-not ($spec -is [hashtable] -and ($spec.Engine -eq 'Odt' -or $spec.NeedsShare))) { continue }
                if ($action -eq 'Uninstall' -and $spec.Engine -eq 'Odt' -and $odtCached) { continue }
                if ($spec.SkipShareIfPresent -and (Test-Path -LiteralPath $spec.SkipShareIfPresent -ErrorAction SilentlyContinue)) { continue }
                $needShare = $true
                break
            }
            if ($needShare -and -not (Ensure-ShareAccessConsole)) { continue }

            $steps = @()
            foreach ($n2 in $uninstalls) { $steps += @{ Name = $n2; Action = 'Uninstall' } }
            foreach ($n2 in $installs) {
                $step = @{ Name = $n2; Action = 'Install' }
                if ($variantSel.ContainsKey($n2)) { $step.Variant = $variantSel[$n2] }
                $steps += $step
            }
            foreach ($n2 in $repairs) {
                $step = @{ Name = $n2; Action = 'Repair' }
                if ($variantSel.ContainsKey($n2)) { $step.Variant = $variantSel[$n2] }
                $steps += $step
            }
            Invoke-ConsoleRun -Plan $steps
            & $rescanState
            continue
        }
        else {
            Write-Con "  Unrecognized command." Yellow
        }
    }
}

# Engage console mode: explicitly via -ConsoleMode, or automatically on
# any desktop that is not 'Default' (Backstage runs on its own hidden
# desktop).
$script:DesktopName = Get-CurrentDesktopName
if ($ConsoleMode -or ($script:DesktopName -and $script:DesktopName -ne 'Default')) {
    Write-Host ""
    Write-Host "Desktop '$($script:DesktopName)' cannot display the normal windows -- using the console menu." -ForegroundColor Yellow
    Show-ConsoleMenu
    foreach ($unc in $script:ShareMappedTo) {
        [void](Invoke-HiddenExe -FilePath 'net.exe' -Arguments ('use "{0}" /delete /y' -f $unc))
    }
    exit 0
}

# The console window usually belongs to the launcher .bat (cmd stays
# attached, waiting to pause on a non-zero exit), so it is minimized
# FIRST -- detaching alone left the bat's window sitting open on screen
# (CONFIRMED). It closes as before when the bat finishes after the app
# exits; if a Terminal uninstall kills the hosted console mid-run, it
# now takes only the idle bat with it, never the detached UI.
try {
    Add-Type -Name ConsoleUtil -Namespace RWW -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
'@ -ErrorAction Stop
    $consoleHwnd = [RWW.ConsoleUtil]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        [void][RWW.ConsoleUtil]::ShowWindow($consoleHwnd, 6)   # 6 = SW_MINIMIZE
    }
    [void][RWW.ConsoleUtil]::FreeConsole()
} catch {}

Show-SelectionWindow

# Drop any share connection this session established (credentials were
# never persisted; this just tidies the connection itself).
foreach ($unc in $script:ShareMappedTo) {
    [void](Invoke-HiddenExe -FilePath 'net.exe' -Arguments ('use "{0}" /delete /y' -f $unc))
}
exit 0
