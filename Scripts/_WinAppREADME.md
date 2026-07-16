Windows App (Remote Desktop Client) Deployment
Wrike: "Deploy Windows App (RDP client) to all employee machines"

Idempotent install/uninstall scripts for the Windows App (`MicrosoftCorporationII.Windows365`, the modern Microsoft Remote Desktop client), run via ConnectWise Automate against employee machines. Each Automate script step downloads the current version of the matching .ps1 file from the public randysworldwide/rww-installers repo at runtime and executes it, so this repo is the single source of truth — editing the Automate script steps directly should not be necessary.

Files
File	Purpose
Scripts/WinAppInst.ps1	Installs Windows App machine-wide
Scripts/WinAppUninst.ps1	Uninstalls Windows App machine-wide (including currently logged-in sessions)
Both are designed to run as SYSTEM (via Automate) but also work run manually from an elevated PowerShell session.

Why this doesn't use winget
Windows App is a Microsoft Store (MSIX) package. winget's `msstore` source needs an interactive Store auth token that SYSTEM doesn't have, and this environment's TLS inspection proxy blocks the Store source outright. Instead of fighting that, the install script sideloads the package directly from a GitHub Release in this repo and provisions it with `Add-AppxProvisionedPackage`.

Release assets (uploaded to this repo's Release, tag `Release`, not committed into the repo tree — binaries don't belong in git history):

- `MicrosoftCorporationII.Windows365_2.0.1247.0_x64.Msix` (main package)
- `Microsoft.VCLibs.140.00_14.0.33519.0_x64.Appx` (dependency)
- `Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.Appx` (dependency)

If Microsoft ships a new Windows App version, upload the new files to the Release and update the filenames/version strings in `WinAppInst.ps1` — there's no dynamic "latest release" lookup here (unlike Windows Terminal's fallback in the VSCode/Terminal scripts), since the dependency set needs to be verified together as a known-good combination before rolling out.

How they work
Install (WinAppInst.ps1)

- Checks `Get-AppxProvisionedPackage` for an existing machine-wide install before doing anything, so re-running on a machine that already has it is a no-op.
- Creates `C:\ProgramData\Dev\WindowsApp` (staging folder) if it doesn't exist, and makes sure `C:\ProgramData\Dev` is hidden.
- Downloads the three release files above into that staging folder.
- Runs `Add-AppxProvisionedPackage -Online -PackagePath ... -DependencyPackagePath ... -SkipLicense`.
- Leaves the staged files in place afterward (kept intentionally, for easy repair/re-install — nothing deletes them automatically).

Uninstall (WinAppUninst.ps1)

- Removes the machine-wide provisioning via `Remove-AppxProvisionedPackage` (so new profiles won't get it either).
- Finds every user profile that currently has the app installed — including a session that's logged in right now — force-closes any running instance of the app, then removes it for that profile via `Remove-AppxPackage -AllUsers`. This does not log the user out of Windows; it force-closes the app itself and removes it while they stay logged in.
- Optional `-RemoveStagingFiles` switch also deletes `C:\ProgramData\Dev\WindowsApp`. Off by default.

Parameters
WinAppInst.ps1:
```
-LogPath <string>   # default: C:\ProgramData\Dev\Logs\WinAppInst.log
```

WinAppUninst.ps1:
```
-LogPath <string>            # default: C:\ProgramData\Dev\Logs\WinAppUninst.log
-RemoveStagingFiles <switch>  # default: off (staged install files are kept)
```

Exit codes
Install:

Code	Meaning
0	Success — app was actually provisioned this run
1	Install failed
2	One or more required files failed to download
3	Not running elevated
4	Nothing to do — already provisioned

Uninstall:

Code	Meaning
0	Success — deprovisioned and/or per-user copies removed
1	One or more steps failed
3	Not running elevated
4	Nothing to do — app was not present anywhere on this machine

Automate wiring
Each Automate "Execute Script" step does not contain the full script body. It contains a small bootstrap wrapper that:

1. Downloads the current version of the matching .ps1 from the public rww-installers repo (raw.githubusercontent.com, no authentication needed since the repo is public).
2. Saves it to `C:\ProgramData\Dev\Scripts\`.
3. Runs it and propagates its exit code.

The wrapper code itself is kept as a reference copy at `Scripts/BootstrapperScripts/WinApp-Bootstrap-Install.ps1` and `Scripts/BootstrapperScripts/WinApp-Bootstrap-Uninstall.ps1` — see `BootstrapperScripts/README.md` for details on how those relate to the actual Automate Script Editor steps (short version: they are not run directly on target machines; Automate's Script Editor content is what actually runs, and these files are a version-controlled mirror of it).

Script step layout (both Install and Uninstall scripts follow this same pattern):
```
1. Execute Script (PowerShell) → store result in @WinAppInst@ / @WinAppUninst@
2. Log Message → "WinAppInst value: @WinAppInst@"
3. IF Variable Check → @WinAppInst@ Contains "Nothing was installed"/"Nothing was uninstalled"
       → then goto :ESAF
4. IF Variable Check → @WinAppInst@ Contains "[ERROR]"
       → then goto :ESAF
5. Exit Script
6. Label :ESAF
7. Exit Script (as failed)
```
Step 3 catches the "nothing to do" skip case (app already present for install, or already absent for uninstall). Step 4 catches genuine failures — bootstrap download errors and real install/uninstall errors both use the same `[ERROR]` tag (see the `Write-Log` function in both .ps1 files), so this one check covers both failure sources. Without step 4, a bootstrap-level failure (e.g. DNS resolution failing on a specific machine, blocking the raw.githubusercontent.com download) doesn't contain the skip phrase, falls through step 3's IF, and gets reported as a false Success — step 4 closes that gap. Only when neither IF matches does the run fall through to step 5 as a genuine, successful install/uninstall.

Maintenance notes
- This repo's main branch is fetched live on every script run — there is no version pinning on the .ps1 files themselves. Test changes before merging to main, since a bad commit immediately affects the next machine the script runs on.
- The `.msix`/`.appx` release assets ARE version-pinned by filename inside `WinAppInst.ps1` — bumping the Windows App version means updating both the uploaded Release assets and the filenames referenced in the script.
- Local logs land at `C:\ProgramData\Dev\Logs\` on each target machine.
- Staged install files land at `C:\ProgramData\Dev\WindowsApp\` (kept after install by default).
- Because rww-installers is public, anyone can view these scripts. Don't commit anything sensitive (tokens, internal hostnames beyond what's already here, credentials) into this repo.
