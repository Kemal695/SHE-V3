# V3 — Roadmap (52-Week Production-Ready Plan)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer

---

## 0. Scope

A 52-week (12-month) phased plan that takes SHE V3 from "docs locked" to General Availability. Each phase has a clear theme, named deliverables, and exit criteria. Two corrections from the original V3 draft are reflected here:

1. **NPS metric fixed** — Phase 5C exit criterion was "NPS ≥ 8/10". NPS is a -100 to +100 score, not 0-10. The corrected criterion is "Average satisfaction rating ≥ 8/10" (a 0-10 satisfaction rating, the standard beta feedback instrument).
2. **Adoption vs manufacturing reconciled** — original targets were "500 manufactured by GA" and "5,000 registered in 12 months", which is impossible (you cannot register 5,000 devices if only 500 are made). The corrected targets: 500 manufactured + 100 deployed (beta) by GA (month 12); 5,000 registered is the **month 24** target (12 months post-GA). See V3-SUCCESS-METRICS.md.

---

## 1. Phasing overview

| Phase | Weeks | Theme | Exit criteria (summary) |
|---|---|---|---|
| **0** | 1-4 | Foundation | EMQX cluster running; CA operational; CI/CD pipeline; V3 docs locked |
| **1** | 5-12 | Device integration | BLE provisioning; self-hosted OTA; local control; energy ingest; cert-based MQTT auth |
| **2** | 13-24 | Custom hardware | PCB fab; 50-unit pilot; factory partner selected; factory flashing workflow |
| **3** | 25-32 | B2B multi-tenant + payments | RLS policies; white-label branding; Chapa integration live; first B2B tenant onboarded |
| **4** | 33-40 | Premium UX + energy + voice + Amharic | Dark-mode Bento UI shipped; energy dashboard; Picovoice on R16; Amharic 100% |
| **5** | 41-52 | Hardening + certification + GA | CE/FCC/ECA certified; pentest passed; 100-device beta; GA launch |

**Critical path:** Phase 0 → Phase 1 → Phase 2 (parallel with 3) → Phase 4 → Phase 5

**Team:** 2-3 engineers (Lead + Backend) full-time; 1 firmware contractor months 4-9; 1 mobile/frontend engineer months 7-12.

---

## 2. Phase 0 — Foundation (weeks 1-4)

| Stream | Owner | Deliverables |
|---|---|---|
| Self-hosted MQTT | Backend | EMQX cluster (3 nodes on Ethio Telecom Cloud); cert-based mTLS auth (own CA); shared subscriptions; topic ACL via HTTP backend |
| Certificate authority | Lead | step-ca root CA + intermediate CA; cert issuance API; CRL endpoint; key backup to encrypted offline store |
| Spring Boot MVP | Backend | Skeleton app: health endpoint, Flyway, Postgres pool, JWT auth, one CRUD endpoint (users), test framework |
| CI/CD pipeline | Backend | GitHub Actions: build → test → deploy to staging; auto-deploy on merge to main |
| Documentation lock | Lead | All V3 docs reviewed + locked; ADRs 001-014 written |

### Exit criteria
- [ ] EMQX cluster running with cert-based mTLS auth — `openssl s_client -connect she.et:8883` succeeds with device cert
- [ ] CA operational — can issue + revoke device certs via step-ca; CRL endpoint serves
- [ ] Spring Boot MVP deployed to staging — `/actuator/health` returns UP
- [ ] CI/CD pipeline builds + deploys backend automatically on merge
- [ ] All V3 docs + ADRs locked

---

## 3. Phase 1 — Device integration (weeks 5-12)

### 1A: BLE provisioning (firmware + mobile)
| Step | Deliverable |
|---|---|
| 1 | Firmware: BLE provisioning manager (`wifi_prov_scheme_ble` + custom claim flow) |
| 2 | Spring Boot claim endpoint `POST /api/v3/nodes/claim` — issues X.509 cert via step-ca |
| 3 | Flutter app BLE integration (flutter_blue_plus, mDNS discovery) |
| 4 | End-to-end: provision device via Flutter app → cert issued → MQTT connects → device appears in app |

