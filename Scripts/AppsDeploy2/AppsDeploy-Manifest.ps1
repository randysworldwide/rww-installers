#Requires -Version 5.1
<#
.SYNOPSIS
    AppsDeploy v2 -- shared application manifest. Dot-sourced by BOTH the
    UI process (for detection scans) and the worker process (for actions).

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/AppsDeploy2/AppsDeploy-Manifest.ps1

    REDESIGN NOTE: unlike v1's 65 per-app script files, v2 is
    manifest-driven. Each app declares:

      Name        - display name (unique key)
      Category    - selection-UI grouping
      Detect      - scriptblock returning $true/$false. Used three ways:
                    the UI's pre-check scan (installed = box starts
                    checked), the worker's pre-action skip guard, and
                    the worker's post-action verification. Detection IS
                    the ground truth everywhere -- exit codes never
                    outrank it.
      Install     - action spec (see engines below)
      Uninstall   - action spec
      Notes       - optional tooltip text

    ACTION ENGINES (worker implements these generically):
      @{ Engine='Winget';  Id='<winget id>' }
          silent:      winget install/uninstall --id <Id> -e --silent ...
          interactive: same with --interactive instead of --silent
      @{ Engine='Msi';     Url='<direct url>'; Properties='<extra props>' }
          downloads the MSI, msiexec /i ... (/qn when silent). Install only.
      @{ Engine='MsiRegistry'; DisplayNameLike='<pattern>' }
          finds the ARP entry, extracts {ProductCode}, msiexec /x with
          MSIRESTARTMANAGERCONTROL=Disable (prevents the confirmed
          Restart Manager explorer-kill behavior). Uninstall only.
      @{ Engine='Custom';  Script={ param($Context) ... } }
          escape hatch for the complex ports to come (ZAC, Office/ODT,
          SentinelOne passphrase, share-based installs). $Context carries
          Interactive, Log (scriptblock), and StageDir.

    v1 SCOPE: three apps, every engine/path proven in real RWW logs --
    Chrome's direct-MSI install (replaced winget after a confirmed
    manifest-hash failure), and winget install+uninstall for VLC and
    7-Zip (both succeeded in real test runs). The remaining ~23 apps
    port in after the architecture is bench-validated.
#>

# Display order of the category cards in the menu: LAYERS, foundation
# first (Aaron's model) -- base runtimes every PC can carry, then the
# agents every company machine needs, then Office, then the per-user
# layers, with rarely-needed Development last. Edit freely: a category
# missing from this list falls to the end (alphabetically). Apps inside
# each category always sort by name -- the entries below can stay in
# any order.
$script:CategoryOrder = @(
    'Runtimes',
    'Agents',
    'Microsoft Office',
    'Communications',
    'Browsers',
    'Utilities',
    'Development'
)

# Profiles: named pre-selection sets. Choosing one in the menu CHECKS
# the listed apps (on top of whatever the machine already has) -- it
# never unchecks anything, and the desired-state diff still decides
# what actually runs, so already-installed apps are simply kept. App
# names must match the manifest Names exactly; the menu calls out any
# that do not. Add profiles freely.
$script:Profiles = @(
    @{
        Name = 'Standard'
        Apps = @(
            '.NET Desktop Runtime 10',
            'Java (Temurin JRE)',
            'Visual C++ Redistributables',
            'Cisco Secure Client (VPN)',
            'ConnectWise Automate Agent',
            'Office (Microsoft 365)',
            'ZAC',
            'Google Chrome',
            'Adobe Acrobat Reader',
            'Dell Command Update',
            'VLC Media Player',
            'Windows App',
            'Windows Terminal',
            'Microsoft VS Code'
        )
    }
    @{
        Name = 'Developer'
        Apps = @(
            '.NET Desktop Runtime 10',
            'Java (Temurin JRE)',
            'Visual C++ Redistributables',
            'Cisco Secure Client (VPN)',
            'ConnectWise Automate Agent',
            'Office (Microsoft 365)',
            'MXAdmin',
            'ZAC',
            'Google Chrome',
            'Mozilla Firefox',
            '7-Zip',
            'Adobe Acrobat Reader',
            'Claude',
            'Dell Command Update',
            'VLC Media Player',
            'Windows App',
            'Windows Terminal',
            'Git',
            'GitHub CLI',
            'Microsoft VS Code',
            'Node.js'
        )
    }
)

