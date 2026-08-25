# Smart Home Ethiopia (SHE) — V3 Documentation

**Production-ready, fully independent IoT platform for the Ethiopian market.**

V3 is a complete smart home platform: custom ESP32 relay hardware (SHE-R4/R8/R16), self-hosted device cloud (EMQX + own CA + Spring Boot + Postgres + TimescaleDB + MinIO), premium dark-mode mobile app, B2B white-label multi-tenancy via Postgres RLS, energy monitoring in ETB, offline voice control via Picovoice, and Telebirr mobile money payments via Chapa.

The device data model adopts the ESP RainMaker hierarchy (Node → Device → Service → Parameter → Attribute) as a conceptual framework. **No dependency on RainMaker cloud or any third-party IoT platform.**

## Quick navigation

### Start here
| File | Purpose |
|---|---|
| `V3-OVERVIEW.md` | Platform vision, architecture summary, team allocation, what changed |
| `CANONICAL-DECISIONS.md` | Single source of truth for all P0/P1 issue resolutions — every other doc must cite this |
| `V3-DEVICE-MODEL.md` | RainMaker hierarchy adoption (Node/Device/Service/Param/Attr) — **start here** |
| `V3-ROADMAP.md` | 12-month phased delivery plan |

### Architecture + infrastructure
| File | Purpose |
|---|---|
| `V3-ARCHITECTURE.md` | System diagram, component overview, data flows, production infra |
| `V3-DATABASE-DESIGN.md` | Schema: nodes, node_devices, node_params, multi-tenant RLS, energy, payments, audit |
| `V3-API-SPECIFICATION.md` | All REST endpoints + WebSocket events |
| `V3-MQTT-STANDARDS.md` | Topic namespace `she/{tenant}/{home}/{room}/{mac}/{direction}`, QoS, ACL |
| `V3-SECURITY-MODEL.md` | JWT + RBAC (10 roles), X.509 certs, Secure Boot v2, Flash Encryption, threat model |
| `V3-CONFIGURATION.md` | Env var catalog, secret generation (step-ca, not openssl), rotation schedule |

### Hardware + firmware
| File | Purpose |
|---|---|
| `V3-HARDWARE.md` | Custom ESP32 relay controller (SHE-R4/R8/R16), BOM, schematic, PCB, enclosure, manufacturing |
| `V3-FIRMWARE.md` | ESP-IDF firmware: RainMaker hierarchy, FreeRTOS tasks, OTA, local control, voice |
| `V3-FACTORY-OPS.md` | Factory flashing workflow: cert generation, QC, packaging, shipping |

### Client applications
| File | Purpose |
|---|---|
| `V3-MOBILE-APP.md` | Flutter app: dark-mode Bento UI, BLE provisioning, offline cache |
| `V3-ADMIN-PLATFORM.md` | Platform admin roles, admin API endpoints, impersonation |
| `V3-ADMIN-WEB-APP.md` | Next.js admin console — 9 screens (reduced from 16) |
| `V3-DESIGN-SYSTEM.md` | Brand colors, typography, Bento grid, micro-interactions |

### Business features
| File | Purpose |
|---|---|
| `V3-B2B-WHITELABEL.md` | Multi-tenant architecture, white-label branding, B2B pricing (incl. family plan) |
| `V3-ENERGY-MONITORING.md` | PZEM sensor, TimescaleDB, ETB tariff, anomaly detection |
| `V3-VOICE-MATTER.md` | Picovoice offline voice, Matter-over-Wi-Fi (V3.1) |
| `V3-PAYMENTS.md` | Telebirr via Chapa, B2B billing, B2C freemium + family |
| `V3-I18N.md` | Amharic first UI, Ethiopian calendar, cultural adaptations |
| `V3-UNIT-ECONOMICS.md` | BOM cost, manufacturing, shipping, CAC, LTV, payback |
| `V3-GO-TO-MARKET.md` | Sales strategy, partnerships, distribution channels |
| `V3-SUPPORT-RMA.md` | Warranty, RMA process, support tiers, SLA |

