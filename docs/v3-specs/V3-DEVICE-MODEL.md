# V3 — Device Model

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Lead Engineer

---

## 1. Purpose

This document defines the canonical data model for every SHE V3 device. It adopts the **ESP RainMaker hierarchy** (Node → Device → Service → Parameter → Attribute) as the abstraction layer between physical hardware and the cloud/application layer.

This hierarchy is adopted because:
- It is a proven, well-documented model used by Espressif's own IoT platform
- It is self-describing — the node reports its own configuration, enabling dynamic UI generation
- It cleanly separates user-controllable entities (Devices) from background functionality (Services)
- It maps naturally to our MQTT topic namespace and Postgres schema

**Critical clarification:** SHE V3 adopts the RainMaker *data hierarchy* only. The SHE V3 cloud is **fully self-hosted** (EMQX + own CA + Spring Boot + Postgres). No data flows to Espressif or AWS. The hierarchy is a conceptual model, not a dependency on RainMaker cloud services.

---

## 2. The Hierarchy

```
Node: SHE-R8 (MAC: 24:6F:28:AA:BB:CC)
│
├── Device: "Relay 1"        (esp.device.switch)
│   ├── Parameter: Power      (bool, read+write)
│   └── Attribute: Label      ("Kitchen Light")
│
├── Device: "Relay 2"        (esp.device.switch)
│   ├── Parameter: Power      (bool, read+write)
│   └── Attribute: Label      ("Living Room Fan")
│
├── ... (relays 3-8)
│
├── Service: OTA             (esp.service.ota)
│   ├── Parameter: URL        (string, write-only)
│   ├── Parameter: Status     (string, read-only)
│   └── Parameter: Progress   (int 0-100, read-only)
│
└── Service: Diagnostics     (esp.service.diag)
    ├── Parameter: Uptime     (int, read-only)
    └── Parameter: RSSI       (int, read-only)
```

### 2.1 Level definitions

| Level | Represents | Example | Count per parent |
|---|---|---|---|
| **Node** | One physical ESP32 board | SHE-R8 controller in living room | 1 per board |
| **Device** | A logical, user-controllable entity | "Kitchen Light" (a switch) | 1-N per node |
| **Service** | Background functionality (not user-controlled) | OTA, Diagnostics, Timezone | 0-N per node |
| **Parameter** | A controllable or measurable value | Power (bool), Temperature (float) | 1-N per device/service |
| **Attribute** | Read-only metadata | Serial Number, Model, Firmware Version | 0-N per node/device |

### 2.2 Naming conventions

**Node names** follow the pattern `SHE-{model}-{last-4-of-MAC}`:
- `SHE-R8-AABBCC` — SHE-R8 board, MAC ending AABBCC
- `SHE-R4-DEFF12` — SHE-R4 board, MAC ending DEFF12

**Device names** are user-assigned at provisioning time, defaulting to `Relay N`:
- Default: `Relay 1`, `Relay 2`, ... `Relay 8`
- User-customized: `Kitchen Light`, `Living Room Fan`, `Bedroom Lamp`

**Device types** use RainMaker's standard type namespace (`esp.device.*`):

| Type | Description | Parameters |
|---|---|---|
| `esp.device.switch` | On/off relay (default for SHE-R4/R8/R16) | `power` (bool) |
| `esp.device.lightbulb` | Dimmable light (future SHE-DIMMER SKU) | `power`, `brightness`, `hue` |
| `esp.device.fan` | Speed-controlled fan (future) | `power`, `speed` |
| `esp.device.temp_sensor` | Temperature sensor (future SHE-SENSOR) | `temperature`, `humidity` |
| `esp.device.energy_meter` | Energy monitoring (PZEM-004T) | `power`, `voltage`, `current`, `energy` |

**Service types** use `esp.service.*`:

| Type | Description | Parameters |
|---|---|---|
| `esp.service.ota` | Over-the-air firmware updates | `url`, `status`, `progress` |
| `esp.service.diag` | Diagnostics | `uptime`, `rssi`, `free_heap`, `reset_reason` |
| `esp.service.timezone` | Timezone management | `timezone` |
| `esp.service.schedule` | On-device scheduling | `schedules` (array) |

**Parameter types** use `esp.param.*`:

