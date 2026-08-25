# V3 — Voice Control + Matter

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Firmware Contractor

---

## 0. Scope

This document covers three separate capabilities that are bundled into one doc because they share the "external control surface" theme:

1. **Offline voice** — Picovoice Porcupine + Rhino on the SHE-R16 only (V3 GA)
2. **Cloud voice** — Alexa Skill + Google Home Action calling the Spring Boot REST API (V3.1)
3. **Matter** — Matter-over-Wi-Fi per-device, no central Border Router (V3.1)

> **Critical clarification:** This document supersedes the original `V3-VOICE-MATTER.md` (Proposed). The original proposed a Raspberry Pi Border Router at the Addis Ababa data center for Matter-over-Thread. That topology was architecturally wrong — Thread is a local-mesh protocol with ~30 m range, and a Border Router in a DC cannot reach a Thread mesh in a user's home. The corrected topology is **Matter-over-Wi-Fi per-device** (no central Border Router, no Thread radio). See §3 and ADR-007 (renamed from `007-matter-border-router.md` to `007-matter-over-wifi.md`).

---

## 1. Offline voice — Picovoice on SHE-R16

### 1.1 Why offline

Ethiopian internet is unreliable (cellular data dropouts, frequent power-cycle restarts of home routers), so cloud voice assistants would fail at the exact moments users need light control. Cloud assistants (Alexa, Google) do not support Amharic as of 2024-Q4. Cloud voice sends audio out of the home, conflicting with our PDPP-compliant self-hosted posture. Cloud voice also adds 200-500 ms latency per command. Offline voice addresses all four issues.

### 1.2 Hardware

- **INMP441** I2S MEMS microphone, ~$2 BOM (V3-HARDWARE.md §3.6)
- Connected to the ESP32-S3 I2S peripheral on SHE-R16 only
- SHE-R4 and SHE-R8 omit the microphone for cost (rev-e planned 2025-Q4 may add it)

### 1.3 Wake word

- **"Hey Sheba"** (English phonetics, recognizable across Amharic + English speakers)
- Trained via Picovoice Console; one custom Porcupine wake-word model baked into firmware at build time
- Chosen for cross-lingual phonetic distinctiveness (works for Amharic and English speakers alike — see ADR-006)
- **Off by default** — user opts in via the app (privacy default: no microphone capture until explicitly enabled). When enabled, the wake word is processed locally; no audio is recorded, transmitted, or stored.

### 1.4 Intent inference (Picovoice Rhino)

A custom Rhino context (`SmartHome_Ethiopian`) ships with ~25 intents covering the 80% case. The intent catalog is bilingual Amharic + English:

| Intent (English) | Intent (Amharic) | Action |
|---|---|---|
| `turn on relay N` | `ሬሌ N አብር` | Set `Power` param `true` on relay N |
| `turn off relay N` | `ሬሌ N አጥፋ` | Set `Power` param `false` on relay N |
| `turn on the living room light` | `የሳሎን ብርሃን አብር` | Set `Power` param `true` on relay with `Label = "Living Room Light"` |
| `turn everything off` | `ሁሉንም አጥፋ` | Set `Power=false` on all relays |
| `what's the power usage` | `የኃይል መጠን ስንት ነው` | Speak current `power_consumption` value via TTS |
| `activate movie night scene` | `movie night ስኪን አስጀምር` | Trigger scene by name |

Intent inference runs entirely on the ESP32-S3. Rhino emits a structured intent JSON; the firmware calls the existing internal `node_set_param` function (same code path as a cloud MQTT command) to toggle the relay. No cloud round-trip.

### 1.5 RainMaker hierarchy mapping

Voice is exposed as a Service per the RainMaker hierarchy (V3-DEVICE-MODEL.md §3.3):

```
Node: SHE-R16
└── Service: Voice       (esp.service.voice)  [SHE-R16 only]
    ├── Parameter: Wake Word Active (bool, read+write)
    ├── Parameter: Last Intent (string, read)
    └── Parameter: Last Confidence (float, read)
```

The `Wake Word Active` parameter is writable from the app — toggling it ON enables the microphone and starts Porcupine; toggling it OFF mutes the mic and stops the wake-word task. This means voice state is queryable + controllable from the app like any other device parameter, and the same MQTT topic patterns apply:

- `she/{tenant_id}/{home_id}/{room_id}/{node_mac}/params/local` — voice telemetry (Last Intent, Last Confidence)
- `she/{tenant_id}/{home_id}/{room_id}/{node_mac}/params/remote` — toggle Wake Word Active

### 1.6 Latency budget

| Stage | Target |
|---|---|
| Wake word detection (Porcupine) | < 500 ms after end of phrase |
| Intent inference (Rhino) | < 300 ms |
| Relay toggle (internal `node_set_param`) | < 50 ms |
| **End-to-end (phrase end → relay click)** | **< 1 s** |
| Works in ambient noise | Up to 60 dB (typical Ethiopian living room with TV on) |

### 1.7 Licensing

