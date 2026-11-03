# =============================================================================
# SHE V3 - switch the board to the CURRENT Wi-Fi network in one step.
# -----------------------------------------------------------------------------
# Re-bakes fctry/nvs to this PC's current Wi-Fi IP, then flashes them.
# Use it whenever you move the PC + board to a different Wi-Fi.
#
# Usage (PowerShell):
#     cd "D:\project X\SHE-V3"
#     powershell -ExecutionPolicy Bypass -File .\switch-network.ps1
#
#   Or force an IP:  .\switch-network.ps1 -Ip 192.168.1.21
# =============================================================================
param([string]$Ip)

$ErrorActionPreference = "Stop"
$root = "D:\project X\SHE-V3"
$py   = "C:\Espressif\python_env\idf5.1_py3.11_env\Scripts\python.exe"
$cert = "$root\infra\ca\out\devices\10061cae5328.crt"
$key  = "$root\infra\ca\out\devices\10061cae5328.key"
$out  = "$root\scripts\nvs-build"

# ---- 1. Find the PC's current Wi-Fi IPv4 (or use -Ip) ------------------------
if (-not $Ip) {
    $Ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -like "*Wi-Fi*" -and $_.IPAddress -ne "127.0.0.1" } |
           Select-Object -First 1).IPAddress
}
if (-not $Ip) { throw "No Wi-Fi IPv4 found. Connect Wi-Fi first, or pass -Ip x.x.x.x" }

$ssid = (Get-NetConnectionProfile -ErrorAction SilentlyContinue |
         Where-Object { $_.InterfaceAlias -like "*Wi-Fi*" }).Name
Write-Host ""
Write-Host "  SSID : $ssid"
Write-Host "  IP   : $Ip"
Write-Host ""

# ---- 2. Re-bake fctry + nvs for this IP -------------------------------------
Write-Host "== Building fctry/nvs for $Ip ..."
& $py "$root\scripts\build-device-nvs.py" `
    --mac 10:06:1C:AE:53:28 --pop 123456789 --sku SHE-R24 --hw-rev rev-c --node-id SHE-24-AE5328 `
    --cert "$cert" --key "$key" `
    --tenant 00000000-0000-0000-0000-000000000001 `
    --home 69b4294f-c1bf-4a68-838e-b906892174ab `
    --mqtt-broker "mqtts://${Ip}:8883" `
    --api-base "http://${Ip}:8080" `
    --out "$out"
if ($LASTEXITCODE -ne 0) { throw "nvs build failed" }

# ---- 3. Flash (board must be in download mode) ------------------------------
Write-Host ""
Write-Host "  Put the board in DOWNLOAD MODE now:"
Write-Host "     hold BOOT, tap EN, release BOOT"
Write-Host ""
Read-Host "  Press Enter when the board is in download mode"

Write-Host "== Flashing nvs (0x9000) + fctry (0x5c0000) ..."
& $py -m esptool --chip esp32 --port COM3 --baud 460800 `
    write_flash 0x9000 "$out\nvs.bin" 0x5c0000 "$out\fctry.bin"
if ($LASTEXITCODE -ne 0) { throw "flash failed" }

Write-Host ""
Write-Host "================ DONE ================"
Write-Host " 1. Press EN (reset only) to boot the board."
Write-Host " 2. In the app -> Server settings:"
Write-Host "      API : http://${Ip}:8080"
Write-Host "      WS  : ws://${Ip}:8080"
Write-Host " 3. Provision with the '$ssid' SSID + password."
Write-Host "====================================="
