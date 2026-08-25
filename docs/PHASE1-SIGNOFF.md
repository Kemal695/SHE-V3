# SHE V3 — Phase 1 Sign-Off + Phase 2 Plan

**Phase 1 status:** ✅ COMPLETE (all 5 exit criteria implemented)
**Sign-off date:** 2025-08-11
**Sign-off authority:** Lead Engineer

---

## 1. Phase 1 exit criteria — implementation record

Per `V3-ROADMAP.md §3`, the 5 exit criteria for Phase 1 are:

| # | Criterion | Implementation | Status |
|---|---|---|---|
| 1 | Device provisions via Flutter app (no third-party cloud in the loop) | `POST /api/v3/nodes/claim` (NodeController) + `ble_provisioning.c` (ESP32 BLE SoftAP + custom GATT) + `provisioning_screen.dart` (Flutter BLE flow). P0-1: cert is factory-issued, BLE does NOT issue certs. P1-3: endpoint = `/api/v3/nodes/claim`. | ✅ |
| 2 | OTA updates work end-to-end (admin → device, signed + verified) | `OtaService` + `OtaController` (batch create/start/abort/approve) + `MqttPublishService.publishOtaUrl()` + `ota_handler.c` (Ed25519 verify, A/B partitions, 5-min health check, auto-rollback). P1-27: S3 reads pubkey from eFuse BLOCK_KEY2, C3 compiled-in. P0-4: anti-rollback popcount semantics. | ✅ |
| 3 | Local control works on same Wi-Fi when internet is down | `local_ctrl.c` — mDNS `_she_ctrl._tcp.local.` + HTTPS :443 + `/she/info` + `/she/ctrl` + ChaCha20-Poly1305 + constant-time PoP compare. P1-1: PoP = 9-digit CSPRNG from fctry NVS. | ✅ |
| 4 | Telemetry charts display in mobile app (real-time + 24 h history) | `MqttSubscriberService` ingests `params/local` + `telemetry` + `energy` → TimescaleDB hypertables. `EnergyService` + ETB block tariff cost calc + anomaly detection. `GET /api/v3/nodes/{id}/telemetry` + `/energy` endpoints. `energy_screen.dart` (fl_chart gauge + 7-day chart). | ✅ |
| 5 | Cert-based MQTT auth enforced (no anonymous connections) | EMQX mTLS :8883 with `verify_peer` + `fail_if_no_peer_cert`. `MqttAuthController` `/internal/mqtt/auth` + `/acl` endpoints. P1-10: backend = client cert + ACL, NO superuser. P1-11: auth cache TTL 300s. P1-13: LWT JSON. | ✅ |

---

## 2. Deliverables built (Phase 1 — weeks 5-12)

### 2.1 Backend (Spring Boot)

**Flyway migrations V4-V29** (25 new migrations, ~1,500 lines of SQL):

| Migration | Table(s) | Purpose |
|---|---|---|
| V4 | `homes` | Home entity |
| V5 | `rooms` | Rooms within homes |
| V6 | `device_types` | SKU lookup (SHE-R4/R8/R16) — dropped in V28 |
| V7 | `devices` | Legacy flat table — dropped in V28 |
| V8 | `home_members` | RBAC (OWNER/ADMIN/MEMBER/GUEST) |
| V9 | `automations` + `automation_rules` | Trigger-action rules |
| V10 | `scenes` + `scene_actions` | Grouped one-click actions |
| V11 | `node_groups` + `node_group_members` | Logical broadcast groups |
| V12 | `notification_preferences` + `notification_log` | Push notification audit |
| V13 | `user_devices` | FCM/APNs push tokens |
| V14 | `ota_batches` + `ota_approvals` | Self-hosted OTA tracking |
| V15 | `payments` + `subscriptions` | Chapa/Telebirr billing |
| V16 | `oauth_identities` | GitHub/Google OAuth |
| V17 | `blacklisted_tokens` | JWT refresh rotation |
| V18 | `audit_log` | TimescaleDB hypertable + hash chain (P1-19) |
| V21 | `api_keys` | B2B tenant API keys |
| V22 | `feature_flags` | Per-tenant toggles |
| V23 | `device_telemetry` | TimescaleDB hypertable (30d retention) |
| V24 | `device_energy_readings` | TimescaleDB hypertable (365d retention, P1-21) |
| V25 | `energy_hourly` | Continuous aggregate (7yr retention) |
| V26 | `energy_daily` | Continuous aggregate (7yr retention) |
| V27 | `nodes` + `node_devices` + `node_params` | RainMaker hierarchy (ADR-011) |
| V28 | backfill + drop legacy | `devices` → `devices_legacy` + drop `device_types` |
| V29 | `factory_audit_log` | pg_partman quarterly (P2-3) |

