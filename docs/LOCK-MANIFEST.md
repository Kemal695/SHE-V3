# SHE V3 — Documentation Lock Manifest

**Status:** LOCKED
**Lock date:** 2025-Q1
**Locked by:** Lead Engineer
**Authority:** `CANONICAL-DECISIONS.md` (single source of truth; supersedes all other docs on conflict)

This manifest certifies that **all V3 documentation and ADRs are reviewed, complete, and locked**. Per V3-ROADMAP §2 (Phase 0 — Foundation, weeks 1–4), this is a required Phase 0 exit criterion. No V3 doc may be modified after lock; future changes must go through a new ADR.

---

## 1. V3 documentation set (45 files)

All files live under `docs/v3-docs-final/`. Every file header carries `**Status:** Locked`.

| # | File | Purpose | Status |
|---|---|---|---|
| 1 | `V3-README.md` | Top-level navigation, status legend, what's new in finalization | Locked |
| 2 | `V3-OVERVIEW.md` | Platform vision, tech stack, team allocation, open-question resolutions | Locked |
| 3 | `CANONICAL-DECISIONS.md` | Single source of truth for P0/P1/P2 issue resolutions | Locked |
| 4 | `V3-ROADMAP.md` | 52-week phased delivery plan (Phases 0–5) | Locked |
| 5 | `V3-ARCHITECTURE.md` | System diagram, component overview, data flows, production infra | Locked |
| 6 | `V3-DEVICE-MODEL.md` | RainMaker hierarchy (Node/Device/Service/Param/Attr) | Locked |
| 7 | `V3-DATABASE-DESIGN.md` | Schema (V1–V28), RLS policies, hypertables, indexes | Locked |
| 8 | `V3-API-SPECIFICATION.md` | REST + WebSocket + Internal endpoint catalog | Locked |
| 9 | `V3-MQTT-STANDARDS.md` | Topic namespace `she/{tenant}/{home}/{room}/{mac}/{direction}`, QoS, ACL | Locked |
| 10 | `V3-SECURITY-MODEL.md` | JWT (EdDSA), 10-role RBAC, X.509, Secure Boot v2, threat model | Locked |
| 11 | `V3-CONFIGURATION.md` | Env var catalog, step-ca setup, secret generation, rotation schedule | Locked |
| 12 | `V3-HARDWARE.md` | Custom ESP32 relay controller (SHE-R4/R8/R16), BOM, schematic | Locked |
| 13 | `V3-FIRMWARE.md` | ESP-IDF firmware: RainMaker hierarchy, FreeRTOS tasks, OTA, voice | Locked |
| 14 | `V3-FACTORY-OPS.md` | Factory flashing workflow, cert generation, QC, packaging | Locked |
| 15 | `V3-MOBILE-APP.md` | Flutter app: dark-mode Bento UI, BLE provisioning, offline cache | Locked |
| 16 | `V3-ADMIN-PLATFORM.md` | Platform admin roles, admin API endpoints, impersonation | Locked |
| 17 | `V3-ADMIN-WEB-APP.md` | Next.js admin console (9 screens) | Locked |
| 18 | `V3-DESIGN-SYSTEM.md` | Brand colors, typography, Bento grid, micro-interactions | Locked |
| 19 | `V3-B2B-WHITELABEL.md` | Multi-tenant architecture, white-label branding, B2B pricing | Locked |
| 20 | `V3-ENERGY-MONITORING.md` | PZEM sensor, TimescaleDB, ETB tariff, anomaly detection | Locked |
| 21 | `V3-VOICE-MATTER.md` | Picovoice offline voice, Matter-over-Wi-Fi (V3.1) | Locked |
| 22 | `V3-PAYMENTS.md` | Telebirr via Chapa, B2B billing, B2C freemium + family | Locked |
| 23 | `V3-I18N.md` | Amharic first UI, Ethiopian calendar, cultural adaptations | Locked |
| 24 | `V3-UNIT-ECONOMICS.md` | BOM cost, manufacturing, shipping, CAC, LTV, payback | Locked |
| 25 | `V3-GO-TO-MARKET.md` | Sales strategy, partnerships, distribution channels | Locked |
| 26 | `V3-SUPPORT-RMA.md` | Warranty, RMA process, support tiers, SLA | Locked |
| 27 | `V3-OPS-RUNBOOK.md` | Deploy, monitor, on-call diagnostics, incident response | Locked |
| 28 | `V3-PRIVACY-COMPLIANCE.md` | Ethiopia PDPP, PII inventory, subprocessors, breach response | Locked |
| 29 | `V3-DPIA.md` | Data Protection Impact Assessment (cross-border transfer analysis) | Locked |
| 30 | `V3-DEVELOPER-SETUP.md` | Engineer onboarding: prerequisites, build/run, workflows | Locked |
| 31 | `V3-ERROR-CODES.md` | Error code catalog (~100 codes) with HTTP status + debugging | Locked |
| 32 | `V3-INTEGRATION-TEST-PLAN.md` | Test strategy, load test, chaos test, device testing | Locked |
| 33 | `V3-SUCCESS-METRICS.md` | KPIs: reliability, performance, adoption, security | Locked |

