#Requires -Version 5.1
<#
.SYNOPSIS
    AppsDeploy v2 -- worker process. A plain console PowerShell process
    with NO UI of any kind: it executes the job plan and writes
    level-tagged lines to the run log, which the UI process tails.

.DESCRIPTION
    Repo: randysworldwide/rww-installers
    Path: Scripts/AppsDeploy2/AppsDeploy-Worker.ps1

    WHY A SEPARATE PROCESS: v1 ran installs on a background runspace
    inside the GUI process, and the GUI suffered a recurring total
    freeze that survived four separate root-cause fixes (STA apartment,
    WaitForExit->polling, marquee removal, scheduled-task priority) --
    never fully solved. v2 makes that freeze STRUCTURALLY impossible:
    the worker shares no thread, message pump, apartment, or priority
    class with any window. The only contract between the processes is
    this log file.

    LOG PROTOCOL (one line per event):
      [yyyy-MM-dd HH:mm:ss] [LEVEL] message
        LEVEL: INFO, WARN, ERROR, SUCCESS, CMD
      ::STEP::<i>/<n>::<app name>::<Install|Uninstall|Update|Repair>   (machine line)
      ::RESULT::<app name>::<OK|FAILED>                  (machine line)
      ::DONE::<overall exit code>                        (machine line)
    Machine lines (::) drive the UI's header/status; they are not
    rendered as log text. Everything else is for humans, colorized by
    level tag.

    DESIRED-STATE SEMANTICS: before acting on a step, Detect runs again
    -- an Install target already present (or Uninstall target already
    absent) is logged and counted OK with no action, so a plan built
    from a stale scan can never do redundant or destructive work. After
    acting, Detect runs again as the verification: detection is the
    ground truth, exit codes are advisory (a lesson paid for repeatedly
    in v1 -- e.g. the null-ExitCode bug that failed a successful ZAC
    install).

.PARAMETER JobFile
    JSON job plan written by the UI:
      { "Interactive": false, "Steps": [ {"Name":"...","Action":"Install"} ] }
    A step may carry "Interactive": true (the row's wrench in the GUI),
    which shows the vendor's own installer window for THAT step; the
    top-level flag still forces every step interactive (kept for jobs
    written by hand or by older front-ends).

.PARAMETER CleanupApp
    Cancel-sweep mode: best-effort uninstall of ONE app, used by the UI
    after killing a cancelled in-flight step. MSI installs roll back on
    their own when killed; this sweep catches non-MSI remnants.
#>

[CmdletBinding()]
param(
    [string]$JobFile,
    [Parameter(Mandatory)][string]$LogFile,
    # Default resolved in the body -- $PSScriptRoot is not reliably
    # populated during param() default evaluation (same real-machine
    # failure the UI hit). The UI always passes -ManifestPath explicitly
    # anyway; this guard covers running the worker by hand.
    [string]$ManifestPath,
    [string]$CleanupApp,
    [string]$CleanupAction = 'Uninstall'
)

$ErrorActionPreference = 'Stop'
# PS 5.1 does not always offer TLS 1.2 by default; vendor download
# endpoints require it. -bor keeps whatever is already enabled.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $workerRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ManifestPath = Join-Path $workerRoot 'AppsDeploy-Manifest.ps1'
}
$StageRoot = "$env:ProgramData\RWW\AppsDeploy\Stage"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    for ($try = 1; $try -le 5; $try++) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8; break }
        catch { Start-Sleep -Milliseconds (40 * $try) }
    }
}

function Write-Machine {
    param([string]$Line)
    for ($try = 1; $try -le 5; $try++) {
        try { Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8; break }
        catch { Start-Sleep -Milliseconds (40 * $try) }
    }
}