| Type | Data type | Properties | Example |
|---|---|---|---|
| `esp.param.power` | bool | read, write, persist | `true` / `false` |
| `esp.param.brightness` | int (0-100) | read, write, persist | `75` |
| `esp.param.temperature` | float | read | `24.6` |
| `esp.param.humidity` | float | read | `61.2` |
| `esp.param.power_consumption` | float | read | `47.3` (watts) |
| `esp.param.voltage` | float | read | `220.1` |
| `esp.param.current` | float | read | `0.21` |

**Attributes** are free-form key-value pairs:
- `Serial Number` — factory-assigned, e.g. `SHE-R8-2024-00142`
- `Model` — `SHE-R8`
- `Manufacturer` — `Smart Home Ethiopia`
- `Firmware Version` — `1.4.2`
- `Hardware Revision` — `rev-b`
- `MAC Address` — `24:6F:28:AA:BB:CC`

---

## 3. SKU Definitions

### 3.1 SHE-R4 — 4-Channel Relay Controller

**Hardware:** ESP32-C3 + PCF8574 4-channel relay driver
**Target:** Entry-level consumer (1 room, ≤4 appliances)

```
Node: SHE-R4 (MAC: 24:6F:28:AA:BB:CC)
├── Device: "Relay 1"    (esp.device.switch)
│   ├── Parameter: Power  (bool)
│   └── Attribute: Label  ("Light")
├── Device: "Relay 2"    (esp.device.switch)
│   ├── Parameter: Power  (bool)
│   └── Attribute: Label  ("Fan")
├── Device: "Relay 3"    (esp.device.switch)
│   ├── Parameter: Power  (bool)
│   └── Attribute: Label  ("Outlet 1")
├── Device: "Relay 4"    (esp.device.switch)
│   ├── Parameter: Power  (bool)
│   └── Attribute: Label  ("Outlet 2")
├── Service: OTA         (esp.service.ota)
│   ├── Parameter: URL
│   ├── Parameter: Status
│   └── Parameter: Progress
└── Service: Diagnostics (esp.service.diag)
    ├── Parameter: Uptime
    └── Parameter: RSSI
```

### 3.2 SHE-R8 — 8-Channel Relay Controller (volume SKU)

**Hardware:** ESP32-S3 + PCF8574 (x1) 8-channel relay driver + PZEM-004T energy sensor
**Target:** Whole-home control (2-3 rooms, 8 appliances)

```
Node: SHE-R8 (MAC: 24:6F:28:AA:BB:CC)
├── Device: "Relay 1"    (esp.device.switch)
│   ├── Parameter: Power  (bool)
│   └── Attribute: Label  ("Kitchen Light")
├── Device: "Relay 2"    (esp.device.switch)
│   ├── Parameter: Power  (bool)
│   └── Attribute: Label  ("Living Room Fan")
├── ... (relays 3-8, same structure)
├── Service: OTA         (esp.service.ota)
│   ├── Parameter: URL
│   ├── Parameter: Status
│   └── Parameter: Progress
└── Service: Diagnostics (esp.service.diag)
    ├── Parameter: Uptime
    ├── Parameter: RSSI
    ├── Parameter: Free Heap
    └── Parameter: Reset Reason
```

### 3.3 SHE-R16 — 16-Channel Relay Controller

**Hardware:** ESP32-S3 + PCF8574 (x2) 16-channel relay driver + PZEM-004T + INMP441 I2S mic (Picovoice)
**Target:** Prosumer / small B2B (whole building, 16 circuits)

```
Node: SHE-R16 (MAC: 24:6F:28:AA:BB:CC)
├── Device: "Relay 1" through "Relay 16"  (esp.device.switch)
│   each with: Parameter: Power (bool), Attribute: Label (string)
├── Service: OTA         (esp.service.ota)
│   └── ...
├── Service: Diagnostics (esp.service.diag)
│   └── ...
└── Service: Voice       (esp.service.voice)  [SHE-R16 only]
    ├── Parameter: Wake Word Active (bool)
    ├── Parameter: Last Intent (string)
    └── Parameter: Last Confidence (float)
```

---

## 4. Parameter Properties

Every parameter has a `properties` bitmask:

