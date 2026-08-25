# V3 — Overview

**Status:** Locked
**Last updated:** 2025-Q1

---

## 1. Platform vision

**Smart Home Ethiopia (SHE) V3** is a production-ready, fully self-hosted IoT platform built for the Ethiopian market. It combines custom ESP32 relay hardware, a self-hosted device cloud (no third-party dependencies), premium dark-mode mobile app, Telebirr mobile money payments, offline voice control, and Amharic-first internationalization.

**Core principle:** Every byte of data stays in Ethiopia. Every component is owned and operated by SHE. No RainMaker, no AWS IoT, no third-party cloud. The device data model adopts the ESP RainMaker hierarchy (Node → Device → Service → Parameter → Attribute) as a conceptual framework — but the cloud infrastructure is entirely self-hosted.

---

## 2. Architecture summary

### 2.1 Fully self-hosted device cloud

No dependency on any third-party IoT platform. Everything runs on SHE-owned infrastructure in Addis Ababa:

- **EMQX cluster** (3 nodes) for MQTT messaging
- **Own Certificate Authority** (root + intermediate) for X.509 device authentication
- **Spring Boot** (2+ instances) for REST API, auth, multi-tenancy, automations, payments
- **PostgreSQL 16** with Row-Level Security for multi-tenant isolation
- **TimescaleDB** for time-series energy + telemetry data
- **MinIO** for OTA firmware image storage
- **Redis** for caching + session state
- **Cloudflare** for DDoS protection + DNS (data stays in Ethiopia, only edge terminates TLS)

### 2.2 Custom ESP32 relay hardware

Three SKUs covering entry to prosumer:
- **SHE-R4** — 4-channel, ESP32-C3, $18 BOM, $55 sale
- **SHE-R8** — 8-channel, ESP32-S3, $24 BOM, $75 sale (volume SKU)
- **SHE-R16** — 16-channel, ESP32-S3 + mic, $38 BOM, $120 sale

See V3-HARDWARE.md for full BOM, schematic, PCB design, enclosure, manufacturing plan.

### 2.3 Device data model — RainMaker hierarchy adopted

Every device is modeled using the ESP RainMaker hierarchy:

```
Node: SHE-R8 (MAC: 24:6F:28:AA:BB:CC)
├── Device: "Relay 1" (esp.device.switch)
│   ├── Parameter: Power (bool)
│   └── Attribute: Label ("Kitchen Light")
├── Device: "Relay 2" (esp.device.switch)
│   └── ...
├── Service: OTA (esp.service.ota)
└── Service: Diagnostics (esp.service.diag)
```

This is a conceptual model only — no dependency on RainMaker cloud. See V3-DEVICE-MODEL.md.

### 2.4 Premium dark-mode mobile app

Flutter 3.22+ app with Bento grid dashboard, BLE provisioning, offline cache, haptic feedback. Dark-mode-first per ADR-009. Amharic-first i18n with Ethiopian calendar support.

### 2.5 Multi-tenant B2B + B2C

Postgres Row-Level Security (ADR-003) provides tenant isolation at the database layer. B2B white-label branding (logo, colors, app name). Per-device/month billing for B2B, freemium + premium for B2C.

### 2.6 Telebirr + CBE Birr payments via Chapa

Chapa payment aggregator handles Telebirr + CBE Birr + cards. B2C: free tier + 150 ETB/month premium + 300 ETB/month family plan. B2B: $1-0.80/device/month tiered.

### 2.7 Offline voice control

Picovoice Porcupine + Rhino on ESP32-S3 (SHE-R16). "Hey Sheba" wake word, Amharic + English intents. No cloud dependency for voice.

### 2.8 Matter support (V3.1)

Matter-over-Wi-Fi per-device (not a central Border Router). SHE devices appear as Matter devices to Apple Home / Google Home / Alexa. Deferred to V3.1.

---

## 3. Feature set

