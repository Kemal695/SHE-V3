# V3 — Success Metrics

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Lead Engineer

---

## 0. Scope

Defines the Key Performance Indicators (KPIs) for SHE V3 across reliability, performance, adoption, operational health, and security. Each metric has a target, a measurement method, and an owner.

> **Correction from the original V3-SUCCESS-METRICS.md (Proposed):** The original §3 listed "5,000 registered devices in 12 months" alongside V3-ROADMAP.md's "500 manufactured by GA". These are incompatible — you cannot register 5,000 devices if only 500 are manufactured. The corrected targets below reconcile manufacturing capacity with adoption reality:
>
> - **Month 12 (GA):** 500 manufactured, 100 deployed (beta), 50 paying B2C, 2 B2B pilot tenants
> - **Month 18 (V3.1 launch):** 2,000 manufactured, 1,000 registered, 500 paying B2C, 5 B2B tenants
> - **Month 24 (V3.2 + adoption milestone):** 5,000 registered, 1,000 paying B2C, 10 B2B tenants
>
> The original "12-month" framing is replaced with a 24-month adoption arc, of which the first 12 months are manufacturing-led (limited supply) and months 12-24 are market-led (full production volume).

---

## 1. Reliability

| Metric | Target | Measurement |
|---|---|---|
| MQTT uptime (monthly) | 99.5% | EMQX `/stats` endpoint — `1 - (downtime_seconds / 2_592_000)` |
| API uptime (monthly) | 99.5% | UptimeRobot external pings to `/actuator/health` |
| API error rate (5xx) | < 0.1% | Spring Boot `/actuator/metrics/http.server.requests` |
| Command success rate | > 95% | `audit_log` — `command.acked / command.sent` |
| Telemetry delivery rate | > 95% | EMQX publish count vs Spring Boot ingest count |
| OTA success rate | > 95% | `ota_approvals` — `SUCCEEDED / (SUCCEEDED + FAILED)` per batch |
| Notification delivery rate | > 95% | FCM + APNs delivery receipts vs `notification_log` |
| Device LWT accuracy | 100% | Devices showing offline within 60 s of network loss |

---

## 2. Performance

| Metric | Target | Measurement |
|---|---|---|
| API p95 latency | < 300 ms | Spring Boot `/actuator/metrics/http.server.requests` |
| Command publish p95 | < 500 ms | Spring Boot → EMQX publish timestamp vs API request timestamp |
| Command end-to-end p95 (API → device ack) | < 2 s | `audit_log` — `command.acked_at - command.sent_at` |
| Telemetry ingest p95 | < 200 ms | EMQX receive timestamp vs Postgres insert timestamp |
| Energy ingest p95 | < 100 ms | EMQX receive vs TimescaleDB insert |
| Automation execution p95 | < 2 s | Trigger timestamp vs last action timestamp |
| Scene activation p95 | < 1 s | API call vs last device state change |
| App cold start | < 3 s | Firebase Performance Monitoring (Flutter) |
| WebSocket event delivery p95 | < 500 ms | Spring Boot publish vs client receive (instrumented) |

### 2.1 Load capacity (V3 GA design target)

| Metric | Target | Measurement |
|---|---|---|
| Concurrent devices | 10,000 | EMQX cluster (3 nodes, 8 vCPU each) — `mqtt.connected` metric |
| Telemetry ingest rate | 1,000 msgs/s sustained | EMQX `messages.receive` per second |
| Command rate | 100 msgs/s sustained | EMQX `messages.publish` per second |
| Concurrent API users | 1,000 | Spring Boot session count |
| API throughput | 500 req/s sustained | Nginx access log |

---

## 3. Adoption (24-month arc)

### 3.1 Month 12 (GA — manufacturing-led)

