# VS Code / Windows Terminal Deployment

Wrike: "Install VS Code and Windows Terminal on all employee machines"

Idempotent install/uninstall scripts for VS Code and Windows Terminal, run
via ConnectWise Automate against employee machines. Each Automate script step
downloads the current version of the matching `.ps1` file from the public
`randysworldwide/rww-installers` repo at runtime and executes it, so this
repo is the single source of truth — editing the Automate script steps
directly should not be necessary.

## Files

| File | Purpose |
|---|---|
| `Scripts/VSCWinTerminalInst.ps1` | Installs VS Code and/or Windows Terminal machine-wide |
| `Scripts/VSCWinTerminalUninst.ps1` | Uninstalls VS Code and/or Windows Terminal machine-wide |

Both are designed to run as SYSTEM (via Automate) but also work run manually
from an elevated PowerShell session.

## How they work

**Install (`VSCWinTerminalInst.ps1`)**
- Resolves `winget.exe` directly (SYSTEM doesn't have it on PATH by default).
- Installs VS Code via `winget --scope machine` (forcing machine scope avoids
  it landing in the SYSTEM profile instead of somewhere the real user can see it).
- Installs Windows Terminal via winget; if that doesn't result in a verified
  machine-wide package (SYSTEM has no Store auth token), falls back to
  downloading the latest `.msixbundle` from the Microsoft/terminal GitHub
  releases and provisioning it via `Add-AppxProvisionedPackage -SkipLicense`.
- Checks registry (`Uninstall` keys, including loaded user hives) and
  `Get-AppxPackage -AllUsers` before doing anything, so re-running on a
  machine that already has both apps is a no-op.

**Uninstall (`VSCWinTerminalUninst.ps1`)**
- Mirrors the install script's structure and idempotency checks.
- Removes VS Code via `winget uninstall`, falling back to the registry
  `QuietUninstallString`/`UninstallString` if winget doesn't fully clear it.
- Removes Windows Terminal via `Remove-AppxProvisionedPackage` (so new
  profiles don't get it either) and `Remove-AppxPackage -AllUsers`.

## Parameters

Both scripts accept:

```powershell
-Apps <'VSCode','Terminal'>   # default: both
-LogPath <string>             # default: C:\ProgramData\Dev\Logs\Install-DevTools.log
                               #      or  C:\ProgramData\Dev\Logs\Uninstall-DevTools.log
```

## Exit codes

**Install:**
| Code | Meaning |
|---|---|
| 0 | Success — at least one app was actually installed this run |
| 1 | One or more apps failed to install |
| 2 | winget could not be resolved and no fallback available |
| 3 | Not running elevated |
| 4 | Nothing to do — every requested app was already installed |

**Uninstall:**
| Code | Meaning |
|---|---|
| 0 | Success — at least one app was actually removed this run |
| 1 | One or more apps failed to uninstall |
| 3 | Not running elevated |
| 4 | Nothing to do — none of the requested apps were installed |

## Automate wiring

Each Automate "Execute Script" step does **not** contain the full script body.
It contains a small bootstrap wrapper that:

1. Downloads the current version of the matching `.ps1` from the public
   `rww-installers` repo (`raw.githubusercontent.com`, no authentication
   needed since the repo is public).
2. Saves it to `C:\ProgramData\Dev\Scripts\`.
3. Runs it and propagates its exit code.

Script step layout (both Install and Uninstall scripts follow this same
pattern):

```
1. Execute Script (PowerShell) → store result in @VSCInst@ / @VSCUninst@
2. Log Message → "VSCInst value: @VSCInst@"
3. IF Variable Check → @VSCInst@ Contains "Nothing was installed"/"Nothing was uninstalled"
       → then goto :ESAF
4. IF Variable Check → @VSCInst@ Contains "[ERROR]"
       → then goto :ESAF
5. Exit Script
6. Label :ESAF
7. Exit Script (as failed)
```

Step 4 matters as much as step 3: without it, a genuine failure (download
failure, winget failure, not-elevated, etc.) doesn't contain the "Nothing
was..." skip phrase, so step 3's condition is false and execution falls
through to the plain "Exit Script" in step 5 — which reports **success**
regardless of what actually happened. The `[ERROR]` tag is used consistently
by every real error line in both the bootstrap wrapper and the underlying
`Write-Log` function, so checking for it catches download failures, install/
uninstall failures, and any other genuine error in one place.

This makes Automate report a **failure** specifically when the run did
nothing (every app already present for install, or every app already absent
for uninstall) — a genuine install/uninstall failure (exit 1) or a normal
success (exit 0) both fall through step 4 as usual.

## Maintenance notes

- This repo's `main` branch is fetched live on every script run — there is no
  version pinning. Test changes before merging to `main`, since a bad commit
  immediately affects the next machine the script runs on.
- Windows Terminal's fallback path pulls the latest `.msixbundle` from
  `github.com/microsoft/terminal/releases/latest` dynamically — no version
  is hardcoded there either.
- Local logs land at `C:\ProgramData\Dev\Logs\` on each target machine.
- Because `rww-installers` is public, anyone can view these scripts. Don't
  commit anything sensitive (tokens, internal hostnames beyond what's already
  here, credentials) into this repo.
