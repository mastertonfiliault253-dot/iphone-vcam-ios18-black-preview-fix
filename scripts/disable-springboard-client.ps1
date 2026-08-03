param(
    [string]$DeviceIp = "192.168.2.101"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$key = Join-Path $projectRoot "dist\trollvnc\ssh\id_ed25519"
$knownHosts = Join-Path $projectRoot "dist\trollvnc\ssh\known_hosts"
$remote = 'set -e; plist=$(find /var/jb /.jbroot /Library -path "*/Library/MobileSubstrate/DynamicLibraries/VCAMSpringBoardClient.plist" -type f 2>/dev/null | head -n 1); test -n "$plist"; mv "$plist" "$plist.disabled"; echo VCAM_SPRINGBOARD_CLIENT_DISABLED'
& ssh -i $key -o "UserKnownHostsFile=$knownHosts" -o StrictHostKeyChecking=yes "root@$DeviceIp" $remote
if ($LASTEXITCODE -ne 0) { throw "Could not disable the SpringBoard client." }

Write-Host "SpringBoard VCAM UI disabled. Manually restart userspace when ready."
