# V3 — Firmware

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Firmware Lead

---

## 1. Tech stack

| Component | Version | Notes |
|---|---|---|
| ESP-IDF | v5.1.x (LTS) | Locked to LTS branch for factory stability |
| Target chip (SHE-R4) | **ESP32-C3-WROOM-02** | RISC-V single-core, 4MB flash |
| Target chip (SHE-R8, SHE-R16) | **ESP32-S3-WROOM-1** | Xtensa LX7 dual-core, 8MB flash |
| FreeRTOS | Bundled with ESP-IDF | Pre-emptive scheduling |
| mbedTLS | Bundled | TLS 1.3, X.509, Ed25519 |
| LWIP | Bundled | TCP/IP stack |
| mqtt_client | ESP-IDF component | MQTT 5.0, mTLS |
| wifi_provisioning | ESP-IDF component | BLE SoftAP provisioning |
| esp_local_ctrl | ESP-IDF component | mDNS + HTTPS local control |
| esp_https_ota | ESP-IDF component | A/B partition OTA |
| PCF8574 driver | Custom (`relay_driver.c`) | I2C GPIO expander |
| PZEM-004T driver | Custom (`energy_monitor.c`) | Modbus RTU over UART |
| Picovoice SDK | v3.0.x | Porcupine wake word + Rhino intent — **SHE-R16 only** |
| rainmaker_hierarchy | Custom (`device_profiles.c`) | Replicates RainMaker Node/Device/Service/Param/Attr in C — see §11 |

**Chip selection rationale:** The original V3 docs specified "ESP32-WROOM-32" (the classic dual-core). This was a documentation error — WROOM-32 lacks Secure Boot v2 (only the weaker v1) and is being phased out by Espressif. ESP32-C3 (R4) and ESP32-S3 (R8/R16) are cheaper, support Secure Boot v2 + Flash Encryption, and have better long-term availability. See `V3-HARDWARE.md` §3.1 and ADR-012.

---

## 2. Directory structure

```
firmware/v3/
├── CMakeLists.txt
├── idf_component.yml                 # ESP-IDF component manager manifest
├── partitions.csv                    # OTA A/B + NVS + fctry NVS + phy_init
├── sdkconfig.defaults                # Common defaults
├── sdkconfig.prod                    # Secure Boot + Flash Encryption enabled
├── sdkconfig.dev                     # Dev build (no Secure Boot)
├── certs/
│   ├── ca.pem                        # SHE CA root+intermediate (mTLS trust anchor)
│   └── ota_pub_key.pem               # Ed25519 public key for OTA signature verification (C3 only — S3 reads from eFuse BLOCK_KEY2, see §6.2)
├── main/
│   ├── main.c                        # app_main — boot orchestration
│   ├── app_wifi.c/h                  # Wi-Fi connect + reconnect with exponential backoff
│   ├── mqtt_client.c/h               # mTLS MQTT client (NO third-party SDK)
│   ├── ble_provisioning.c/h          # BLE SoftAP + cert claim flow
│   ├── ota_handler.c/h               # Self-hosted OTA (MinIO + Ed25519 + A/B)
│   ├── local_ctrl.c/h                # esp_local_ctrl wrapper (mDNS + HTTPS + PoP)
│   ├── relay_driver.c/h              # PCF8574 I2C relay control
│   ├── feedback_monitor.c/h          # Optocoupler feedback per relay channel
│   ├── energy_monitor.c/h            # PZEM-004T v3 Modbus RTU
│   ├── voice_control.c/h             # Picovoice Porcupine + Rhino (R16 only)
│   ├── device_profiles.c/h           # RainMaker hierarchy: Node/Device/Service/Param/Attr
│   ├── system_service.c/h            # Reboot / wifi_reset / factory_reset
│   ├── button_task.c/h               # BOOT button — short press = cycle relays, long = factory reset
│   └── nvs_keys.h                    # Single source of truth for NVS namespace + keys
└── components/
    ├── picovoice/                    # Picovoice SDK (only compiled for SHE-R16)
    └── pcf8574/                      # PCF8574 driver component
```