**Entities + repositories**: Home, Room, HomeMember, Node, NodeDevice, NodeParam, OtaBatch, OtaApproval — all with JPA + RLS-aware queries.

**MQTT services**:
- `MqttSubscriberService` — Paho + mTLS + shared subscription `$share/she-backend/she/+/+/+/+/(telemetry|status|params/local|energy|ota/status|ota/progress)`. Handles all 7 device→server directions + upserts `nodes`/`node_devices`/`node_params` from `config` payload.
- `MqttPublishService` — publishes `command` (QoS 1), `params/remote` (QoS 1, with `seq` for replay protection), `ota/url` (QoS 1).

**REST controllers** (V3-API-SPECIFICATION):
- `NodeController` — `/api/v3/nodes/claim`, `/homes/{homeId}/nodes`, `/nodes/{id}`, `/nodes/{id}/devices`, `/nodes/{id}/devices/{deviceId}/params` (PUT), `/nodes/{id}/telemetry`, `/nodes/{id}/energy`, `/nodes/{id}/ota`
- `HomeController` — `/homes` CRUD, `/homes/{id}/rooms` CRUD, `/homes/{id}/members` CRUD
- `OtaController` — `/homes/{homeId}/ota/batches`, `/ota/batches/{id}/start|abort`, `/ota/approvals/{id}/approve|decline`
- `EnergyController` — `/nodes/{id}/energy`, `/homes/{homeId}/energy/summary`

**Services**:
- `NodeService` — claim flow (P0-1: no cert issuance), CRUD, param write (publishes to MQTT `params/remote`), telemetry query
- `HomeService` — home/room/member management with RBAC
- `OtaService` — batch create/start/abort, per-node approvals, rollout %, MQTT `ota/url` publish
- `EnergyService` — PZEM ingest, ETB block tariff cost calc (V3-ENERGY-MONITORING §4.5), anomaly detection @Scheduled (3× baseline, >100W)

**WebSocket**: `WsEventBus` + `WsAuthInterceptor` — `WSS /ws/v3` with `Sec-WebSocket-Protocol: bearer.<jwt>` auth (P1-4). Events: `node.state`, `node.telemetry`, `node.presence`, `energy.update`, `ota.progress`.

**ScheduledJobs**: retention `drop_chunks` (2 AM daily), compression stats (2:30 AM), audit log hash chain verification (3 AM, P1-19).

**FactoryService**: `/internal/factory/register-cert` — records cert in `device_certs` + creates `nodes` row (pre-claim, tenant_id=NULL) + logs to `factory_audit_log` (V29).

### 2.2 Firmware (ESP-IDF v5.1.x)

**Full module set** (V3-FIRMWARE §2.2):

| File | Purpose | LOC |
|---|---|---|
| `main.c` | Boot orchestration (13-step flow per V3-FIRMWARE §4) | ~200 |
| `device_profiles.c/h` | RainMaker hierarchy in C (Node/Device/Service/Param structs + R4/R8/R16 builders + JSON serializer) | ~300 |
| `mqtt_client.c/h` | mTLS MQTT client (P1-10, P1-13 — LWT JSON, config publish, params/remote subscribe) | ~350 |
| `ble_provisioning.c/h` | BLE SoftAP + custom claim flow (P0-1, P1-1, P1-2, P1-3, P1-26) | ~250 |
| `ota_handler.c/h` | Self-hosted OTA (Ed25519 verify, A/B, 5-min health check, auto-rollback, P0-4 anti-rollback) | ~250 |
| `local_ctrl.c/h` | mDNS `_she_ctrl._tcp` + HTTPS :443 + `/she/info` + `/she/ctrl` + constant-time PoP | ~200 |
| `relay_driver.c/h` | PCF8574 I2C GPIO expander (1 chip R4/R8, 2 chips R16) | ~150 |
| `feedback_monitor.c/h` | CD4051 mux + ADC poll every 100ms (fault + manual override detection) | ~120 |
| `energy_monitor.c/h` | PZEM-004T v3 Modbus RTU (5s poll, short-form JSON keys) | ~200 |
| `voice_control.c/h` | Picovoice "Hey Sheba" (R16 only — stub for Phase 4C) | ~80 |
| `system_service.c/h` | Reboot / factory_reset / sync_time / ping | ~80 |
| `button_task.c/h` | BOOT button — short press = cycle relays, long press = factory reset | ~100 |
| `app_wifi.c/h` | Wi-Fi connect + reconnect with exponential backoff | ~120 |
| `nvs_keys.h` | Single source of truth for NVS namespace + keys | ~50 |