### 1B: Self-hosted OTA (backend + firmware)
| Step | Deliverable |
|---|---|
| 1 | MinIO bucket setup for firmware image storage |
| 2 | Ed25519 signing infrastructure (CI/CD signs firmware at build time) |
| 3 | Spring Boot `OtaService` (batch create, rollout %, status tracking) |
| 4 | Firmware OTA handler (download from MinIO, verify Ed25519 signature, partition swap, anti-rollback via eFuse, automatic rollback on health-check failure) |
| 5 | End-to-end: push OTA from admin web → device updates + reboots → telemetry resumes |

### 1C: Local control (firmware + mobile)
| Step | Deliverable |
|---|---|
| 1 | ESP32 mDNS service advertisement (`_she._tcp.local`) |
| 2 | ESP32 HTTPS server (esp_https_server + self-signed cert per device) |
| 3 | Security handshake (PoP = factory-generated 9-digit CSPRNG number read from `fctry` NVS, constant-time compare) |
| 4 | Flutter app mDNS discovery + local control fallback when internet is down |
| 5 | End-to-end: disconnect internet → control device via LAN within 500 ms |

### 1D: Telemetry + timeseries (backend + firmware)
| Step | Deliverable |
|---|---|
| 1 | Firmware: PZEM-004T driver, telemetry JSON publish every 5 s on `she/.../params/local` |
| 2 | Spring Boot `TelemetryService` ingests MQTT → TimescaleDB hypertable |
| 3 | Time series query API (aggregate, bucket, retention policy) |
| 4 | Flutter app time series chart (fl_chart) |

### Exit criteria
- [ ] Device provisions via Flutter app (no third-party cloud in the loop)
- [ ] OTA updates work end-to-end (admin → device, signed + verified)
- [ ] Local control works on same Wi-Fi when internet is down
- [ ] Telemetry charts display in mobile app (real-time + 24 h history)
- [ ] Cert-based MQTT auth enforced (no anonymous connections)

---

## 4. Phase 2 — Custom hardware + firmware (weeks 13-24)

### 2A: Hardware design (Lead + PCB designer)
| Step | Deliverable | Timeline |
|---|---|---|
| 1 | Schematic design (Altium) — SHE-R4, SHE-R8, SHE-R16 | Week 13-14 |
| 2 | PCB layout (4-layer, ENIG finish, antenna keepout) | Week 15-16 |
| 3 | Order prototypes from JLCPCB fab + LCSC parts | Week 17 |
| 4 | Assembly + bring-up testing (smoke test, Wi-Fi, relay toggle) | Week 18-19 |
| 5 | Feedback circuit verification (manual override detection, relay weld detection) | Week 20 |
| 6 | Pre-production PCB revision (rev-c) | Week 21-22 |
| 7 | Enclosure design (FreeCAD → 3D print → injection mold tooling) | Week 23-24 |

### 2B: Firmware (firmware contractor)
| Step | Deliverable |
|---|---|
| 1 | Self-hosted MQTT client (cert-based mTLS, no third-party SDK) |
| 2 | PCF8574 GPIO expander driver (1 chip for R4/R8, 2 chips for R16) |
| 3 | Feedback circuit driver (CD4051 mux + ADC poll every 500 ms) |
| 4 | Digital input driver (wall switch detection) |
| 5 | Energy monitor driver (PZEM-004T v3, Modbus RTU) |
| 6 | Multi-device profile support (R4/R8/R16 — auto-detect at boot via GPIO strapping) |
| 7 | RainMaker hierarchy self-description (Node → Devices → Services → Params published on `config` topic at connect) |

### 2C: Manufacturing setup (Lead)
| Step | Deliverable |
|---|---|
| 1 | Factory partner selection (Shenzhen — JLCPCB fab + assembly partner) |
| 2 | BOM finalization + supplier agreements (long-lead parts: ESP32-S3, PZEM-004T) |
| 3 | QC test procedure documented (V3-HARDWARE.md §7.3) |
| 4 | Factory flashing workflow (V3-FACTORY-OPS.md) — test jig, cert issuance, provisioning QR print |
| 5 | First 50-unit pilot run (week 24) |

### Exit criteria
- [ ] 50 prototype boards assembled + tested (all pass §7.3 QC)
- [ ] Firmware runs on custom hardware (all features: relay, feedback, energy, OTA, BLE provisioning)
- [ ] Feedback circuit detects manual override + relay failures
- [ ] Factory partner selected + pilot run completed
- [ ] Factory flashing workflow documented + tested on pilot batch