### 2.1 Partition table (`partitions.csv`)

```
# Name,   Type, SubType, Offset,  Size,    Flags
nvs,      data, nvs,     0x9000,  0x6000,
phy_init, data, phy,     0xF000,  0x1000,
factory,  app,  factory, 0x10000, 0x180000,
ota_0,    app,  ota_0,   0x200000,0x180000,
ota_1,    app,  ota_1,   0x380000,0x180000,
otadata,  data, ota,     0x500000,0x2000,
fctry,    data, nvs,     0x510000,0x10000,  # Factory cert + key + PoP (read-only in production)
```

The `fctry` NVS partition is written once at the factory and never modified by firmware — it holds the device's X.509 cert + private key + PoP (proof-of-possession token). See `V3-FACTORY-OPS.md` §5.

---

## 3. FreeRTOS task structure

| Task | Priority | Stack | Core | Purpose |
|---|---|---|---|---|
| `app_main` | 1 | 4096 | 0 | Boot orchestration, then deletes self |
| `rainmaker_task` | 5 | 6144 | 1 | MQTT client + hierarchy sync — publishes `config` on connect, processes `params/remote` commands |
| `feedback_task` | 3 | 3072 | 0 | Read optocoupler feedback every 100ms, detect manual override + relay fault |
| `energy_task` | 2 | 3072 | 0 | Read PZEM-004T every 5s, publish to `.../energy` topic |
| `voice_task` | 3 | 8192 | 1 | Picovoice Porcupine wake word + Rhino intent (R16 only) |
| `button_task` | 2 | 2048 | 0 | BOOT button short/long press detection |
| `driver_task` | 3 | 4096 | 0 | GPIO read/write via event queue (PCF8574) |
| `wifi_task` | 5 | 4096 | 0 | Wi-Fi connect + reconnect with backoff |
| `local_ctrl_task` | 4 | 4096 | 0 | esp_local_ctrl HTTPS server (mDNS + PoP) |
| `ota_handler_task` | 2 | 8192 | 1 | OTA download + verify + flash (on-demand) |

Tasks are pinned to cores on dual-core ESP32-S3 (R8/R16). ESP32-C3 (R4) is single-core — all tasks run on core 0. The `voice_task` is only spawned on R16 builds (compile-time `#ifdef CONFIG_SHE_R16`).

---

## 4. Boot flow