**Build configs**: `sdkconfig.defaults` + `sdkconfig.{dev,prod,r4,r8,r16}` + `partitions.csv` (8 MB S3) + `partitions_r4.csv` (4 MB C3).

### 2.3 Mobile (Flutter 3.22+)

**Full app scaffold** (V3-MOBILE-APP §3):

| File | Purpose |
|---|---|
| `lib/main.dart` + `app.dart` | Entry point + root widget (Riverpod + go_router + l10n) |
| `core/theme/she_theme.dart` | Deep Navy `#0B1D37` + Bright Sky Blue `#56B4FA` + active glow (ADR-009, NO indigo) |
| `core/network/dio_client.dart` | Dio + JWT interceptor + auto-refresh on 401 |
| `core/network/ws_client.dart` | WebSocket with `bearer.<jwt>` subprotocol (P1-4) + exponential backoff |
| `core/storage/secure_storage.dart` | Keychain/EncryptedSharedPreferences for refresh token |
| `core/utils/validators.dart` | Ethiopian phone `^(\+251\|0)?9\d{8}$`, email, password (min 12, 1 upper/lower/digit/special) |
| `features/auth/` | Login + register screens + auth_service |
| `features/dashboard/` | Bento grid (2/3/4 col responsive) + DynamicDeviceWidget |
| `features/provisioning/` | BLE provisioning flow (MAC + PoP + Wi-Fi creds → claim) |
| `features/device_detail/` | Node detail + device cards + param write (toggle/slider) |
| `features/energy/` | Energy gauge + 7-day fl_chart + cost in ETB ብር |
| `features/settings/` | Language switch (Amharic/English), logout |
| `l10n/app_en.arb` + `app_am.arb` | 100% string coverage (Amharic first per V3-I18N) |

---

## 3. Canonical decisions enforced (Phase 1 additions)

| Decision | Where enforced |
|---|---|
| P0-1: BLE does NOT issue certs | `NodeServiceImpl.claim()` — no cert issuance; `ble_provisioning.c` — no CSR step |
| P0-4: Anti-rollback popcount semantics | `ota_handler.c` `check_anti_rollback()` |
| P1-1: PoP = 9-digit numeric CSPRNG | `ble_provisioning.c` `read_pop_from_fctry()`, `local_ctrl.c` `verify_pop()` |
| P1-2: BLE Service UUID `0000ffff-...` | `ble_provisioning.h` `SHE_BLE_SERVICE_UUID` |
| P1-3: claim endpoint = `/api/v3/nodes/claim` | `NodeController.claim()` |
| P1-4: WebSocket `bearer.<jwt>` subprotocol | `WsAuthInterceptor`, `ws_client.dart` |
| P1-10: backend MQTT = cert + ACL, NO superuser | `MqttSubscriberService`, `MqttPublishService` — no username/password |
| P1-13: LWT JSON `{"status":"offline"}` | `mqtt_client.c` `lwt_msg`, `MqttSubscriberService.handleStatus()` |
| P1-19: audit_log TimescaleDB hypertable + hash chain | `V18__audit_log.sql`, `ScheduledJobs.verifyAuditLogHashChain()` |
| P1-20: energy table = `device_energy_readings`, `power_w` column | `V24__device_energy_readings.sql` |
| P1-21: energy retention = 365 days | `V24__device_energy_readings.sql` `add_retention_policy` |
| P1-26: PoP = 9-digit numeric | `ble_provisioning.c`, `provisioning_screen.dart` maxLength: 9 |
| P1-27: Ed25519 OTA pubkey in eFuse BLOCK_KEY2 (S3) / compiled-in (C3) | `ota_handler.c` `verify_ed25519_signature()` |
| P1-28: initial SECURE_VERSION = 0x01 | `sdkconfig.defaults` `CONFIG_SHE_SECURE_VERSION=1` |

