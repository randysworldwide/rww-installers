# Camera Roll Tablet Sync

Deploys and maintains the Camera Roll → network share sync for warehouse
tablets. One generic deployment covers every location - no per-site scripts
to maintain, and no per-site Automate scripts either.

## What this does

Warehouse tablets take photos that need to land in each location's
"Incoming Receipt Photos" folder on `\\svazdfs001\DepartmentalShares`. This
deployment:

1. Redirects the tablet's Camera Roll folder to a local public path
2. Maps a network drive to the shared photo destination (if not already mapped)
3. Auto-detects which warehouse location the tablet belongs to
4. Syncs new photos to that location's folder on the network share every
   couple of minutes, as the logged-in user (so the right network
   credentials are available)

New tablets in an existing location (CA1, KY1, TX1, WA1) work with zero
per-site setup - just run the Automate script.

## Files

| File | Runs as | Purpose |
|---|---|---|
| `Install-CameraRoll.ps1` | SYSTEM (via Automate) | Bootstrapper - deploys the two payload scripts and registers the `SetCameraRoll` scheduled task. Run once per tablet. |
| `Uninstall-CameraRoll.ps1` | SYSTEM (via Automate) | Idempotent removal - unregisters all Camera Roll scheduled tasks and deletes the payload scripts. Leaves local photos and already-synced network photos untouched. |
| `SetCameraRoll.ps1` | SYSTEM, at every logon | Redirects Camera Roll locally, creates a desktop shortcut, maps the network drive if needed, and (re)registers the per-user sync task for whoever just logged on. |
| `SyncCameraRoll.ps1` | Logged-in user, every 2 min | Auto-detects the tablet's location and copies new Camera Roll photos to that location's network folder. |

All scripts and their logs live in `C:\ProgramData\Dev\CameraRoll` on the
tablet.

## How location detection works

`SyncCameraRoll.ps1` figures out which warehouse it's running in every time
it runs - it is never hardcoded per tablet.

**1. Hostname parsing (primary).** Tablet names follow the convention
`WS<LOC><category><###>`, e.g. `WSCA1WHS027`. The script pulls only the
3 characters immediately after `WS` (2 letters + 1 digit) as the location
code - it does not care what follows, so `WHS`, `ACC`, `SLS`, `ITG`, or any
future category still resolves correctly:

```
WSCA1WHS027  -> CA1
WSWA1SLS103  -> WA1
WSCA2ACC003  -> CA2
```

**2. AD OU lookup (fallback).** If the hostname doesn't match the pattern
(e.g. a tablet gets renamed off-convention), the script queries the
computer's Active Directory OU path via `System.DirectoryServices` and
extracts the location code from the OU name, which follows the format
`<LOC> - <City>` (e.g. `CA1 - Fresno` -> `CA1`). No RSAT module required.

**3. Fail safe.** If neither method resolves to a location in
`$validLocations` inside `SyncCameraRoll.ps1`, the script logs an `[ERROR]`
and exits without syncing. It never guesses and pushes photos to the wrong
warehouse folder.

### Current locations

| Code | City | OU |
|---|---|---|
| CA1 | Fresno | `RPSInc Clients/Workstations/Distribution/CA1 - Fresno` |
| KY1 | Florence | `RPSInc Clients/Workstations/Distribution/KY1 - Florence` |
| TX1 | Carrolton | `RPSInc Clients/Workstations/Distribution/TX1 - Carrolton` |
| WA1 | Everett | `RPSInc Clients/Workstations/Distribution/WA1 - Everett` |

### Adding a new location

1. Add the new code to the `$validLocations` array in `SyncCameraRoll.ps1`
   and commit.
2. Make sure new tablets at that location either follow the `WS<LOC>...`
   naming convention or sit in an OU named `<LOC> - <City>`.
3. Nothing else to do - the network destination folder
   (`...\Incoming Receipt Photos\<LOC>\Camera Roll`) is created
   automatically on first successful sync.

## Scheduled tasks

Three tasks exist across the two-layer automation below - none are created
manually:

| Task | Created by | Runs as | Trigger |
|---|---|---|---|
| `SetCameraRoll` | `Install-CameraRoll.ps1` | SYSTEM | At logon |
| `CameraRoll-Sync-User` | `SetCameraRoll.ps1` (dynamically, every logon) | Logged-in user | Every 2 min |
| `CameraRoll-MapDrive` | `SetCameraRoll.ps1` (only if drive not already mapped) | Logged-in user | One-time, 20s after creation |

Automate only ever touches `Install-CameraRoll.ps1` / `Uninstall-CameraRoll.ps1`
directly - everything downstream registers and re-registers itself.

## Deployment (ConnectWise Automate)

**Script: "Camera Roll Tablet Sync - Install"**

1. Execute Script (PowerShell) - download and run `Install-CameraRoll.ps1`,
   store output in `CRInstOut`
2. Log Message - `CRInstOut` value
3. IF Variable Check - `CRInstOut` Contains `[ERROR]` -> `:ESAF`
4. Execute Script (PowerShell) - confirm the `SetCameraRoll` task was
   registered, store in `SetCRTaskExists`
5. Log Message - `SetCRTaskExists` value
6. IF Variable Check - `SetCRTaskExists` Not = `True` -> `:ESAF`
7. Execute Script (PowerShell) - trigger `SetCameraRoll` once immediately
   and tail its log, store in `SetCRLog`
8. Log Message - `SetCRLog` value
9. IF Variable Check - `SetCRLog` Contains `[ERROR]` -> `:ESAF`
10. EXIT SCRIPT
11. Label `:ESAF`
12. EXIT SCRIPT (as failed)

**Script: "Camera Roll Tablet Sync - Uninstall"** follows the same
log-then-check pattern, calling `Uninstall-CameraRoll.ps1` and then
verifying the tasks and payload files are actually gone (rather than just
trusting the script's own exit status).

## Logs (on the tablet)

All under `C:\ProgramData\Dev\CameraRoll`:

- `Install-CameraRoll.log`
- `Uninstall-CameraRoll.log`
- `SetCameraRoll.log`
- `SyncCameraRoll.log` (rotates at 500 KB, keeps last 500 lines)

## Troubleshooting

- **Sync log shows `[ERROR] Unable to determine a valid location`** - the
  tablet's hostname doesn't match `WS<LOC>...` and the AD OU lookup also
  failed or returned an unrecognized code. Check the hostname and OU
  placement, or confirm the location code has been added to
  `$validLocations`.
- **Network path unreachable** - `SyncCameraRoll.ps1` checks
  `\\svazdfs001\DepartmentalShares` before doing anything else and exits
  quietly if it's down; it retries on its next scheduled run, no action
  needed unless the outage is prolonged.
- **Drive letter never maps** - check `CameraRoll-MapDrive` in Task
  Scheduler; it's a one-time task that deletes itself after running, so if
  it's missing entirely it either already succeeded (check
  `SetCameraRoll.log` for "already mapped") or never got created because a
  mapping was already detected in the registry.
