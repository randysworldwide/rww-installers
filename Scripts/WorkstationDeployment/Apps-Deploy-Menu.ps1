<#
.SYNOPSIS
    GUI menu for deploying the standard RWW application set to a machine.
    Meant to be run from the USB deployment stick or the network deployment
    share, on a machine that already has a qualifying OEM Windows image on it.

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/WorkstationDeployment/Apps-Deploy-Menu.ps1

    This is a standalone project, separate from the older ConnectWise Automate
    scripting under Scripts/ (VSCWinTerminalInst.ps1, the BootstrapperScripts
    folder, etc). Those are left alone for now and may be revisited later.

    TWO-STAGE GUI:
      1. Selection screen -- categorized checkboxes, hover tooltips (see
         Show-SelectionGui). Same as before.
      2. Progress screen -- after clicking "Install Selected", shows a
         per-app marquee progress bar (fills solid briefly when that app is
         confirmed done, then resets to marquee for the next one), an
         overall "app N of Total" progress bar, and a live scrolling text
         log of what each script is doing (see Show-ProgressGui).

    HONESTY NOTE on the per-app bar: winget/msiexec don't expose real
    install percentage without a lot of extra plumbing to parse their live
    output byte-by-byte, which none of these scripts currently do. The
    per-app bar is therefore an INDETERMINATE marquee while installing, not
    a true percentage -- it fills solid the instant the app is confirmed
    installed (success or failure), then resets for the next one. This is
    an honest visual of "working / done", not a fabricated percentage.

    ARCHITECTURE NOTE on live log capture: every install script logs via
    [Console]::WriteLine rather than PowerShell's normal output stream
    (deliberately, so Write-Log calls can never leak into a function's
    return value). To surface that output in the GUI, every script under
    AppsDeployScripts now checks for a $Global:RWWLogSink callback first
    and only falls back to Console::WriteLine if none is registered --
    so they still work fine run standalone/manually outside this menu.
    The actual install loop runs on a background PowerShell runspace (so
    the GUI doesn't freeze during a blocking msiexec/winget call); that
    runspace sets $Global:RWWLogSink to push lines into a thread-safe
    queue that the GUI's timer drains into the log textbox.

    This script does NOT contain install logic itself. Each app in $script:AppManifest
    points at either:
      - a script already in this repo, downloaded fresh from GitHub at
        runtime (so a machine always gets the current version, not a stale
        copy on a USB stick), or
      - nothing yet (Status = 'Placeholder') -- these show in the GUI,
        greyed out and unselectable, so the list stays complete without
        letting anyone pick something that won't do anything.

    Per-app install scripts for this project live under
    Scripts/WorkstationDeployment/AppsDeployScripts/. WinAppInst.ps1 is a
    copy of the version used by the older Automate deployment path (still at
    Scripts/WinAppInst.ps1) rather than a shared reference to it -- the two
    may drift over time until a decision is made about the old Automate
    scripting.

    Local folder convention on the target machine:
      - C:\ProgramData\Dev\AppsDeploy\               downloaded scripts (this menu's own cache)
      - C:\ProgramData\Dev\AppsDeploy\Logs\           every script's log file
      - C:\ProgramData\Dev\AppsDeploy\<AppName>\      installer binaries (.exe/.msi/.msix),
                                                       one subfolder per app that needs one
                                                       -- e.g. ...\AppsDeploy\WindowsApp\,
                                                       ...\AppsDeploy\ConnectWiseAgent\
    Apps installed purely via winget (no repo-hosted installer) don't need
    one of these subfolders -- winget handles its own download/cache.

    Idempotency is handled inside each app's own install script (same as the
    Automate versions) -- this menu just decides what to run, not whether it's
    safe to run again.

.PARAMETER LogPath
    Where to write the run log. Defaults under ProgramData so it's readable
    without a user profile loaded, consistent with the other rww-installers scripts.

.NOTES
    This is a MENU/DISPATCHER, not an installer. Exit codes reflect the run
    as a whole:
        0 = every selected app succeeded (or was already installed)
        1 = one or more selected apps failed
        3 = not running elevated
        6 = user quit without installing anything
        7 = aborted -- at least one selected app needed \\svazdfs001\systems$
            access and all 3 credential attempts failed or were cancelled

    Requires launching with -STA (Windows Forms needs a single-threaded
    apartment) -- both Apps-Deploy-Menu.bat and Apps-Deploy-Menu-Blank.bat
    already pass this.

    The progress window has no visible titlebar close/min/max buttons
    (ControlBox is off; "Close" is its own button, disabled until installs
    finish), but Alt+F4 IS enabled -- technicians can force-close a
    stuck/hung run. Doing so orphans the background runspace mid-install;
    the cleanup code after ShowDialog() stops it, but whatever installer
    process it was running (msiexec, winget, setup.exe, etc.) may be left
    running or in a partial state on the machine. There's no graceful
    "cancel and roll back" -- Alt+F4 is an emergency escape hatch, not a
    clean cancel.

    MID-RUN REBOOT AND AUTO-RESUME (Change Computer Name + Join Domain):
    every other reboot-needing step in this project (Domain Join alone,
    Change Computer Name alone, Reboot Computer itself) just logs a
    "restart needed" warning and keeps the current session going --
    nothing about the change is actually live until some LATER restart,
    whenever that happens. The one exception is when Change Computer Name
    and Join Domain are BOTH selected: they combine into a single
    Add-Computer -NewName call (see DomainJoinInst.ps1), and neither the
    new name nor the domain membership is live until an ACTUAL restart
    happens -- continuing the same session afterward would be operating
    on stale identity information. So specifically in that combination,
    right after Join Domain reports success, this script:
      1. Saves whatever apps were still left in the selected queue (by
         name, in order) to PendingResumeApps.txt.
      2. Registers a one-time Scheduled Task ("RWW-ResumeDeployment"),
         triggered at the next interactive logon of the current user,
         that re-launches this same script with -ResumeAfterReboot.
      3. Restarts the machine (20-second delay, same reasoning as
         RebootInst.ps1 -- lets the progress window's state render first).
    On the next logon, the resume task runs this script again with
    -ResumeAfterReboot: it skips the selection GUI entirely, reads back
    the saved app list, and continues installing exactly where it left
    off -- including re-prompting for share credentials if needed, since
    those don't persist across a reboot.

    UNTESTED, FLAGGING HONESTLY: this depends on the "at logon" Scheduled
    Task trigger actually firing after whatever gets the machine back to
    an interactive desktop (AutoAdminLogon if configured, or a manual
    logon otherwise) -- similar category of assumption as
    RemoveThrowawayAccountInst.ps1's original "at startup" trigger, which
    turned out to race against AutoAdminLogon in real testing. This one
    is "at logon" rather than "at startup" specifically to avoid that
    same race (it fires as a consequence of the logon itself, not
    competing with it), but it hasn't been exercised on a real machine yet.
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:ProgramData\Dev\AppsDeploy\Logs\Apps-Deploy-Menu.log",

    # When set, every app starts unchecked regardless of DefaultOn, instead
    # of the normal fresh-deployment defaults. Used by the "blank" .bat
    # variant for going back onto already-deployed machines to install just
    # a couple of specific apps (e.g. Claude, which is per-user and often
    # gets requested one machine at a time).
    [switch]$StartBlank,

    # For local testing before anything is pushed to the repo. When set,
    # AppsDeployScripts\*.ps1 are run directly from disk (relative to this
    # script's own folder) instead of being downloaded from GitHub. Used by
    # Apps-Deploy-Menu-Test.bat -- the real .bat launchers never pass this.
    [switch]$Local,

    # When set, skips the selection GUI entirely and resumes a deployment
    # run that was interrupted by a mid-run reboot -- specifically the
    # Change Computer Name + Join Domain combination, which needs a real
    # restart to actually take effect (unlike everything else in this
    # project, which defers restart to the end). A Scheduled Task passes
    # this automatically at the next logon; nothing about this needs to
    # be passed manually by a technician. See the resume-handling block in
    # Main, and the reboot-triggering block in Show-ProgressGui's worker
    # script, for the two ends of this mechanism.
    [switch]$ResumeAfterReboot
)

$script:LocalRoot = $PSScriptRoot

$ErrorActionPreference = 'Stop'

$RepoOwner = 'randysworldwide'
$RepoName  = 'rww-installers'
$Branch    = 'main'
$StagingDir = "$env:ProgramData\Dev\AppsDeploy"

# Shared with the reboot-and-resume mechanism in Show-ProgressGui's worker
# script and the resume-handling block in Main below. Named apps (one per
# line, in original selection order) that still need to run after a
# mid-run reboot triggered by Change Computer Name + Join Domain running
# together.
$script:ResumeStateFile = "$env:ProgramData\Dev\AppsDeploy\PendingResumeApps.txt"
$script:ResumeTaskName  = 'RWW-ResumeDeployment'
# Needed so the resume scheduled task knows what to re-launch after a
# mid-run reboot -- $PSCommandPath only resolves correctly here, in the
# top-level script; it wouldn't resolve inside the in-memory scriptblock
# Show-ProgressGui's worker runs via AddScript(), so it's captured once
# here and threaded through as a parameter instead.
$script:SelfScriptPath  = $PSCommandPath

# ---------------------------------------------------------------------------
# Logging for the handful of top-level messages that happen outside the
# progress GUI (elevation failure, user-quit paths). Once installs start,
# all logging happens inside the background runspace instead -- see
# Show-ProgressGui's worker script.
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [Console]::WriteLine($line)
    try {
        $dir = Split-Path -Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line
    } catch {
        # Logging failures shouldn't kill the run
    }
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.IsSystem
}