---

## 5. Phase 3 — B2B multi-tenant + payments (weeks 25-32)

### 3A: Multi-tenant architecture (backend)
| Step | Deliverable |
|---|---|
| 1 | `tenants` table + `tenant_id` column on all tenant-scoped tables |
| 2 | Postgres Row-Level Security (RLS) policies — `USING (tenant_id = current_setting('app.tenant_id')::uuid)` |
| 3 | Spring Boot `TenantContextFilter` — sets `app.tenant_id` session var on every request from JWT claim |
| 4 | Tenant management admin endpoints (CRUD + branding config) — V3-ADMIN-PLATFORM.md §3.1 |
| 5 | White-label branding (Flutter app reads tenant config from `GET /api/v3/tenant/branding`) |

### 3B: Telebirr via Chapa (backend + mobile)
| Step | Deliverable |
|---|---|
| 1 | Chapa aggregator integration: `initiate payment`, `webhook handler` (signature verify), `verify` |
| 2 | Subscription model: B2C (Free / Premium 150 ETB / Family 300 ETB), B2B ($100 / $800 / $2000+ monthly) |
| 3 | Invoice generation + email (monthly for B2B, on-demand for B2C upgrades) |
| 4 | Flutter app payment screen (Chapa checkout via in-app browser) |
| 5 | B2B billing: per-device monthly, auto-invoice, suspension on non-payment after 7-day grace |

### 3C: Admin portal enhancements (admin web)
| Step | Deliverable |
|---|---|
| 1 | Platform-level admin (`admin.she.et`) — all tenants view (9 screens per V3-ADMIN-WEB-APP.md) |
| 2 | Tenant-level admin (`{tenant}.she.et/admin`) — tenant-scoped user/device/billing |
| 3 | Billing dashboard (invoices, payments, MRR chart) |
| 4 | API key management for B2B integrations |