```
app_main()
  │
  ├─ 1. NVS init (default + fctry partitions)
  │     └─ Load factory cert + private key + PoP from fctry NVS
  │
  ├─ 2. Wi-Fi subsystem init (does NOT connect yet)
  │
  ├─ 3. Driver init
  │     ├─ PCF8574 I2C expander(s): 1 chip (R4/R8), 2 chips (R16)
  │     ├─ CD4051 multiplexer for feedback ADC
  │     └─ PZEM-004T UART init (R8/R16 only)
  │
  ├─ 4. Restore last relay state from NVS (persist property — V3-DEVICE-MODEL.md §4)
  │
  ├─ 5. Node init  ────────────────────────────────────────┐
  │     device_profiles.c creates the RainMaker hierarchy: │
  │     ├─ Node: SHE-R8-AABBCC                            │
  │     ├─ 8× Device: "Relay 1".."Relay 8"                │
  │     │    each with: Parameter: Power (bool, r/w/persist)│
  │     │            Attribute: Label, Channel, Serial     │
  │     ├─ Service: OTA (esp.service.ota)                 │
  │     │    Parameters: URL, Status, Progress             │
  │     └─ Service: Diagnostics (esp.service.diag)         │
  │          Parameters: Uptime, RSSI, Free_Heap, Reset_Reason│
  │   (R16 also adds Service: Voice with wake-word status)│
  │   ─────────────────────────────────────────────────────┘
  │
  ├─ 6. If not provisioned (no Wi-Fi creds in NVS):
  │     └─ Start BLE SoftAP provisioning (blocks until complete)
  │        ├─ Receive: Wi-Fi SSID + password + tenant_id + claim_token
  │        ├─ POST /internal/nodes/claim (mutual TLS to Spring Boot)
  │        │  Body: { claim_token, mac, sku, tenant_id, config_payload }
  │        │  Response: { node_db_id, mqtt_broker }   ← NO cert/key returned
  │        └─ Store mqtt_broker + tenant mapping in fctry NVS, reboot
  │
  ├─ 7. Wi-Fi connect (from NVS creds, 30s timeout)
  │
  ├─ 8. MQTT connect (mutual TLS, cert from fctry NVS)
  │     ├─ Set LWT: {"status":"offline"} (JSON payload, NOT plain string — V3-MQTT-STANDARDS.md §6.3)
  │     │         on she/.../{mac}/status (retained)
  │     ├─ On connect: publish {"status":"online"} to status topic
  │     ├─ Publish node config to she/.../{mac}/config (retained)
  │     └─ Subscribe to: she/.../{mac}/params/remote (commands)
  │                      she/.../{mac}/ota/url             (OTA trigger)
  │                      she/.../{mac}/ota/abort           (OTA cancel)
  │
  ├─ 9. Start esp_local_ctrl (mDNS + HTTPS + PoP) — works without internet
  │
  ├─ 10. Start energy_monitor (R8/R16 only — R4 has no PZEM)
  │
  ├─ 11. Start voice_control (R16 only — R4/R8 lack I2S mic)
  │
  ├─ 12. Start OTA handler
  │      └─ Check otadata — if PENDING_VERIFY, start 5-min health check
  │         (see §6 — auto-rollback if health check fails)
  │
  └─ 13. Main loop: publish heartbeat + telemetry every 60s
         (energy publishes independently every 5s in energy_task)
```

---

## 5. BLE provisioning

SHE V3 uses ESP-IDF's `wifi_provisioning` component (BLE SoftAP mode) with a **custom claim flow** — we are self-hosted, so this is our own implementation rather than RainMaker's claiming service.

### 5.1 Flow

> **Important (P0-1):** BLE provisioning does **NOT** issue certs. The device cert + private key are already on the device from **factory provisioning** (see `V3-FACTORY-OPS.md` §3 + `V3-SECURITY-MODEL.md` §3.2). BLE provisioning only transfers Wi-Fi creds + performs user-node mapping.

```
ESP32 boots unprovisioned → starts BLE provisioning service
  │
  │  Service UUID: 0000ffff-0000-1000-8000-00805f9b34fb
  │  Device name: "SHE-R8-AABBCC" (last 6 of MAC)
  │  PoP: stored in fctry NVS (factory-assigned, 9-digit numeric)
  │
  ▼
Flutter app scans BLE → finds "SHE-R8-AABBCC"
  │
  ▼
App connects (Security 1, PoP required)
  │
  ▼
App sends custom protobuf message:
  {
    wifi_ssid:     "MyHome",
    wifi_password: "********",
    tenant_id:     "uuid",
    claim_token:   "uuid",  // obtained by app from POST /api/v3/auth/claim-token
    api_base_url:  "https://api.she.et"
  }
  │
  ▼
ESP32:
  1. Connects to Wi-Fi (uses provided creds)
  2. Once Wi-Fi up, POSTs to {api_base_url}/internal/nodes/claim
     Body: {
       claim_token: "...",
       mac:         "24:6F:28:AA:BB:CC",
       sku:         "SHE-R8",
       tenant_id:   "uuid",
       config:      { ... node config payload ... }
     }
  3. Spring Boot verifies claim_token (10-min TTL, single-use),
     validates tenant_id matches the token's issuer,
     creates `nodes` + `node_devices` + `node_params` rows in Postgres
     (assigns the device — already has a factory-issued cert — to the user's tenant).
     Returns: { node_db_id, mqtt_broker }
     NOTE: **No cert or private key is returned** — the device already has its cert
     from factory provisioning (V3-FACTORY-OPS.md §3, V3-SECURITY-MODEL.md §3.2).
  4. ESP32 stores mqtt_broker + tenant mapping in fctry NVS (no cert/key change).
  5. ESP32 disconnects BLE, reboots
  │
  ▼
After reboot → boots as provisioned (skips step 6 in §4)
  → connects to MQTT broker (mutual TLS — uses factory-issued cert from fctry NVS)
  │
  ▼
Spring Boot detects MQTT connect → WebSocket push to Flutter
  → Device appears in dashboard (online status)
```