**Total:** 33 root docs (V3-README + 32 V3-* docs; `CANONICAL-DECISIONS.md` is the 34th root-level file).

## 2. Architecture Decision Records (14 ADRs)

All ADRs live under `docs/v3-docs-final/V3-ADR/`. Every ADR contains the required sections: `## Context`, `## Decision`, `## Alternatives Considered`, `## Consequences`. Every ADR header carries `**Status:** Locked`.

| ADR | File | Decision | Date | Status |
|---|---|---|---|---|
| 001 | `001-day1-self-hosted.md` | Fully self-hosted device cloud (no third-party IoT cloud) | 2024-Q4 | Locked |
| 002 | `002-custom-hardware.md` | Build own ESP32 relay controller with feedback circuit | 2024-Q4 | Locked |
| 003 | `003-multi-tenant-rls.md` | Multi-tenant isolation via Postgres Row-Level Security | 2024-Q4 | Locked |
| 004 | `004-cert-based-mqtt-auth.md` | X.509 client certs (own CA) for device authentication | 2024-Q4 | Locked |
| 005 | `005-telebirr-via-chapa.md` | Chapa payment aggregator for Telebirr/CBE Birr | 2024-Q4 | Locked |
| 006 | `006-picovoice-offline-voice.md` | Offline voice via Picovoice (no cloud dependency) | 2024-Q4 | Locked |
| 007 | `007-matter-over-wifi.md` | Matter-over-Wi-Fi per-device (no central Border Router) | 2024-Q4 | Locked |
| 008 | `008-addis-ababa-hosting.md` | Host in Addis Ababa data center (Ethio Telecom Cloud) | 2024-Q4 | Locked |
| 009 | `009-bento-dark-mode.md` | Dark-mode first, Bento grid dashboard design | 2024-Q4 | Locked |
| 010 | `010-ethiopia-only-scope.md` | Target Ethiopia exclusively for V3 | 2024-Q4 | Locked |
| 011 | `011-rainmaker-hierarchy.md` | Adopt RainMaker Node/Device/Service/Param/Attr data model | 2024-Q4 | Locked |
| 012 | `012-esp32-chip-selection.md` | ESP32-C3 for R4, ESP32-S3 for R8/R16 | 2024-Q4 | Locked |
| 013 | `013-firmware-security.md` | Secure Boot v2 + Flash Encryption + anti-rollback eFuses | 2025-Q1 | Locked |
| 014 | `014-factory-flashing.md` | Pre-flash certs at factory via own CA + Admin CLI | 2025-Q1 | Locked |

## 3. Canonical decision references for Phase 0

The following canonical decisions from `CANONICAL-DECISIONS.md` directly govern Phase 0 implementation. Every line of code in this repository must respect them; any deviation is a defect.