### Operations + compliance
| File | Purpose |
|---|---|
| `V3-OPS-RUNBOOK.md` | Deploy, monitor, on-call diagnostics, incident response |
| `V3-PRIVACY-COMPLIANCE.md` | Ethiopia PDPP, PII inventory, subprocessors, breach response |
| `V3-DPIA.md` | Data Protection Impact Assessment (cross-border transfer analysis) |
| `V3-DEVELOPER-SETUP.md` | Engineer onboarding: prerequisites, build/run, workflows |
| `V3-ERROR-CODES.md` | Error code catalog (~100 codes) with HTTP status + debugging |
| `V3-INTEGRATION-TEST-PLAN.md` | Test strategy, load test, chaos test, device testing |
| `V3-SUCCESS-METRICS.md` | KPIs: reliability, performance, adoption, security |

### Architecture Decision Records
| ADR | Decision | Status |
|---|---|---|
| `001-day1-self-hosted.md` | Fully self-hosted device cloud (no third-party IoT cloud) | Locked |
| `002-custom-hardware.md` | Build own ESP32 relay controller with feedback circuit | Locked |
| `003-multi-tenant-rls.md` | Shared DB + Postgres Row-Level Security | Locked |
| `004-cert-based-mqtt-auth.md` | X.509 client certs (own CA) for device authentication | Locked |
| `005-telebirr-via-chapa.md` | Chapa payment aggregator for Telebirr/CBE Birr | Locked |
| `006-picovoice-offline-voice.md` | Offline voice via Picovoice (no cloud dependency) | Locked |
| `007-matter-over-wifi.md` | Matter-over-Wi-Fi per-device (no central Border Router) | Locked |
| `008-addis-ababa-hosting.md` | Host in Addis Ababa data center (Ethio Telecom Cloud) | Locked |
| `009-bento-dark-mode.md` | Dark-mode first, Bento grid dashboard design | Locked |
| `010-ethiopia-only-scope.md` | Target Ethiopia exclusively for V3 | Locked |
| `011-rainmaker-hierarchy.md` | Adopt RainMaker Node/Device/Service/Param/Attr data model | Locked |
| `012-esp32-chip-selection.md` | ESP32-C3 for R4, ESP32-S3 for R8/R16 | Locked |
| `013-firmware-security.md` | Secure Boot v2 + Flash Encryption + anti-rollback eFuses | Locked |
| `014-factory-flashing.md` | Pre-flash certs at factory via own CA + Admin CLI | Locked |

## Status legend

- **Locked** — design is final; implementation can proceed
- **Proposed** — design is sketched; needs team review before lock
- **Deferred** — out of V3 scope, listed for visibility

All V3 docs are **Locked**.

## What's new in this finalization

This documentation set addresses all gaps identified in the V3 review:

1. **V3-HARDWARE.md** — written from scratch (was completely missing)
2. **V3-DEVICE-MODEL.md** — new doc adopting RainMaker hierarchy
3. **6 new business/compliance docs** — Unit Economics, Go-to-Market, Support/RMA, DPIA, Factory Ops
4. **All internal contradictions fixed** — role count, chip selection, Matter topology, NPS metric, manufacturing vs adoption
5. **All technical errors fixed** — Secure Boot v2, Flash Encryption, TimescaleDB compression, step-ca for CA generation, WebSocket auth
6. **4 new ADRs** — RainMaker hierarchy, chip selection, firmware security, factory flashing
7. **All ADRs include Alternatives Considered** section
8. **Privacy + DPIA** — honest subprocessor inventory, lawful basis for data processing

**Previous rating:** 5.5/10 (initial review)

**Documentation status:** Locked. See `CANONICAL-DECISIONS.md` for issue resolutions.