if (-not (Test-IsElevated)) {
    Write-Log "Not running elevated. Re-run as administrator." 'ERROR'
    exit 3
}

# WELL-REASONED HYPOTHESIS, NOT YET FULLY CONFIRMED: real testing showed
# ConnectWise Agent (an MSI custom action handle leak) and Google Chrome
# (winget) BOTH failing in the SAME run -- specifically the resumed
# session right after the Change Computer Name + Join Domain reboot,
# launched via the "at logon" scheduled task. Two completely unrelated
# installer technologies failing together in that exact spot rules out
# "bug in one vendor's package" as the sole explanation. Chrome's own
# winget exit code (-1978335215) decodes to 0x8A150011,
# APPINSTALLER_CLI_ERROR_INSTALL_TIME_OUT -- a real, concrete data point
# consistent with the network/DNS stack not being fully stable yet. A
# freshly domain-joined machine's DNS servers often change to point at
# the domain's own DNS the moment the join completes, and that can take
# a genuine, noticeable amount of time to settle after that specific
# kind of reboot -- plausibly explaining both the winget timeout AND
# ConnectWise's own custom action hitting an unhandled exception path
# (if it does some network-dependent property lookup) that happens to be
# exactly where their code fails to release its handle. Checked via DNS
# resolution specifically, not just raw connectivity, since DNS is what
# tends to lag behind basic IP connectivity in this exact scenario.
function Wait-ForNetworkReadiness {
    param([int]$MaxWaitSeconds = 60, [int]$PollSeconds = 5)
    $elapsed = 0
    while ($elapsed -lt $MaxWaitSeconds) {
        try {
            if (Resolve-DnsName -Name 'www.microsoft.com' -ErrorAction Stop) {
                return $true
            }
        } catch {}
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds
    }
    return $false
}

# Minimize (not hide) the console window now that we're handing off to the
# GUI, so it doesn't sit visible behind the selection/progress windows for
# the whole run. Minimized rather than hidden on purpose: if something goes
# wrong before a GUI ever appears, the window is still reachable from the
# taskbar instead of vanishing outright. Failure here is purely cosmetic and
# never blocks the rest of the script.
try {
    Add-Type -Name Win32Window -Namespace RWW -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
'@
    $consolePtr = [RWW.Win32Window]::GetConsoleWindow()
    if ($consolePtr -ne [IntPtr]::Zero) {
        [RWW.Win32Window]::ShowWindow($consolePtr, 6) | Out-Null   # 6 = SW_MINIMIZE
    }
} catch {
    # Cosmetic only -- never fail the run over this
}