| Feature | Status | Doc |
|---|---|---|
| Custom ESP32 hardware (R4/R8/R16) | Locked | V3-HARDWARE.md |
| Self-hosted EMQX MQTT cluster | Locked | V3-ARCHITECTURE.md |
| Own CA + X.509 mTLS device auth | Locked | V3-SECURITY-MODEL.md |
| RainMaker device hierarchy | Locked | V3-DEVICE-MODEL.md |
| Multi-tenant RLS | Locked | V3-B2B-WHITELABEL.md |
| Premium dark-mode Flutter app | Locked | V3-MOBILE-APP.md |
| Next.js admin console | Locked | V3-ADMIN-WEB-APP.md |
| Telebirr via Chapa | Locked | V3-PAYMENTS.md |
| Energy monitoring in ETB | Locked | V3-ENERGY-MONITORING.md |
| Offline voice (Picovoice) | Locked | V3-VOICE-MATTER.md |
| Amharic-first i18n | Locked | V3-I18N.md |
| OTA firmware updates | Locked | V3-FIRMWARE.md §6 |
| Automations + scenes | Locked | V3-API-SPECIFICATION.md §5-6 |
| PDPP compliance | Locked | V3-PRIVACY-COMPLIANCE.md + V3-DPIA.md |
| Factory flashing workflow | Locked | V3-FACTORY-OPS.md |
| Matter / Thread | V3.1 | V3-VOICE-MATTER.md §3 |
| Solar inverter integration | V3.2 | — |

---

## 4. Tech stack

| Layer | Technology | Notes |
|---|---|---|
| Firmware | ESP-IDF v5.1 + C | Custom drivers for PCF8574, PZEM, Picovoice |
| Device cloud (MQTT) | EMQX 5.x (3-node cluster) | Mutual-TLS, per-device ACL via HTTP backend |
| Device auth | X.509 (own CA, root + intermediate) | Pre-flashed at factory |
| App backend | Spring Boot 3.x / Java 21 (LTS) | REST API, WebSocket, auth, automations |
| Database | PostgreSQL 16 + RLS | Multi-tenant isolation at DB layer |
| Time-series | TimescaleDB (Postgres extension) | Energy + telemetry, compression enabled |
| Object storage | MinIO | OTA firmware images |
| Cache | Redis 7 | Session, rate limit, idempotency |
| Mobile app | Flutter 3.22+ / Riverpod | Dark-mode Bento UI, BLE provisioning |
| Admin web | Next.js 16 / TypeScript | ~9 screens (reduced from 16) |
| Payments | Chapa → Telebirr/CBE Birr | B2C + B2B billing |
| Voice | Picovoice SDK | Offline, Amharic + English |
| Gateway | Nginx + Cloudflare | TLS termination, geo-block (with exceptions) |
| Hosting | Addis Ababa data center | PDPP data residency |

---

## 5. Team allocation

| Role | Months 1-3 | Months 4-6 | Months 7-9 | Months 10-12 |
|---|---|---|---|---|
| Lead Engineer | Architecture + EMQX + CA setup | Firmware + factory ops | B2B multi-tenant + energy | Beta + GA launch |
| Backend Engineer | Spring Boot + Postgres + RLS | API + OTA + payments | Mobile app integration | Hardening + scale |
| Firmware Contractor | — | ESP32 firmware + BLE + OTA | Hardware rev-b + testing | Factory support |
| Mobile/Frontend | — | — | Flutter app + admin console | Polish + beta feedback |

**Total:** 2-3 engineers + 1 firmware contractor (months 4-9).

---

## 6. Phase 0 open questions — RESOLVED

All six open questions from the previous V3 draft are now resolved:

| # | Question | Resolution | ADR |
|---|---|---|---|
| 1 | Data center provider | **Ethio Telecom Cloud** (Addis Ababa, single-region) | ADR-008 |
| 2 | Factory partner | **Shenzhen (JLCPCB fab + assembly partner)** — sea freight to Djibouti | V3-HARDWARE.md §7.1 |
| 3 | Matter certification | **Deferred to V3.1** — use Matter SDK in dev, apply for CSA membership post-GA | ADR-007 |
| 4 | Solar inverter brand | **Deferred to V3.2** — not in V3 scope | V3-ROADMAP.md |
| 5 | Telebirr direct vs Chapa | **Chapa for V3 GA** — direct Telebirr in V3.1 if volume justifies | ADR-005 |
| 6 | B2B pricing model | **Per-device/month** — $1 (≤100), $0.80 (≤1000), custom (unlimited) | V3-B2B-WHITELABEL.md §4 |