function Test-IsSystem {
    [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Resolve-WinGet {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Get-WingetErrorHint {
    # Plain-language hints for winget's most common HRESULTs, so the log
    # explains failures instead of just printing a negative number.
    param([int]$Code)
    switch ($Code) {
        -1978335212 { 'no matching installed package was found (0x8A150014)' }
        -1978335215 { 'installer hash mismatch (0x8A150011) -- the community manifest is out of date for this app right now; retrying will not help until the manifest catches up' }
        -1978335216 { 'no applicable installer for this system/scope (0x8A150010)' }
        -1978335217 { 'source data missing (0x8A15000F) -- the winget source cache on this machine is stale or incomplete' }
        -1978335221 { 'the configured winget sources are invalid (0x8A15000B)' }
        -1978335211 { 'no winget sources are defined on this machine (0x8A150015)' }
        -1978335224 { 'the download failed (0x8A150008)' }
        -1978335226 { 'the installer itself reported failure (0x8A150006)' }
        default     { $null }
    }
}

# winget codes that indicate a SOURCE problem rather than an app problem
# -- worth an automatic 'winget source update' and one retry.
$script:WingetSourceErrorCodes = @(-1978335217, -1978335221, -1978335211)

function Restore-ExplorerIfKilled {
    # Confirmed real behavior (7-Zip uninstall incident, RestartManager
    # events 10010+10006): a silent uninstall of an app with shell
    # extensions can shut down explorer.exe and fail to restart it.
    # Skipped as SYSTEM -- explorer belongs to user sessions there and
    # SYSTEM relaunching it would put an explorer in the wrong session.
    if (Test-IsSystem) { return }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Write-Log "explorer.exe is not running -- an uninstaller's Restart Manager step likely killed it. Relaunching." 'WARN'
        try { Start-Process explorer.exe } catch {}
    }
}

function Invoke-ProcessStep {
    # Launches + waits with the two hard-won v1 fixes baked in (.Handle
    # caching for the null-ExitCode gotcha; HasExited polling instead of
    # a blocking WaitForExit), AND captures the child's stdout/stderr
    # into the run log. ADDED AFTER REAL DEBUGGING PAIN: winget failures
    # were reaching the log only as bare exit codes, because the child's
    # console text died with the hidden worker window -- every diagnosis
    # meant decoding HRESULTs by hand. GUI installers emit nothing, so
    # this costs silent runs nothing.
    param(
        [string]$FilePath,
        [string]$Arguments,
        [int]$TimeoutSeconds = 1800,
        # Optional: engines can supply a probe that reports progress for
        # children that print NOTHING (ODT/Click-to-Run). Called every
        # ProbeIntervalSeconds during the wait; exceptions are swallowed.
        [scriptblock]$ProgressProbe,
        [int]$ProbeIntervalSeconds = 30
    )
    Write-Log "Running: $FilePath $Arguments" 'CMD'

    $outFile = Join-Path $env:TEMP ('rww-out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = Join-Path $env:TEMP ('rww-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            $proc = Start-Process -FilePath $FilePath -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        } else {
            $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        }
    } catch {
        Write-Log "Failed to start the process: $($_.Exception.Message)" 'ERROR'
        return $null
    }
    $null = $proc.Handle

    # LIVE output relay: read the capture files WHILE the child runs and
    # log new complete lines each second, so the tech sees winget's (or
    # any CLI's) output as it happens instead of one burst after exit
    # (CONFIRMED need: a whole winget run used to land at a single
    # timestamp, leaving minutes of apparent silence). UTF-8 StreamReader
    # on purpose -- PS 5.1's ANSI default mojibakes winget -- and the
    # reader's decoder is stateful, so multibyte chars split across polls
    # survive. Progress-bar lines (block-drawing chars) are dropped.
    $readers = @()
    foreach ($pair in @(@($outFile, 'INFO'), @($errFile, 'WARN'))) {
        $r = @{ Path = $pair[0]; Level = $pair[1]; Reader = $null; Buffer = '' }
        try {
            $fs = [System.IO.File]::Open($pair[0], 'OpenOrCreate', 'Read', 'ReadWrite')
            $r.Reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        } catch {}
        $readers += , $r
    }
    $relayNew = {
        param($r, [bool]$Final)
        if (-not $r.Reader) { return }
        try { $chunk = $r.Reader.ReadToEnd() } catch { return }
        if ($chunk) { $r.Buffer += ($chunk -replace '\x08', '') }
        if (-not $r.Buffer) { return }
        $parts = $r.Buffer -split '[\r\n]+', -1
        if ($Final) { $r.Buffer = ''; $upto = $parts.Count }
        else        { $r.Buffer = $parts[-1]; $upto = $parts.Count - 1 }   # keep any partial last line
        for ($i = 0; $i -lt $upto; $i++) {
            $l = $parts[$i].Trim()
            if ($l -and $l -notmatch '[\u2580-\u259F]' -and $l -notmatch '^[\s\\|/\-]+$') {
                Write-Log ("  > " + $l) $r.Level
            }
        }
    }

    $elapsed = 0
    $nextProbe = $ProbeIntervalSeconds
    while (-not $proc.HasExited -and $elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $elapsed += 1
        foreach ($r in $readers) { & $relayNew $r $false }
        if ($ProgressProbe -and $elapsed -ge $nextProbe) {
            $nextProbe += $ProbeIntervalSeconds
            try { & $ProgressProbe } catch {}
        }
    }
    $exitVal = $null
    if (-not $proc.HasExited) {
        Write-Log "Process did not finish within ${TimeoutSeconds}s -- killing it." 'ERROR'
        try { $proc.Kill() } catch {}
        Start-Sleep -Seconds 1
    } else {
        $exitVal = $proc.ExitCode
    }

    Start-Sleep -Milliseconds 300   # let the child's last buffered writes land
    foreach ($r in $readers) {
        & $relayNew $r $true
        if ($r.Reader) { try { $r.Reader.Close() } catch {} }
        Remove-Item -LiteralPath $r.Path -Force -ErrorAction SilentlyContinue
    }
    return $exitVal
}

function Invoke-LoggedDownload {
    # Streamed download that logs progress every ~3 seconds, so a long
    # download shows life in the Progress window instead of minutes of
    # silence (CONFIRMED need: the Chrome MSI download took 5+ silent
    # minutes and looked frozen). Throws on failure -- callers catch.
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    Write-Log "Downloading $Url"
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.AllowAutoRedirect = $true
    $req.UserAgent = 'RWW-AppsDeploy/2'
    $resp = $req.GetResponse()
    try {
        $total = [long]$resp.ContentLength   # -1 when the server does not say
        $in  = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($OutFile)
        try {
            $buf = New-Object byte[] 262144
            $got = [long]0
            $lastNote = Get-Date
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $got += $n
                if (((Get-Date) - $lastNote).TotalSeconds -ge 3) {
                    $lastNote = Get-Date
                    if ($total -gt 0) {
                        Write-Log ("  Downloaded {0:N1} MB of {1:N1} MB ({2}%)" -f ($got / 1MB), ($total / 1MB), [int](100 * $got / $total))
                    } else {
                        Write-Log ("  Downloaded {0:N1} MB so far" -f ($got / 1MB))
                    }
                }
            }
        } finally { $out.Close(); $in.Close() }
        Write-Log ("Download complete ({0:N1} MB)." -f ($got / 1MB))
    } finally { $resp.Close() }
}

