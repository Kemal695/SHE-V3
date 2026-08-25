# ADR-011: Adopt ESP RainMaker Data Hierarchy (data model only, not cloud service)

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

Every IoT platform needs a device data model — the abstraction that says "this physical box has these controllable things, these measurable things, and these background services, organized like *this*." The choice of model shapes the firmware API, the MQTT topic namespace, the database schema, the REST API shape, and the mobile app's UI generation logic. Getting it wrong means re-architecting all five layers later.

The previous V3 docs used a **flat device model**: a `devices` table with a `device_type` column ("R8") and a `reported_state` JSONB blob (`{"1": true, "2": false, ...}`). This worked for "toggle relay 3" but failed for: (a) per-channel metadata (each relay has its own user-assigned name, "Kitchen Light" vs "Living Room Fan"); (b) dynamic UI (a flat blob can't tell the app "this is a switch with a power param, render a toggle"); (c) background services (OTA, diagnostics, voice had no clean place to live); (d) future device types (temperature sensor, dimmer, fan controller) — each would require schema changes.

Espressif's **ESP RainMaker** platform defines a well-documented hierarchy — **Node → Device → Service → Parameter → Attribute** — that solves exactly these problems. It is self-describing (the node reports its own configuration, enabling dynamic UI generation), separates user-controllable entities (Devices) from background functionality (Services), and has a standard type namespace (`esp.device.switch`, `esp.service.ota`, `esp.param.power`). The firmware team is already familiar with it from ESP-IDF examples.

The question is: do we adopt the RainMaker *cloud service* (broker, CA, OTA pipeline, console) along with the data model? ADR-001 has already answered "no" to the cloud service — we are fully self-hosted for PDPP/B2B reasons. This ADR answers "yes" to the data model. The two are not in conflict: the hierarchy is a conceptual schema, the cloud service is a hosted implementation of that schema. We borrow the schema, not the service.

## Decision

Adopt the **ESP RainMaker data hierarchy** (Node → Device → Service → Parameter → Attribute) as the canonical device data model for SHE V3. This is a **data-model-only adoption** — no dependency on the RainMaker cloud service, the RainMaker MQTT broker, the RainMaker CA, the RainMaker OTA pipeline, or the RainMaker console.

The hierarchy is documented in full in V3-DEVICE-MODEL.md:

- **Node** — one physical ESP32 board (e.g., `SHE-R8-AABBCC`). Maps to a row in `nodes` table, an MQTT topic root `she/{tenant}/{home}/{room}/{node_mac}/`, and a RainMaker-style `node_id`.
- **Device** — a logical, user-controllable entity (e.g., "Kitchen Light", type `esp.device.switch`). Maps to a row in `node_devices` table and a key in the MQTT `params/local` payload.
- **Service** — background functionality, not directly user-controlled (e.g., `esp.service.ota`, `esp.service.diag`, `esp.service.voice`). Implemented as `node_devices` rows where `device_type LIKE 'esp.service.%'`.
- **Parameter** — a controllable or measurable value (e.g., `Power` of type `esp.param.power`, `Temperature` of type `esp.param.temperature`). Maps to a row in `node_params` table with `properties` bitmask (`read`, `write`, `persist`, `time_series`).
- **Attribute** — read-only metadata (e.g., `Serial Number`, `Model`, `Firmware Version`, `MAC Address`). Stored as key-value pairs on the node or device.

The hierarchy maps cleanly to: MQTT topic structure (V3-MQTT-STANDARDS.md §2), Postgres schema (V3-DATABASE-DESIGN.md §3 — `nodes`, `node_devices`, `node_params` tables), REST API (V3-API-SPECIFICATION.md §4 — `/nodes`, `/nodes/{id}/devices`, `/nodes/{id}/params`), and dynamic UI generation in the Flutter app (V3-MOBILE-APP.md — renders controls from the node's `config` payload, no per-SKU hardcoding).

**The naming convention uses RainMaker-style type namespaces** (`esp.device.switch`, `esp.param.power`, `esp.service.ota`) so that firmware engineers familiar with the RainMaker SDK find the model intuitive. Node IDs use our own naming (`SHE-R8-AABBCC`, last 6 of MAC) — these are *our* identifiers, not RainMaker cloud IDs.

## Alternatives Considered

### Alternative A: Flat device model (the previous V3 docs approach)
- **Pros:** Simple schema (one `devices` table); simple MQTT payload (`{"1": true, "2": false}`); simple API (`POST /devices/{id}/state`).
- **Cons:** No per-channel metadata (each relay's user-assigned name has nowhere clean to live); no dynamic UI (app must hardcode per-SKU layouts); no place for background services (OTA, diagnostics, voice end up as ad-hoc fields); adding a new device type (temperature sensor, dimmer) requires schema migration + app release; the `reported_state` JSONB blob is opaque to SQL queries (can't easily do "show me all relays currently ON across all homes"). **Rejected — does not scale beyond "toggle relay N".**

### Alternative B: Custom hierarchy (design our own Node → Channel → Sensor → Service model)
- **Pros:** No external conceptual dependency; we control the naming; could be more "Ethiopian" or more "SHE-branded".
- **Cons:** Reinventing a well-tested model — RainMaker's hierarchy was designed by Espressif's IoT team and validated across thousands of deployed devices; we'd spend weeks debating names ("Channel" vs "Device" vs "Endpoint" vs "Component") for zero net benefit; firmware team is already familiar with RainMaker terms from ESP-IDF examples; documentation burden (we'd have to write the equivalent of RainMaker's docs ourselves); loses the conceptual portability (a future engineer familiar with RainMaker has to relearn our model). **Rejected — reinventing a solved problem.**

### Alternative C: Full RainMaker cloud adoption (use RainMaker cloud service end-to-end)
- **Pros:** Zero infrastructure to operate (broker, CA, OTA, console all managed by Espressif); tightest firmware integration via `esp_rmaker_*` SDK calls; built-in Apple Home / Google Home / Alexa skills via RainMaker's cloud; fastest time-to-market.
- **Cons:** **Violates ADR-001** — RainMaker cloud runs on AWS (region not in Ethiopia), violating PDPP data residency; per-device pricing ($0.10–$0.30/device/month estimated); vendor lock-in on device auth, OTA, and topic namespace; B2B tenants with "no foreign cloud" clauses cannot be sold to; RainMaker's billing portal is USD-only and not B2B white-label. **Rejected — see ADR-001 for the full case.**

### Alternative D: AWS IoT Thing Model / shadow
- **Pros:** Industry standard (AWS IoT); well-documented; tight integration with AWS IoT Core if we ever used it.
- **Cons:** We don't use AWS IoT Core (ADR-001); the Thing Shadow document model is a flat JSON blob (same problems as Alternative A); AWS-specific naming conventions (`$aws/things/{thingId}/shadow/...`) don't translate to our self-hosted EMQX topics; tightly coupled to AWS SDK patterns. **Rejected.**

### Alternative E: W3C Web of Things Thing Description
- **Pros:** Open W3C standard; semantically rich (JSON-LD); interoperable across vendors in principle.
- **Cons:** Designed for web-API-style interop, not constrained-device MQTT; JSON-LD is heavy for ESP32; minimal tooling in the ESP-IDF ecosystem; semantic web pedigree is overkill for our use case. **Rejected.**

## Consequences

### Positive
- **Self-describing devices** — the node reports its own `config` payload on MQTT connect, enabling dynamic UI generation in the app (new device types can be added in firmware without app changes)
- **Clean separation** of user-controllable entities (Devices) from background functionality (Services) — OTA, diagnostics, voice are first-class, not ad-hoc fields
- **Per-channel metadata** — each relay has its own user-assigned name, type, and properties, queryable in SQL (no more JSONB blob)
- **Type-safe parameters** — `node_params.data_type` enforces bool/int/float/string at the DB layer; bad firmware payloads are caught
- **Standard naming** — `esp.device.switch`, `esp.param.power`, `esp.service.ota` are familiar to anyone who has read RainMaker docs or ESP-IDF examples
- **Maps cleanly** to MQTT topics (V3-MQTT-STANDARDS.md), Postgres schema (V3-DATABASE-DESIGN.md §3), REST API (V3-API-SPECIFICATION.md §4), and dynamic UI (V3-MOBILE-APP.md) — one model, five layers, no impedance mismatch
- **No vendor lock-in** — the hierarchy is a conceptual schema, not a service dependency; we can replace any layer (broker, DB, app) without changing the model

### Negative
- **"esp.*" naming implies RainMaker affiliation** — engineers reading our docs may assume we use the RainMaker cloud; we must repeatedly clarify "data model only, not cloud service" (this ADR, V3-DEVICE-MODEL.md §1, V3-OVERVIEW.md §2.3)
- **Three tables instead of one** — `nodes` + `node_devices` + `node_params` is more complex than a single `devices` table; joins are required for "give me all relay states in home X"
- **Migration cost** — V26–V28 database migrations are required to move from the flat `devices` table to the hierarchy (V3-DATABASE-DESIGN.md §2); one-time engineering effort
- **Firmware must build the config payload** — the node must enumerate its devices/params/services/attributes at boot and publish a `config` JSON; this is ~200 lines of C code that didn't exist before
- **Type namespace stewardship** — if we invent new device types (`esp.device.ethiopian_calendar_clock`?), we own the namespace; risk of inconsistency

### Neutral
- We could have renamed the type namespace to `she.device.switch` etc. to disambiguate from RainMaker — we chose to keep `esp.*` because the firmware team's mental model aligns with RainMaker docs and the SDK's `esp_rmaker_*` constants use the same naming
- The hierarchy is implementation-agnostic — it would work the same on AWS IoT, Azure IoT Hub, or a self-hosted EMQX (our case)
- Migration from the flat model is a one-time V26–V28 migration; new deployments after V3 GA start on the hierarchy directly

## References
- V3-DEVICE-MODEL.md (canonical definition of the hierarchy, SKU mappings, MQTT/DB/API mappings)
- V3-MQTT-STANDARDS.md §2 (MQTT topic structure derived from the hierarchy)
- V3-DATABASE-DESIGN.md §2–3 (Postgres schema: `nodes`, `node_devices`, `node_params`)
- V3-API-SPECIFICATION.md §4 (REST endpoints mapped to the hierarchy)
- V3-FIRMWARE.md (firmware implementation — `esp_rmaker_*` style API on self-hosted broker)
- V3-MOBILE-APP.md (dynamic UI generation from the `config` payload)
- ADR-001 (self-hosted cloud — clarifies we do NOT adopt the RainMaker cloud service)
- ADR-002 (custom hardware — the physical nodes in the hierarchy)
- ESP RainMaker docs: https://docs.rainmaker.espressif.com/docs/product_overview/concepts/terminologies
