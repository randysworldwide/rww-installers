# AppsDeploy v2 — How It Works and Why

AppsDeploy is RANDYS's tool for installing, uninstalling, and repairing workstation software. A tech checks boxes for the apps a machine should have, clicks Proceed, and the tool makes the machine match. It works on a bench machine before shipping, in a user's live session, or remotely as SYSTEM through Automate Backstage.

It replaced the v1 Apps-Deploy-Menu as part of the deployment overhaul: OSDCloud now handles imaging and baseline agents, Intune handles user-driven apps, and AppsDeploy covers everything a tech applies by hand.

## Running it

Run `AppsDeploy.bat` from `rww-installers/Scripts/AppsDeploy2/`. It elevates itself, downloads the latest scripts from GitHub into `%TEMP%`, and launches. The bat works standalone (e.g. from the Automate Shared Toolbox), and because it always pulls from GitHub, updating the repo updates every machine. If GitHub is unreachable it runs the last downloaded copy and says so.

Logs: `C:\ProgramData\RWW\AppsDeploy\Logs\` — one log plus the job plan per run.

## The pieces

- **AppsDeploy.bat** — launcher: elevate, download, run.
- **AppsDeploy-UI.ps1** — the menu and progress window. Never installs anything itself.
- **AppsDeploy-Worker.ps1** — a separate process that does the actual work.
- **AppsDeploy-Manifest.ps1** — the app catalog: how to detect, install, and uninstall each app, plus the role profiles. **To add an app or a role profile, edit only this file** — a new entry automatically gets the wrench, detection, cancel cleanup, share gating, and console mode.

## The four design rules

**1. The UI and the worker are separate processes.** In v1, installs ran inside the GUI process and heavy installers froze the window. In v2 the UI writes a job file, launches the worker, and just tails its log. They share nothing else, so the GUI cannot freeze no matter what an installer does.

**2. Detection is the truth, not exit codes.** Installers lie — Logi Options+ returns an "error" code on success, and ZAC's v1 "chronic failures" were actually successes. So every app has a detection check (is it really installed?). The worker detects before each step (skip if already done) and after (that result, not the exit code, decides pass/fail). The menu checkboxes always show what's actually on the machine.

**3. One install method per app, no automatic fallbacks.** An early build tried a second method when the first failed. That made failures ambiguous and the code hard to trust, so it was removed: each app has exactly one silent install method and one uninstall method, which works or fails clearly in the log. If an app keeps failing silently, the tech lights its **wrench** (below) to get the vendor's normal wizard — the only fallback, and a visible per-app human choice.

**4. Cancel cleans up after itself.** Cancel kills the worker and then sweeps the one app that was mid-flight: a cancelled install gets uninstalled, a cancelled update or repair gets a repair reinstall. (Office is special — see below.)

## The wrench (interactive runs and repairs)

Every row has a wrench-and-gear toggle at its far right edge, shown whenever the app is installed or checked to be installed. Lit (green), it means **"show the vendor's own installer window for this app instead of running silently"**, and what that does follows from the row's state:

- Checked but not installed → an **interactive install** (the vendor's setup wizard).
- Unchecked but installed → an **interactive uninstall**.
- Installed and staying installed → queues a **Repair**: the installer runs again over the existing install, and the vendor's setup opens with its own Repair/Modify options.

Interactivity is per app, not per run, so one Proceed can mix silent installs with an interactive repair. Repairs are verified by detection like everything else, and a repair of a share-based app needs the share just like its install does. In Backstage's console mode, repairs exist too (`E <num>`) but always run silently — a vendor window on a hidden desktop would be invisible and hang the run.

## Install methods (engines)

Each manifest entry names one engine for install and one for uninstall (a repair re-runs the install engine over the top — the standard repair for MSI-based installers; winget gets `--force`):

| Engine | What it does |
|---|---|
| Winget | Installs from winget, machine-scope where supported. |
| Msi | Downloads an MSI from a URL and installs silently. |
| MsiRegistry | Uninstalls via `msiexec /x` using the app's registry entry (by name or exact ProductCode). |
| Registry | Uninstalls non-MSI apps via their own registered uninstaller with the right silent switches. |
| Odt | Microsoft Office, via the Office Deployment Tool. |
| Custom | A script in the manifest, for anything the above can't express. It receives the action (Install/Repair), interactivity, and any variant choice. |

**Key pattern:** winget *installs* are reliable, but its "silent" *uninstalls* often pop the vendor's full wizard (VLC, VS Code, Firefox). Those apps install with Winget and uninstall with Registry.

## Office

Office products install via the ODT `setup.exe` from the software share, with a minimal config generated on the fly (one product, en-US). Each product (M365 Apps, Office 2021, Project, Visio, standalone Outlook) is its own menu entry. Installs are slow and silent, so the log reports Click-to-Run's disk usage every 30 seconds and warns if it stalls.

Two things to know:
- **Uninstalls never need the share** — setup.exe is cached locally at install time.
- **Cancelling Office:** the Click-to-Run *service* keeps installing after setup.exe dies, so the cancel sweep stops the service first. And if a C2R install is ever force-killed outside the tool, a leftover process can hang the *next* Office install at 0% CPU — reboot to clear it.

## The network share

Apps installed from `\\svazdfs001\systems$` are tagged "(uses network share)" in the menu. The tool only asks for credentials when the selected plan actually needs the share, tries silent access first (domain-joined techs usually sail through), and pre-fills `RPSINC\` in the prompt. The connection is temporary and credentials are never saved. A winget-only plan never sees any of this.

## Menu features

- **Categories** in deployment order (Runtimes → Agents → Office → Communications → Browsers → Utilities → Development), alphabetical within.
- **Profiles** — "Standard" and "Developer" pre-check a known-good app set on top of whatever's installed. Profiles never uncheck or uninstall anything. Lists live in the manifest; a new role for deployment = a new profile there (a name plus a list of app names).
- **Rescan** — re-detect everything on demand.
- **Update installed apps** — `winget upgrade` across winget-managed apps; self-updaters (Chrome, Claude) skipped.
- **Site dropdown** on the ConnectWise agent row (inboard of the wrench) — picks which client site the agent binds to. Proceeding with the default "New PCs" still selected asks for confirmation, because installing an agent under the wrong site is an easy mistake. The choice also rides a repair.
- **Liveness** — a status dot, an elapsed/last-output ticker, and streamed installer output, so a quiet log never leaves you guessing whether it's alive.

## Backstage

WPF can't render on hidden desktops — Backstage gets a black window, full stop. So the UI detects its desktop and, outside a normal session, presents the same tool as a **text menu**: same manifest, same worker, same logs, same confirmations, plus silent repairs via `E <num>`. Only limitation: no mid-run cancel. Also note: MSIX apps can't install as SYSTEM (fails with a clear message), and uninstalls warn if users are logged on.

## App quick reference

| App | Notes |
|---|---|
| ConnectWise Automate agent | Site MSI + MST transform from the share (the MST binds the site). Detect = LTService. Uninstall = ConnectWise's generic uninstaller, cached at install time. **Each install consumes an Automate seat — retire the old console record. Backstage uninstall cuts your own session.** |
| Cisco Secure Client | VPN module only (Umbrella lapsed). Our prebuilt silent bundle from the share. Detect = profile XML + service *exists* (not running — a stopped service isn't "uninstalled"). |
| Acrobat Reader / Pro | Same display name in Add/Remove, so both are keyed by ProductCode (Pro = `...FFFF...`, Reader = `...FF00...`). Pro needs no license to install; users sign in on their own profile. |
| MXAdmin | Downloads from **our own** MX (`randysww.mxvirtual.com`) — each MX serves its matching MXAdmin version. Never use a third-party MX found by search. |
| ZAC | winget (Zultys keeps the manifest current). ARP name is exactly 'ZAC'. |
| MSIX apps (Terminal, Windows App, Claude) | Detect by exact package name (`-AllUsers`); loose wildcards match the wrong packages. Per-user winget install; uninstall removes + de-provisions. Terminal's auto-launch after install gets auto-closed (skipped on repairs — a running Terminal could be the tech's own). Claude uses Anthropic's evergreen MSIX URL and self-updates, so re-provisioning the same version on a repair is refused by Windows — logged as a warning, not a failure. |
| VC++ Redistributables | One checkbox = 2010/2012/2013/2015+ × both architectures. Microsoft renamed "2015-2022" to "v14" in new builds; detection accepts both. |
| Office 2021 | Detect string is `*Office LTSC*2021*` — v1's pattern never matched (latent bug). |
| winget itself | If broken machine-wide (0x8A15000F): `winget source reset --force`. |

Full details for every app are in the manifest.

## For maintainers — pitfalls baked into the code

These each cost real debugging time; don't reintroduce them.

- Never do work or force rendering inside a WPF event handler — handlers return immediately and a timer does the work. Pumping the dispatcher in a handler crashes the app.
- No `$script:` variables inside `GetNewClosure()` blocks — they silently become `$null`.
- Sort hashtables with `Sort-Object { $_.Name }`, never `-Property Name` (returns nulls, then PS 5.1's unstable sort scrambles the order).
- The UI detaches from its console and launches every native exe windowless — otherwise each child spawns a visible console window, and uninstalling Windows Terminal (the default console host on Win11) would kill the tool itself.
- The UI waits 3 seconds after the worker exits before reading the verdict — the final log write can race the exit.
- The wrench icon is vector path data in the UI (same grammar as SVG paths), so the scripts stay pure ASCII — no image files, no Unicode glyphs.

## Status

The GUI/feature set is considered settled for now; the roster will keep growing as more roles come up for deployment (new apps = manifest entries, new roles = profiles). All 27 apps proven on real machines except the ConnectWise agent (needs an expendable test box — each install burns a seat). Remaining: push the current wrench/repair build to GitHub (the repo still holds the pre-repair version), run the bat from the Automate Toolbox end-to-end once, bench the CW agent, pilot, then decommission v1.
## Next steps
- Bench the last three on suitable hardware: CW Automate Agent (expendable box; seat consumed per install), Acrobat Pro (licensed sign-in machine; also the Reader+Pro coexistence check), Cisco Secure Client wrapper.
- Push `Scripts/AppsDeploy2/` to main when ready; production .bat already points there. Then production pilot.
- Decommission v1's rename/join/reboot-resume/throwaway-account machinery. RPS Reporting Center shortcuts deferred pending Intune approach.