### 5.2 Challenge-response (user-node mapping)

To bind a physical device to a user's account without trusting the app blindly:

1. App requests `POST /api/v3/auth/claim-token` → receives `{claim_token, expires_at}` (10-min TTL).
2. App scans QR code on device enclosure (printed at factory — see `V3-FACTORY-OPS.md` §4) → reads `{name, pop, transport}`.
3. App sends `claim_token` + Wi-Fi creds to ESP32 via BLE (PoP-protected).
4. ESP32 forwards `claim_token` + `mac` + `sku` to Spring Boot.
5. Spring Boot verifies the claim_token was issued to the same authenticated user (RLS-tenant match) and that the MAC is not already claimed by another tenant.
6. Spring Boot creates `nodes` + `node_devices` + `node_params` rows in the user's tenant — **but does NOT issue a cert** (the cert is already on the device from factory).

---

## 6. Self-hosted OTA

SHE V3 OTA is **fully self-hosted** — firmware images live in MinIO (`https://minio.she.et/firmware/`), are signed with Ed25519, and use A/B partitions + 5-min health check + auto-rollback. This is **NOT** RainMaker OTA (which would require data to transit Espressif/AWS).

### 6.1 Trigger flow

```
Spring Boot publishes to MQTT topic she/.../{mac}/ota/url:
  {
    "version":   "3.1.0",
    "url":       "https://minio.she.et/firmware/v3.1.0-r8.bin?X-Amz-...",
    "signature": "ed25519:base64-encoded-signature",
    "checksum":  "sha256:..."
  }
```

### 6.2 ESP32 OTA sequence

```
ota_handler_task:
  1. Receive OTA URL from MQTT (queued via esp_event)
  2. Update local OTA service params: Status=DOWNLOADING, Progress=0
  3. esp_https_ota_begin() — opens HTTPS connection to MinIO
  4. Loop:
     a. esp_https_ota_perform() — writes stream to alternate partition
     b. Update Progress every 10% (publish to ota/progress)
     c. On HTTP error: retry 3x with backoff, then abort + Status=FAILED
  5. esp_https_ota_finish() — verifies SHA-256 checksum
  6. Verify Ed25519 signature against the OTA pubkey:
     ├─ ESP32-S3: pubkey read from eFuse BLOCK_KEY2 (KEY_PURPOSE=USER) — immutable, burned at factory
     └─ ESP32-C3: pubkey from compiled-in ota_pub_key.pem, protected by Secure Boot v2
     └─ If signature invalid: abort, Status=SIGNATURE_FAILED, do NOT reboot
  7. esp_ota_set_boot_partition() — mark alternate as PENDING_VERIFY
  8. Update Status=REBOOTING
  9. esp_restart()
```

### 6.3 Post-reboot health check + auto-rollback

```
After reboot:
  1. Bootloader loads alternate partition (state = PENDING_VERIFY)
  2. app_main runs normally — Wi-Fi, MQTT, drivers all start
  3. If Wi-Fi fails OR MQTT fails to connect within 5 minutes:
     └─ Bootloader auto-rolls back to previous partition on next reboot
       (esp_ota_mark_app_invalid_rollback_and_reboot())
  4. If Wi-Fi + MQTT connect successfully within 5 minutes:
     └─ rainmaker_task publishes a "healthy" telemetry message
     └─ esp_ota_mark_app_valid_cancel_rollback() — commit new partition
     └─ Update Status=COMPLETED via MQTT
```