function Invoke-RegistryUninstall {
    # Tiered fallback when winget cannot correlate an installed app
    # (CONFIRMED real case: VLC installed, detection positive, winget
    # said NO_APPLICATIONS_FOUND). Uses the app's OWN registered
    # uninstall command, most-authoritative first -- the same tiering
    # that proved itself in v1 (MXAdmin, OEM debloat):
    #   1. QuietUninstallString, verbatim -- it IS the registered silent
    #      command. EXCEPTION: recognized Inno uninstallers skip this
    #      (their quiet string is /SILENT, which shows a progress window)
    #      and take tier 3's /VERYSILENT instead.
    #   2. MSI product code -> msiexec /x (MSIRESTARTMANAGERCONTROL=
    #      Disable prevents the confirmed explorer-kill behavior).
    #   3. Inno-style unins*.exe -> documented Inno silent switches.
    #   4. Any other exe -> /S (NSIS convention; VLC's actual case).
    # Interactive mode skips the silent switches so the vendor UI shows.
    param([string]$DisplayNameLike, [bool]$Interactive)

    $entry = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $DisplayNameLike -and $_.UninstallString } |
        Select-Object -First 1
    if (-not $entry) {
        Write-Log "No uninstall registry entry matches '$DisplayNameLike'." 'ERROR'
        return
    }
    Write-Log "Using the registered uninstaller for '$($entry.DisplayName)'."


    $exePath = $null; $exeArgs = $null
    # Inno Setup is recognized FIRST, ahead of QuietUninstallString: an
    # Inno app's registered quiet command uses /SILENT, which still shows
    # a progress window (CONFIRMED: VS Code's uninstall popped its status
    # window mid-run). Every Inno uninstaller supports /VERYSILENT, which
    # is fully invisible, so recognized Inno skips the quiet string and
    # falls through to the Inno tier below.
    $isInno = $false
    if ($entry.UninstallString -match '"?([^"]*\.exe)"?') {
        $isInno = ((Split-Path -Leaf $Matches[1]) -match '^unins\d{3}\.exe$')
    }
    $quiet = $entry.PSObject.Properties['QuietUninstallString']
    if (-not $Interactive -and -not $isInno -and $quiet -and $quiet.Value) {
        if ($quiet.Value -match '^"([^"]+)"\s*(.*)$') { $exePath = $Matches[1]; $exeArgs = $Matches[2] }
        elseif ($quiet.Value -match '^(\S+)\s*(.*)$')   { $exePath = $Matches[1]; $exeArgs = $Matches[2] }
    } elseif ($entry.UninstallString -match 'msiexec' -and $entry.UninstallString -match '\{[0-9A-Fa-f\-]+\}') {
        $exePath = 'msiexec.exe'
        $exeArgs = "/x $($Matches[0]) $(if (-not $Interactive) { '/qn ' })/norestart MSIRESTARTMANAGERCONTROL=Disable"
    } elseif ($entry.UninstallString -match '"?([^"]*\.exe)"?\s*(.*)$') {
        $exePath = $Matches[1]
        $baseArgs = $Matches[2].Trim()
        if (-not (Test-Path -LiteralPath $exePath)) {
            Write-Log "Registered uninstaller not found on disk: $exePath" 'ERROR'
            return
        }
        if ($Interactive) {
            $exeArgs = $baseArgs
        } elseif ((Split-Path -Leaf $exePath) -match '^unins\d{3}\.exe$') {
            # Inno Setup uninstallers are literally unins000.exe,
            # unins001.exe, ... -- matched precisely. (CONFIRMED BUG the
            # loose 'unins*' wildcard caused: VLC's NSIS uninstall.exe
            # ALSO starts with 'unins', got Inno switches it ignores, and
            # popped its language dialog instead of running silently.)
            $exeArgs = ($baseArgs + ' /VERYSILENT /NORESTART /SUPPRESSMSGBOXES').Trim()
        } else {
            # NSIS and most other setup engines: /S (VLC's actual case).
            $exeArgs = ($baseArgs + ' /S').Trim()
        }
    } else {
        Write-Log "Could not parse the registered uninstall string: $($entry.UninstallString)" 'ERROR'
        return
    }

    $code = Invoke-ProcessStep -FilePath $exePath -Arguments $exeArgs
    if ($null -ne $code) { Write-Log "Registered uninstaller exit code: $code" }
    # NOTE: Inno/NSIS uninstallers respawn from %TEMP% and the launched
    # process exits immediately -- completion is judged by the caller's
    # detection POLL, not by this exit code.
}