Picovoice SDK is **free for up to 100 devices per month** (developer tier). Above 100 devices, commercial pricing is ~$0.50–$2.00/device/month depending on volume and model complexity (custom Amharic context commands a premium). At the R16 volume forecast (~500 devices in year 1, ~2,000 by year 3), this is ~$1,000–$4,000/month at scale. The R16 sale price ($120 vs R8's $75) is set partly to absorb this ongoing license cost. See V3-UNIT-ECONOMICS.md §6 for the full cost model and ADR-006 for the alternatives considered (TFLite Micro custom model, no voice at all, Mycroft, Snips).

---

## 2. Cloud voice (V3.1) — Alexa + Google Home

> **Scope:** Deferred to V3.1. Documented here for completeness; not in V3 GA.

For users who already have Alexa or Google Home devices and want to use them as an additional control surface (alongside the SHE app and Matter), V3.1 will ship:

### 2.1 Alexa Skill (AWS Lambda)

```
User: "Alexa, turn off the bedroom light"
   │
   ▼
Alexa Voice Service → AWS Lambda (SHE Skill)
   │  (account linked to SHE user via OAuth 2.0 Authorization Code w/ PKCE)
   ▼
Lambda calls Spring Boot REST:
   POST /api/v3/alexa/smarthome/discover  → list user's devices
   POST /api/v3/alexa/smarthome/control   → { device_id, command: "power_off" }
   │
   ▼
Spring Boot → MQTT publish on she/.../params/remote → device toggles relay
```

### 2.2 Google Home Action

Same flow via Google Actions SDK + Smart Home fulfillment endpoint:

```
POST /api/v3/google/smarthome/execute
   { "devices": [...], "execution": [{"command": "action.devices.commands.OnOff", "params": {"on": false}}] }
```

### 2.3 Critical: Spring Boot is NOT bypassed

Both Alexa and Google integrations route through the Spring Boot REST API, never directly to EMQX or to devices. This is because:

- **Auth:** Spring Boot enforces JWT auth, RBAC, and RLS. Alexa/Google hold an OAuth token, not an MQTT credential.
- **Audit:** Every command must be audit-logged (V3-ADMIN-PLATFORM.md §4) — only Spring Boot writes to `audit_log`.
- **Multi-tenant isolation:** Spring Boot enforces `tenant_id` via the `TenantContextFilter`. Bypassing Spring Boot would skip RLS.
- **Idempotency:** Spring Boot dedupes commands via the Redis idempotency cache. Direct-to-MQTT would bypass dedup.
- **No RainMaker direct:** The original V3 draft suggested Alexa/Google "calling RainMaker" — irrelevant; we are self-hosted (ADR-001). There is no RainMaker cloud to call.

### 2.4 Limitations

- **Internet required** — cloud voice fails when connectivity is down (offline Picovoice voice on R16 still works)
- **Amharic not supported** by Alexa/Google as of 2024-Q4 — cloud voice is English-only; Amharic speakers use offline voice
- **Account linking friction** — users must link their SHE account to Alexa/Google, which adds setup steps

---

## 3. Matter — Matter-over-Wi-Fi per device (V3.1)

> **Scope:** Deferred to V3.1. The original V3 draft proposed a Raspberry Pi Border Router at the Addis Ababa data center — that decision is **overturned** here. See §3.1 and ADR-007.

### 3.1 Topology fix — why no Border Router

The original V3 doc proposed:

```
[Apple Home / Google Home / Alexa]
         │
         ▼
[Matter Border Router — Raspberry Pi 4 + ESP32-H2 at Addis Ababa DC]
         │
         ▼
[Spring Boot (MatterService)] → EMQX → SHE ESP32 devices
```

**This is architecturally wrong.** Thread is a low-power mesh over IEEE 802.15.4 at 2.4 GHz with ~30 m line-of-sight range. A Thread Border Router bridges a Thread mesh to a different IP transport — but the Border Router must be **physically on the same Thread mesh** as the devices. A Border Router hosted in an Addis Ababa DC cannot reach a Thread mesh in a user's home 10 km away. The original ADR conflated "Border Router" with "cloud service" — they are not the same.

Furthermore, the ESP32-C3 (R4) and ESP32-S3 (R8/R16) we ship are **Wi-Fi/BLE chips, not Thread/802.15.4 chips**. Doing Matter-over-Thread would require an ESP32-H2 co-processor on every device — a ~$1.50 BOM adder × 5k devices = $7.5k/year, plus a PCB redesign, plus Thread certification ($3.5k/variant × 3 = $10.5k).

### 3.2 Corrected topology — Matter-over-Wi-Fi per device

```
[Apple Home / Google Home / Alexa on user's phone]
                  │ Matter-over-Wi-Fi (commissioned via QR code)
                  ▼
        [Home Wi-Fi router (user-owned)]
                  │
                  ▼
        [SHE-R8 device — Matter-on-Wi-Fi + native MQTT to SHE cloud]
                  │
                  │ (also publishes to she/... MQTT topics on our EMQX broker)
                  ▼
        [SHE cloud — sees the same device via MQTT, app control still works]
```

Each SHE device runs the Matter SDK natively on its ESP32 Wi-Fi chip and appears as a Matter device on the user's home Wi-Fi network. There is **no central Border Router** at the data center and **no Thread radio** on any V3 SKU.

The SHE device runs **both** the Matter stack (so Apple Home can control it) and the native MQTT-to-SHE-cloud stack (so the SHE mobile app can control it). The two control planes share the same relay-state machine in firmware — a Matter `OnOff` cluster write and a SHE MQTT `params/remote` command both call the same `relay_set(channel, state)` function. This is the standard "bridged" pattern for Matter devices that also have a proprietary cloud.

### 3.3 Matter device types

V3 supports the Matter device types that map cleanly to our SKUs:

| Matter cluster | SHE device type | SKU |
|---|---|---|
| On/Off (Cluster 0x0006) | `esp.device.switch` (one per relay) | R4, R8, R16 |
| Dimmable (Cluster 0x0008) | `esp.device.lightbulb` (future SHE-DIMMER) | future |
| Sensor (Cluster 0x0042) | `esp.device.temp_sensor` (future) | future |

Each SHE relay appears as **one Matter endpoint** (so an R8 appears as 8 separate On/Off endpoints to Apple Home, all on one Matter node). This matches the RainMaker hierarchy mapping in V3-DEVICE-MODEL.md §2 — one Node has N Devices, and each Device maps to one Matter endpoint.

### 3.4 Certification

| Option | Cost | Notes |
|---|---|---|
| CSA Member (Participant tier) | $5,000/year | Required to use Matter logo + ship certified products |
| Matter SDK (dev only) | Free | Cannot ship with Matter logo |
| Per-variant certification | $3,500/variant × 3 (R4/R8/R16) = $10,500 | One-time per device variant |
| Total upfront (V3.1 launch) | **~$15,500** + ongoing $5,000/yr | |

**Decision (ADR-007):** Use Matter SDK in development during V3. Apply for CSA membership + certification in V3.1 (target 2025-Q3, post-GA). Start certification on the R8 (volume SKU) first; R4 and R16 follow.

### 3.5 Commissioning flow (V3.1)

```
User opens Apple Home / Google Home / Alexa
         │
         ▼
Taps "Add Accessory" → scans Matter QR code printed on SHE enclosure
         │
         ▼
Phone commissions SHE device via Matter-over-Wi-Fi
   (device joins home Wi-Fi, receives Matter fabric ID + credentials)
         │
         ▼
Device appears in Apple Home / Google Home as N On/Off endpoints
         │
         ▼
(Optionally) User also installs SHE app, provisions same device via BLE
   → device now controllable from both Apple Home and SHE app
```

The Matter QR code on the enclosure is **in addition to** the BLE-provisioning QR (V3-FACTORY-OPS.md §5). Both QR codes are printed during factory QC.

### 3.6 Thread (out of scope for V3.x)

SHE-R4/R8/R16 are **Wi-Fi-only for V3**. Thread SKUs would require ESP32-H2 or ESP32-C6 silicon — a hardware revision. V3-HARDWARE.md §9 documents a planned **rev-d** (2025-Q2) that adds an ESP32-H2 co-processor for Thread, but only as a research-grade SKU. Production Thread SKUs are deferred to **V3.2 or later**, contingent on Thread ecosystem maturity in Ethiopia (Border Router penetration in Ethiopian homes is currently near zero — no Apple TV 4K, no HomePod, no Nest Hub).

---

## 4. Decision records

| Topic | ADR | Status |
|---|---|---|
| Picovoice offline voice on SHE-R16 | ADR-006 | Locked |
| Matter-over-Wi-Fi per device (no Border Router) | ADR-007 | Locked |
| Dark-mode first (affects voice UI overlay) | ADR-009 | Locked |
| ESP32 chip selection (C3/S3 support Matter-over-Wi-Fi) | ADR-012 | Locked |

---

## 5. References

- V3-HARDWARE.md §3.6 — INMP441 microphone on SHE-R16; §9 — rev-d plan for Thread research, rev-e plan to add mic to R4/R8
- V3-DEVICE-MODEL.md §3.3 — `esp.service.voice` service definition
- V3-FIRMWARE.md — Picovoice SDK integration module
- V3-PRIVACY-COMPLIANCE.md + V3-DPIA.md — microphone as a privacy surface, opt-in default
- V3-UNIT-ECONOMICS.md §6 — Picovoice license cost in unit-economics model
- V3-SECURITY-MODEL.md — account linking (OAuth 2.0 Authorization Code w/ PKCE) for Alexa/Google
- V3-ADMIN-PLATFORM.md §3.8 — CA management (Matter DAC cert issuance will reuse CA infrastructure)
- ADR-006 — offline voice decision
- ADR-007 — Matter-over-Wi-Fi decision (renamed from `007-matter-border-router.md`)
- ADR-012 — ESP32 chip selection
- CSA Matter spec: https://csa-iot.org/all-solutions/matter/
- ESP-Matter SDK: https://github.com/espressif/esp-matter
- Picovoice docs: https://picovoice.ai/docs/