| ID | Topic | Decision |
|---|---|---|
| P0-1 | Device private key | ESP32 generates ECDSA P-256 keypair on-chip via mbedTLS; private key never leaves device. Factory workstation NEVER sees private key. BLE provisioning does NOT issue certs. |
| P0-2 | Device cert type | Root CA: RSA 4096-bit, 20 yr. Intermediate CA: RSA 4096-bit, 10 yr. Device cert: ECDSA P-256, 5 yr. |
| P0-3 | eFuse burn sequence (S3) | BLOCK_KEY0=Secure Boot digest, BLOCK_KEY1=Flash Enc HMAC, BLOCK_KEY2=Ed25519 OTA pubkey, SECURE_VERSION=0x01, then DIS_PAD_JTAG, DIS_DOWNLOAD_JTAG, DIS_DOWNLOAD_MODE, SECURE_BOOT_EN, FLASH_ENCRYPTION. |
| P0-4 | Anti-rollback math | `SECURE_VERSION` 32-bit field with popcount semantics. Max 32 versions. Burn 1 bit per major security release. |
| P0-5 | RLS bypass mechanism | Custom GUC `app.is_platform_admin` checked by RLS policy itself. NOT `BYPASSRLS` role. `she_app` Postgres role does NOT have `BYPASSRLS`. |
| P1-3 | BLE provisioning endpoint | `POST /api/v3/nodes/claim` (NOT `/devices/claim`). |
| P1-4 | WebSocket | Path `/ws/v3`, subprotocol `bearer.<jwt>` (dot separator). |
| P1-6 | JWT algorithm | EdDSA (Ed25519) with `kid` header for multi-key rotation. Replaces HS256/`JWT_SECRET`. |
| P1-10 | Backend MQTT superuser | Removed. Spring Boot uses client cert + explicit ACL — no blanket bypass, no `is_superuser=true`. |
| P1-11 | EMQX auth cache TTL | 300s (5 min, not default 60s). |
| P1-13 | LWT payload | JSON `{"status":"offline"}` (NOT plain string). |
| P1-19 | Audit log | TimescaleDB hypertable (NOT pg_partman). 30d raw + 2yr compressed + 7yr CSV archive. Hash chain (`hash`+`prev_hash`). |
| P1-20 | Energy table | `device_energy_readings`. Power column = `power_w`. Time column = `time`. |
| P1-21 | Energy retention | 365 days. |
| P1-22 | CRL refresh | Every 6 hours. Revocation SLA < 6 hours. |
| P1-23 | Root CA | RSA 4096-bit, 20 years (NOT 25). |
| P1-24 | Intermediate CA | HSM-backed (YubiHSM 2) in production. NOT merely KEK-encrypted. |
| P1-25 | Java version | 21 LTS (NOT 17). |
| P1-29 | Alerting | PagerDuty (NOT Telegram). |
| P1-31 | Office VPN CF rule | Public NAT egress IP `197.156.78.42/32` (NOT private `10.88.0.0/16`). |
| P1-32 | EMQX authorization config | HOCON `authorization { sources = [...] }` via `EMQX_AUTHORIZATION__SOURCES` JSON env var. NOT flattened 4.x-style env vars. |

## 4. Phase 0 exit criteria mapping

| Exit criterion | Source | Implementation artifact |
|---|---|---|
| EMQX cluster running with cert-based mTLS auth — `openssl s_client -connect she.et:8883` succeeds with device cert | V3-ROADMAP §2 | `infra/emqx/` (cluster config + ACL), `infra/ca/bootstrap-ca.sh` (device cert issuance) |
| CA operational — can issue + revoke device certs via step-ca; CRL endpoint serves | V3-ROADMAP §2 | `infra/ca/bootstrap-ca.sh`, `infra/ca/revoke-device.sh`, `infra/ca/serve-crl.nginx.conf`, `backend/src/main/java/et/she/v3/ca/StepCaClient.java` |
| Spring Boot MVP deployed to staging — `/actuator/health` returns UP | V3-ROADMAP §2 | `backend/` (full Spring Boot app), `backend/Dockerfile`, `.github/workflows/ci.yml` |
| CI/CD pipeline builds + deploys backend automatically on merge | V3-ROADMAP §2 | `.github/workflows/ci.yml` (build → test → Docker build → push → deploy on `main`) |
| All V3 docs + ADRs locked | V3-ROADMAP §2 | This manifest (you are reading it) |

## 5. Documentation governance

After this lock:

- **No V3 doc may be edited.** To change a decision, write a new ADR (ADR-015+) that supersedes the prior one, and update `CANONICAL-DECISIONS.md` with a new P-numbered entry pointing to the new ADR.
- **Migration files are forward-only.** A Flyway migration, once merged to `main`, may not be edited — write a new migration that reverses the change.
- **Error codes are part of the public API contract.** Once shipped, an error code cannot be renamed — only deprecated with a 12-month sunset per `V3-ERROR-CODES.md §12.1`.
- **Schema names, env var names, and topic namespace segments are part of the public API contract.** Renames require a new ADR.

---

**Lock signature:** Lead Engineer, SHE V3 — 2025-Q1