### 6.4 Anti-rollback (eFuse enforced)

Each firmware version embeds a monotonic version counter in the firmware header. The ESP32 eFuse `SECURE_VERSION` field uses **popcount semantics** — each set bit represents one version increment (max 32 versions). The **initial value (`0x01`) is burned at factory**. Subsequent burns happen **on OTA** — the bootloader burns the next bit after a successful OTA of a security-critical release (not every minor release; minor releases use signed version comparison in firmware). The bootloader rejects any firmware with `version_counter < popcount(SECURE_VERSION)`. This prevents downgrade attacks even with physical access. See `V3-SECURITY-MODEL.md` §5.3.

---

## 7. Local control (offline operation)

When the internet is down, the mobile app can still control devices on the same LAN via the `esp_local_ctrl` ESP-IDF component.

### 7.1 Architecture

```
ESP32 runs HTTPS server on port 443 (self-signed cert, PoP-protected)
  │
  ├─ mDNS advertisement: _she_ctrl._tcp.local. → ESP32 IP
  │
  ▼
Flutter app on same Wi-Fi:
  1. mDNS scan → discovers ESP32 IP
  2. HTTPS GET /she/info → {node_id, sku, devices[], params[]}
  3. HTTPS POST /she/ctrl → {"device_name": "Relay 1", "params": {"Power": true}}
  │
  ▼
ESP32 toggles relay directly (no cloud round-trip)
  │
  ▼
ESP32 queues command for MQTT (published when internet returns)
```

### 7.2 PoP (Proof of Possession)

PoP = **9-digit CSPRNG number** (e.g., `482917305`), stored in `fctry` NVS. Generated at factory during provisioning (see `V3-FACTORY-OPS.md` §3.2) — never reused, never derived from MAC. The Flutter app scans the QR code on the device enclosure to read the PoP, then uses it to authenticate the BLE provisioning session. All local control traffic is encrypted with ChaCha20-Poly1305 after the handshake (key derived from the PoP via HKDF).

**Security note:** Local control is intentionally LAN-only — the ESP32 does NOT expose the HTTPS server to the WAN. Cloudflare geo-block does not affect local control. See `V3-SECURITY-MODEL.md` §7.

---

## 8. Feedback circuit

Each relay channel has an optocoupler (PC817) reading the actual relay contact state (NO → COM closure). The `feedback_task` reads each channel via a CD4051 8:1 multiplexer on the ESP32 ADC every 100ms and compares to the commanded relay state:

| Commanded | Feedback | Action |
|---|---|---|
| ON | ON | Normal — sync `last_value` to cloud |
| ON | OFF | **Relay fault** — publish alert, set `Relay 1.Fault = true`, update reported state |
| OFF | OFF | Normal — sync to cloud |
| OFF | ON | **Manual override detected** — wall switch toggled; sync actual state to cloud, update `last_value` |

This enables three features:

