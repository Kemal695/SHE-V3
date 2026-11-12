# =============================================================================
# SHE V3 — backend connectivity check
# =============================================================================
#   powershell -ExecutionPolicy Bypass -File scripts\check-backend.ps1
#
# WHY THE IP IS DETECTED, NOT WRITTEN DOWN
# ----------------------------------------
# This bench has moved three times: 192.168.0.5 -> 192.168.1.7 -> 192.168.1.21.
# Every hardcoded copy of an old value produced a bare "Unable to connect",
# which reads exactly like a dead backend — when the backend was healthy on a
# different address. Worse, 192.168.1.7 now belongs to a *different device* on
# this network, so pinging it succeeds and the confusion gets deeper.
#
# So: ask Windows for the address the phone and the ESP32 would use, and check
# that. Nothing to update when the router hands out a new lease.
# =============================================================================

$ErrorActionPreference = 'Continue'
$port = 8080

function Get-LanIp {
    $candidates = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Bluetooth|Local Area Connection'
        }

    # Wi-Fi first, then wired — those are the two the devices can actually reach.
    $wifi = $candidates | Where-Object { $_.InterfaceAlias -like '*Wi-Fi*' } | Select-Object -First 1
    if ($wifi) { return $wifi.IPAddress }

    $eth = $candidates | Where-Object { $_.InterfaceAlias -like '*Ethernet*' } | Select-Object -First 1
    if ($eth) { return $eth.IPAddress }

    return $null
}

$ip = Get-LanIp
if (-not $ip) {
    Write-Host "Could not detect a LAN address. Is Wi-Fi or Ethernet connected?" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "This machine : $ip"
Write-Host ""

# ---- 1. localhost: is the process alive at all? ------------------------------
Write-Host "[1/3] http://localhost:$port/actuator/health" -NoNewline
try {
    $h = Invoke-RestMethod "http://localhost:$port/actuator/health" -TimeoutSec 5
    Write-Host "  -> $($h.status)" -ForegroundColor Green
}
catch {
    Write-Host "  -> FAILED" -ForegroundColor Red
    Write-Host "      The backend is not running. Check: docker ps / the Spring Boot log." -ForegroundColor Yellow
}

# ---- 2. LAN: what the phone and the ESP32 must reach ------------------------
Write-Host "[2/3] http://${ip}:$port/actuator/health" -NoNewline
try {
    $h = Invoke-RestMethod "http://${ip}:$port/actuator/health" -TimeoutSec 5
    Write-Host "  -> $($h.status)" -ForegroundColor Green

    $degraded = @()
    foreach ($component in $h.components.PSObject.Properties) {
        if ($component.Value.status -ne 'UP') { $degraded += $component.Name }
    }
    if ($degraded.Count -gt 0) {
        Write-Host "      DEGRADED: $($degraded -join ', ')" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "  -> FAILED" -ForegroundColor Red
    Write-Host "      localhost works but the LAN address does not, so check:" -ForegroundColor Yellow
    Write-Host "        - server.address is 0.0.0.0 (not 127.0.0.1)" -ForegroundColor Yellow
    Write-Host "        - Windows Firewall allows inbound TCP $port" -ForegroundColor Yellow
}

# ---- 3. the values to type into the app ------------------------------------
Write-Host ""
Write-Host "[3/3] Settings -> Server, on the phone:"
Write-Host "        API base URL       : http://${ip}:$port"
Write-Host "        WebSocket base URL : ws://${ip}:$port"
Write-Host ""
Write-Host "      Board is expected at the same host: mqtts://${ip}:8883"
Write-Host ""
