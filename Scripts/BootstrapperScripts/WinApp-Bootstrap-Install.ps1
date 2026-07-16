# --- Automate bootstrap wrapper -- paste this into the Execute Script step ---
# Pulls the current version of WinAppInst.ps1 from the public
# randysworldwide/rww-installers repo and runs it. Do not edit the
# install logic here -- that lives in the repo now. This wrapper only
# handles fetch + run.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$repoOwner = 'randysworldwide'
$repoName  = 'rww-installers'
$branch    = 'main'
$repoPath  = 'Scripts/WinAppInst.ps1'
$localPath = "$env:ProgramData\Dev\Scripts\WinAppInst.ps1"
$url = "https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/$repoPath"
try {
    $dir = Split-Path -Path $localPath -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    [Console]::WriteLine("Fetching latest install script from $url")
    Invoke-WebRequest -Uri $url -OutFile $localPath -UseBasicParsing
} catch {
    [Console]::WriteLine("[ERROR] Failed to download install script from GitHub: $($_.Exception.Message)")
    exit 5
}
# The downloaded script calls exit itself on every path, so its exit code
# becomes this process's exit code directly. This trailing exit is just a
# safety net in case that ever changes.
& $localPath
exit $LASTEXITCODE