1. **Relay fault detection** — commanded ON but COM reads OFF → hardware failure alert (push notification + audit log entry)
2. **Manual override** — someone physically toggled the wall switch → app syncs to actual state within 100ms
3. **Power-on recovery** — after an outage, firmware reads actual relay states + syncs to cloud (the `persist` property means the ESP32 restores the last commanded state, but the feedback circuit confirms what's *actually* live)

See `V3-HARDWARE.md` §3.5 + §4.4 for the schematic.

---

## 9. Energy monitoring (PZEM-004T)

The PZEM-004T v3 sensor (mounted on SHE-R8 and SHE-R16 — see `V3-HARDWARE.md` §3.4) reports voltage, current, power, energy, frequency, and power factor via Modbus RTU over UART1 (GPIO 17/18 on ESP32-S3).

### 9.1 `energy_task` (every 5 seconds)

```c
void energy_task(void *arg) {
    pzem_reading_t reading;
    while (1) {
        if (pzem_read(&reading) == ESP_OK) {
            // Publish to MQTT topic she/.../{mac}/energy
            char payload[256];
            snprintf(payload, sizeof(payload),
                "{\"voltage\":%.1f,\"current\":%.2f,\"power\":%.1f,"
                "\"energy_wh\":%.2f,\"frequency\":%.1f,\"pf\":%.2f}",  // FIXED: added % before .1f and .2f
                reading.voltage, reading.current, reading.power_w,
                reading.energy_wh, reading.frequency, reading.power_factor);
            // QoS 0 for energy topic (per V3-MQTT-STANDARDS.md) — fire-and-forget, high-frequency
            mqtt_publish("she/.../energy", payload, QOS_0, RETAINED_NO);

            // Also update Diagnostics service params locally
            update_param("Diagnostics", "Voltage", esp_rmaker_float(reading.voltage));
        }
        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}
```

### 9.2 Cost calculation

Cost (in ETB) is calculated by Spring Boot on ingest — the device sends raw kWh, the cloud applies the EEU block tariff (see `V3-ENERGY-MONITORING.md`). This keeps the tariff logic in one place (the cloud) and allows tariff updates without firmware changes.

---

## 10. Voice control (SHE-R16 only)

SHE-R16 includes an INMP441 I2S MEMS microphone and runs the Picovoice SDK entirely on-device — **no audio leaves the device**, no cloud dependency for voice.

### 10.1 Wake word

**"Hey Sheba"** — a custom-trained Porcupine wake word model. Runs in `voice_task` at priority 3 (doesn't block relay control or MQTT).

### 10.2 Intent parsing

Rhino context (`she_v3_am_en.rhn`) supports Amharic + English intents:

```
"Hey Sheba, turn on the living room light"
   → {intent: "turn_on", slot_device: "living room light"}

"Hey Sheba, activate movie night"
   → {intent: "activate_scene", slot_scene: "movie night"}

"Hey Sheba, set AC to 24"
   → {intent: "set_param", slot_device: "AC", slot_param: "temperature", slot_value: 24}
```

### 10.3 Voice service params

The Voice service (`esp.service.voice`) exposes three params so the app can monitor voice activity:

| Param | Type | Notes |
|---|---|---|
| `Wake Word Active` | bool | TRUE during intent inference window (~1.5s after wake word) |
| `Last Intent` | string | e.g., `"turn_on"` |
| `Last Confidence` | float | 0.0-1.0 (Rhino confidence score) |

### 10.4 Multilingual model

The Picovoice model is trained on both Amharic and English phonemes. Wake word "Hey Sheba" works in both languages. Intent slot values are language-tagged (e.g., `slot_device: "living room light"` vs `slot_device: "የእንቅልፍ ቤት መብራት"`); the firmware resolves the slot value to a `node_device_id` via the device's local config cache.

---

## 11. Device profiles (RainMaker hierarchy in C)

`device_profiles.c` defines the Node / Device / Service / Parameter / Attribute hierarchy in C structs. This mirrors the RainMaker SDK's data model (V3-DEVICE-MODEL.md §2) but is our own implementation — **no RainMaker SDK dependency**.

### 11.1 Data structures

```c
typedef enum {
    PROP_READ       = 1 << 0,
    PROP_WRITE      = 1 << 1,
    PROP_PERSIST    = 1 << 2,
    PROP_TIME_SERIES= 1 << 3,
} param_props_t;

typedef enum { DATA_BOOL, DATA_INT, DATA_FLOAT, DATA_STRING } data_type_t;

typedef struct {
    const char       *name;         // "Power"
    const char       *type;         // "esp.param.power"
    data_type_t       data_type;    // DATA_BOOL
    param_props_t     properties;   // PROP_READ | PROP_WRITE | PROP_PERSIST
    float             min_val;      // 0 (for sliders)
    float             max_val;      // 100
    esp_rmaker_val_t  last_value;   // cached (synced to cloud via MQTT)
    bool              dirty;        // TRUE = needs to be published
} node_param_t;

typedef struct {
    const char        *name;         // "Relay 1"
    const char        *type;         // "esp.device.switch"
    uint8_t            channel;      // 0-15 (maps to PCF8574 pin)
    node_param_t      *params;       // array
    uint8_t            param_count;
    cJSON             *attributes;   // {"Label":"Kitchen Light","Channel":"0"}
} node_device_t;

typedef struct {
    const char        *node_id;      // "SHE-R8-AABBCC"
    const char        *mac;          // "24:6F:28:AA:BB:CC"
    const char        *sku;          // "SHE-R8"
    const char        *firmware;     // "1.4.2"
    node_device_t     *devices;      // array (includes services)
    uint8_t            device_count;
} she_node_t;
```

### 11.2 Profile construction

```c
// device_profiles.c
she_node_t* profile_build_r8(void) {
    static node_device_t devices[10];  // 8 relays + OTA + Diagnostics
    static node_param_t  relay_params[8];

    for (int i = 0; i < 8; i++) {
        relay_params[i] = (node_param_t){
            .name = "Power",
            .type = "esp.param.power",
            .data_type = DATA_BOOL,
            .properties = PROP_READ | PROP_WRITE | PROP_PERSIST,
            .last_value = esp_rmaker_bool(false),
        };
        devices[i] = (node_device_t){
            .name = relay_names[i],   // "Relay 1" ... "Relay 8"
            .type = "esp.device.switch",
            .channel = i,
            .params = &relay_params[i],
            .param_count = 1,
            .attributes = build_attrs(i),  // Label, Channel, Serial
        };
    }

    devices[8] = build_ota_service();       // esp.service.ota
    devices[9] = build_diagnostics_service(); // esp.service.diag

    return &(she_node_t){
        .node_id = "SHE-R8-AABBCC",
        .mac = "24:6F:28:AA:BB:CC",
        .sku = "SHE-R8",
        .firmware = FIRMWARE_VERSION,
        .devices = devices,
        .device_count = 10,
    };
}
```

### 11.3 Config payload publication

On MQTT connect, the firmware serializes `she_node_t` to the JSON shape defined in `V3-DEVICE-MODEL.md` §5 and publishes to `she/.../{mac}/config` (retained). Spring Boot consumes this, upserts `nodes` + `node_devices` + `node_params` rows, and surfaces the config to the mobile app via `GET /api/v3/nodes/{nodeId}/config`.

### 11.4 SKU-specific profiles

| SKU | Devices | Services | Params |
|---|---|---|---|
| SHE-R4 | 4× `esp.device.switch` | OTA, Diagnostics | 4× Power |
| SHE-R8 | 8× `esp.device.switch` | OTA, Diagnostics | 8× Power |
| SHE-R16 | 16× `esp.device.switch` | OTA, Diagnostics, Voice | 16× Power + 3× Voice status |

Future SKUs (SHE-DIMMER, SHE-SENSOR) add new `esp.device.*` types — see `V3-DEVICE-MODEL.md` §2.2.

---

## 12. Firmware security

This section summarizes the firmware security stack. Full details in `V3-SECURITY-MODEL.md` §5.

### 12.1 Secure Boot v2

- ESP32-C3 + ESP32-S3 both support Secure Boot v2 (RSA-PSS + 3-key revocable)
- Bootloader verifies app image signature on every boot (incl. OTA)
- Public key digest burned into eFuse at factory (one-way, cannot be undone)
- See `V3-SECURITY-MODEL.md` §5.1 + ADR-013

### 12.2 Flash Encryption

- AES-XTS-256 encryption of all flash contents (except bootloader + eFuses)
- Enabled at factory via `esp_flash_encrypt()` one-time operation
- NVS partitions are automatically encrypted (fctry NVS holds cert + private key — protected at rest)
- See `V3-SECURITY-MODEL.md` §5.2

### 12.3 Anti-rollback eFuses

- 32 eFuse bits (`SECURE_VERSION`) — each bit = one firmware version counter increment
- Bootloader rejects any app image with version < SECURE_VERSION
- Prevents downgrade attacks even with physical flash access
- See `V3-SECURITY-MODEL.md` §5.4 + §6 of this doc

### 12.4 JTAG / UART disable

Production builds (`sdkconfig.prod`) disable:

```
CONFIG_ESP_CONSOLE_NONE=y                # No UART console output
CONFIG_ESP_SYSTEM_PANIC_SILENT_REBOOT=y  # Silent panic (no stack trace to UART)
CONFIG_SECURE_DISABLE_JTAG=y             # JTAG permanently disabled (eFuse)
CONFIG_SECURE_DISABLE_ROM_DL_MODE=y      # ROM download mode disabled (eFuse)
```

Development builds (`sdkconfig.dev`) keep JTAG + UART console enabled for debugging.

### 12.5 NVS encryption

The `fctry` NVS partition (holding the X.509 private key) is encrypted with a key derived from the device's Flash Encryption key. Even with physical flash dump, the private key is unrecoverable without the eFuse-derived key.

### 12.6 mTLS to EMQX

The MQTT client uses mutual TLS:

```c
esp_mqtt_client_config_t mqtt_cfg = {
    .uri = "mqtts://mqtt.she.et:8883",
    .client_cert_pem = (const char *)client_cert_pem_start,  // from fctry NVS
    .client_key_pem  = (const char *)client_key_pem_start,   // from fctry NVS
    .server_cert_pem = (const char *)ca_cert_pem_start,      // compiled in
    .client_id = "SHE-R8-AABBCC",
    .lwt_topic = "she/.../status",
    .lwt_msg = "{\"status\":\"offline\"}",
    .lwt_qos = 1,
    .lwt_retain = 1,
};
```

EMQX verifies the client cert against the SHE CA (intermediate) and authorizes per-device topics via the HTTP ACL backend (V3-API-SPECIFICATION.md §15). See `V3-SECURITY-MODEL.md` §6.

**LWT payload format:** The LWT message MUST be JSON `{"status":"offline"}` (not a plain string) — Spring Boot parses JSON status updates. See `V3-MQTT-STANDARDS.md` §6.3 for the canonical LWT format.

---

## 13. KPIs + budgets

| Metric | Target | Measurement |
|---|---|---|
| Boot to MQTT connect | <8s | Watchdog logs on first MQTT connect |
| BLE provisioning time | <60s | App-side timer (claim_token issue → MQTT online) |
| OTA download + flash (1.5MB image) | <120s on 2Mbps Wi-Fi | `ota_handler_task` logs |
| OTA health-check success rate | ≥99% | Aggregate from `ota_progress` events |
| Voice wake-word latency | <800ms | Picovoice SDK benchmark |
| RAM usage (R8) | <60% of 512KB SRAM | `esp_get_free_heap_size()` |
| Flash usage (R8) | <70% of 8MB | Build artifact size |

---

## 14. References

- `V3-HARDWARE.md` — schematic, BOM, PCB design, component selection
- `V3-DEVICE-MODEL.md` — RainMaker hierarchy (this firmware implements it)
- `V3-SECURITY-MODEL.md` §5 — Secure Boot, Flash Encryption, anti-rollback
- `V3-MQTT-STANDARDS.md` — topic structure + payload formats
- `V3-FACTORY-OPS.md` — factory flashing + cert generation workflow
- `V3-API-SPECIFICATION.md` §6 + §15 — REST + internal endpoints called by firmware
- `V3-VOICE-MATTER.md` §1 — voice design (wake word, intents, multilingual)
- ADR-012 — ESP32 chip selection per SKU
- ADR-013 — firmware security (Secure Boot v2, Flash Encryption)
- ESP-IDF docs: https://docs.espressif.com/projects/esp-idf/en/v5.1/esp32s3/
- Picovoice docs: https://picovoice.ai/docs/
