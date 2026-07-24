# SyncCameraRoll.ps1
# Runs every 2 minutes as the logged-in AD user (registered dynamically by
# SetCameraRoll.ps1 at each logon). Copies new photos from
# C:\Users\Public\Pictures\Camera Roll to this tablet's warehouse folder on
# the network share. Auto-detects which location the tablet belongs to, so
# one script covers every location - no per-site copies to maintain.
#
# Location detection (in order):
#   1. Parse from computer name using the WS<LOC>... naming convention
#      (e.g. WSCA1WHS027 -> CA1, WSWA1SLS103 -> WA1). Only the 2 letters +
#      1 digit immediately after "WS" are used - whatever follows
#      (WHS/ACC/SLS/ITG/etc. plus any numbers) is ignored.
#   2. Fallback: read the location code from the computer's AD OU
#      (OU name format "<LOC> - <City>", e.g. "CA1 - Fresno" -> CA1).
# If neither method resolves to a location in $validLocations, the script
# logs an [ERROR] and exits without syncing - it never guesses and pushes
# photos to the wrong warehouse folder.
#
# To onboard a new location: add its code to $validLocations below and
# make sure "<LOC>\Camera Roll" exists under $baseNetwork (the script will
# also create it automatically on first successful sync).

$logFile        = "C:\ProgramData\Dev\CameraRoll\SyncCameraRoll.log"
$uncRoot        = "\\svazdfs001\DepartmentalShares"
$baseNetwork    = "\\svazdfs001\DepartmentalShares\Logistics\Incoming Receipt Photos"
$localPath      = "C:\Users\Public\Pictures\Camera Roll"
$validLocations = @('CA1','KY1','TX1','WA1')

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $msg" | Out-File -FilePath $logFile -Append
}

if (-not (Test-Path "C:\ProgramData\Dev\CameraRoll")) {
    New-Item -Path "C:\ProgramData\Dev\CameraRoll" -ItemType Directory -Force | Out-Null
}

# Rotate log when it exceeds 500 KB (keep last 500 lines)
$logItem = Get-Item $logFile -ErrorAction SilentlyContinue
if ($logItem -and $logItem.Length -gt 512000) {
    $lines = Get-Content $logFile -ErrorAction SilentlyContinue
    if ($lines -and $lines.Count -gt 500) {
        $lines[-500..-1] | Set-Content $logFile
    }
}

Log "--- Sync started ---"

# ------------------------------------------------------------------
# Location detection
# ------------------------------------------------------------------
function Get-LocationFromHostname {
    param([string]$ComputerName)
    if ($ComputerName -match '^WS([A-Z]{2}\d)') {
        return $Matches[1]
    }
    return $null
}

function Get-LocationFromOU {
    try {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.Filter = "(&(objectClass=computer)(cn=$env:COMPUTERNAME))"
        $searcher.PropertiesToLoad.Add("distinguishedname") | Out-Null
        $result = $searcher.FindOne()
        if ($result) {
            $dn = $result.Properties["distinguishedname"][0]
            # Matches an OU segment like "OU=CA1 - Fresno"
            if ($dn -match 'OU=([A-Z]{2}\d)\s*-') {
                return $Matches[1]
            }
        }
    } catch {
        Log "AD OU lookup failed: $_"
    }
    return $null
}

$location = Get-LocationFromHostname -ComputerName $env:COMPUTERNAME

if (-not $location -or $validLocations -notcontains $location) {
    Log "Hostname '$env:COMPUTERNAME' didn't yield a valid location - trying AD OU lookup."
    $location = Get-LocationFromOU
}

if (-not $location -or $validLocations -notcontains $location) {
    Log "[ERROR] Unable to determine a valid location for '$env:COMPUTERNAME'. Valid: $($validLocations -join ', '). Skipping sync."
    exit
}

Log "Detected location: $location"

$networkPath = Join-Path $baseNetwork "$location\Camera Roll"

# Quick network check - no waiting. If unreachable, bail and try again next run.
if (-not (Test-Path $uncRoot)) {
    Log "Network share unreachable. Skipping sync - will retry next run."
    exit
}

Log "Network reachable."

# Nothing to do if local source does not exist yet
if (-not (Test-Path $localPath)) {
    Log "Local path not found: $localPath. Nothing to sync."
    exit
}

# Ensure destination folder exists on the network
try {
    if (-not (Test-Path $networkPath)) {
        New-Item -Path $networkPath -ItemType Directory -Force | Out-Null
        Log "Created network folder: $networkPath"
    }
} catch {
    Log "[ERROR] Cannot access or create network folder: $_. Aborting sync."
    exit
}

# Enumerate all files in the local Camera Roll folder
$localFiles = Get-ChildItem -Path $localPath -Recurse -File -ErrorAction SilentlyContinue

if (-not $localFiles -or $localFiles.Count -eq 0) {
    Log "No files found in local folder."
    exit
}

$copied  = 0
$skipped = 0
$failed  = 0

foreach ($file in $localFiles) {
    # Preserve any subfolder structure under Camera Roll
    $relativePath = $file.FullName.Substring($localPath.Length).TrimStart('\')
    $destPath     = Join-Path $networkPath $relativePath
    $destDir      = Split-Path $destPath -Parent

    # Skip if destination already has the file with the same size (already synced)
    if (Test-Path $destPath) {
        $destFile = Get-Item $destPath -ErrorAction SilentlyContinue
        if ($destFile -and $destFile.Length -eq $file.Length) {
            $skipped++
            continue
        }
        Log "Re-copying (size mismatch): $relativePath"
    }

    try {
        # Create subfolder on network if needed
        if (-not (Test-Path $destDir)) {
            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Stop
        Log "Copied: $relativePath"
        $copied++
    } catch {
        Log "[ERROR] copying ${relativePath}: $_"
        $failed++
    }
}

Log "Sync complete. Copied: $copied | Already synced: $skipped | Errors: $failed"
Log "--- Sync finished ---"
