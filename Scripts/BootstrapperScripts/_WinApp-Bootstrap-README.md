Windows App Bootstrapper Scripts

These two files are **not run directly on target machines**. They exist purely as a reference copy of the code pasted into the ConnectWise Automate Control Center's "Execute Script" step editor, for the Windows App install/uninstall Automate scripts.

Files
File	Used in
WinApp-Bootstrap-Install.ps1	The "WinApp Install" Automate script's Execute Script step
WinApp-Bootstrap-Uninstall.ps1	The "WinApp Uninstall" Automate script's Execute Script step

What they actually do
When an Automate script runs on a target machine, the *only* code that executes there is whatever is pasted into that step in the Script Editor. These two files are that pasted code — kept here so there's a version-controlled, readable copy of what's currently live in Automate, since the Script Editor itself isn't a great place to review or diff PowerShell.

Each one is a small wrapper that, when it runs on the target machine:

1. Downloads the current version of `WinAppInst.ps1` / `WinAppUninst.ps1` from `rww-installers/Scripts/` (the real install/uninstall logic — see `../_WinAppREADME.md`).
2. Saves it to `C:\ProgramData\Dev\Scripts\` on that machine.
3. Runs it and propagates its exit code back to Automate.

If Automate's Execute Script step content ever drifts from what's in this folder, **Automate wins** — it's the thing actually running. Update both: paste the change into the Script Editor first, confirm it works, then copy the same content back into this file so the repo stays an accurate reference.

Why the wrapper is split out from the real logic
Keeping the wrapper this thin means the actual install/uninstall behavior (`WinAppInst.ps1` / `WinAppUninst.ps1`) can be edited and improved in this repo without ever touching the Automate script steps again. The wrapper only needs to change if the fetch mechanism itself changes (e.g. a different repo, branch, or file path).

Related Automate configuration
Both Automate scripts follow the same step layout after the Execute Script step runs and stores its result in a variable (`@WinAppInst@` / `@WinAppUninst@`):

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

Step 4 is what catches genuine failures (download errors from this wrapper, or real install/uninstall errors from the downloaded script) that don't happen to contain the "nothing to do" skip phrase — without it, those failures fall through to step 5 and get reported as a false Success.

See `../_WinAppREADME.md` for the full install/uninstall script documentation, exit codes, and staging file locations.