---

## 7. What changed from V3 draft

All P0 and P1 issues from the technical review are resolved. See `CANONICAL-DECISIONS.md` for the full issue resolution register.

This section documents the improvements made during the documentation finalization:

### 7.1 Critical gaps fixed
- ✅ **V3-HARDWARE.md** — written from scratch (BOM, schematic, PCB, enclosure, manufacturing, certification)
- ✅ **V3-DEVICE-MODEL.md** — new doc adopting RainMaker hierarchy (Node/Device/Service/Param/Attr)
- ✅ **V3-DPIA.md** — Data Protection Impact Assessment (PDPP-required)
- ✅ **V3-UNIT-ECONOMICS.md** — full cost model + margins + CAC/LTV
- ✅ **V3-GO-TO-MARKET.md** — sales strategy + partnerships + distribution
- ✅ **V3-SUPPORT-RMA.md** — warranty + RMA + support tiers
- ✅ **V3-FACTORY-OPS.md** — factory flashing + cert generation workflow

### 7.2 Internal contradictions fixed
- ✅ Role count: 10 (corrected in V3-ARCHITECTURE.md — was "8" in two places)
- ✅ ESP32 chip: ESP32-C3 (R4) + ESP32-S3 (R8/R16) — corrected in V3-SECURITY-MODEL.md (was "ESP32-C3" in security, "WROOM-32" in firmware)
- ✅ Family plan added to V3-B2B-WHITELABEL.md (was in V3-PAYMENTS.md but missing from B2B doc)
- ✅ `/ca` screen removed from V3-ADMIN-WEB-APP.md (was self-contradictory)
- ✅ NPS → "Average satisfaction rating ≥ 8/10" in V3-ROADMAP.md (NPS is -100 to +100, not 0-10)
- ✅ Manufacturing (500 devices) vs adoption (5,000 registered) reconciled in V3-SUCCESS-METRICS.md

### 7.3 Technical errors fixed
- ✅ Matter Border Router topology corrected (V3-VOICE-MATTER.md §3) — no central DC-side Border Router; Matter-over-Wi-Fi per-device
- ✅ Geo-block exceptions documented (Cloudflare whitelists Chapa, FCM, APNs IPs)
- ✅ Secure Boot v2 + Flash Encryption added to V3-SECURITY-MODEL.md §5
- ✅ Anti-rollback eFuses added
- ✅ JTAG/UART disable in production builds documented
- ✅ TimescaleDB compression policy added to V3-DATABASE-DESIGN.md §6
- ✅ CA generation via step-ca (not raw openssl CLI) in V3-CONFIGURATION.md
- ✅ WebSocket auth moved to Sec-WebSocket-Protocol header (not ?token= query param)

### 7.4 ADRs improved
- ✅ All ADRs now include **Alternatives Considered** section
- ✅ ADR-001, 004, 007, 008 rewritten with corrected decisions
- ✅ 4 new ADRs: 011 (RainMaker hierarchy), 012 (ESP32 chip selection), 013 (firmware security), 014 (factory flashing)
- ✅ All ADRs status: Locked (was "Proposed")

### 7.5 Privacy + compliance
- ✅ V3-PRIVACY-COMPLIANCE.md rewritten — honest about subprocessors (Cloudflare, Chapa, FCM, APNs)
- ✅ "No data leaves Ethiopia" claim qualified — push notification tokens transit FCM/APNs (documented in DPIA)
- ✅ Subprocessor inventory added
- ✅ Lawful basis for data processing documented
- ✅ Breach response includes 72-hour ECA notification

---

## 8. References

- V3-README.md — documentation index
- V3-ARCHITECTURE.md — system architecture + data flows
- V3-ROADMAP.md — 12-month phased delivery plan
- V3-SUCCESS-METRICS.md — KPIs + targets