# ---------------------------------------------------------------------------
# App manifest
# ---------------------------------------------------------------------------
# Status:
#   Ready       -> Install scriptblock below actually works today
#   NeedsStaging-> script exists in repo but assumes Automate-staged files
#                  next to it (e.g. an MSI), not a standalone GitHub pull yet
#   Placeholder -> no install script in the repo yet
#
# Note (optional): shown in the GUI tooltip on hover, for anything with a
# real-world caveat worth a tech knowing about before they pick it.
#
# InstallRepoPath is plain string data (not a scriptblock) on purpose --
# it gets handed across a runspace boundary to the background install
# worker in Show-ProgressGui, and only plain data (not scriptblocks, which
# carry a binding back to whatever runspace created them) crosses that
# boundary reliably. The worker's own copy of Invoke-RemoteInstallScript
# is what actually resolves and runs each app's script.
#
# The order of entries below matters within a category: apps run in this
# order when multiple are selected, so a dependency (e.g. .NET 8 Desktop
# Runtime, needed by Dell Command | Update) should be listed before
# anything that needs it.
#
# DefaultOn reflects the checkbox state when the menu first draws.
$script:AppManifest = @(
    # --- Preparation ---
    # Runs before Initial Setup on purpose -- these are all machine-
    # stability/cleanup steps meant to happen before the bulk of app
    # downloads and installs, not alongside them. See the informational
    # banner rendered between this category and Initial Setup in
    # Show-SelectionGui for the related guidance about running Windows
    # Update + Dell Command Update between these two categories.
    @{ Name = 'Set Brightness to 50%';            Category = 'Preparation'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/BrightnessInst.ps1'
       Note = "Only works on laptop-integrated panels; most external desktop monitors don't support this and it will just skip harmlessly." }
    @{ Name = 'Power Settings (Plugged In)';      Category = 'Preparation'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/PowerPluggedInInst.ps1'
       Note = "Screen off after 20 min, sleep after 60 min, while plugged in -- prevents the machine dimming/sleeping mid-deployment." }
    @{ Name = 'Power Settings (On Battery)';      Category = 'Preparation'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/PowerOnBatteryInst.ps1'
       Note = "Screen off after 10 min, sleep after 20 min, while on battery. Harmless (and irrelevant) on a desktop with no battery." }
    @{ Name = 'Remove OEM Bloatware';             Category = 'Preparation'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/DebloatOEMInst.ps1'
       NeedsShareCredentials = $true
       Note = "Removes Dell SupportAssist/Optimizer/Core Services/Trusted Device/Watchdog Timer (via Appx) and ALL pre-installed Office/OneNote (via ODT Remove-All, every language including English) -- the pre-installed copy is a different product from what's installed separately. Leaves Dell Command Update, Edge, OneDrive, and runtime dependencies alone on purpose." }

    # --- Initial Setup ---
    @{ Name = 'Enable Administrator Account';    Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/EnableAdminAccountInst.ps1'
       Note = "Prompts for a password at runtime (masked, with confirm). Defaults ON -- a known-good local admin fallback matters more once Remove Throwaway Setup Account has run." }
    @{ Name = 'Change Computer Name';            Category = 'Initial Setup'; DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/ChangeComputerNameInst.ps1'
       Note = "Prompts for the new name at runtime. Runs before Join Domain on purpose -- renaming while still a workgroup machine only needs local admin rights, not domain permissions." }
    @{ Name = 'Join Domain (rpsinc.ringpinion.com)'; Category = 'Initial Setup'; DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/DomainJoinInst.ps1'
       Note = "Prompts for its OWN AD credentials, separate from the file-share prompt -- domain-join rights aren't the same as share-read rights. No auto-restart; a manual restart is needed afterward for it to fully take effect." }
    @{ Name = 'ConnectWise Agent';              Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/CWAgentInst.ps1'
       NeedsShareCredentials = $true
       Note = "Pulls from the private network share, not GitHub -- won't work on a machine with no network access yet." }
    @{ Name = 'Windows App (RDP)';               Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/WinAppInst.ps1' }
    @{ Name = 'ZAC Softphone';                   Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/ZACInst.ps1'
       NeedsShareCredentials = $true
       Note = "Pulls its MSI from the private share, not GitHub. Uses the .msi, not the .exe also on the share." }
    @{ Name = 'Microsoft Visual Studio Code';    Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/VSCodeInst.ps1' }
    @{ Name = 'Windows Terminal';                 Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/WinTerminalInst.ps1' }
    @{ Name = 'Cisco Secure Client';             Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/CiscoSecureClientInst.ps1'
       NeedsShareCredentials = $true
       Note = "Runs a pre-built installer bundle from the private share -- handles the VPN profile and retries internally." }
    @{ Name = 'Microsoft .NET Desktop Runtime 8';   Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/DotNet8Inst.ps1'
       Note = "A dependency for other apps (e.g. Dell Command Update) -- installs first on purpose." }
    @{ Name = 'Dell Command | Update';           Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/DCUInst.ps1'
       Note = "Dell hardware only; harmless elsewhere. Occasional download failures are a Dell CDN issue, not this script." }
    @{ Name = 'VLC Media Player';                Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/VLCInst.ps1' }
    @{ Name = 'SentinelOne EDR';                 Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/SentinelOneInst.ps1'
       NeedsShareCredentials = $true
       Note = "Pulls its MSI and site token from the private share. The token is a secret and is never logged." }
    @{ Name = 'RPS Reporting Center Shortcuts';  Category = 'Initial Setup'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/ReportingCenterInst.ps1'
       NeedsShareCredentials = $true
       Note = "Not a software install -- copies two RDP shortcuts to the Public desktop, visible to all users. Skips if both already exist." }

    # --- Conditional ---
    @{ Name = 'Office O365';                     Category = 'Conditional';   DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/OfficeO365Inst.ps1'
       NeedsShareCredentials = $true
       Note = "Uses ODT with the x64 config. Can take 10-20+ minutes. Mutually exclusive with Office Suite 2021." }
    @{ Name = 'Office Suite 2021';                Category = 'Conditional';   DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/Office2021Inst.ps1'
       NeedsShareCredentials = $true
       Note = "Uses ODT with the 2021 volume-license config. Can take 10-20+ minutes. Mutually exclusive with Office O365." }
    @{ Name = 'Adobe Acrobat Pro';                Category = 'Conditional';   DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/AcroProInst.ps1'
       NeedsShareCredentials = $true
       Note = "Stages the full install folder, not just the MSI. Mutually exclusive with Acrobat Reader -- they can't coexist." }
    @{ Name = 'Adobe Acrobat Reader';             Category = 'Conditional';   DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/AcroRdrInst.ps1'
       Note = "Free Reader only. Mutually exclusive with Acrobat Pro -- they can't coexist on the same machine." }

    # --- Optional ---
    @{ Name = 'Google Chrome';                    Category = 'Optional';      DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/GChromeInst.ps1' }
    @{ Name = 'Microsoft Outlook Classic';        Category = 'Optional';      DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/OutlookClassicInst.ps1'
       NeedsShareCredentials = $true
       Note = "Silent by design, but unverified -- has a timeout safety net just in case." }
    @{ Name = 'Logi Options+';                    Category = 'Optional';      DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/LogiOptInst.ps1'
       Note = "Doesn't force machine-wide install (known issue with that combo). May occasionally fail from an upstream hash mismatch." }
    @{ Name = '7-Zip';                            Category = 'Optional';      DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/7ZipInst.ps1' }
    @{ Name = 'Claude';                           Category = 'Optional';      DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/ClaudeInst.ps1'
       Note = "Installs per-user, not machine-wide -- run as the actual end user, not a technician's own account." }
    @{ Name = 'Project Professional 2021';        Category = 'Optional';      DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/ProjectPro2021Inst.ps1'
       NeedsShareCredentials = $true
       Note = "Standalone install via ODT. Compatible alongside Office O365 or Office 2021, no conflict." }
    @{ Name = 'Visio LTSC Professional 2021';     Category = 'Optional';      DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/VisioPro2021Inst.ps1'
       NeedsShareCredentials = $true
       Note = "Standalone install via ODT. Compatible alongside Office O365 or Office 2021, no conflict." }

    # --- IT ---
    @{ Name = 'Microsoft Visual C++ Redistributables'; Category = 'IT';       DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/VCRedistInst.ps1'
       Note = "Installs both x64 and x86, since some apps expect x86 even on 64-bit Windows." }
    @{ Name = 'Java';                             Category = 'IT';            DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/JavaInst.ps1'
       Note = "Installs Eclipse Temurin (OpenJDK), not Oracle's JDK -- avoids Oracle's licensing requirements." }
    @{ Name = 'Git';                              Category = 'IT';            DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/GitInst.ps1' }
    @{ Name = 'GitHub CLI';                       Category = 'IT';            DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/GHCliInst.ps1' }
    @{ Name = 'Node.js';                          Category = 'IT';            DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/NodeJSInst.ps1'
       Note = "Installs the LTS line, not the latest -- safer default for business machines." }
    @{ Name = 'MXAdmin';                          Category = 'IT';            DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/MXAdminInst.ps1'
       NeedsShareCredentials = $true
       Note = "Silent switch is an unverified guess. Has a 10-minute timeout in case it's wrong." }

    # --- Finishing Touches ---
    # CRITICAL: Reboot Computer must stay the LAST entry in this entire
    # array (not just last in this category) -- see RebootInst.ps1's own
    # header for why. Apps-Deploy-Menu.ps1 builds its selection list by
    # walking this array in order, so as long as Reboot stays last here,
    # it's guaranteed to run last whenever it's checked.
    @{ Name = 'Mute Volume';                      Category = 'Finishing Touches'; DefaultOn = $true;  Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/MuteInst.ps1'
       Note = "Sets mute (doesn't toggle it). Least-verified script in this project -- uses hand-written COM interop with no way to compile-test it outside a real Windows box." }
    @{ Name = 'Remove Throwaway Setup Account';   Category = 'Finishing Touches'; DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/RemoveThrowawayAccountInst.ps1'
       Note = "Defaults OFF, same as Reboot Computer -- account deletion is consequential enough to require a deliberate click. Schedules removal for the next startup instead of deleting immediately (can't delete the account running this script)." }
    # CRITICAL ORDERING: must come after Remove Throwaway Setup Account
    # (the actual removal happens post-reboot, so this needs to fire
    # after that scheduling step, not before it).
    @{ Name = 'Reboot Computer';                  Category = 'Finishing Touches'; DefaultOn = $false; Status = 'Ready';
       InstallRepoPath = 'Scripts/WorkstationDeployment/AppsDeployScripts/RebootInst.ps1'
       Note = "Defaults OFF on purpose -- a reboot is consequential enough that it shouldn't happen without a deliberate click. Restarts ~20 seconds after this run finishes, giving time for the summary to render." }
)

$script:CategoryOrder = @('Preparation', 'Initial Setup', 'Conditional', 'Optional', 'IT', 'Finishing Touches')

# Informational banners rendered BEFORE the named category, inline with
# the checkbox groups but not selectable themselves -- for guidance that
# belongs at a specific point in the flow rather than as a tooltip on any
# single app. Keyed by which category the banner should appear before.
$script:CategoryInfoBanners = @{
    'Initial Setup' = "Before continuing: run a full round of Windows Update, then a round of Dell Command | Update, and reboot if either applies updates. Getting the machine current here first makes Windows more stable for the app downloads and installs below."
}

# ---------------------------------------------------------------------------
# GUI stage 1: selection screen
# ---------------------------------------------------------------------------
function Show-SelectionGui {
    param([bool]$StartBlank)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($StartBlank) { 'rww-installers - Deployment Menu (blank mode)' } else { 'rww-installers - Deployment Menu' }
    $form.Size = New-Object System.Drawing.Size(540, 660)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # Force this window to the foreground on first appearance -- by default
    # a window created by a background/elevated process (like this one,
    # launched via the .bat's UAC relaunch) doesn't automatically win
    # Windows' foreground-focus rules and can open behind whatever was
    # already active. Briefly going TopMost grabs focus; releasing it right
    # after means the window behaves normally afterward instead of staying
    # pinned above everything else for the rest of the run.
    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })

    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 20000
    $tooltip.InitialDelay = 300
    $tooltip.ReshowDelay = 100
    $tooltip.ShowAlways = $true

    if ($StartBlank) {
        $banner = New-Object System.Windows.Forms.Label
        $banner.Text = 'Blank mode -- nothing pre-selected'
        $banner.ForeColor = [System.Drawing.Color]::DimGray
        $banner.Location = New-Object System.Drawing.Point(15, 8)
        $banner.AutoSize = $true
        $form.Controls.Add($banner)
        $scrollTop = 30
    } else {
        $scrollTop = 8
    }

    $scrollPanel = New-Object System.Windows.Forms.Panel
    $scrollPanel.AutoScroll = $true
    $scrollPanel.Location = New-Object System.Drawing.Point(10, $scrollTop)
    $scrollPanel.Size = New-Object System.Drawing.Size(505, 555)
    $scrollPanel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($scrollPanel)

    $checkboxByApp = New-Object 'System.Collections.Generic.Dictionary[object,object]'
    $y = 8

    foreach ($cat in $script:CategoryOrder) {
        $items = @($script:AppManifest | Where-Object { $_.Category -eq $cat })
        if ($items.Count -eq 0) { continue }

        if ($script:CategoryInfoBanners.ContainsKey($cat)) {
            $bannerText = $script:CategoryInfoBanners[$cat]

            $bannerPanel = New-Object System.Windows.Forms.Panel
            $bannerPanel.Location = New-Object System.Drawing.Point(8, $y)
            $bannerPanel.Size = New-Object System.Drawing.Size(465, 1)  # height finalized below, after measuring the label
            $bannerPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
            $bannerPanel.BorderStyle = 'FixedSingle'

            $bannerLabel = New-Object System.Windows.Forms.Label
            $bannerLabel.Text = $bannerText
            $bannerLabel.Location = New-Object System.Drawing.Point(10, 8)
            $bannerLabel.Size = New-Object System.Drawing.Size(440, 0)
            $bannerLabel.AutoSize = $false
            $bannerLabel.Font = New-Object System.Drawing.Font($bannerLabel.Font, [System.Drawing.FontStyle]::Italic)
            # Measure the wrapped text at this width to size the panel to
            # fit exactly, rather than guessing a fixed height that could
            # clip longer banner text or leave awkward empty space for
            # shorter text.
            $measured = [System.Windows.Forms.TextRenderer]::MeasureText($bannerText, $bannerLabel.Font, (New-Object System.Drawing.Size(440, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
            $bannerLabel.Size = New-Object System.Drawing.Size(440, $measured.Height)
            $bannerPanel.Controls.Add($bannerLabel)
            $bannerPanel.Size = New-Object System.Drawing.Size(465, ($measured.Height + 16))

            $scrollPanel.Controls.Add($bannerPanel)
            $y += $bannerPanel.Height + 10
        }

        $groupBox = New-Object System.Windows.Forms.GroupBox
        $groupBox.Text = $cat
        $groupBox.Location = New-Object System.Drawing.Point(8, $y)
        $groupBox.Size = New-Object System.Drawing.Size(465, (24 + 24 * $items.Count))
        $scrollPanel.Controls.Add($groupBox)

        $innerY = 20
        foreach ($app in $items) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $app.Name
            $cb.Location = New-Object System.Drawing.Point(12, $innerY)
            $cb.Size = New-Object System.Drawing.Size(435, 20)
            $cb.Tag = $app

            $isReady = ($app.Status -eq 'Ready')
            $cb.Checked = $isReady -and (-not $StartBlank) -and [bool]$app.DefaultOn

            if (-not $isReady) {
                $cb.ForeColor = [System.Drawing.Color]::Gray
                # Enabled stays $true on purpose -- a disabled control suppresses
                # WM_MOUSEMOVE, which would silently kill the tooltip too. Instead
                # we let it be clicked, then immediately snap it back off.
                $cb.Add_CheckedChanged({
                    if ($this.Checked) { $this.Checked = $false }
                })
            }

            $noteParts = @()
            switch ($app.Status) {
                'Placeholder'  { $noteParts += 'No install script exists for this yet -- selecting it does nothing.' }
                'NeedsStaging' { $noteParts += 'Has a script, but it is not wired up for standalone use yet -- selecting it does nothing.' }
            }
            if ($app.Note) { $noteParts += $app.Note }
            if ($noteParts.Count -gt 0) {
                $tooltip.SetToolTip($cb, ($noteParts -join "`r`n`r`n"))
            }

            $groupBox.Controls.Add($cb)
            $checkboxByApp[$app] = $cb
            $innerY += 24
        }
        $y += $groupBox.Height + 10
    }

    $scrollPanel.AutoScrollMinSize = New-Object System.Drawing.Size(0, $y)

    # Some app pairs can't coexist on a machine (running both installs
    # together is either unsupported or actively conflicts) -- checking one
    # immediately unchecks AND disables the other, so it can't be clicked
    # at all while the first stays selected.
    #
    # Implementation note: $partnerOf is declared here, in Show-SelectionGui's
    # own function scope, which stays on the call stack for the whole
    # $form.ShowDialog() message pump below -- the same reasoning that
    # already makes Show-ProgressGui's Timer.Add_Tick handler able to read
    # $logQueue/$state safely. The event handlers below use $this (the
    # sender checkbox, the same idiom already used for the disabled-checkbox
    # handler above) to look up the partner rather than trying to capture a
    # specific checkbox variable from inside a helper function that would
    # have already returned by the time the event actually fires.
    $partnerOf = New-Object 'System.Collections.Generic.Dictionary[object,object]'

    function Register-MutuallyExclusivePair {
        param(
            [Parameter(Mandatory)][string]$NameA,
            [Parameter(Mandatory)][string]$NameB
        )
        $appA = $script:AppManifest | Where-Object { $_.Name -eq $NameA } | Select-Object -First 1
        $appB = $script:AppManifest | Where-Object { $_.Name -eq $NameB } | Select-Object -First 1
        if (-not ($appA -and $appB -and $checkboxByApp.ContainsKey($appA) -and $checkboxByApp.ContainsKey($appB))) {
            return
        }
        $partnerOf[$checkboxByApp[$appA]] = $checkboxByApp[$appB]
        $partnerOf[$checkboxByApp[$appB]] = $checkboxByApp[$appA]
    }

    # Office O365 vs Office Suite 2021 -- running both installs together
    # isn't a supported Office configuration.
    Register-MutuallyExclusivePair -NameA 'Office O365' -NameB 'Office Suite 2021'

    # Adobe Acrobat Reader vs Adobe Acrobat Pro -- modern, 64-bit-unified
    # builds of these can't coexist on the same machine at all; installing
    # one replaces the other.
    Register-MutuallyExclusivePair -NameA 'Adobe Acrobat Reader' -NameB 'Adobe Acrobat Pro'

    foreach ($cb in $partnerOf.Keys) {
        $cb.Add_CheckedChanged({
            $partner = $partnerOf[$this]
            if ($this.Checked) {
                $partner.Checked = $false
                $partner.Enabled = $false
            } else {
                $partner.Enabled = $true
            }
        })
    }

    # The initial Checked state above was set directly on each checkbox
    # BEFORE these handlers existed, so it never triggered the disable
    # logic -- without this pass, a Default ON app (e.g. Office O365)
    # shows checked at load with its partner still clickable, only
    # actually disabling it after the first real click. Sync once here so
    # the initial render already matches what the handler would produce.
    foreach ($cb in $partnerOf.Keys) {
        if ($cb.Checked) {
            $partnerOf[$cb].Enabled = $false
        }
    }

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = 'Install Selected'
    $btnRun.Location = New-Object System.Drawing.Point(300, ($scrollTop + 565))
    $btnRun.Size = New-Object System.Drawing.Size(210, 34)
    $btnRun.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnRun)

    $btnQuit = New-Object System.Windows.Forms.Button
    $btnQuit.Text = 'Quit'
    $btnQuit.Location = New-Object System.Drawing.Point(15, ($scrollTop + 565))
    $btnQuit.Size = New-Object System.Drawing.Size(110, 34)
    $btnQuit.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnQuit)

    $form.AcceptButton = $btnRun
    $form.CancelButton = $btnQuit
    $form.ClientSize = New-Object System.Drawing.Size(535, ($scrollTop + 615))

    $result = $form.ShowDialog()
    $form.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $selected = @()
    # Walk $script:AppManifest -- NOT $checkboxByApp.Keys -- to build the
    # selection. .NET Dictionaries don't guarantee enumeration order
    # matches insertion order (it usually happens to in practice, but
    # that's an implementation detail, not a contract). That was a
    # low-stakes gap before (it only affected soft ordering, like .NET 8
    # installing before Dell Command Update), but it stops being
    # low-stakes once the manifest includes things like domain join and
    # a reboot -- a reboot firing mid-queue instead of at the end because
    # of an unguaranteed enumeration order would be a real problem, not
    # just a cosmetic one. $script:AppManifest is a plain array, so its
    # order is guaranteed and matches exactly what's documented in the
    # manifest comments below.
    foreach ($app in $script:AppManifest) {
        if ($checkboxByApp.ContainsKey($app) -and $checkboxByApp[$app].Checked) {
            $selected += $app
        }
    }
    return $selected
}

# ---------------------------------------------------------------------------
# GUI stage 2: progress screen. Runs the actual installs on a background
# runspace so the window stays responsive, and polls a thread-safe queue to
# stream each script's log lines into the textbox live.
# ---------------------------------------------------------------------------
function Show-ProgressGui {
    param(
        [Parameter(Mandatory)][array]$Apps,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$StagingDir,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$Branch,
        [bool]$UseLocal = $false,
        [string]$LocalRoot = '',
        [string]$ResumeStateFile = '',
        [string]$ResumeTaskName = '',
        [string]$SelfScriptPath = ''
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # --- Thread-safe state shared between the UI thread and the worker runspace ---
    $logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $state = [hashtable]::Synchronized(@{
        CurrentApp    = ''
        Index         = 0
        Total         = $Apps.Count
        AppDone       = $false
        AllDone       = $false
        FinalExitCode = 0
    })

    # --- Background runspace that does the actual installing ---
    # CONFIRMED ROOT CAUSE OF A REAL FREEZE, VIA REAL TEST LOGS: this
    # runspace was created without ever setting ApartmentState, which
    # means it defaulted to MTA (Multi-Threaded Apartment). WinForms
    # fundamentally requires STA threading, and creating/showing a Form
    # (Show-CredentialDialog / Show-ShareCredentialDialog, both of which
    # run inside THIS runspace via .ShowDialog()) from an MTA thread is a
    # well-documented source of instability -- it can corrupt or freeze
    # the OTHER thread's WinForms message pump (the main progress window
    # on the main STA thread) while the actual script execution
    # underneath keeps running fine, since the freeze is in the UI layer,
    # not the PowerShell execution itself. This exactly matches a real
    # report: the progress window froze right at Join Domain (the first
    # point a WinForms dialog gets shown from this runspace), while the
    # console/log kept showing installs actually completing underneath.
    # Fixed by explicitly setting STA before opening, matching the main
    # thread's own apartment state (the whole process is launched with
    # -STA in Apps-Deploy-Menu.bat).
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace

    $workerScript = {
        param($Apps, $LogPath, $StagingDir, $RepoOwner, $RepoName, $Branch, $QueueRef, $StateRef, $UseLocal, $LocalRoot, $ResumeStateFile, $ResumeTaskName, $SelfScriptPath)

        # $Global:RWWQueue (not just a local variable) so that Write-Log calls
        # inside downloaded child scripts -- which may be many function-call
        # levels deep in a totally different script file -- can still find it.
        # PowerShell scriptblocks resolve variables dynamically from the
        # CALLER's scope chain when invoked with &, not from where they were
        # originally defined, so anything short of Global scope would silently
        # fail to resolve from inside those child scripts.
        $Global:RWWQueue = $QueueRef
        $Global:RWWLogSink = { param($line) $Global:RWWQueue.Enqueue($line) }

        function Write-WorkerLog {
            param([string]$Message, [string]$Level = 'INFO')
            $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
            $Global:RWWQueue.Enqueue($line)
            try {
                $dir = Split-Path -Path $LogPath -Parent
                if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
                Add-Content -Path $LogPath -Value $line
            } catch {}
        }

        # Deferred, just-in-time share-credential prompting. This used to
        # run once up front in Main, before any app in the run even
        # started -- meaning a tech got prompted for share credentials
        # immediately, then had to sit through Enable Administrator
        # Account, Change Computer Name, Join Domain (including its own
        # separate credential prompt and the mid-run reboot it can
        # trigger), and Remove OEM Bloatware before the share access was
        # actually used for anything. Moved here so it only fires right
        # before the FIRST app in the remaining queue that actually needs
        # it -- which naturally also handles the mid-run reboot case
        # correctly on its own: the resumed session is a fresh process,
        # so its own net use session doesn't exist yet either, and this
        # will correctly re-prompt right before whichever remaining app
        # needs it first, with no special-casing required.
        #
        # Uses a custom WinForms dialog, not Get-Credential -- this runs
        # inside the background install runspace (created via
        # [runspacefactory]::CreateRunspace() in Show-ProgressGui), which
        # gets a minimal default PowerShell host with no credential-
        # prompting support. Get-Credential depends on $Host implementing
        # that and fails here with "the host program... does not support
        # user interaction" -- confirmed in testing for the identical
        # issue in DomainJoinInst.ps1. This dialog doesn't depend on
        # $Host at all, so it works fine from this same runspace.
        function Show-ShareCredentialDialog {
            param([string]$Message)

            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing

            $form = New-Object System.Windows.Forms.Form
            $form.Text = 'Network Share Credentials'
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
            $txtUser.Text = 'RPSINC\'
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

        function Request-ShareAccessIfNeededInWorker {
            param([Parameter(Mandatory)][array]$SelectedApps)

            $needsShare = @($SelectedApps | Where-Object { $_.NeedsShareCredentials })
            if ($needsShare.Count -eq 0) {
                return $true
            }

            $appNames = ($needsShare | ForEach-Object { $_.Name }) -join ', '
            Write-WorkerLog "The following remaining app(s) need access to \\svazdfs001\systems`$: $appNames"

            $sharePaths  = @('\\svazdfs001\systems$', '\\10.1.0.5\systems$')
            $maxAttempts = 3

            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                $cred = Show-ShareCredentialDialog -Message "Enter AD credentials (e.g. DOMAIN\username) with access to \\svazdfs001\systems$ -- needed for: $appNames"
                if (-not $cred) {
                    Write-WorkerLog "Credential prompt was cancelled (attempt $attempt/$maxAttempts)." 'WARN'
                    continue
                }

                $anySucceeded = $false
                foreach ($path in $sharePaths) {
                    try {
                        Start-Process -FilePath 'net.exe' -ArgumentList @('use', $path, '/delete', '/y') `
                            -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null

                        $netUseArgs = @('use', $path, "/user:$($cred.UserName)", $cred.GetNetworkCredential().Password, '/persistent:no')
                        $proc = Start-Process -FilePath 'net.exe' -ArgumentList $netUseArgs -Wait -PassThru -NoNewWindow
                        if ($proc.ExitCode -eq 0) {
                            Write-WorkerLog "Authenticated to $path successfully."
                            $anySucceeded = $true
                        } else {
                            Write-WorkerLog "Could not authenticate to $path (net use exit $($proc.ExitCode))." 'WARN'
                        }
                    } catch {
                        Write-WorkerLog "Error attempting to authenticate to $path : $($_.Exception.Message)" 'WARN'
                    }
                }

                if ($anySucceeded) {
                    return $true
                }

                Write-WorkerLog "Credential attempt $attempt/$maxAttempts failed for both share paths." 'WARN'
            }

            $failMessage = "Could not establish access to \\svazdfs001\systems$ after $maxAttempts attempts (wrong credentials, cancelled, or the share is genuinely unreachable). Aborting -- remaining apps needing the share ($appNames) would only fail anyway."
            Write-WorkerLog $failMessage 'ERROR'

            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                $failMessage, 'rww-installers - Share access failed',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null

            return $false
        }

        function Invoke-RemoteInstallScript {
            param(
                [Parameter(Mandatory)][string]$RepoPath,
                [string[]]$ScriptArgs = @()
            )

            if ($UseLocal) {
                # Local test mode: run straight from disk, relative to this
                # menu script's own folder -- e.g. RepoPath
                # 'Scripts/WorkstationDeployment/AppsDeployScripts/CWAgentInst.ps1'
                # becomes '<LocalRoot>\AppsDeployScripts\CWAgentInst.ps1'.
                # No GitHub involved at all.
                $relative = $RepoPath -replace '^Scripts/WorkstationDeployment/', ''
                $localScriptPath = Join-Path $LocalRoot ($relative -replace '/', '\')
                if (-not (Test-Path $localScriptPath)) {
                    Write-WorkerLog "[LOCAL TEST] Script not found: $localScriptPath" 'ERROR'
                    return 2
                }
                Write-WorkerLog "[LOCAL TEST] Running $localScriptPath (no download, no GitHub)"
                try {
                    & $localScriptPath @ScriptArgs
                    return $LASTEXITCODE
                } catch {
                    Write-WorkerLog "$localScriptPath threw an unhandled error: $($_.Exception.Message)" 'ERROR'
                    return 1
                }
            }

            $fileName  = Split-Path -Path $RepoPath -Leaf
            $localPath = Join-Path $StagingDir $fileName
            $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/$RepoPath"
            try {
                if (-not (Test-Path $StagingDir)) { New-Item -Path $StagingDir -ItemType Directory -Force | Out-Null }
                Write-WorkerLog "Fetching $url"
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $url -OutFile $localPath -UseBasicParsing
            } catch {
                Write-WorkerLog "Failed to download $fileName from GitHub: $($_.Exception.Message)" 'ERROR'
                Write-WorkerLog "If this is a fresh/pre-domain machine, check that the TLS inspection proxy's root cert is trusted, and that raw.githubusercontent.com is reachable." 'ERROR'
                return 2
            }
            try {
                & $localPath @ScriptArgs
                return $LASTEXITCODE
            } catch {
                Write-WorkerLog "$fileName threw an unhandled error: $($_.Exception.Message)" 'ERROR'
                return 1
            }
        }

        try {
            Write-WorkerLog "=== Apps-Deploy-Menu install run starting ==="
            Write-WorkerLog ("Selected: " + (($Apps | ForEach-Object { $_.Name }) -join ', '))

            # If both Change Computer Name and Join Domain are selected in
            # the SAME run, they need to coordinate: renaming a machine
            # takes a restart to actually apply, and joining a domain
            # before that restart would create the AD computer object
            # under the OLD name -- a mismatch that isn't simple to
            # correct after the fact. Rather than each script guessing
            # whether the other one is also running, decide it once here
            # (this is the only place with full visibility into the whole
            # selected list) and share the answer via Global scope, the
            # same pattern already used for $Global:RWWLogSink. When both
            # are selected, ChangeComputerNameInst.ps1 defers the actual
            # rename and DomainJoinInst.ps1 applies rename+join together
            # in one Add-Computer call -- the Microsoft-documented correct
            # way to do both at once.
            $Global:RWWCombineRenameAndJoin = [bool](
                ($Apps | Where-Object { $_.Name -eq 'Change Computer Name' }) -and
                ($Apps | Where-Object { $_.Name -eq 'Join Domain (rpsinc.ringpinion.com)' })
            )
            if ($Global:RWWCombineRenameAndJoin) {
                Write-WorkerLog "Both 'Change Computer Name' and 'Join Domain' are selected -- they'll coordinate to rename+join in a single combined step."
            }

            $results = @()
            $i = 0
            $shareCredentialsHandled = $false
            foreach ($app in $Apps) {
                $i++
                $StateRef.Index = $i
                $StateRef.CurrentApp = $app.Name
                $StateRef.AppDone = $false

                Write-WorkerLog ""
                Write-WorkerLog "--- $($app.Name) ($i of $($Apps.Count)) ---"

                if ($app.NeedsShareCredentials -and -not $shareCredentialsHandled) {
                    $shareCredentialsHandled = $true
                    # Include the CURRENT app in the "who needs this"
                    # message, not just what comes after it -- $i is
                    # already this app's own 1-based position at this
                    # point in the loop, so ($i-1) is its 0-based index.
                    $upcomingShareApps = @($Apps[($i - 1)..($Apps.Count - 1)] | Where-Object { $_.NeedsShareCredentials })
                    $shareOk = Request-ShareAccessIfNeededInWorker -SelectedApps $upcomingShareApps
                    if (-not $shareOk) {
                        Write-WorkerLog "Aborting run -- share credentials could not be established. See error above." 'ERROR'
                        $StateRef.FinalExitCode = 7
                        $StateRef.AllDone = $true
                        break
                    }
                }

                $code = Invoke-RemoteInstallScript -RepoPath $app.InstallRepoPath
                $ok = ($code -eq 0 -or $code -eq 4)   # 4 = "already installed", per existing scripts' convention
                if ($ok) {
                    Write-WorkerLog "$($app.Name) finished (exit $code)."
                } else {
                    Write-WorkerLog "$($app.Name) FAILED (exit $code). Check its own log under $StagingDir\Logs." 'ERROR'
                }
                $results += [pscustomobject]@{ Name = $app.Name; Result = if ($ok) { 'OK' } else { 'FAILED' }; Code = $code }

                $StateRef.AppDone = $true
                Start-Sleep -Milliseconds 500   # let the UI actually show the "filled" state before resetting

                # Change Computer Name + Join Domain together need a REAL
                # reboot to actually take effect (unlike everything else in
                # this project, which just logs a "restart needed" warning
                # and keeps going) -- the combined Add-Computer -NewName
                # call only stages both changes; nothing about the new name
                # or domain membership is live until Windows restarts. So
                # rather than continue this session pretending both are
                # already in effect, reboot now and pick up any remaining
                # selected apps automatically afterward via a one-time
                # "at logon" Scheduled Task.
                if ($app.Name -eq 'Join Domain (rpsinc.ringpinion.com)' -and $ok -and $Global:RWWCombineRenameAndJoin) {
                    $remainingApps = @($Apps[$i..($Apps.Count - 1)])
                    if ($remainingApps.Count -gt 0) {
                        Write-WorkerLog ""
                        Write-WorkerLog "Change Computer Name + Join Domain both completed -- a restart is required for the new name and domain membership to actually take effect."
                        Write-WorkerLog ("Remaining selected app(s) will resume automatically after logging back in: " + (($remainingApps | ForEach-Object { $_.Name }) -join ', '))

                        try {
                            $remainingApps | ForEach-Object { $_.Name } | Set-Content -LiteralPath $ResumeStateFile -Encoding UTF8 -ErrorAction Stop

                            $resumeAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                                -Argument "-NoProfile -STA -ExecutionPolicy Bypass -File `"$SelfScriptPath`" -ResumeAfterReboot"
                            $resumeTrigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
                            $resumePrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
                            $resumeSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

                            Register-ScheduledTask -TaskName $ResumeTaskName -Action $resumeAction -Trigger $resumeTrigger `
                                -Principal $resumePrincipal -Settings $resumeSettings -Force -ErrorAction Stop | Out-Null

                            Write-WorkerLog "Registered resume task '$ResumeTaskName' for user '$env:USERNAME' at next logon."
                        } catch {
                            Write-WorkerLog "Failed to set up automatic resume: $($_.Exception.Message)" 'ERROR'
                            Write-WorkerLog "The remaining apps listed above will need to be selected manually after restarting." 'ERROR'
                        }

                        # Skip the manual "press Enter at the lock screen"
                        # step for a passwordless throwaway account, ONLY
                        # for this one reboot cycle. Deliberately narrow
                        # and self-cleaning: this is the OPPOSITE of the
                        # AutoAdminLogon DISABLE in RemoveThrowawayAccountInst.ps1
                        # (which exists specifically because AutoAdminLogon
                        # racing against that task's "at startup" trigger
                        # was a confirmed real bug) -- enabling it here is
                        # safe specifically because it gets disabled again
                        # immediately when the resumed session starts back
                        # up (see the -ResumeAfterReboot handling in Main),
                        # before continuing with the rest of the queue.
                        # That keeps the passwordless auto-login window
                        # open for exactly one reboot cycle, regardless of
                        # whether Remove Throwaway Setup Account is even
                        # selected in this run -- it never lingers on the
                        # machine afterward.
                        try {
                            $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
                            Set-ItemProperty -Path $winlogonKey -Name 'AutoAdminLogon' -Value '1' -ErrorAction Stop
                            Set-ItemProperty -Path $winlogonKey -Name 'DefaultUserName' -Value $env:USERNAME -ErrorAction Stop
                            # No DefaultPassword set -- the throwaway
                            # account has no password, and Windows
                            # correctly auto-logs-on with a blank password
                            # when the target account genuinely has none.
                            Write-WorkerLog "Enabled a one-time auto-login as '$env:USERNAME' for this reboot only (will be disabled again immediately on resume)."
                        } catch {
                            Write-WorkerLog "Could not enable auto-login for this reboot -- the lock screen will need a manual Enter press as before: $($_.Exception.Message)" 'WARN'
                        }

                        Write-WorkerLog "Restarting in 20 seconds..." 'WARN'
                        $StateRef.FinalExitCode = 0
                        $StateRef.AllDone = $true
                        Start-Sleep -Seconds 20
                        try {
                            Restart-Computer -Force -ErrorAction Stop
                        } catch {
                            Write-WorkerLog "Restart-Computer failed: $($_.Exception.Message)" 'ERROR'
                        }
                        break
                    }
                }
            }

            Write-WorkerLog ""
            Write-WorkerLog "=== Summary ==="
            foreach ($r in $results) {
                Write-WorkerLog ("{0,-35} {1}" -f $r.Name, $r.Result)
            }

            $anyFailed = $results | Where-Object { $_.Result -eq 'FAILED' }
            if ($anyFailed) {
                Write-WorkerLog "One or more apps failed. See log at $LogPath" 'ERROR'
                $StateRef.FinalExitCode = 1
            } else {
                Write-WorkerLog "Run complete."
                $StateRef.FinalExitCode = 0
            }
        } catch {
            Write-WorkerLog "Unhandled error in install run: $($_.Exception.Message)" 'ERROR'
            $StateRef.FinalExitCode = 1
        } finally {
            $StateRef.AllDone = $true
        }
    }

    [void]$ps.AddScript($workerScript)
    [void]$ps.AddArgument($Apps)
    [void]$ps.AddArgument($LogPath)
    [void]$ps.AddArgument($StagingDir)
    [void]$ps.AddArgument($RepoOwner)
    [void]$ps.AddArgument($RepoName)
    [void]$ps.AddArgument($Branch)
    [void]$ps.AddArgument($logQueue)
    [void]$ps.AddArgument($state)
    [void]$ps.AddArgument($UseLocal)
    [void]$ps.AddArgument($LocalRoot)
    [void]$ps.AddArgument($ResumeStateFile)
    [void]$ps.AddArgument($ResumeTaskName)
    [void]$ps.AddArgument($SelfScriptPath)

    $asyncResult = $ps.BeginInvoke()

    # --- Progress form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($UseLocal) { 'rww-installers - Installing (LOCAL TEST MODE)' } else { 'rww-installers - Installing' }
    $form.Size = New-Object System.Drawing.Size(1280, 680)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox = $true
    $form.MinimizeBox = $true
    $form.MinimumSize = New-Object System.Drawing.Size(760, 420)
    $form.ControlBox = $false

    # Same foreground-focus fix as the selection window -- see its comment
    # for why this is needed.
    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        $form.TopMost = $false
    })

    # Alt+F4 is intentionally left enabled (no FormClosing cancellation) --
    # technicians running this need a way to force-kill a stuck/hung run.
    # ControlBox stays $false (no visible titlebar close/min/max buttons,
    # "Close" is its own button below, disabled until installs finish) but
    # Alt+F4 still works as a normal OS-level accelerator regardless of
    # ControlBox. Closing mid-install orphans the background runspace, but
    # the cleanup code after ShowDialog() below already handles that --
    # $ps.Stop() runs if the runspace hasn't finished when the form closes
    # for any reason, Alt+F4 included.

    $lblCurrent = New-Object System.Windows.Forms.Label
    $lblCurrent.Location = New-Object System.Drawing.Point(15, 15)
    $lblCurrent.Size = New-Object System.Drawing.Size(1240, 20)
    $lblCurrent.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lblCurrent.Font = New-Object System.Drawing.Font($lblCurrent.Font, [System.Drawing.FontStyle]::Bold)
    $lblCurrent.Text = 'Starting...'
    $form.Controls.Add($lblCurrent)

    $barCurrent = New-Object System.Windows.Forms.ProgressBar
    $barCurrent.Location = New-Object System.Drawing.Point(15, 40)
    $barCurrent.Size = New-Object System.Drawing.Size(1240, 24)
    $barCurrent.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    # NOT using the native 'Marquee' style here -- see the Timer.Tick
    # handler below for why. Continuous style + a manually-driven bounce
    # gives the same "actively working" visual without relying on the
    # native marquee's own separate internal animation mechanism.
    $barCurrent.Style = 'Continuous'
    $barCurrent.Minimum = 0
    $barCurrent.Maximum = 100
    $barCurrent.Value = 0
    $form.Controls.Add($barCurrent)

    $lblOverall = New-Object System.Windows.Forms.Label
    $lblOverall.Location = New-Object System.Drawing.Point(15, 72)
    $lblOverall.Size = New-Object System.Drawing.Size(1240, 18)
    $lblOverall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lblOverall.Text = "App 0 of $($Apps.Count)"
    $form.Controls.Add($lblOverall)

    $barOverall = New-Object System.Windows.Forms.ProgressBar
    $barOverall.Location = New-Object System.Drawing.Point(15, 92)
    $barOverall.Size = New-Object System.Drawing.Size(1240, 18)
    $barOverall.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $barOverall.Minimum = 0
    $barOverall.Maximum = [Math]::Max($Apps.Count, 1)
    $barOverall.Value = 0
    $form.Controls.Add($barOverall)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point(15, 120)
    $txtLog.Size = New-Object System.Drawing.Size(1240, 460)
    $txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = 'Both'
    $txtLog.WordWrap = $false
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.BackColor = [System.Drawing.Color]::Black
    $txtLog.ForeColor = [System.Drawing.Color]::LightGray
    $form.Controls.Add($txtLog)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'
    $btnClose.Location = New-Object System.Drawing.Point(1165, 590)
    $btnClose.Size = New-Object System.Drawing.Size(90, 30)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Enabled = $false
    $form.Controls.Add($btnClose)
    $btnClose.Add_Click({ $form.Close() })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $script:barDirection = 1
    $timer.Add_Tick({
        try {
            $line = $null
            $appended = $false
            while ($logQueue.TryDequeue([ref]$line)) {
                $txtLog.AppendText($line + "`r`n")
                $appended = $true
            }
            if ($appended) {
                $txtLog.SelectionStart = $txtLog.Text.Length
                $txtLog.ScrollToCaret()
            }

            if ($state.Index -gt 0) {
                $lblCurrent.Text = "Installing: $($state.CurrentApp)"
                $lblOverall.Text = "App $($state.Index) of $($state.Total)"
            }

            if ($state.AppDone) {
                $barCurrent.Value = 100
                $barOverall.Value = [Math]::Min($state.Index, $barOverall.Maximum)
            } else {
                # Manually-driven bounce instead of the native 'Marquee'
                # style -- see the ProgressBar setup above for why. Simple
                # back-and-forth sweep between 0 and 100, driven by this
                # same reliable timer rather than a separate native
                # animation mechanism.
                $next = $barCurrent.Value + (5 * $script:barDirection)
                if ($next -ge 100) { $next = 100; $script:barDirection = -1 }
                if ($next -le 0) { $next = 0; $script:barDirection = 1 }
                $barCurrent.Value = $next
            }

            if ($state.AllDone) {
                $timer.Stop()
                if ($state.FinalExitCode -eq 0) {
                    $lblCurrent.Text = 'All selected apps finished successfully.'
                } else {
                    $lblCurrent.Text = 'Finished with one or more failures -- see log above.'
                    $lblCurrent.ForeColor = [System.Drawing.Color]::Firebrick
                }
                $barCurrent.Value = 100
                $barOverall.Value = $barOverall.Maximum
                $btnClose.Enabled = $true
            }
        } catch {
            # Defensive only -- an unhandled exception here could
            # otherwise silently stop this Timer (and therefore the
            # entire visible progress display) without any indication
            # why, which is indistinguishable from a real freeze to
            # whoever's watching. Swallowing and continuing keeps the
            # display alive even if one tick's update has a problem;
            # written directly to a fixed path (not through Write-Log)
            # since if the UI layer itself is having trouble, that's
            # exactly the wrong moment to depend on more UI-thread state.
            try {
                Add-Content -Path "$env:ProgramData\Dev\AppsDeploy\Logs\Apps-Deploy-Menu-GuiTimerErrors.log" `
                    -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $($_.Exception.Message)" -ErrorAction SilentlyContinue
            } catch {}
        }
    })
    $timer.Start()

    [void]$form.ShowDialog()
    $timer.Stop()
    $form.Dispose()

    # --- Clean up the background runspace ---
    try {
        if (-not $asyncResult.IsCompleted) { $ps.Stop() }
        $ps.EndInvoke($asyncResult) | Out-Null
    } catch {}
    $ps.Dispose()
    $runspace.Close()
    $runspace.Dispose()

    return $state.FinalExitCode
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Log "=== Apps-Deploy-Menu starting on $env:COMPUTERNAME ==="

if ($ResumeAfterReboot.IsPresent) {
    Write-Log "Resuming a deployment run interrupted by a mid-run reboot (Change Computer Name + Join Domain)."

    # Close the one-time auto-login window immediately -- it was enabled
    # for exactly this one reboot cycle (see the worker script's
    # combined-reboot block), and needs to be turned back off right away
    # regardless of whether Remove Throwaway Setup Account is even
    # selected in this run, so a passwordless auto-login never lingers on
    # the machine longer than the single reboot it was needed for.
    try {
        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonKey -Name 'AutoAdminLogon' -Value '0' -ErrorAction Stop
        Write-Log "Disabled the one-time auto-login now that it's served its purpose."
    } catch {
        Write-Log "Could not disable auto-login after resuming (non-fatal, but worth checking manually): $($_.Exception.Message)" 'WARN'
    }

    # Self-unregister first, before doing anything else -- an "at logon"
    # trigger fires on EVERY logon, not just this one, so this needs to
    # stop existing the moment it's actually consumed, regardless of what
    # happens next (success or failure below).
    try {
        Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false -ErrorAction Stop
        Write-Log "Self-unregistered the resume scheduled task."
    } catch {
        Write-Log "Could not unregister the resume scheduled task (may already be gone): $($_.Exception.Message)" 'WARN'
    }

    if (-not (Test-Path -LiteralPath $script:ResumeStateFile -ErrorAction SilentlyContinue)) {
        Write-Log "No pending-resume state file found at $script:ResumeStateFile -- nothing to resume." 'ERROR'
        exit 6
    }

    $pendingNames = Get-Content -LiteralPath $script:ResumeStateFile -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if (-not $pendingNames -or $pendingNames.Count -eq 0) {
        Write-Log "Pending-resume state file was empty -- nothing to resume." 'WARN'
        Remove-Item -LiteralPath $script:ResumeStateFile -Force -ErrorAction SilentlyContinue
        exit 6
    }

    # Look up each saved name against the (freshly rebuilt) manifest above,
    # in the SAME order the names were saved in -- that order is already
    # correct, since it was taken as a straight slice of the original,
    # correctly-ordered selection.
    $selected = @()
    foreach ($name in $pendingNames) {
        $match = $script:AppManifest | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($match) {
            $selected += $match
        } else {
            Write-Log "Pending app '$name' no longer exists in the manifest -- skipping it." 'WARN'
        }
    }

    Remove-Item -LiteralPath $script:ResumeStateFile -Force -ErrorAction SilentlyContinue

    if ($selected.Count -eq 0) {
        Write-Log "Nothing left to resume after filtering against the current manifest." 'WARN'
        exit 6
    }

    Write-Log ("Resuming with: " + (($selected | ForEach-Object { $_.Name }) -join ', '))

    Write-Log "Checking network/DNS readiness before proceeding -- a freshly domain-joined machine's DNS can take a moment to fully settle right after this specific reboot."
    if (Wait-ForNetworkReadiness) {
        Write-Log "Network/DNS confirmed ready."
    } else {
        Write-Log "Network/DNS still not confirmed ready after the wait -- proceeding anyway, but this may explain a network-timing-related failure if one occurs early in this run." 'WARN'
    }
} else {
    $selected = Show-SelectionGui -StartBlank:$StartBlank.IsPresent

    if ($null -eq $selected) {
        Write-Log "User quit without installing anything."
        exit 6
    }
    if ($selected.Count -eq 0) {
        Write-Log "Nothing was selected. Exiting."
        exit 6
    }
}

$exitCode = Show-ProgressGui -Apps $selected -LogPath $LogPath -StagingDir $StagingDir `
    -RepoOwner $RepoOwner -RepoName $RepoName -Branch $Branch -UseLocal:$Local.IsPresent -LocalRoot $script:LocalRoot `
    -ResumeStateFile $script:ResumeStateFile -ResumeTaskName $script:ResumeTaskName -SelfScriptPath $script:SelfScriptPath

exit $exitCode