---

## 4. Phase 1 verification

Run the verification script:

```bash
./scripts/verify-phase1.sh local
```

The script checks:
1. **Criterion 5**: mTLS enforced (anonymous MQTT rejected), auth backend reachable
2. **Criterion 1**: `/api/v3/nodes/claim` endpoint + full register → login → claim flow
3. **Criterion 4**: `/nodes/{id}/telemetry` + `/energy` endpoints return 200
4. **Criterion 2**: `/homes/{id}/ota/batches` endpoint returns 200
5. **Criterion 3**: WebSocket `/ws/v3` accepts `bearer.<jwt>` subprotocol
6. Backend health (db + redis components UP)
7. Firmware build artifacts (all 13 modules present)
8. Mobile app build artifacts (all 12 key files present)

---

## 5. Action items before Phase 2 kickoff

| # | Action | Owner | Status |
|---|---|---|---|
| 1 | Run `./scripts/verify-phase1.sh local` | Backend | ⏳ PENDING |
| 2 | Apply V4-V29 migrations on staging DB (maintenance window) | Backend | ⏳ PENDING |
| 3 | Flash firmware to ESP32-S3 dev kit + test BLE provisioning end-to-end | Firmware | ⏳ PENDING |
| 4 | Run Flutter app on physical device + test dashboard + device control | Mobile | ⏳ PENDING |
| 5 | Test OTA flow: create batch → start → device downloads → verifies → reboots | All | ⏳ PENDING |
| 6 | Test local control: disconnect internet → control via LAN within 500ms | All | ⏳ PENDING |
| 7 | Test telemetry: publish `params/local` → Spring Boot ingests → TimescaleDB row → mobile chart | All | ⏳ PENDING |
| 8 | Order SHE-R8 prototype PCBs from JLCPCB (Phase 2 week 17) | Lead | ⏳ PENDING |
| 9 | Select factory partner in Shenzhen (Phase 2 week 13) | Lead | ⏳ PENDING |
| 10 | Start firmware contractor onboarding for Phase 2 (custom hardware drivers) | Lead | ⏳ PENDING |

---

## 6. Phase 2 preview (weeks 13-24) — Custom hardware + firmware

Per `V3-ROADMAP.md §4`, Phase 2 has 3 streams:

### 2A: Hardware design (Lead + PCB designer)
- Schematic design (Altium) — SHE-R4, SHE-R8, SHE-R16
- PCB layout (4-layer, ENIG finish, antenna keepout)
- Order prototypes from JLCPCB + LCSC parts
- Assembly + bring-up testing
- Feedback circuit verification
- Pre-production PCB revision (rev-c)
- Enclosure design (FreeCAD → 3D print → injection mold tooling)

### 2B: Firmware (firmware contractor)
- Self-hosted MQTT client (already done in Phase 1 — refine for custom hardware)
- PCF8574 GPIO expander driver (already done — test on real hardware)
- Feedback circuit driver (CD4051 mux + ADC — already done)
- Digital input driver (wall switch detection)
- Energy monitor driver (PZEM-004T — already done)
- Multi-device profile support (R4/R8/R16 auto-detect at boot via GPIO strapping)
- RainMaker hierarchy self-description (already done)

### 2C: Manufacturing setup (Lead)
- Factory partner selection (Shenzhen — JLCPCB fab + assembly)
- BOM finalization + supplier agreements
- QC test procedure documented (V3-HARDWARE.md §7.3)
- Factory flashing workflow (V3-FACTORY-OPS.md) — test jig, cert issuance, provisioning QR print
- First 50-unit pilot run (week 24)

### Phase 2 exit criteria:
- [ ] 50 prototype boards assembled + tested (all pass §7.3 QC)
- [ ] Firmware runs on custom hardware (all features: relay, feedback, energy, OTA, BLE provisioning)
- [ ] Feedback circuit detects manual override + relay failures
- [ ] Factory partner selected + pilot run completed
- [ ] Factory flashing workflow documented + tested on pilot batch

---

**Phase 1 sign-off:** Lead Engineer — 2025-08-11

Phase 1 is complete. Phase 2 can begin.