$script:AppManifest = @(
    @{
        Name     = '7-Zip'
        Category = 'Utilities'
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '7-Zip*' })
        }
        Install   = @{ Engine = 'Winget'; Id = '7zip.7zip' }
        Uninstall = @{ Engine = 'Winget'; Id = '7zip.7zip' }
        Notes     = 'File archiver. Has a shell extension -- the worker watches for the known Restart Manager explorer-kill on uninstall and recovers it.'
    }
    @{
        Name     = 'VLC Media Player'
        Category = 'Utilities'
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'VLC media player*' })
        }
        # One engine per action, by design: this either installs
        # silently or fails visibly, and a tech re-runs interactively if
        # it keeps failing. (If winget itself is broken on a machine --
        # 0x8A15000F that survives a source update -- fix the machine:
        # winget source reset --force.)
        Install   = @{ Engine = 'Winget'; Id = 'VideoLAN.VLC' }
        # Registry (not Winget) on purpose: winget's 'silent' VLC
        # uninstall pops the NSIS 'Installer Language' dialog and removes
        # nothing (CONFIRMED on WSTEST001), while the registered
        # uninstall.exe /S is silent and works (CONFIRMED on two machines).
        Uninstall = @{ Engine = 'Registry'; DisplayNameLike = 'VLC media player*' }
        Notes     = 'Media player.'
    }
    @{
        Name     = 'Google Chrome'
        Category = 'Browsers'
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Google Chrome*' })
        }
        # Direct Enterprise MSI from Google's own endpoint -- NOT winget.
        # Confirmed necessary in real testing: winget's community manifest
        # hash lagged Google's evergreen installer and failed every
        # attempt; this replacement then worked on real machines.
        Install   = @{ Engine = 'Msi'; Url = 'https://dl.google.com/chrome/install/GoogleChromeStandaloneEnterprise64.msi'; Properties = 'ALLUSERS=1' }
        Uninstall = @{ Engine = 'MsiRegistry'; DisplayNameLike = 'Google Chrome*' }
        Notes     = 'Installs from Google''s official Enterprise MSI endpoint (winget''s manifest hash proved unreliable for Chrome).'
    }
    @{
        Name     = 'Mozilla Firefox'
        Category = 'Browsers'
        Detect   = {
            # ARP name embeds version/locale ('Mozilla Firefox (x64
            # en-US)'), hence the wildcard. Nothing else starts with
            # 'Mozilla Firefox'.
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Mozilla Firefox*' })
        }
        Install   = @{ Engine = 'Winget'; Id = 'Mozilla.Firefox' }
        # Registry (not Winget) on purpose: winget's 'silent' Firefox
        # uninstall launches helper.exe in full WIZARD mode and exits 0
        # without removing anything (CONFIRMED on WSTEST001 -- same class
        # as VLC). The Registry engine runs the registered helper.exe
        # with NSIS /S, Mozilla's documented silent uninstall.
        Uninstall = @{ Engine = 'Registry'; DisplayNameLike = 'Mozilla Firefox*' }
        Notes     = 'Firefox rapid-release channel, machine-wide. Self-updates once installed.'
    }
    @{
        Name     = 'Microsoft VS Code'
        Category = 'Development'
        Detect   = {
            # HKLM only, like every Detect here: this tool installs
            # machine-wide (--scope machine picks VS Code's System
            # setup). A per-user VS Code lives in HKCU and is invisible
            # on purpose -- we neither own it nor can safely remove it
            # from another user's profile.
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Microsoft Visual Studio Code*' })
        }
        Install   = @{ Engine = 'Winget'; Id = 'Microsoft.VisualStudioCode' }
        # Registry (not Winget) on purpose: winget runs VS Code's Inno
        # quiet string (/SILENT), which flashes an uninstall progress
        # window (CONFIRMED on WSTEST001). The Registry engine's Inno
        # tier uses /VERYSILENT -- fully invisible.
        Uninstall = @{ Engine = 'Registry'; DisplayNameLike = 'Microsoft Visual Studio Code*' }
        Notes     = 'Machine-wide (System) setup, not the per-user installer.'
    }
    @{
        Name     = 'Windows Terminal'
        Category = 'Utilities'
        # MSIX/Store-packaged app, so all three legs differ from the
        # registry-based pattern:
        #  - Detect: packaged apps never appear in ARP; Get-AppxPackage
        #    -AllUsers is the machine-level truth (we always run elevated).
        #  - Install: MSIX has no machine-wide installer, so winget runs
        #    WITHOUT --scope machine; the app installs for the account
        #    running the tool. Preinstalled on Win11, so this mostly
        #    stays checked and skipped. Not installable as SYSTEM (no
        #    user context) -- it will fail visibly there.
        #  - Uninstall: winget would remove it for the current user only
        #    and -AllUsers detection would rightly still see it. Custom
        #    step removes it for ALL users and de-provisions it so new
        #    profiles do not get it back.
        Detect   = {
            [bool](Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue)
        }
        # Custom (not plain Winget) on purpose: a freshly installed
        # Terminal auto-launches itself with an idle shell (CONFIRMED
        # twice on WSTEST001). This runs the same winget install, then
        # watches ~15s and closes any Terminal process that appears.
        # That is safe BECAUSE this step only runs when detection said
        # Terminal was absent -- any Terminal process during the step is
        # the auto-launch, never a tech's own session.
        Install   = @{ Engine = 'Custom'; Script = {
            param($Context)
            $winget = Resolve-WinGet
            if (-not $winget) { & $Context.Log 'winget.exe could not be located.' 'ERROR'; return }
            $mode = if ($Context.Interactive) { '--interactive' } else { '--silent --disable-interactivity' }
            $code = Invoke-ProcessStep -FilePath $winget -Arguments "install --id Microsoft.WindowsTerminal -e $mode --accept-source-agreements --accept-package-agreements --source winget"
            if ($null -ne $code) { & $Context.Log "winget exit code: $code" }
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                $stray = @(Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue)
                if ($stray.Count -gt 0) {
                    & $Context.Log "Closing the Windows Terminal window that auto-opens after install."
                    foreach ($p in $stray) { try { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null } catch {} }
                    break
                }
            }
        } }
        Uninstall = @{ Engine = 'Custom'; Script = {
            param($Context)
            & $Context.Log "Removing the Windows Terminal package for all users..."
            Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue |
                Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Microsoft.WindowsTerminal' }
            if ($prov) {
                & $Context.Log "De-provisioning Windows Terminal so new user profiles do not receive it..."
                $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            }
        } }
        Notes     = 'Store-packaged (MSIX). Preinstalled on Windows 11; install is per-user by nature. Uninstall removes it for all users and de-provisions it.'
    }
    @{
        Name     = 'Windows App'
        Category = 'Utilities'
        # MSIX pattern (same as Windows Terminal). Identity gotcha: this
        # app grew out of the 'Windows 365' app, so its package identity
        # is historically MicrosoftCorporationII.Windows365, NOT
        # '...WindowsApp'. Detection matches BOTH candidate identities
        # EXACTLY -- never a '*WindowsApp*' wildcard, which would
        # false-positive on Microsoft.WindowsAppRuntime (preinstalled
        # everywhere). The first bench install proves which name is real:
        # 'verified by detection' only appears if one matched.
        Detect   = {
            [bool](Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('MicrosoftCorporationII.Windows365', 'MicrosoftCorporationII.WindowsApp') })
        }
        Install   = @{ Engine = 'Winget'; Id = 'Microsoft.WindowsApp'; MachineScope = $false }
        Uninstall = @{ Engine = 'Custom'; Script = {
            param($Context)
            & $Context.Log "Removing the Windows App package for all users..."
            Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('MicrosoftCorporationII.Windows365', 'MicrosoftCorporationII.WindowsApp') } |
                Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -in @('MicrosoftCorporationII.Windows365', 'MicrosoftCorporationII.WindowsApp') }
            if ($prov) {
                & $Context.Log "De-provisioning the Windows App so new user profiles do not receive it..."
                $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            }
        } }
        Notes     = 'Microsoft''s remote desktop / Windows 365 / AVD client (MSIX). Install is per-user by nature; uninstall removes it for all users and de-provisions it.'
    }
    @{
        Name     = 'Git'
        Category = 'Development'
        Detect   = {
            # DisplayName is EXACTLY 'Git' -- matched exactly on purpose.
            # A 'Git*' wildcard would also hit GitHub CLI, GitHub
            # Desktop, or GitKraken if present.
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Git' })
        }
        Install   = @{ Engine = 'Winget'; Id = 'Git.Git' }
        # Registry engine: Git is Inno Setup, and the Inno-first tier runs
        # unins000.exe /VERYSILENT (winget would use the /SILENT quiet
        # string, which shows a progress window -- same as VS Code).
        Uninstall = @{ Engine = 'Registry'; DisplayNameLike = 'Git' }
        Notes     = 'Git for Windows (Inno Setup; machine-wide).'
    }
    @{
        Name     = 'GitHub CLI'
        Category = 'Development'
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'GitHub CLI' })
        }
        Install   = @{ Engine = 'Winget'; Id = 'GitHub.cli' }
        Uninstall = @{ Engine = 'Winget'; Id = 'GitHub.cli' }
        Notes     = 'The gh command-line tool (MSI; machine-wide).'
    }
    @{
        Name     = 'Node.js'
        Category = 'Development'
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Node.js' })
        }
        # LTS channel on purpose: it is what production tooling targets
        # and receives fixes the longest. For the 'current' channel,
        # change the Id to OpenJS.NodeJS (both register ARP 'Node.js').
        Install   = @{ Engine = 'Winget'; Id = 'OpenJS.NodeJS.LTS' }
        Uninstall = @{ Engine = 'Winget'; Id = 'OpenJS.NodeJS.LTS' }
        Notes     = 'Node.js LTS (MSI; machine-wide). Includes npm.'
    }
    @{
        Name     = 'Visual C++ Redistributables'
        Category = 'Runtimes'
        # The full set still in active use on Windows 10/11: 2010, 2012,
        # 2013 and the unified 2015+ (2015-2022), each in x64 AND x86 --
        # eight packages behind one checkbox. 2005/2008 are end-of-life
        # (no security fixes) and deliberately excluded. Detection is
        # satisfied only when ALL eight are present. ARP naming differs
        # by era: 2010 is 'Visual C++ 2010  x64 Redistributable' (no
        # parentheses), 2012/2013 are 'Redistributable (x64)', 2015+ is
        # range-named ('2015-2022'), hence the per-version patterns.
        Detect   = {
            $arp = Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue
            $names = @($arp | ForEach-Object { $_.DisplayName } | Where-Object { $_ })
            # Each slot lists the acceptable name(s) for one runtime --
            # ANY match satisfies that slot. The unified 2015+ runtime
            # has TWO naming generations: range-named ('2015-2022') on
            # older installs, and 'v14'-named on current ones (CONFIRMED:
            # a fresh 14.52 install failed the range pattern).
            $slots = @(
                @('Microsoft Visual C++ 2010*x64*'),
                @('Microsoft Visual C++ 2010*x86*'),
                @('Microsoft Visual C++ 2012 Redistributable (x64)*'),
                @('Microsoft Visual C++ 2012 Redistributable (x86)*'),
                @('Microsoft Visual C++ 2013 Redistributable (x64)*'),
                @('Microsoft Visual C++ 2013 Redistributable (x86)*'),
                @('Microsoft Visual C++ 20??-20?? Redistributable (x64)*', 'Microsoft Visual C++ v14*x64*'),
                @('Microsoft Visual C++ 20??-20?? Redistributable (x86)*', 'Microsoft Visual C++ v14*x86*')
            )
            $all = $true
            foreach ($slot in $slots) {
                $hit = $false
                foreach ($p in $slot) {
                    if ($names | Where-Object { $_ -like $p }) { $hit = $true; break }
                }
                if (-not $hit) { $all = $false; break }
            }
            $all
        }
        # No --scope machine here: the older redists' winget manifests do
        # not declare a scope (they are machine-wide by nature), and the
        # flag would risk NO_APPLICABLE_INSTALLER refusals.
        Install   = @{ Engine = 'Custom'; Script = {
            param($Context)
            $winget = Resolve-WinGet
            if (-not $winget) { & $Context.Log 'winget.exe could not be located.' 'ERROR'; return }
            $mode = if ($Context.Interactive) { '--interactive' } else { '--silent --disable-interactivity' }
            $ids = @('Microsoft.VCRedist.2010.x64', 'Microsoft.VCRedist.2010.x86',
                     'Microsoft.VCRedist.2012.x64', 'Microsoft.VCRedist.2012.x86',
                     'Microsoft.VCRedist.2013.x64', 'Microsoft.VCRedist.2013.x86',
                     'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86')
            foreach ($id in $ids) {
                $code = Invoke-ProcessStep -FilePath $winget -Arguments "install --id $id -e $mode --accept-source-agreements --accept-package-agreements --source winget"
                if ($null -ne $code) { & $Context.Log "winget exit code (${id}): $code" }
            }
        } }
        Uninstall = @{ Engine = 'Custom'; Script = {
            param($Context)
            $winget = Resolve-WinGet
            if (-not $winget) { & $Context.Log 'winget.exe could not be located.' 'ERROR'; return }
            $mode = if ($Context.Interactive) { '--interactive' } else { '--silent --disable-interactivity' }
            $ids = @('Microsoft.VCRedist.2010.x64', 'Microsoft.VCRedist.2010.x86',
                     'Microsoft.VCRedist.2012.x64', 'Microsoft.VCRedist.2012.x86',
                     'Microsoft.VCRedist.2013.x64', 'Microsoft.VCRedist.2013.x86',
                     'Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86')
            foreach ($id in $ids) {
                $code = Invoke-ProcessStep -FilePath $winget -Arguments "uninstall --id $id -e $mode --accept-source-agreements"
                if ($null -ne $code) { & $Context.Log "winget exit code (${id}): $code" }
            }
        } }
        Notes     = 'VC++ runtimes 2010/2012/2013/2015+, x64 AND x86 (eight packages). CAUTION on uninstall: shared dependencies -- removing them can break unrelated apps.'
    }
    @{
        Name     = '.NET Desktop Runtime 10'
        Category = 'Runtimes'
        # Version-specific on purpose: modern .NET majors are NOT
        # backward compatible (an app built for 8 cannot run on 10), so
        # this detects and manages major version 10 exactly. 10 is the
        # current LTS; an app demanding an older major gets its own
        # entry if that day comes. OSDCloud deployments preinstall this
        # (DCU needs it) -- this entry is for every other machine.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Microsoft Windows Desktop Runtime - 10.*' })
        }
        # No machine scope flag: Microsoft's runtime installers are
        # machine-wide by nature and their winget manifests may not
        # declare a scope (same reasoning as the VC++ entry).
        Install   = @{ Engine = 'Winget'; Id = 'Microsoft.DotNet.DesktopRuntime.10'; MachineScope = $false }
        Uninstall = @{ Engine = 'Winget'; Id = 'Microsoft.DotNet.DesktopRuntime.10' }
        Notes     = '.NET Desktop Runtime 10 (current LTS; needed by DCU among others). CAUTION on uninstall: a shared dependency.'
    }
    @{
        Name     = 'Java (Temurin JRE)'
        Category = 'Runtimes'
        # Eclipse Temurin, NOT Oracle, on purpose (Aaron's call,
        # 2026-11-18): Oracle's JRE carries commercial licensing;
        # Temurin is the free OpenJDK build and functionally equivalent
        # for running Java apps. Major 25 = current LTS; if an app
        # demands an older major, change both Ids (and the Detect
        # pattern) to that major, or add a second entry -- Java majors
        # coexist.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Eclipse Temurin JRE*25*' })
        }
        Install   = @{ Engine = 'Winget'; Id = 'EclipseAdoptium.Temurin.25.JRE' }
        Uninstall = @{ Engine = 'Winget'; Id = 'EclipseAdoptium.Temurin.25.JRE' }
        Notes     = 'Eclipse Temurin JRE 25 (free OpenJDK build; MSI, machine-wide). Runs Java apps without Oracle licensing.'
    }
    @{
        Name     = 'Logi Options+'
        Category = 'Utilities'
        # 'Logi Options+*' ONLY -- never 'Logitech Options*', which would
        # false-positive on the legacy 'Logitech Options' app.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Logi Options+*' })
        }
        # No machine-scope flag: Logitech's winget manifest declares no
        # scope (the installer is machine-wide by nature), and asking for
        # one risks NO_APPLICABLE_INSTALLER. NOTE: an ONLINE installer --
        # it downloads its real payload during install, so it needs
        # internet and is slower than its download size suggests.
        Install   = @{ Engine = 'Winget'; Id = 'Logitech.OptionsPlus'; MachineScope = $false }
        Uninstall = @{ Engine = 'Winget'; Id = 'Logitech.OptionsPlus' }
        Notes     = 'Logitech mouse/keyboard software. Online installer (needs internet). Not expected to work as SYSTEM.'
    }
    @{
        Name     = 'Claude'
        Category = 'Utilities'
        # Anthropic's official enterprise method, not winget: Claude
        # Desktop is an MSIX (package name exactly 'Claude'), per-user by
        # nature; the supported machine-wide install is PROVISIONING the
        # MSIX (Add-AppxProvisionedPackage), which gives it to every user
        # at their next sign-in. Evergreen URL redirects to the newest
        # build. The app self-updates (~every 4 hours), so it is not in
        # this tool's update path by design.
        Detect   = {
            [bool]((Get-AppxPackage -AllUsers -Name 'Claude' -ErrorAction SilentlyContinue) -or
                   (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -eq 'Claude' }))
        }
        Install   = @{ Engine = 'Custom'; Script = {
            param($Context)
            $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
            $url = "https://claude.ai/api/desktop/win32/$arch/msix/latest/redirect"
            if (-not (Test-Path $Context.StageDir)) { New-Item -Path $Context.StageDir -ItemType Directory -Force | Out-Null }
            $msix = Join-Path $Context.StageDir 'Claude.msix'
            try {
                Invoke-LoggedDownload -Url $url -OutFile $msix
            } catch {
                & $Context.Log "Download failed: $($_.Exception.Message)" 'ERROR'
                return
            }
            & $Context.Log "Provisioning Claude machine-wide (Anthropic's supported all-users method). It appears for each user at their next sign-in."
            try {
                Add-AppxProvisionedPackage -Online -PackagePath $msix -SkipLicense -Regions 'all' | Out-Null
            } catch {
                & $Context.Log "Provisioning failed: $($_.Exception.Message)" 'ERROR'
            }
            Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue
        } }
        Uninstall = @{ Engine = 'Custom'; Script = {
            param($Context)
            & $Context.Log "Removing the Claude package for all users..."
            Get-AppxPackage -AllUsers -Name 'Claude' -ErrorAction SilentlyContinue |
                Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Claude' }
            if ($prov) {
                & $Context.Log "De-provisioning Claude so new user profiles do not receive it..."
                $prov | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
            }
        } }
        Notes     = 'Claude Desktop (MSIX). Install provisions it machine-wide -- users get it at next sign-in. Self-updates. Cowork additionally needs the Virtual Machine Platform Windows feature.'
    }
    @{
        Name     = 'Adobe Acrobat Reader'
        Category = 'Utilities'
        # Detection by Reader's STABLE MSI product code, not DisplayName:
        # since Adobe unified the product line, Reader's ARP entry shows
        # 'Adobe Acrobat (64-bit)' -- the SAME name a licensed Acrobat
        # Pro carries -- so a name pattern would collide with the Acrobat
        # Pro entry. Adobe keeps this GUID constant across 64-bit Reader
        # versions.
        Detect   = {
            # Exact GUIDs, not a wildcard: Acrobat Pro lives in the same
            # GUID family with a different language field, so a pattern
            # would re-create the name collision. FF00 = current 64-bit
            # MUI build (CONFIRMED on WSTEST001); 1033 = older
            # single-language builds.
            $guids = @(
                '{AC76BA86-1033-FF00-7760-BC15014EA700}',
                '{AC76BA86-1033-1033-7760-BC15014EA700}'
            )
            $found = $false
            foreach ($g in $guids) {
                if ((Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$g") -or
                    (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$g")) { $found = $true; break }
            }
            $found
        }
        Install   = @{ Engine = 'Winget'; Id = 'Adobe.Acrobat.Reader.64-bit' }
        Uninstall = @{ Engine = 'Winget'; Id = 'Adobe.Acrobat.Reader.64-bit' }
        Notes     = 'Free PDF reader (MSI; machine-wide). Not the licensed Acrobat Pro -- that is a separate entry.'
    }
    @{
        Name     = 'Dell Command Update'
        Category = 'Utilities'
        # 'Dell Command | Update*' covers both ARP spellings (classic and
        # 'for Windows Universal') without matching other Dell Command
        # tools (Monitor, Configure...). The pipe is literal in -like.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'Dell Command | Update*' })
        }
        # The 'Universal' id is the maintained 5.x line. No machine-scope
        # flag (Dell's manifest declares no scope; the installer is
        # machine-wide by nature). Needs .NET Desktop Runtime 10 -- its
        # own entry under Runtimes. Dell hardware only: the installer
        # refuses non-Dell machines, which the log will show plainly.
        Install   = @{ Engine = 'Winget'; Id = 'Dell.CommandUpdate.Universal'; MachineScope = $false }
        Uninstall = @{ Engine = 'Winget'; Id = 'Dell.CommandUpdate.Universal' }
        Notes     = 'Dell driver/BIOS updater. Preinstalled by OSDCloud deployments -- this entry is for every other Dell. Requires .NET Desktop Runtime 10.'
    }
    @{
        Name     = 'Office (Microsoft 365)'
        Category = 'Microsoft Office'
        # ARP shows 'Microsoft 365 Apps for business - en-us'. The 'Apps'
        # word is in the pattern so unrelated 'Microsoft 365 ...' entries
        # (Copilot etc.) never match.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Microsoft 365 Apps*' })
        }
        # O365BusinessRetail = Microsoft 365 Apps for business (v1-
        # confirmed tier). No Channel = ODT's default (Current).
        Install   = @{ Engine = 'Odt'; ProductId = 'O365BusinessRetail' }
        Uninstall = @{ Engine = 'Odt'; ProductId = 'O365BusinessRetail' }
        Notes     = 'Microsoft 365 Apps for business via the Office Deployment Tool. 10-20+ min installs are normal. Do not mix with Office 2021 on one machine -- pick one.'
    }
    @{
        Name     = 'Office Suite 2021'
        Category = 'Microsoft Office'
        # ARP shows 'Microsoft Office LTSC Professional Plus 2021 -
        # en-us'; the two-wildcard pattern covers Standard too. (v1's
        # '*Office LTSC 2021*' pattern never matched this contiguously --
        # its post-install verification was silently falling through.)
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Office LTSC*2021*' })
        }
        # v1-confirmed: ProPlus2021Volume under PerpetualVL2021. The
        # generated config requests ONLY Office -- Project and Visio are
        # their own entries, selectable independently.
        Install   = @{ Engine = 'Odt'; ProductId = 'ProPlus2021Volume'; Channel = 'PerpetualVL2021' }
        Uninstall = @{ Engine = 'Odt'; ProductId = 'ProPlus2021Volume' }
        Notes     = 'Office LTSC Professional Plus 2021 (volume license) via the Office Deployment Tool. 10-20+ min installs are normal. Do not mix with Microsoft 365 on one machine -- pick one.'
    }
    @{
        Name     = 'Project Professional 2021'
        Category = 'Microsoft Office'
        # Per Microsoft, Project/Visio are separate products from Office
        # and coexist with either Office track with no known conflict
        # (v1-documented) -- no mutual-exclusion caution needed here.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Microsoft Project*' })
        }
        Install   = @{ Engine = 'Odt'; ProductId = 'ProjectPro2021Volume'; Channel = 'PerpetualVL2021' }
        Uninstall = @{ Engine = 'Odt'; ProductId = 'ProjectPro2021Volume' }
        Notes     = 'Project Professional 2021 (volume license) via the Office Deployment Tool. Coexists with either Office track.'
    }
    @{
        Name     = 'Visio Professional 2021'
        Category = 'Microsoft Office'
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Microsoft Visio*' })
        }
        Install   = @{ Engine = 'Odt'; ProductId = 'VisioPro2021Volume'; Channel = 'PerpetualVL2021' }
        Uninstall = @{ Engine = 'Odt'; ProductId = 'VisioPro2021Volume' }
        Notes     = 'Visio LTSC Professional 2021 (volume license) via the Office Deployment Tool. Coexists with either Office track.'
    }
    @{
        Name     = 'Outlook Classic'
        Category = 'Microsoft Office'
        # Odt engine, NOT v1's share-hosted exe: that exe was Microsoft's
        # per-app C2R web installer (OfficeSetup.exe renamed), which
        # installs the ODT product OutlookRetail on the Current channel
        # -- the same thing this entry requests directly, gaining a real
        # uninstall and the cached-setup share-free removal. Detection
        # matches the standalone ARP entry only: the Outlook inside an
        # Office suite registers no separate entry, and the NEW Outlook
        # is an MSIX package that never appears in ARP.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Microsoft Outlook*' })
        }
        Install   = @{ Engine = 'Odt'; ProductId = 'OutlookRetail' }
        Uninstall = @{ Engine = 'Odt'; ProductId = 'OutlookRetail' }
        Notes     = 'Classic (desktop) Outlook, standalone, via the Office Deployment Tool. Activates with the user''s Microsoft 365 license.'
    }
    @{
        Name     = 'ConnectWise Automate Agent'
        Category = 'Agents'
        # Variants: one Automate SITE per subfolder of AllConnectWiseAgents,
        # each holding that site's Agent_Install.msi + Agent_Install.mst
        # (the TRANSFORM carries the site config -- both are required).
        # The dropdown list is DISCOVERED from the subfolder names, so
        # adding a site = adding a folder. 'Uninstaller' is the shared
        # generic-uninstaller folder, not a site -- excluded.
        Variants = @{
            Label        = 'Site'
            Default      = 'New PCs'
            # Proceed double-checks when the agent is being installed
            # with the default site still selected (profiles pre-select
            # it, and a tech can forget to pick the real site).
            WarnOnDefault = $true
            # Seed: site names shown in the dropdown even before the
            # share is reachable (no credentials yet) -- the folder names
            # exactly as of 2026-11-19. The dropdown also auto-merges
            # anything newly discovered on the share the moment
            # credentials are provided, on Rescan, and on every return
            # to the menu, so a NEW site folder needs no edit here.
            Seed         = @(
                'New PCs',
                'AB1 - NAPC',
                'Azure',
                'CA1',
                'CA2 - DYNATRAC',
                'CA3 - ICON',
                'CA4 - LASERTECH',
                'CA5 - Carli',
                'CA6 - COGNITO',
                'COLO',
                'FL1 - BPH',
                'IA1 - EVO',
                'ID1 - Van Compass',
                'KY1',
                'MN1 - Zumbrota',
                'NC1 - ECGS',
                'NV1 - Adams Driveshaft',
                'Remote Users',
                'TX1',
                'WA1 - RANDYS HQ',
                'WA2 - TRC'
            )
            DiscoverFrom = '\\svazdfs001\systems$\Software\ConnectWise\AllConnectWiseAgents'
            Exclude      = @('Uninstaller')
        }
        # Detection by the agent's SERVICE (LTService), not ARP: it is
        # the agent's real footprint and survives ARP naming drift.
        Detect   = {
            [bool](Get-Service -Name 'LTService' -ErrorAction SilentlyContinue)
        }
        Install   = @{ Engine = 'Custom'; NeedsShare = $true; Script = {
            param($Context)
            $site = if ($Context.Variant) { [string]$Context.Variant } else { 'New PCs' }
            $bases = @(
                '\\svazdfs001\systems$\Software\ConnectWise\AllConnectWiseAgents',
                '\\10.1.0.5\systems$\Software\ConnectWise\AllConnectWiseAgents'
            )
            $base = $null
            foreach ($b in $bases) {
                if (Test-Path -LiteralPath (Join-Path $b $site) -ErrorAction SilentlyContinue) { $base = $b; break }
            }
            if (-not $base) {
                & $Context.Log "Could not reach the '$site' agent folder on the share. Checked under: $($bases -join ', ')" 'ERROR'
                return
            }
            $dir = Join-Path $base $site
            $msi = Join-Path $dir 'Agent_Install.msi'
            $mst = Join-Path $dir 'Agent_Install.mst'
            if (-not (Test-Path -LiteralPath $msi) -or -not (Test-Path -LiteralPath $mst)) {
                & $Context.Log "The '$site' folder is missing Agent_Install.msi and/or Agent_Install.mst ($dir)." 'ERROR'
                return
            }
            & $Context.Log "Installing the Automate agent for site '$site' (MSI + site transform)."
            if (-not (Test-Path $Context.StageDir)) { New-Item -Path $Context.StageDir -ItemType Directory -Force | Out-Null }
            $localMsi = Join-Path $Context.StageDir 'Agent_Install.msi'
            $localMst = Join-Path $Context.StageDir 'Agent_Install.mst'
            Copy-Item -LiteralPath $msi -Destination $localMsi -Force
            Copy-Item -LiteralPath $mst -Destination $localMst -Force
            $quiet = if ($Context.Interactive) { '' } else { '/qn ' }
            $code = Invoke-ProcessStep -FilePath 'msiexec.exe' -Arguments "/i `"$localMsi`" TRANSFORMS=`"$localMst`" $quiet/norestart"
            if ($null -ne $code) { & $Context.Log "msiexec exit code: $code" }

            # Cache the share's GENERIC uninstaller now, while we have
            # share access, so a later agent removal needs no share or
            # credentials (same idea as the cached ODT setup.exe).
            try {
                $unDir = Join-Path $Context.StageDir 'CWAgentUninstaller'
                if (-not (Test-Path $unDir)) { New-Item -Path $unDir -ItemType Directory -Force | Out-Null }
                foreach ($f in @('Uninstall.exe', 'Uninstall.exe.config')) {
                    Copy-Item -LiteralPath (Join-Path (Join-Path $base 'Uninstaller') $f) -Destination (Join-Path $unDir $f) -Force -ErrorAction Stop
                }
                & $Context.Log "Cached the generic agent uninstaller locally for share-free removals."
            } catch {
                & $Context.Log "Could not cache the generic uninstaller ($($_.Exception.Message)) -- a later uninstall will fetch it from the share instead." 'WARN'
            }
        } }
        # Generic uninstaller (site-independent), cached at install time;
        # the share is only needed when the cache is missing.
        Uninstall = @{ Engine = 'Custom'; NeedsShare = $true; SkipShareIfPresent = "$env:ProgramData\RWW\AppsDeploy\Stage\CWAgentUninstaller\Uninstall.exe"; Script = {
            param($Context)
            $unDir = Join-Path $Context.StageDir 'CWAgentUninstaller'
            $exe = Join-Path $unDir 'Uninstall.exe'
            if (Test-Path -LiteralPath $exe) {
                & $Context.Log "Using the locally cached generic agent uninstaller -- no share access needed."
            } else {
                $bases = @(
                    '\\svazdfs001\systems$\Software\ConnectWise\AllConnectWiseAgents\Uninstaller',
                    '\\10.1.0.5\systems$\Software\ConnectWise\AllConnectWiseAgents\Uninstaller'
                )
                $src = $null
                foreach ($b in $bases) {
                    if (Test-Path -LiteralPath (Join-Path $b 'Uninstall.exe') -ErrorAction SilentlyContinue) { $src = $b; break }
                }
                if (-not $src) {
                    & $Context.Log "No cached uninstaller and the share's Uninstaller folder is unreachable. Checked: $($bases -join ', ')" 'ERROR'
                    return
                }
                if (-not (Test-Path $unDir)) { New-Item -Path $unDir -ItemType Directory -Force | Out-Null }
                foreach ($f in @('Uninstall.exe', 'Uninstall.exe.config')) {
                    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $unDir $f) -Force
                }
                & $Context.Log "Fetched the generic agent uninstaller from the share (and cached it)."
            }
            & $Context.Log "Running the generic Automate agent uninstaller (removes any site's agent)."
            $code = Invoke-ProcessStep -FilePath $exe -TimeoutSeconds 900
            if ($null -ne $code) { & $Context.Log "Uninstaller exit code: $code" }
        } }
        Notes     = 'RMM agent; the Site dropdown picks which Automate site this machine reports to. CAUTION: uninstalling it from Backstage cuts your own remote session. Decommissioned PCs must ALSO be deleted in the Automate console to free the seat.'
    }
    @{
        Name     = 'ZAC'
        Category = 'Communications'
        # DisplayName is EXACTLY 'ZAC' (confirmed on a real machine), and
        # modern ZAC registers as an MSI (MsiExec /I{GUID}) -- the v1-era
        # NSIS/Inno guesswork no longer applies.
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'ZAC' })
        }
        # Zultys maintains the winget manifest themselves, same-day with
        # releases, pulling from their own mirror (mirror.zultys.biz) --
        # so Winget install IS 'always the newest ZAC from Zultys', with
        # hash verification, and no version-frozen URL lives here.
        Install   = @{ Engine = 'Winget'; Id = 'Zultys.ZAC' }
        # MsiRegistry, not winget: the product code changes per version,
        # and winget's correlation of a non-winget-installed ZAC is not
        # trusted; the registry lookup finds whatever GUID is current.
        Uninstall = @{ Engine = 'MsiRegistry'; DisplayNameLike = 'ZAC' }
        Notes     = 'Zultys softphone. v1''s chronic ZAC failures were exit-code lies from its installer -- this tool''s detection-based verification is immune to those.'
    }
    @{
        Name     = 'Adobe Acrobat Pro'
        Category = 'Utilities'
        # GUID-keyed, like the Reader entry: Pro and Reader BOTH display
        # 'Adobe Acrobat (64-bit)', but Pro's product code uses FFFF in
        # the language field (CONFIRMED on a licensed RWW machine) where
        # Reader's MUI build uses FF00. Each entry only ever sees itself.
        Detect   = {
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{AC76BA86-1033-FFFF-7760-BC15014EA700}') -or
            (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{AC76BA86-1033-FFFF-7760-BC15014EA700}')
        }
        # Named-user licensing: this installs Adobe's standard 64-bit Pro
        # build; the user signs in with their licensed Adobe ID to
        # activate. No Admin Console package to host or keep updated.
        Install   = @{ Engine = 'Winget'; Id = 'Adobe.Acrobat.Pro' }
        # ProductCode-precise uninstall: a DisplayName lookup could grab
        # Reader's entry instead (same name).
        Uninstall = @{ Engine = 'MsiRegistry'; ProductCode = '{AC76BA86-1033-FFFF-7760-BC15014EA700}' }
        Notes     = 'Licensed Acrobat (named-user). Users sign in with their Adobe ID to activate. Not the free Reader -- that is a separate entry.'
    }
    @{
        Name     = 'MXAdmin'
        Category = 'Communications'
        # DisplayName confirmed: 'MXAdmin version 19.0.20' (Inno Setup --
        # its unins000.exe under Program Files (x86)\Zultys is the one
        # that confused v1's ZAC work).
        Detect   = {
            [bool](Get-ItemProperty `
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'MXAdmin*' })
        }
        # Downloaded from RANDYS' OWN MX (randysww.mxvirtual.com), which
        # always serves the MXAdmin build matching the PBX's current
        # release -- self-updating with every MX update, and a version
        # mismatch is impossible. (Deliberately NOT a third-party MX's
        # googleable link.) Inno installer: /VERYSILENT etc. when silent.
        Install   = @{ Engine = 'Custom'; Script = {
            param($Context)
            $url = 'https://randysww.mxvirtual.com/admin_setup.exe'
            if (-not (Test-Path $Context.StageDir)) { New-Item -Path $Context.StageDir -ItemType Directory -Force | Out-Null }
            $exe = Join-Path $Context.StageDir 'mxadmin_setup.exe'
            try {
                Invoke-LoggedDownload -Url $url -OutFile $exe
            } catch {
                & $Context.Log "Download failed: $($_.Exception.Message)" 'ERROR'
                return
            }
            # Sanity: a real Windows executable, not an error page
            # (standing rule for direct downloads).
            $fi = Get-Item -LiteralPath $exe
            $sig = New-Object byte[] 2
            $fs = [System.IO.File]::OpenRead($exe)
            try { [void]$fs.Read($sig, 0, 2) } finally { $fs.Close() }
            if ($fi.Length -lt 1MB -or $sig[0] -ne 0x4D -or $sig[1] -ne 0x5A) {
                & $Context.Log "The downloaded file is NOT a valid Windows executable (size $([math]::Round($fi.Length/1MB,1)) MB) -- the MX may have returned an error page." 'ERROR'
                Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
                return
            }
            $args = if ($Context.Interactive) { '' } else { '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES' }
            $code = Invoke-ProcessStep -FilePath $exe -Arguments $args
            if ($null -ne $code) { & $Context.Log "MXAdmin installer exit code: $code" }
        } }
        Uninstall = @{ Engine = 'Registry'; DisplayNameLike = 'MXAdmin*' }
        Notes     = 'Zultys MX administration console. Downloads from RANDYS'' own MX (randysww.mxvirtual.com), so it always matches the PBX''s release.'
    }
    @{
        Name     = 'Cisco Secure Client (VPN)'
        Category = 'Agents'
        # PRESENCE detection, deliberately different from the SecureConnect
        # README's health check (profile + service RUNNING): a stopped
        # service would make an installed client read 'not installed' in
        # the menu. Presence = the RWW profile exists AND the VPN agent
        # service exists; the install bundle restarts the service anyway.
        Detect   = {
            $profilePath = 'C:\ProgramData\Cisco\Cisco Secure Client\VPN\Profile\RWW-SecureConnect-VpnProfile.xml'
            [bool]((Test-Path -LiteralPath $profilePath -ErrorAction SilentlyContinue) -and
                   (Get-Service -Name 'csc_vpnagent' -ErrorAction SilentlyContinue))
        }
        # The install artifact is RWW's own prebuilt SecureConnect SFX
        # bundle (from the private SecureConnect repo, hosted on the
        # share): it self-extracts silently and internally runs msiexec
        # /quiet with 1618 retry, drops the RWW VPN profile XML, and
        # restarts csc_vpnagent -- so this wrapper stays thin on purpose.
        # The bundle writes its own logs to C:\Windows\Logs\
        # SecureConnect-OnDemand*.log.
        Install   = @{ Engine = 'Custom'; NeedsShare = $true; Script = {
            param($Context)
            $bases = @(
                '\\svazdfs001\systems$\Software\CiscoSecureClient',
                '\\10.1.0.5\systems$\Software\CiscoSecureClient'
            )
            $src = $null
            foreach ($b in $bases) {
                if (Test-Path -LiteralPath (Join-Path $b 'SecureConnect-VPN-Install.exe') -ErrorAction SilentlyContinue) { $src = $b; break }
            }
            if (-not $src) {
                & $Context.Log "Could not reach SecureConnect-VPN-Install.exe on the share. Checked: $($bases -join ', ')" 'ERROR'
                return
            }
            if (-not (Test-Path $Context.StageDir)) { New-Item -Path $Context.StageDir -ItemType Directory -Force | Out-Null }
            $exe = Join-Path $Context.StageDir 'SecureConnect-VPN-Install.exe'
            Copy-Item -LiteralPath (Join-Path $src 'SecureConnect-VPN-Install.exe') -Destination $exe -Force
            & $Context.Log "Running the SecureConnect bundle (silent; installs the VPN core, drops the RWW profile, restarts the agent -- its own logs land in C:\Windows\Logs)."
            $code = Invoke-ProcessStep -FilePath $exe -TimeoutSeconds 600
            if ($null -ne $code) { & $Context.Log "Bundle exit code: $code" }
        } }
        # Core VPN module uninstalls as a normal MSI; the precise ARP name
        # matters because every Cisco module registers its own
        # similarly-named entry. The leftover profile XML is harmless and
        # gets refreshed by the next install.
        Uninstall = @{ Engine = 'MsiRegistry'; DisplayNameLike = 'Cisco Secure Client - AnyConnect VPN*' }
        Notes     = 'Core VPN only (Umbrella lapsed). Installs RWW''s prebuilt SecureConnect bundle: client + RWW VPN profile in one step.'
    }
)