| Metric | Target | Notes |
|---|---|---|
| Devices manufactured | 500 | At factory partner (Shenzhen); sea-freighted to Addis |
| Devices deployed (beta) | 100 | Across 10 beta sites (5 B2C + 5 B2B) |
| Paying B2C users | 50 | Early adopters from beta cohort |
| B2B pilot tenants | 2 | Trial/ACTIVE status |
| B2C MRR | ~$140 (50 × $2.73 Premium) | Excludes Family plan |
| B2B MRR | ~$200-1,000 (depending on plan tier) | B2B-100 or B2B-1000 |
| Average satisfaction rating (beta) | ≥ 8/10 | In-app survey at GA — V3-ROADMAP.md §7 5C |

### 3.2 Month 18 (V3.1 launch — market-led ramp)

| Metric | Target | Notes |
|---|---|---|
| Devices manufactured (cumulative) | 2,000 | Factory running at ~150 units/month |
| Devices registered | 1,000 | Active in the platform (manufactured + deployed + provisioned) |
| Paying B2C users | 500 | Mix of Premium + Family |
| B2B tenants | 5 | At least 2 ACTIVE (paying) |
| B2C MRR | ~$1,500 | |
| B2B MRR | ~$2,000-5,000 | |
| NPS (post-GA cohort) | ≥ +30 | First formal NPS survey at month 18 |

### 3.3 Month 24 (V3.2 — adoption milestone)

| Metric | Target | Notes |
|---|---|---|
| Devices registered (cumulative) | 5,000 | Original "5,000 in 12 months" target — achieved at month 24, not 12 |
| Paying B2C users | 1,000 | 20% conversion rate from registered → paying |
| B2B tenants | 10 | Mix of B2B-100 / B2B-1000 / B2B-UNLIMITED |
| B2C MRR | ~$3,000 | |
| B2B MRR | ~$5,000-10,000 | |
| Monthly Active Users | 800 | 80% of paying users active monthly |
| NPS | ≥ +40 | Healthy SaaS benchmark |

### 3.4 Manufacturing vs adoption reconciliation

The original "5,000 registered in 12 months" was incompatible with "500 manufactured by GA" because devices must be physically built, shipped (6-week sea freight from Shenzhen to Djibouti + 2-day truck to Addis), and sold to a user before they can be registered.

Reconciliation:
- **Month 12 (GA):** 500 manufactured → 100 deployed in beta. No retail sales yet — manufacturing is just-in-time.
- **Months 13-18:** Factory ramps to ~150 units/month → 2,000 manufactured cumulative. Retail + B2B sales channels open. 1,000 of the 2,000 manufactured are sold + registered.
- **Months 19-24:** Factory at full run-rate (~250 units/month) → 5,000 registered cumulative.

**Implication for V3-ROADMAP.md:** GA exit criterion is "500 manufactured" (not "5,000 registered"). The 5,000-registered milestone is a post-GA target tracked separately, achieved at month 24.

---

## 4. Operational health

| Metric | Target | Measurement |
|---|---|---|
| Deploy frequency | ≥ 1/week | GitHub Actions deployment count |
| Change failure rate | < 10% | Deploys requiring rollback / total deploys |
| MTTR (SEV-1/2) | < 60 min | PagerDuty incident → resolved timestamp |
| Incidents/month (SEV-1+2) | < 4 | PagerDuty incident count |
| Backup test success | 100% quarterly | Restore-to-staging test (V3-OPS-RUNBOOK.md §7.1) |
| Cert renewal | 100% before expiry | Grafana "Cert Expiry" dashboard — alert at < 14 days |
| Postmortem filed within 48h | 100% for SEV-1/2 | `docs/postmortems/` directory |
| On-call alert noise | < 10 actionable alerts/week | PagerDuty — filter out auto-resolved |

---

## 5. Security

