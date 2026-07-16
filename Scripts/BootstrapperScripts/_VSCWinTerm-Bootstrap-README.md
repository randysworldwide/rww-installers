# Bootstrapper Scripts

This folder holds the two small wrapper scripts used inside ConnectWise
Automate's **Execute Script** step for the VS Code / Windows Terminal
install and uninstall jobs.

## What these are — and what they're not

These files are **not** standalone scripts meant to be run directly on a
target machine, and they are **not** downloaded or fetched by anything
themselves. They contain no install/uninstall logic at all.

Instead, the content of each file is pasted directly into the **Script
Editor** box of the corresponding Automate script's `Execute Script` step
(Control Center → Scripts → [script name] → Editor). Automate runs that
pasted text as the actual PowerShell payload on the target machine — the
`.ps1` file sitting in this repo folder is just the source-controlled copy
of what should be in that box, kept here so changes to the wrapper logic
are tracked and reviewable instead of only existing inside Automate itself.

## What they actually do

At runtime, on the target machine, each wrapper:

1. Downloads the current version of the real install/uninstall script from
   `rww-installers/Scripts/` (`VSCWinTerminalInst.ps1` or
   `VSCWinTerminalUninst.ps1`) via `raw.githubusercontent.com`.
2. Saves it to `C:\ProgramData\Dev\Scripts\`.
3. Runs it and propagates its exit code back to Automate.

This means the real install/uninstall logic always comes from whatever is
currently on the `main` branch of `Scripts/` — editing those two files is
enough to change behavior fleet-wide. Editing the Automate script steps
themselves should only be necessary if the bootstrap/fetch logic itself
needs to change (e.g. a different local path, a different repo location).

## Files

| File | Pastes into |
|---|---|
| `VSCWinTerm-Bootstrap-Install.ps1` | The `Execute Script` step of the Install Automate script |
| `VSCWinTerm-Bootstrap-Uninstall.ps1` | The `Execute Script` step of the Uninstall Automate script |

## Keeping Automate in sync with this folder

If you change either file here, the corresponding Automate script step must
be updated to match — select all the existing text in that step's Script
Editor box, delete it, and paste in the new version fresh. Automate does not
pull these files automatically; only the *install/uninstall logic itself*
is fetched live at runtime, not the bootstrapper that does the fetching.

See the main [README](../_VSCWinTerminalREADME.md) for the full Automate
step layout (Log Message, IF Variable Check, skip/error branching) that
these wrappers feed into.
