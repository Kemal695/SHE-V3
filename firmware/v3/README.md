# SHE V3 Firmware

**ESP-IDF v5.1.x (LTS)** firmware for SHE-R4 (ESP32-C3), SHE-R8 (ESP32-S3), SHE-R16 (ESP32-S3 + mic).

## Directory structure (V3-FIRMWARE §2.2)

```
firmware/v3/
├── CMakeLists.txt                 # ESP-IDF project file
├── idf_component.yml              # ESP Component Registry manifest
├── partitions.csv                 # 8 MB flash layout (R8/R16)
├── partitions_r4.csv              # 4 MB flash layout (R4)
├── sdkconfig.defaults             # Common defaults
├── sdkconfig.dev                  # Dev build (no Secure Boot)
├── sdkconfig.prod                 # Prod build (Secure Boot v2 + Flash Encryption)
├── sdkconfig.r4                   # SHE-R4 (ESP32-C3, 4 relays, no PZEM)
├── sdkconfig.r8                   # SHE-R8 (ESP32-S3, 8 relays + PZEM)
├── sdkconfig.r16                  # SHE-R16 (ESP32-S3, 16 relays + PZEM + mic)
├── certs/
│   └── ca.pem                     # CA bundle (root + intermediate) — copy from infra/ca/
└── main/
    ├── CMakeLists.txt
    ├── main.c                     # app_main — boot orchestration (V3-FIRMWARE §4)
    ├── app_wifi.c/h               # Wi-Fi connect + reconnect
    ├── mqtt_client.c/h            # mTLS MQTT client (P1-10, P1-13)
    ├── ble_provisioning.c/h       # BLE SoftAP + cert claim flow (P0-1, P1-1, P1-2, P1-3)
    ├── ota_handler.c/h            # Self-hosted OTA (Ed25519 + A/B + auto-rollback)
    ├── local_ctrl.c/h             # mDNS + HTTPS + PoP local control
    ├── relay_driver.c/h           # PCF8574 I2C relay control
    ├── feedback_monitor.c/h       # CD4051 mux + ADC feedback polling
    ├── energy_monitor.c/h         # PZEM-004T v3 Modbus RTU
    ├── voice_control.c/h          # Picovoice "Hey Sheba" (R16 only)
    ├── device_profiles.c/h        # RainMaker hierarchy (Node/Device/Service/Param)
    ├── system_service.c/h         # Reboot / factory_reset / sync_time / ping
    ├── button_task.c/h            # BOOT button — short press = cycle, long = factory reset
    └── nvs_keys.h                 # Single source of truth for NVS namespace + keys
```

## Build + flash

```bash
# Set up ESP-IDF environment
. $HOME/esp/esp-idf/export.sh

# Copy CA bundle from infra
cp ../../infra/ca/ca_bundle.pem certs/ca.pem

# Build for SHE-R8 (default — the volume SKU)
idf.py set-target esp32s3
idf.py build

# Flash to device
idf.py -p /dev/ttyUSB0 flash monitor

# Build for SHE-R4
idf.py set-target esp32c3
idf.py -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.r4;sdkconfig.dev" build

# Build for SHE-R16
idf.py set-target esp32s3
idf.py -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.r16;sdkconfig.dev" build
```

## Production build (Secure Boot v2 + Flash Encryption)

```bash
# 1. Generate Secure Boot key (RSA-PSS 3072-bit, offline air-gapped machine)
openssl genrsa -out secure_boot_v2.pem 3072

# 2. Build with prod sdkconfig
idf.py -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.r8;sdkconfig.prod" build

# 3. Burn eFuses (IRREVERSIBLE — do this only on factory devices)
#    See infra/ca/bootstrap-ca.sh for the full sequence per P0-3.
```

## FreeRTOS task table (V3-FIRMWARE §3)

| Task | Priority | Stack | Core | Purpose |
|---|---|---|---|---|
| `app_main` | 1 | 4096 | 0 | Boot orchestration, then deletes self |
| `rainmaker_task` | 5 | 6144 | 1 | MQTT client + hierarchy sync |
| `feedback_task` | 3 | 3072 | 0 | Optocoupler feedback every 100ms |
| `energy_task` | 2 | 3072 | 0 | PZEM-004T every 5s |
| `voice_task` | 3 | 8192 | 1 | Picovoice wake word + intent (R16 only) |
| `button_task` | 2 | 2048 | 0 | BOOT button short/long press |
| `driver_task` | 3 | 4096 | 0 | GPIO read/write via event queue (PCF8574) |
| `wifi_task` | 5 | 4096 | 0 | Wi-Fi connect + reconnect with backoff |
| `local_ctrl_task` | 4 | 4096 | 0 | esp_local_ctrl HTTPS server (mDNS + PoP) |
| `ota_handler_task` | 2 | 8192 | 1 | OTA download + verify + flash (on-demand) |

## Canonical decisions enforced

| Decision | Where |
|---|---|
| P0-1: ESP32 generates ECDSA P-256 keypair on-chip; private key never leaves device | `fctry` NVS partition — cert + key loaded at boot in `mqtt_client.c` |
| P0-2: Device cert ECDSA P-256, 5yr | `fctry` NVS — issued at factory via step-ca |
| P0-4: Anti-rollback eFuse popcount semantics (max 32 versions) | `ota_handler.c` `check_anti_rollback()` |
| P1-1: PoP = 9-digit numeric CSPRNG | `ble_provisioning.c` `read_pop_from_fctry()` |
| P1-2: BLE Service UUID = `0000ffff-0000-1000-8000-00805f9b34fb` | `ble_provisioning.h` `SHE_BLE_SERVICE_UUID` |
| P1-3: claim endpoint = `POST /api/v3/nodes/claim` | `ble_provisioning.c` `post_claim()` |
| P1-10: backend MQTT = client cert + ACL, NO superuser | `mqtt_client.c` — no username/password |
| P1-13: LWT payload = JSON `{"status":"offline"}` | `mqtt_client.c` `lwt_msg` field |
| P1-26: PoP = 9-digit numeric | `ble_provisioning.c` |
| P1-27: Ed25519 OTA pubkey in eFuse BLOCK_KEY2 (S3) / compiled-in (C3) | `ota_handler.c` `verify_ed25519_signature()` |
| P1-28: Initial SECURE_VERSION = 0x01 burned at factory | `sdkconfig.defaults` `CONFIG_SHE_SECURE_VERSION=1` |

## MQTT topics (V3-MQTT-STANDARDS §2)

Device subscribes to:
- `she/{tenant}/{home}/{room}/{mac}/params/remote` (commands, QoS 1)
- `she/{tenant}/{home}/{room}/{mac}/ota/url` (OTA trigger, QoS 1)
- `she/{tenant}/{home}/{room}/{mac}/command` (system commands, QoS 1)

Device publishes to:
- `she/{tenant}/{home}/{room}/{mac}/config` (self-description, QoS 1, retained)
- `she/{tenant}/{home}/{room}/{mac}/params/local` (telemetry, QoS 0, every 5s)
- `she/{tenant}/{home}/{room}/{mac}/status` (online/offline, QoS 1, retained, LWT)
- `she/{tenant}/{home}/{room}/{mac}/energy` (PZEM reading, QoS 0, every 5s)
- `she/{tenant}/{home}/{room}/{mac}/ota/status` (downloading/flashing/complete/failed, QoS 1)
- `she/{tenant}/{home}/{room}/{mac}/ota/progress` (0-100%, QoS 0)