| Property | Meaning | Example |
|---|---|---|
| `read` | Parameter can be read by cloud/app | All params |
| `write` | Parameter can be written by cloud/app | `power`, `brightness` |
| `persist` | Parameter value survives reboot | `power` (relay returns to last state) |
| `time_series` | Parameter is logged to TimescaleDB | `temperature`, `power_consumption` |

Example parameter definition (firmware C code):

```c
// Power parameter — read, write, persist
esp_rmaker_param_t *power = esp_rmaker_param_create(
    ESP_RMAKER_DEF_POWER_NAME,    // "Power"
    ESP_RMAKER_DEF_POWER,         // "esp.param.power"
    esp_rmaker_bool(false),       // initial value
    PROP_READ | PROP_WRITE | PROP_PERSIST
);
esp_rmaker_device_add_param(relay_device_1, power);

// Temperature parameter — read, time_series
esp_rmaker_param_t *temp = esp_rmaker_param_create(
    "Temperature",
    "esp.param.temperature",
    esp_rmaker_float(0),
    PROP_READ | PROP_TIME_SERIES
);
```

---

## 5. MQTT Topic Mapping

The hierarchy maps to MQTT topics as follows (V3-MQTT-STANDARDS.md):

```
she/{tenant_id}/{home_id}/{room_id}/{node_mac}/config
  → Node self-description (devices, params, services, attributes)
  → Published on connect, retained

she/{tenant_id}/{home_id}/{room_id}/{node_mac}/params/local
  → Parameter updates from node (telemetry)
  → Published every 5s or on change

she/{tenant_id}/{home_id}/{room_id}/{node_mac}/params/remote
  → Parameter commands from cloud (write)
  → Published by Spring Boot on user action

she/{tenant_id}/{home_id}/{room_id}/{node_mac}/ota/{url,status,progress}
  → OTA service parameters

she/{tenant_id}/{home_id}/{room_id}/{node_mac}/status
  → Node online/offline (LWT, retained)
```

**Payload format** (JSON):

```json
// config topic (retained, published on connect)
{
  "node_id": "SHE-R8-AABBCC",
  "mac": "24:6F:28:AA:BB:CC",
  "model": "SHE-R8",
  "firmware": "1.4.2",
  "devices": [
    {
      "name": "Relay 1",
      "type": "esp.device.switch",
      "params": [
        {"name": "Power", "type": "esp.param.power", "data_type": "bool",
         "properties": ["read","write","persist"]}
      ],
      "attributes": {"Label": "Kitchen Light", "Channel": "0"}
    }
  ],
  "services": [
    {"name": "OTA", "type": "esp.service.ota", "params": [...]},
    {"name": "Diagnostics", "type": "esp.service.diag", "params": [...]}
  ]
}

// params/local topic (telemetry, every 5s)
{
  "Relay 1": {"Power": true},
  "Relay 2": {"Power": false},
  "Diagnostics": {"Uptime": 86400, "RSSI": -52, "Free_Heap": 142336}
}

// params/remote topic (command from cloud)
{
  "Relay 1": {"Power": true}
}
```

---

## 6. Database Mapping

The hierarchy maps to three Postgres tables (V3-DATABASE-DESIGN.md §3):

```sql
-- Node = one physical ESP32 board
nodes (
  id UUID PRIMARY KEY,
  tenant_id UUID, home_id UUID, room_id UUID,
  rainmaker_node_id VARCHAR,  -- "SHE-R8-AABBCC" (our naming, not RainMaker cloud)
  mac_address VARCHAR,
  sku VARCHAR,                -- 'SHE-R4' | 'SHE-R8' | 'SHE-R16'
  name VARCHAR,
  firmware_version VARCHAR,
  is_online BOOLEAN,
  ...
)

-- Device = one logical, user-controllable entity (e.g., "Kitchen Light")
node_devices (
  id UUID PRIMARY KEY,
  node_id UUID REFERENCES nodes(id),
  device_name VARCHAR,        -- "Relay 1" (matches MQTT payload key)
  device_type VARCHAR,        -- "esp.device.switch"
  display_name VARCHAR,       -- "Kitchen Light" (user-assigned)
  channel_index INT,          -- 0-15, maps to GPIO via PCF8574
  ...
)

-- Parameter = a controllable/measurable value
node_params (
  id UUID PRIMARY KEY,
  node_device_id UUID REFERENCES node_devices(id),
  param_name VARCHAR,         -- "Power"
  param_type VARCHAR,         -- "esp.param.power"
  data_type VARCHAR,          -- 'bool' | 'int' | 'float' | 'string'
  properties JSONB,           -- ["read","write","persist"]
  last_value JSONB,           -- true (cached for fast UI reads)
  last_reported_at TIMESTAMPTZ,
  ...
)
```