| Metric | Target | Measurement |
|---|---|---|
| Confirmed data breaches | 0 | (binary — any breach is a SEV-1 + ECA notification within 72h) |
| MFA adoption (admins) | 100% | `users.mfa_enabled` column — enforced at login for SUPER_ADMIN, PLATFORM_ADMIN, TENANT_ADMIN |
| Failed login rate | < 50/min sustained | Spring Boot auth logs (rate-limited at 5 attempts per email per 5 min) |
| RBAC denial rate | < 1% | `audit_log` — `RBAC_FORBIDDEN` events / total API requests |
| Security audit findings (critical) | 0 | External pentest report (annual) |
| Security audit findings (high) | < 3 | External pentest report (annual) |
| Time to patch (critical CVE) | < 14 days | Dependency scanning (Snyk / Dependabot) + GitHub Actions alert |
| Secure Boot + Flash Encryption enabled | 100% of production devices | Factory QC log — every device verified before shipping |
| Cert revocation propagation | < 6 hours (CRL refresh interval) | step-ca CRL generation + EMQX CRL refresh (CRL refreshes every 6h per CANONICAL-DECISIONS.md P1-22) |
| Audit log integrity | 100% (write-once, append-only) | Periodic hash-chain verification (V3-PRIVACY-COMPLIANCE.md) |

---

## 6. Privacy + PDPP compliance

| Metric | Target | Measurement |
|---|---|---|
| Data export request fulfillment | < 30 days (PDPP requirement) | `privacy_requests` table — `requested_at → fulfilled_at` |
| Data erasure request fulfillment | < 30 days | Same — `erased_at` |
| Subprocessor inventory accuracy | 100% (quarterly review) | V3-PRIVACY-COMPLIANCE.md §4 — inventory reviewed quarterly |
| Breach notification to ECA | < 72 hours from discovery | (binary — any breach triggers the 72h clock) |
| Push notification tokens transiting FCM/APNs | Documented in DPIA, no PII in payload | V3-DPIA.md — token only, no user data |

---

## 7. Mobile app quality

| Metric | Target | Measurement |
|---|---|---|
| Crash-free sessions | > 99.5% | Firebase Crashlytics |
| ANR (App Not Responding) rate | < 0.1% | Firebase Performance |
| App store rating | ≥ 4.5/5 | Google Play + Apple App Store |
| BLE provisioning success rate | > 95% | Telemetry: provisioning started → device connected to MQTT |
| OTA via app success rate | > 95% | Same as §1 OTA success rate, scoped to user-initiated |
| Cold start time (p95) | < 3 s | Firebase Performance |

---

## 8. Energy monitoring quality

| Metric | Target | Measurement |
|---|---|---|
| PZEM-004T reading accuracy | ±1% vs calibrated meter | Factory QC test (V3-HARDWARE.md §7.3 step 6) |
| Energy ingest latency | < 100 ms p95 | See §2 |
| ETB cost calculation correctness | 100% vs Ethiopian tariff | Monthly test: simulate known kWh → verify cost_etb matches block-tariff calculation |
| Anomaly detection precision | > 80% (true positives among alerts) | `audit_log` — user dismissed anomaly alert / total anomaly alerts |
| B2B aggregate report generation time | < 5 s for 1-year report | API timing on `/api/v3/tenant/energy` |

---

## 9. Reporting cadence

| Report | Frequency | Audience |
|---|---|---|
| Weekly ops review | Monday 10:00 | Engineering team |
| Monthly KPI dashboard | 1st of month | Engineering + Lead Engineer |
| Quarterly business review | Quarterly | Lead Engineer + investors (if applicable) |
| Annual security audit | Yearly | Lead Engineer + external auditor |
| NPS survey | Month 18, then quarterly | Product team |

---

## 10. References

- V3-ROADMAP.md §7 — Phase 5C exit criterion (satisfaction rating, not NPS)
- V3-ROADMAP.md §10 — V3.1 / V3.2 post-GA milestones
- V3-UNIT-ECONOMICS.md §4 — B2C + B2B LTV / CAC
- V3-PRIVACY-COMPLIANCE.md — PDPP data subject rights fulfillment
- V3-DPIA.md — privacy metrics
- V3-OPS-RUNBOOK.md §3 — monitoring stack + alert routing
- V3-INTEGRATION-TEST-PLAN.md §2 — load test targets (matches §2.1 here)
- V3-ENERGY-MONITORING.md §5 — energy dashboard quality