### Exit criteria
- [ ] First B2B tenant onboarded (white-label branded app + subdomain)
- [ ] Telebirr payment works end-to-end (subscribe via app → Chapa webhook → subscription activated)
- [ ] Multi-tenant isolation verified (tenant A cannot read tenant B's data — verified by SQL test)
- [ ] B2B invoice generated + paid
- [ ] RLS test suite passes 100% (automated test that attempts cross-tenant queries returns 0 rows)

---

## 6. Phase 4 — Premium UX + energy + voice + Amharic (weeks 33-40)

### 4A: Premium dark-mode UI (mobile)
| Step | Deliverable |
|---|---|
| 1 | V3 design tokens (Deep Navy `#0B1D37`, Bright Sky Blue `#56B4FA`, NO indigo/blue-purple) |
| 2 | Bento grid dashboard with active-glow drop-shadows on ON devices |
| 3 | Haptic sliders (circular drag for dimmers/thermostats — `HapticFeedback.selectionClick()`) |
| 4 | Micro-interactions (toggle glow, lock animation, fan spin) |
| 5 | Scenes row (horizontal scrolling) + scene-builder UI |
| 6 | Empty state illustrations + onboarding screens |

### 4B: Energy monitoring (backend + mobile + firmware)
| Step | Deliverable |
|---|---|
| 1 | PZEM-004T firmware driver (already in Phase 2B; here we add `esp.param.power_consumption` to node config) |
| 2 | Spring Boot `EnergyService` (TimescaleDB ingest, aggregation, ETB block-tariff cost calc — V3-ENERGY-MONITORING.md §3) |
| 3 | Energy dashboard (real-time gauge + 7/14/30-day historical chart, kWh + ETB dual axis) |
| 4 | Anomaly detection (3× power spike vs 7-day baseline → push notification) |
| 5 | B2B aggregate energy reports (per-tenant summary, CSV export) |

### 4C: Voice control (firmware + backend)
| Step | Deliverable |
|---|---|
| 1 | Picovoice SDK integration on ESP32-S3 (Porcupine + Rhino, R16 only) |
| 2 | Custom wake word "Hey Sheba" (Picovoice Console-trained model baked into firmware) |
| 3 | Intent model (`SmartHome_Ethiopian` context, ~25 Amharic + English intents — V3-VOICE-MATTER.md §1.4) |
| 4 | Voice service exposed as `esp.service.voice` in RainMaker hierarchy |
| 5 | (V3.1 placeholder) Alexa Skill + Google Home Action — scaffolding only in V3 |

### 4D: Amharic i18n (mobile + backend)
| Step | Deliverable |
|---|---|
| 1 | ARB files (`app_en.arb` + `app_am.arb`) — 100% string coverage |
| 2 | Noto Sans Ethiopic font integration (line-height 1.6, 30% wider buttons) |
| 3 | Ethiopian calendar (13 months, 7-8 years behind Gregorian) + date/time formatting |
| 4 | Cultural adaptations (full-name field not first/last, phone regex `^(\+251\|0)?9\d{8}$`, ETB currency `ብር`) |

### Exit criteria
- [ ] Dark-mode Bento UI shipped + feels premium (internal review ≥ 8/10)
- [ ] Energy monitoring shows real-time + historical data in ETB (PZEM accuracy ±1%)
- [ ] Voice control works offline ("Hey Sheba, turn on the light" → relay toggles in < 1 s)
- [ ] Full Amharic UI (100% strings translated + reviewed by native speaker)

---

## 7. Phase 5 — Hardening + certification + GA (weeks 41-52)

### 5A: Certification (Lead)
| Step | Deliverable | Timeline |
|---|---|---|
| 1 | CE pre-compliance testing (TÜV SÜD Shenzhen — EMC + safety) | Week 41-42 |
| 2 | FCC testing (Element Materials Technology Shenzhen — Part 15B/C) | Week 43-44 |
| 3 | ECA type approval submission (Ethiopian Communications Authority — 8-12 wk review) | Week 45-48 |
| 4 | (V3.1) Matter SDK integration on R8 — not blocking GA | Week 45-48 |
| 5 | (V3.1) CSA membership application + R8 certification | Week 49-52 |

### 5B: Security audit (backend + infra)
| Step | Deliverable |
|---|---|
| 1 | External penetration test (3rd-party firm — selected Week 41) |
| 2 | OWASP Top 10 review (ZAP scan + manual review of all endpoints) |
| 3 | Firmware security review (Secure Boot v2, Flash Encryption, NVS encryption, JTAG/UART disable, anti-rollback eFuses) |
| 4 | Privacy compliance review (PDPP — V3-PRIVACY-COMPLIANCE.md + V3-DPIA.md) |
| 5 | Remediation of findings (track to closure before GA) |

### 5C: Beta program (all teams)
| Step | Deliverable |
|---|---|
| 1 | Recruit 10 beta users (5 B2C + 5 B2B tenants) |
| 2 | Deploy 100 devices to beta sites (Addis Ababa + secondary cities) |
| 3 | Weekly feedback collection + bug triage (Friday review) |
| 4 | Iterate on UX + stability (2-week sprint cadence) |
| 5 | **Exit criterion: Average satisfaction rating ≥ 8/10** (0-10 satisfaction rating collected via in-app survey at week 52) |

> **Metric correction:** The original V3 draft used "NPS ≥ 8/10". NPS (Net Promoter Score) is calculated as `% promoters - % detractors` and ranges from -100 to +100 — it is never a 0-10 score. The corrected metric is "Average satisfaction rating ≥ 8/10" — a 0-10 rating collected via a post-beta in-app survey ("How satisfied are you with your SHE system? 0=very dissatisfied, 10=very satisfied"). This is the standard beta feedback instrument and is unambiguous. NPS will be measured separately post-GA (target: NPS ≥ +30 by month 18).

### 5D: Production deployment (ops)
| Step | Deliverable |
|---|---|
| 1 | Ethio Telecom Cloud provisioning (5 VPS — Spring Boot ×2, EMQX ×3, plus Postgres + Redis + MinIO on dedicated hosts) |
| 2 | Cloudflare setup (DDoS + WAF + SSL termination, geo-block with Chapa/FCM/APNs whitelists) |
| 3 | Monitoring + alerting (Prometheus + Grafana + Loki + PagerDuty — V3-OPS-RUNBOOK.md §3) |
| 4 | Backup + disaster recovery tested (Postgres WAL archiving + MinIO versioning + cert backup) |
| 5 | Runbook dry-run passed (simulate SEV-1, SEV-2, SEV-3 with on-call rotation) |

### Exit criteria (V3 GA)
- [ ] CE + FCC + ECA certification received (or ECA submission acknowledged with letter of no-objection)
- [ ] Security audit: 0 critical, ≤ 3 high findings with documented remediation plan
- [ ] Beta program: 100 devices deployed, average satisfaction ≥ 8/10
- [ ] Production infrastructure running in Addis Ababa (Ethio Telecom Cloud)
- [ ] All V3 docs locked
- [ ] **500 production devices manufactured** (at factory partner, ready to ship) — see V3-SUCCESS-METRICS.md §3 for adoption-vs-manufacturing reconciliation

---

## 8. Critical path + lead-time risks

```
Phase 0 (4 wk) ──► Phase 1 (8 wk) ──► Phase 2 (12 wk) ──┬──► Phase 4 (8 wk) ──► Phase 5 (12 wk) ──► GA
                                                          │
                                                          └──► Phase 3 (8 wk) ──┘
```

**Longest lead-time items** (start early):
1. **Hardware design + manufacturing** (12 weeks for PCB fab + assembly + shipping from Shenzhen) — starts Phase 2 week 13
2. **Certification** (8-12 weeks for ECA alone) — starts Phase 5 week 41 (submission week 45)
3. **Chapa integration** (4 weeks for application + sandbox testing) — starts Phase 3 week 25
4. **Picovoice wake-word training** (4 weeks for Picovoice Console custom-model service) — starts Phase 4 week 33

---

## 9. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Hardware prototype fails EMC testing | Medium | High | Pre-compliance test at Week 20; design with EMC keepout from start |
| BLE provisioning unreliable on some phones | Medium | Medium | Test 10+ Android + iOS devices; fallback to SoftAP provisioning |
| Chapa API access denied or delayed | Medium | High | Start application Week 25; have bank-transfer fallback for B2B |
| Factory partner delays | Medium | High | Have 2 backup partners; order 50% extra long-lead parts (ESP32-S3, PZEM-004T) |
| Picovoice wake-word accuracy in noisy environments | Medium | Medium | Train on Ethiopian accents; sensitivity slider in app |
| Matter certification takes > 12 weeks | Low | Medium | V3.1 (post-GA) — does not block GA; ship without Matter logo if delayed |
| Ethio Telecom Cloud outage | Low | Critical | Multi-AZ where available; daily backups to secondary DC; documented in V3-OPS-RUNBOOK.md |
| Key team member leaves | Low | High | Cross-training; documentation; contractor backup (firmware, mobile) |
| Adoption shortfall vs manufacturing ramp | Medium | Medium | 500 manufactured by GA is conservative; if adoption lags, slow manufacturing in V3.1 |

---

## 10. Post-GA roadmap (V3.1, V3.2 — not in scope for V3 GA)

| Target | Theme | Items |
|---|---|---|
| Month 18 (V3.1) | Cloud voice + Matter | Alexa Skill + Google Home Action; Matter-over-Wi-Fi on R8; CSA membership |
| Month 18 (V3.1) | Adoption milestone | 2,000 manufactured, 1,000 registered, 500 paying B2C, 5 B2B tenants |
| Month 24 (V3.2) | Direct Telebirr + Thread | Direct Telebirr API (drop Chapa if volume justifies); Thread research SKU (rev-d, ESP32-H2) |
| Month 24 (V3.2) | Adoption milestone | 5,000 registered devices, 1,000 paying B2C, 10 B2B tenants |

---

## 11. References

- V3-OVERVIEW.md §6 — Phase 0 open questions resolved
- V3-SUCCESS-METRICS.md §3 — adoption vs manufacturing reconciliation (500 by GA, 5,000 by month 24)
- V3-HARDWARE.md §7.1 + §7.3 — factory partner selection + production test procedure
- V3-FACTORY-OPS.md — factory flashing + cert generation workflow
- V3-VOICE-MATTER.md §3 — Matter-over-Wi-Fi (V3.1) topology + certification plan
- ADR-005 — Telebirr via Chapa
- ADR-006 — Picovoice offline voice
- ADR-007 — Matter-over-Wi-Fi (renamed from Border Router)
- ADR-008 — Ethio Telecom Cloud hosting
- ADR-013 — firmware security
- ADR-014 — factory flashing workflow
