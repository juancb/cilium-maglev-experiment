# Run as Administrator to forward Windows localhost ports to WSL2.
# Usage: Right-click → "Run with PowerShell" (as admin), or:
#   Start-Process powershell -Verb RunAs -ArgumentList "-File scripts\windows-portforward.ps1"
#
# Re-run after every `wsl --shutdown` or Windows restart because the WSL2 IP changes.

$wslIp = (wsl -d Ubuntu-24.04 -- bash -c "hostname -I 2>/dev/null") -split " " | Where-Object { $_ -match '^172\.' } | Select-Object -First 1
if (-not $wslIp) {
    Write-Error "Could not determine WSL2 IP. Is Ubuntu-24.04 running?"
    exit 1
}
Write-Host "WSL2 IP: $wslIp"

$ports = @(
    @{ port = 18080; desc = "Hubble UI" },
    @{ port = 18081; desc = "Grafana"   }
)

foreach ($p in $ports) {
    $port = $p.port
    $desc = $p.desc

    # Remove stale portproxy rule
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=127.0.0.1 2>$null | Out-Null

    # Add new rule pointing at current WSL2 IP
    netsh interface portproxy add v4tov4 `
        listenport=$port listenaddress=127.0.0.1 `
        connectport=$port connectaddress=$wslIp

    # Ensure Windows Firewall allows inbound on this port
    $ruleName = "maglev-lab-$port"
    Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $ruleName -DisplayName "Maglev lab $desc ($port)" `
        -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null

    Write-Host "  $desc  →  http://localhost:$port  (→ $wslIp`:$port)"
}

Write-Host ""
Write-Host "Current portproxy table:"
netsh interface portproxy show v4tov4