function Get-App {
    param([string]$Name)
    $script:AppManifest | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Invoke-EngineSpec {
    # Executes one action spec (an Install/Uninstall
    # entry from the manifest). Infra errors are logged and simply fall
    # through -- Invoke-AppAction's detection-based verification is the
    # single arbiter of success, so these returns carry no verdict.
    param([hashtable]$App, [hashtable]$Spec, [string]$Action, [bool]$Interactive, [string]$Variant)

    switch ($Spec.Engine) {

        'Winget' {
            $winget = Resolve-WinGet
            if (-not $winget) {
                $ctxNote = if (Test-IsSystem) { " (running as SYSTEM -- winget is frequently unavailable in this context; this app may need an MSI-based engine for Backstage use)" } else { "" }
                Write-Log "winget.exe could not be located$ctxNote." 'ERROR'
                return
            }
            $verb = switch ($Action) { 'Install' { 'install' } 'Repair' { 'install' } 'Update' { 'upgrade' } default { 'uninstall' } }
            $mode = if ($Interactive) { '--interactive' } else { '--silent' }
            $wgArgs = @($verb, '--id', $Spec.Id, '-e', $mode, '--accept-source-agreements', '--disable-interactivity')
            if ($Action -eq 'Update') {
                # --include-unknown: offer the upgrade even when winget
                # cannot read the installed version from ARP.
                $wgArgs += @('--accept-package-agreements', '--include-unknown')
            }
            if ($Action -in @('Install', 'Repair')) {
                $wgArgs += @('--accept-package-agreements', '--source', 'winget')
                if ($Action -eq 'Repair') {
                    # Without --force, winget sees the app is already
                    # installed and does nothing -- the whole point of a
                    # repair is to run the installer again anyway.
                    $wgArgs += '--force'
                }
                # Machine scope by default; a manifest entry can opt out
                # with MachineScope = $false. MSIX/Store-packaged apps
                # (e.g. Windows Terminal) have no machine-wide installer
                # -- winget errors with NO_APPLICABLE_INSTALLER if asked.
                if (-not ($Spec.ContainsKey('MachineScope') -and -not $Spec.MachineScope)) {
                    $wgArgs += @('--scope', 'machine')
                }
            }
            if ($Interactive) { $wgArgs = $wgArgs | Where-Object { $_ -ne '--disable-interactivity' } }
            $code = Invoke-ProcessStep -FilePath $winget -Arguments ($wgArgs -join ' ')
            if ($null -ne $code) { Write-Log "winget exit code: $code" }
            $hint = if ($null -ne $code) { Get-WingetErrorHint -Code $code } else { $null }
            if ($hint) { Write-Log "winget: $hint" 'WARN' }

            # 'No applicable update' is SUCCESS for an update run, not an
            # error: the app is simply current already.
            if ($Action -eq 'Update' -and $code -eq -1978335189) {
                Write-Log "Already up to date -- winget has no newer version."
            }

            # Source-problem auto-recovery (CONFIRMED real case: a VLC
            # install failed with 0x8A15000F SOURCE_DATA_MISSING): refresh
            # the source and retry the same command once.
            if ($code -in $script:WingetSourceErrorCodes) {
                Write-Log "winget's source looks stale or broken -- running 'winget source update' and retrying once." 'WARN'
                [void](Invoke-ProcessStep -FilePath $winget -Arguments 'source update --disable-interactivity')
                $code = Invoke-ProcessStep -FilePath $winget -Arguments ($wgArgs -join ' ')
                if ($null -ne $code) { Write-Log "winget retry exit code: $code" }
                $hint = if ($null -ne $code) { Get-WingetErrorHint -Code $code } else { $null }
                if ($hint) { Write-Log "winget: $hint" 'WARN' }
            }

        }

        'Msi' {
            if (-not (Test-Path $StageRoot)) { New-Item -Path $StageRoot -ItemType Directory -Force | Out-Null }
            $localMsi = Join-Path $StageRoot (Split-Path $Spec.Url -Leaf)
            try {
                Invoke-LoggedDownload -Url $Spec.Url -OutFile $localMsi
            } catch {
                Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
                return
            }
            $quiet = if ($Interactive) { '' } else { '/qn ' }
            $props = if ($Spec.Properties) { ' ' + $Spec.Properties } else { '' }
            $code = Invoke-ProcessStep -FilePath 'msiexec.exe' -Arguments "/i `"$localMsi`" $quiet/norestart$props"
            if ($null -ne $code) { Write-Log "msiexec exit code: $code" }
        }

        'MsiRegistry' {
            # Two modes: an exact ProductCode (for apps whose DisplayName
            # collides with a sibling -- Acrobat Pro vs Reader both show
            # 'Adobe Acrobat (64-bit)'), or a DisplayNameLike lookup that
            # extracts whatever GUID is currently registered.
            $guid = $null
            if ($Spec.ProductCode) {
                foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
                    if (Test-Path "$hive\$($Spec.ProductCode)") { $guid = $Spec.ProductCode; break }
                }
                if (-not $guid) {
                    Write-Log "Product code $($Spec.ProductCode) is not registered on this machine." 'ERROR'
                    return
                }
            } else {
                # Filter for the entry whose UninstallString actually
                # carries an MSI product code -- vendors can register the
                # same DisplayName twice (CONFIRMED: Cisco Secure Client
                # registers a non-MSI entry first, and taking First 1
                # before checking for a GUID failed the uninstall).
                $entry = Get-ItemProperty `
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like $Spec.DisplayNameLike -and $_.UninstallString -match '\{[0-9A-Fa-f\-]+\}' } |
                    Select-Object -First 1
                if (-not $entry) {
                    Write-Log "No MSI-registered entry matching '$($Spec.DisplayNameLike)' was found." 'ERROR'
                    return
                }
                $null = $entry.UninstallString -match '\{[0-9A-Fa-f\-]+\}'   # re-match: Where-Object left `$Matches on its LAST evaluation
                $guid = $Matches[0]
            }
            $quiet = if ($Interactive) { '' } else { '/qn ' }
            $code = Invoke-ProcessStep -FilePath 'msiexec.exe' -Arguments "/x $guid $quiet/norestart MSIRESTARTMANAGERCONTROL=Disable"
            if ($null -ne $code) { Write-Log "msiexec exit code: $code" }
        }

        'Odt' {
            # Office Deployment Tool (Click-to-Run) products: Office,
            # Project, Visio, Outlook. setup.exe comes from the private
            # share (v1-proven paths); the config XML is GENERATED here,
            # minimal on purpose -- two v1 lessons baked in: request ONLY
            # the one product (the share's own config bundled Office +
            # Project + Visio together), and pin Language to en-us (no
            # <Language> made ODT install a pack for EVERY configured
            # keyboard/display language). Content pulls from Microsoft's
            # CDN -- 10-20+ minutes is normal.
            if (-not $Spec.ProductId) {
                Write-Log "The 'Odt' engine needs a ProductId ($($App.Name))." 'ERROR'
                return
            }
            if (-not (Test-Path $StageRoot)) { New-Item -Path $StageRoot -ItemType Directory -Force | Out-Null }
            $setup = Join-Path $StageRoot 'odt-setup.exe'
            # Uninstalls reuse the locally cached setup.exe from an
            # earlier install, so REMOVING an Office product needs no
            # share access (and no credentials). Installs always refresh
            # the cache from the share, keeping the ODT current.
            if ($Action -eq 'Uninstall' -and (Test-Path -LiteralPath $setup)) {
                Write-Log "Using the locally cached ODT setup.exe -- no share access needed for removals."
            } else {
                $shares = @(
                    '\\svazdfs001\systems$\Software\Microsoft\Office\MSOffice',
                    '\\10.1.0.5\systems$\Software\Microsoft\Office\MSOffice'
                )
                $src = $null
                foreach ($s in $shares) {
                    if (Test-Path (Join-Path $s 'setup.exe') -ErrorAction SilentlyContinue) { $src = $s; break }
                }
                if (-not $src) {
                    Write-Log "Could not reach the Office Deployment Tool setup.exe on the share. Checked: $($shares -join ', ')" 'ERROR'
                    return
                }
                Write-Log "Found ODT setup.exe at: $src"
                try {
                    Copy-Item -LiteralPath (Join-Path $src 'setup.exe') -Destination $setup -Force
                } catch {
                    Write-Log "Failed to stage setup.exe: $($_.Exception.Message)" 'ERROR'
                    return
                }
            }
            $disp = if ($Interactive) { 'Full' } else { 'None' }
            if ($Action -eq 'Uninstall') {
                # Product-specific <Remove> on purpose: Remove All would
                # take Project/Visio/other C2R products down with it.
                $cfg = @(
                    '<Configuration>',
                    ('  <Remove>'),
                    ('    <Product ID="{0}" />' -f $Spec.ProductId),
                    ('  </Remove>'),
                    ('  <Display Level="{0}" AcceptEULA="TRUE" />' -f $disp),
                    '</Configuration>'
                ) -join "`r`n"
            } else {
                $chan = if ($Spec.Channel) { ' Channel="{0}"' -f $Spec.Channel } else { '' }
                $cfg = @(
                    '<Configuration>',
                    ('  <Add OfficeClientEdition="64"{0}>' -f $chan),
                    ('    <Product ID="{0}">' -f $Spec.ProductId),
                    ('      <Language ID="en-us" />'),
                    ('    </Product>'),
                    ('  </Add>'),
                    ('  <Display Level="{0}" AcceptEULA="TRUE" />' -f $disp),
                    '</Configuration>'
                ) -join "`r`n"
            }
            $cfgPath = Join-Path $StageRoot ('odt-{0}-{1}.xml' -f $Spec.ProductId, $Action.ToLower())
            Set-Content -LiteralPath $cfgPath -Value $cfg -Encoding UTF8
            Write-Log "ODT $Action of $($Spec.ProductId) -- content comes from Microsoft's CDN; 10-20+ minutes is normal for installs."

            # Heartbeat: ODT prints NOTHING, but Click-to-Run's on-disk
            # footprint grows the whole time it is genuinely working --
            # so report that every 30s, and call out stalls loudly
            # (CONFIRMED need: an install sat 14 silent minutes blocked
            # on a stuck previous C2R scenario; a reboot clears that).
            $hb = @{ LastMB = -1; StillSince = $null }
            $probe = {
                $mb = [long]0
                foreach ($p in @("$env:ProgramData\Microsoft\ClickToRun", (Join-Path $env:ProgramFiles 'Microsoft Office'))) {
                    if (Test-Path -LiteralPath $p) {
                        $sum = (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                        if ($sum) { $mb += [long]($sum / 1MB) }
                    }
                }
                if ($mb -ne $hb.LastMB) {
                    Write-Log ("Click-to-Run is working: {0:N0} MB on disk so far..." -f $mb)
                    $hb.LastMB = $mb
                    $hb.StillSince = $null
                } else {
                    if (-not $hb.StillSince) { $hb.StillSince = Get-Date }
                    $stuck = [int]((Get-Date) - $hb.StillSince).TotalSeconds
                    if ($stuck -ge 120) {
                        Write-Log ("No Click-to-Run disk progress for {0}s -- it may be waiting on a stuck previous scenario (a leftover OfficeClickToRun.exe from a cancelled run holds the lock). Cancelling this step and REBOOTING the machine clears that state." -f $stuck) 'WARN'
                        $hb.StillSince = Get-Date   # re-warn every ~2 minutes, not every probe
                    }
                }
            }

            $code = Invoke-ProcessStep -FilePath $setup -Arguments "/configure `"$cfgPath`"" -TimeoutSeconds 5400 -ProgressProbe $probe
            if ($null -ne $code) { Write-Log "ODT setup.exe exit code: $code" }
        }

        'Registry' {
            # Uninstall through the app's own registered uninstaller
            # (tiered: QuietUninstallString -> MSI -> Inno -> NSIS /S),
            # no winget involved. Use this when winget's uninstall of a
            # package is broken (CONFIRMED: winget's 'silent' VLC
            # uninstall pops the NSIS 'Installer Language' dialog and
            # removes nothing; the registered uninstall.exe /S works).
            if ($Action -ne 'Uninstall') {
                Write-Log "The 'Registry' engine only supports uninstalls ($($App.Name))." 'ERROR'
                return
            }
            if (-not $Spec.DisplayNameLike) {
                Write-Log "The 'Registry' engine needs a DisplayNameLike ($($App.Name))." 'ERROR'
                return
            }
            Invoke-RegistryUninstall -DisplayNameLike $Spec.DisplayNameLike -Interactive $Interactive
        }

        'Custom' {
            $context = @{
                Interactive = $Interactive
                StageDir    = $StageRoot
                Log         = ${function:Write-Log}
                Variant     = $Variant
                Action      = $Action   # 'Repair' re-runs an Install script; scripts may branch on this if they ever need to
            }
            try { & $Spec.Script $context } catch {
                Write-Log "Custom action threw: $($_.Exception.Message)" 'ERROR'
            }
        }

        default {
            Write-Log "Unknown engine '$($Spec.Engine)' for $($App.Name)." 'ERROR'
        }
    }
}

function Invoke-AppAction {
    # Returns $true on success. Detection (not any exit code) decides.
    param([hashtable]$App, [string]$Action, [bool]$Interactive, [string]$Variant)

    $spec = if ($Action -eq 'Update') {
        # An explicit Update spec wins; otherwise a Winget-installed app
        # updates through winget upgrade with its install Id. Anything
        # else is not update-managed (the UI filters those out already).
        if ($App.ContainsKey('Update')) { $App.Update }
        elseif ($App.Install -and $App.Install.Engine -eq 'Winget') { @{ Engine = 'Winget'; Id = $App.Install.Id } }
        else { $null }
    } elseif ($Action -eq 'Repair') {
        # Repair = re-run the app's INSTALL method over the existing
        # install, skipping the already-installed shortcut. Reinstalling
        # over the top is the standard repair for MSI-based installers;
        # winget gets --force; ODT re-running its Add config makes
        # Click-to-Run restore itself. An explicit Repair spec in the
        # manifest wins if an app ever needs something different.
        if ($App.ContainsKey('Repair')) { $App.Repair } else { $App.Install }
    } else { $App[$Action] }
    if (-not $spec) {
        Write-Log "$($App.Name) has no $Action action defined in the manifest." 'ERROR'
        return $false
    }

    Invoke-EngineSpec -App $App -Spec $spec -Action $Action -Interactive $Interactive -Variant $Variant


    if ($Action -in @('Uninstall', 'Update', 'Repair')) { Restore-ExplorerIfKilled }

    # --- Verification: detection is the ground truth ---
    $nowPresent = [bool](& $App.Detect)
    $wantPresent = ($Action -ne 'Uninstall')   # Install and Update both want it present
    if ($Action -eq 'Uninstall' -and $nowPresent) {
        # Inno/NSIS uninstallers respawn themselves from %TEMP% so the
        # process we launched exits long before the uninstall finishes
        # (CONFIRMED: VLC's launched process exits in ~2s; the real
        # uninstall can take minutes). Poll detection instead of failing
        # on a single early check.
        Write-Log "Still detected after the uninstall command returned -- a respawned uninstaller may still be working. Waiting up to 120s..." 'WARN'
        $deadline = (Get-Date).AddSeconds(120)
        while ($nowPresent -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $nowPresent = [bool](& $App.Detect)
        }
    }
    if ($nowPresent -eq $wantPresent) {
        Write-Log "$($App.Name) ${Action}: verified by detection." 'SUCCESS'
        return $true
    } else {
        $why = switch ($Action) {
            'Install'   { 'the app is still NOT installed after the install attempt above' }
            'Update'    { 'the app is NO LONGER detected after the update attempt above (the update may have removed or broken it)' }
            'Repair'    { 'the app is NO LONGER detected after the repair attempt above (the repair may have removed or broken it)' }
            default     { 'the app is STILL installed after the uninstall attempt above' }
        }
        Write-Log "$($App.Name) ${Action} FAILED: $why -- detection is the ground truth here, whatever the exit codes said." 'ERROR'
        return $false
    }
}

# =============================== Main ===============================
. $ManifestPath

if ($CleanupApp) {
    # Cancel sweep: the UI killed an in-flight step's process tree and
    # asked for a best-effort tidy-up of that one app. An MSI that was
    # killed mid-install already rolled back on its own; this catches
    # the rest. Never fatal.
    Write-Log "--- Cancel sweep for '$CleanupApp' (best effort) ---" 'WARN'
    $app = Get-App -Name $CleanupApp
    if ($app) {
        if ($CleanupAction -eq 'Install') {
            # A cancelled UPDATE or REPAIR cannot be undone -- repair by
            # reinstall. For an Office product, stop Click-to-Run's
            # in-flight scenario FIRST: the service keeps working after
            # setup.exe dies, and a leftover scenario lock would make the
            # reinstall below wait forever.
            if ($app.Install -is [hashtable] -and $app.Install.Engine -eq 'Odt') {
                Write-Log "Stopping the Office Click-to-Run service's in-flight work before the repair reinstall..." 'WARN'
                try { Stop-Service -Name 'ClickToRunSvc' -Force -ErrorAction SilentlyContinue } catch {}
                foreach ($pname in @('OfficeClickToRun', 'OfficeC2RClient')) {
                    Get-Process -Name $pname -ErrorAction SilentlyContinue | ForEach-Object {
                        try { & taskkill.exe /PID $_.Id /T /F 2>$null | Out-Null } catch {}
                    }
                }
                Start-Sleep -Seconds 3
            }
            if (& $app.Detect) {
                Write-Log "'$CleanupApp' is still detected after the interrupted update/repair -- re-running its installer to make sure it is healthy."
            } else {
                Write-Log "'$CleanupApp' is missing after the interrupted update/repair -- reinstalling it." 'WARN'
            }
            [void](Invoke-AppAction -App $app -Action 'Install' -Interactive:$false)
        } elseif ($app.Uninstall -is [hashtable] -and $app.Uninstall.Engine -eq 'Odt') {
            # ODT apps get the service stop UNCONDITIONALLY, before any
            # detection check: killing ODT's setup.exe does NOT stop an
            # Office install -- the Click-to-Run SERVICE does the real
            # work -- and early in an install NOTHING is registered yet,
            # so a detect-first sweep says "nothing to sweep" while the
            # service quietly finishes the install (CONFIRMED twice: both
            # cancelled Office installs completed anyway).
            Write-Log "Stopping the Office Click-to-Run service's in-flight work..." 'WARN'
            try { Stop-Service -Name 'ClickToRunSvc' -Force -ErrorAction SilentlyContinue } catch {}
            foreach ($pname in @('OfficeClickToRun', 'OfficeC2RClient')) {
                Get-Process -Name $pname -ErrorAction SilentlyContinue | ForEach-Object {
                    try { & taskkill.exe /PID $_.Id /T /F 2>$null | Out-Null } catch {}
                }
            }
            Start-Sleep -Seconds 3
            if (& $app.Detect) {
                [void](Invoke-AppAction -App $app -Action 'Uninstall' -Interactive:$false)
            } else {
                Write-Log "The in-flight Click-to-Run install was stopped before it registered anything. If '$CleanupApp' still appears in Programs and Features later, the service resumed it -- run its uninstall from the menu." 'WARN'
            }
        } elseif (-not (& $app.Detect)) {
            Write-Log "'$CleanupApp' is not detected as installed -- nothing to sweep (an interrupted MSI rolls itself back)." 'SUCCESS'
        } else {
            [void](Invoke-AppAction -App $app -Action 'Uninstall' -Interactive:$false)
        }
    } else {
        Write-Log "'$CleanupApp' not found in the manifest." 'ERROR'
    }
    Write-Machine "::DONE::0"
    exit 0
}

$job = Get-Content -LiteralPath $JobFile -Raw | ConvertFrom-Json
$steps = @($job.Steps)
$interactive = [bool]$job.Interactive

Write-Log "=== AppsDeploy run starting on $env:COMPUTERNAME as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) ==="
Write-Log ("Plan: " + (($steps | ForEach-Object { "$($_.Action) $($_.Name)$(if ($_.Interactive) { ' (interactive)' })" }) -join '; '))
if ($interactive) { Write-Log "Interactive mode is ON for the whole job -- installer UIs will be shown instead of running silently." 'WARN' }

$anyFailed = $false
$i = 0
foreach ($step in $steps) {
    $i++
    $app = Get-App -Name $step.Name
    Write-Machine "::STEP::$i/$($steps.Count)::$($step.Name)::$($step.Action)"
    Write-Log ""
    Write-Log "--- $($step.Name) ($i of $($steps.Count)): $($step.Action) ---"

    if (-not $app) {
        Write-Log "'$($step.Name)' is not in the manifest -- skipping." 'ERROR'
        Write-Machine "::RESULT::$($step.Name)::FAILED"
        $anyFailed = $true
        continue
    }

    # Desired-state pre-check: the world may have changed since the scan.
    $present = [bool](& $app.Detect)
    if ($step.Action -eq 'Install' -and $present) {
        Write-Log "$($app.Name) is already installed -- nothing to do." 'SUCCESS'
        Write-Machine "::RESULT::$($step.Name)::OK"
        continue
    }
    if ($step.Action -eq 'Uninstall' -and -not $present) {
        Write-Log "$($app.Name) is not installed -- nothing to do." 'SUCCESS'
        Write-Machine "::RESULT::$($step.Name)::OK"
        continue
    }
    if ($step.Action -eq 'Update' -and -not $present) {
        Write-Log "$($app.Name) is not installed -- nothing to update." 'SUCCESS'
        Write-Machine "::RESULT::$($step.Name)::OK"
        continue
    }
    if ($step.Action -eq 'Repair' -and -not $present) {
        # A repair deliberately has NO already-in-desired-state skip --
        # running the installer again is the whole point. If the app
        # vanished since the scan, the repair simply installs it fresh.
        Write-Log "$($app.Name) is not currently detected -- the repair will install it fresh." 'WARN'
    }

    # Interactivity is per step (the GUI row's wrench); the job-wide
    # flag still wins when set.
    $stepInteractive = $interactive -or [bool]$step.Interactive
    if ($stepInteractive -and -not $interactive) {
        Write-Log "This step runs INTERACTIVE -- the vendor's own installer window will be shown." 'WARN'
    }
    $ok = Invoke-AppAction -App $app -Action $step.Action -Interactive:$stepInteractive -Variant ([string]$step.Variant)
    Write-Machine "::RESULT::$($step.Name)::$(if ($ok) { 'OK' } else { 'FAILED' })"
    if (-not $ok) { $anyFailed = $true }
}

Write-Log ""
Write-Log "=== Run complete. $(if ($anyFailed) { 'One or more steps FAILED -- see above.' } else { 'All steps succeeded.' }) ===" $(if ($anyFailed) { 'ERROR' } else { 'SUCCESS' })
Write-Machine "::DONE::$(if ($anyFailed) { 1 } else { 0 })"
exit $(if ($anyFailed) { 1 } else { 0 })