**Multi-tenant RLS** (ADR-003): all three tables carry `tenant_id` (via `node_id` join) and enforce `current_setting('app.tenant_id')` policies.

---

## 7. API Mapping

The hierarchy maps to REST endpoints (V3-API-SPECIFICATION.md):

```
GET  /api/v3/homes/{homeId}/nodes                    → list nodes in home
GET  /api/v3/nodes/{nodeId}                          → node details (config, devices, params)
GET  /api/v3/nodes/{nodeId}/devices                  → list devices on node
PUT  /api/v3/nodes/{nodeId}/devices/{deviceId}/params → write parameter
     body: {"Power": true}
GET  /api/v3/nodes/{nodeId}/params                   → all param values (cached)
GET  /api/v3/nodes/{nodeId}/telemetry?from=...&to=... → time-series data
POST /api/v3/nodes/{nodeId}/ota                      → trigger OTA
     body: {"version": "1.5.0"}
```

---

## 8. Dynamic UI Generation

The mobile app generates device controls dynamically from the node's `config` payload:

| Device type | Parameter | UI widget |
|---|---|---|
| `esp.device.switch` | `power` (bool) | Toggle switch |
| `esp.device.lightbulb` | `power` (bool) | Toggle switch |
| `esp.device.lightbulb` | `brightness` (int 0-100) | Slider |
| `esp.device.fan` | `power` (bool) | Toggle switch |
| `esp.device.fan` | `speed` (int 1-5) | Segmented control |
| `esp.device.temp_sensor` | `temperature` (float) | Read-only display |
| `esp.device.energy_meter` | `power` (float) | Read-only display + chart |

This means **new device types can be added in firmware without app changes** — the app renders whatever parameters the node reports.

---

## 9. Migration from flat model

Previous V3 docs used a flat `devices` table with `reported_state`/`desired_state` JSONB blobs. The hierarchy model is adopted because:

| Old (flat) | New (hierarchy) | Benefit |
|---|---|---|
| `devices.reported_state = {"1": true, "2": false}` | `node_params.last_value` per param | Queryable per-param, type-safe |
| `devices.device_type = 'R8'` | `nodes.sku = 'SHE-R8'` + 8 `node_devices` rows | Individual relay naming + metadata |
| No concept of "services" | `node_devices` where `device_type LIKE 'esp.service.%'` | OTA + diagnostics are first-class |
| Static UI per SKU | Dynamic UI from config payload | New params appear without app update |

Migration: V26 migration creates `nodes`, `node_devices`, `node_params` tables. V27 backfills from `devices` (one row per channel). V28 drops `devices.reported_state` + `desired_state` columns. See V3-DATABASE-DESIGN.md §2.

---

## 10. Decision record

This model is documented in **ADR-011: Adopt RainMaker device hierarchy**. The decision was made because:
- The firmware team is already familiar with the RainMaker SDK's data model
- The hierarchy is self-describing, enabling dynamic UI generation
- It cleanly separates user-controllable entities from background services
- It is a conceptual model — no dependency on RainMaker cloud services

**Alternatives considered:**
1. *Flat model (previous V3 docs)* — rejected: no per-channel metadata, no dynamic UI, no service concept
2. *Custom hierarchy* — rejected: reinventing a well-tested model, adds documentation burden
3. *Full RainMaker cloud adoption* — rejected: violates self-hosted requirement (ADR-001), PDPP data residency (ADR-008)

---

## References

- V3-FIRMWARE.md — firmware implementation of this model
- V3-MQTT-STANDARDS.md — MQTT topic structure for this hierarchy
- V3-DATABASE-DESIGN.md — Postgres schema (nodes, node_devices, node_params tables)
- V3-API-SPECIFICATION.md — REST endpoints mapped to this hierarchy
- ADR-011 — decision record for adopting this model
- ESP RainMaker docs: https://docs.rainmaker.espressif.com/docs/product_overview/concepts/terminologies
