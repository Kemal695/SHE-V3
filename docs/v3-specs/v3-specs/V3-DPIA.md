# V3 — Data Protection Impact Assessment (DPIA)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer (DPO role until dedicated hire — see §8)
**Authority:** Personal Data Protection Proclamation (PDPP) No. 1232/2021, Arts. 24–26 (Data Protection Impact Assessment)
**Cross-reference:** V3-PRIVACY-COMPLIANCE.md (operational control sheet — this document is the analytical companion)

---

## 0. Executive summary

A DPIA is mandatory under PDPP Art. 25 when processing is "likely to result in a high risk to the rights and freedoms of natural persons." SHE V3 triggers the DPIA requirement on three of the four PDPP criteria: (a) large-scale processing of personal data, (b) systematic monitoring of a publicly accessible area (smart home telemetry reveals occupancy patterns), and (c) processing of data related to a person's home life (home + device names, energy usage patterns reveal household behavior).

This assessment evaluates the SHE V3 platform end-to-end: the 12 data types inventoried in V3-PRIVACY-COMPLIANCE.md §1, the 5 subprocessors listed in V3-PRIVACY-COMPLIANCE.md §4, the 5 data subject rights mapped in §2, and the breach response procedure in §5. Five risks are identified, each with a mitigation, residual risk rating, and acceptance owner. Net residual risk: **MEDIUM**, acceptable for production launch subject to the annual review cadence in §7.

---

## 1. Data inventory

### 1.1 What data is collected

| # | Data category | Specific data points | Source | Volume (per active user/year) | Purpose |
|---|---|---|---|---|---|
| 1 | Identity | Email, password hash (Argon2id), phone (E.164) | User signup | 3 rows | Authentication, payment reconciliation |
| 2 | Profile metadata | Display name, profile photo (optional), language preference (Amharic/English) | User edit | <1 KB | UI personalization |
| 3 | Push tokens | FCM token (Android) or APNs token (iOS) | Mobile app on login + token refresh | 1-3 tokens/yr (rotated by Google/Apple) | Notification delivery |
| 4 | Home structure | Home name, room names, room assignments | User configures in-app | ~5 rows/home | Service organization |
| 5 | Device metadata | Node MAC, SKU, firmware version, serial number, device display names, channel labels | Factory + user setup | ~5 nodes × ~10 params each | Service operation |
| 6 | Device telemetry | RSSI, uptime, free heap, reset reason, Wi-Fi disconnect count | Firmware MQTT publish (every 5s, dropped to /params/local) | ~63M rows/year for 5,000-node fleet (TimescaleDB compressed) | Health monitoring, OTA targeting |
| 7 | Energy readings | Voltage (V), current (A), power (W), cumulative energy (kWh) per node | PZEM-004T sensor, every 5s | ~31M rows/year for 5,000-node fleet | Energy monitoring feature, EEU cost computation |
| 8 | Control history | Relay on/off events with timestamp + triggering source (user, automation, scene, voice) | Spring Boot audit log | ~50 events/user/day | Audit trail, automation debug |
| 9 | Audit log | Login events (success/fail), admin actions, payment events, API key usage | System events | ~500 events/user/year | Security forensics, compliance |
| 10 | Payment metadata | Chapa transaction reference, amount in ETB, plan, status, paid_at timestamp | Chapa webhook | ~12 events/user/year (monthly subscription) | Billing |
| 11 | Network metadata | Source IP, user-agent, geo (city-level inferred) | Cloudflare edge + Spring Boot | ~5,000 requests/user/year | Fraud + abuse prevention |
| 12 | Support interactions | Telegram chat messages, in-app chat transcripts, support call notes (if Tier 2) | User initiates support contact | ~3 tickets/user/year (median; long tail for troubled installs) | Service delivery |

### 1.2 From whom

- **B2C end users:** homeowner who purchased a SHE-R4/R8/R16 kit and self-installed
- **B2B end users:** tenants/employees of a B2B customer (real estate developer, hotel, ISP, university) who are issued accounts by a tenant admin
- **Data subjects who are not users:** household members whose behavior is indirectly revealed by device telemetry (e.g., a non-user spouse's occupancy patterns are inferable from relay on/off events). These data subjects have not consented. Mitigation: §3.4 covers occupancy pattern inference.

### 1.3 Special category data

PDPP Art. 9 special category data is **not** processed. Voice audio on the SHE-R16 is processed on-device only (Picovoice Porcupine + Rhino inference runs on the ESP32-S3; no audio is transmitted to the cloud). This is verified by code audit (V3-FIRMWARE.md §10) and network traffic inspection (no audio bytes appear in MQTT or HTTP traffic).

---

## 2. Necessity and proportionality

For each data category, the question: is this data **necessary** for the service, and is the volume **proportionate** to the purpose?

| Data category | Necessary for? | Proportionate? | Minimization decision |
|---|---|---|---|
| 1. Identity | Account creation, payment lookup by phone | Yes — minimum required for any account-based service | Phone is required only for Telebirr payment; Free-tier B2C users can sign up with email only |
| 2. Profile metadata | UI personalization | Yes — display name is shown in greeting; photo is optional and off by default | Profile photo stored as 256×256 PNG (max 100 KB), not original |
| 3. Push tokens | Notification delivery | Yes — without tokens, push is impossible | Token only; no device fingerprinting. Token is deleted on logout |
| 4. Home structure | UI organization | Yes — without homes/rooms, the app is unusable | No structural data beyond what user enters; no automated floor-plan inference |
| 5. Device metadata | Service operation | Yes — without MAC, MQTT routing fails; without SKU, OTA targeting fails | MAC is necessary for MQTT topic. Serial number is necessary for warranty + recall. Firmware version is necessary for OTA targeting |
| 6. Telemetry | Health monitoring, OTA targeting, support debugging | **Proportionate question:** 5s telemetry for 5,000 nodes = 63M rows/year. Necessary? Yes — RSSI drops below -75dBm indicate failing Wi-Fi that needs support intervention; reset reason tells us if the device is crashing. But: aggregated-only in B2B reports; raw telemetry is support-tool-only, not surfaced to B2B tenant admins | 30-day retention (down from "until deletion" in original V3 docs). After 30 days, only daily aggregates (uptime %, disconnect count, RSSI min/max/avg) are retained for 12 months |
| 7. Energy readings | Energy monitoring feature (core value prop) | 5s readings = 31M rows/year for 5,000-node fleet. Necessary? Yes — 5s granularity is needed to detect short-load events (microwave on for 30s). Proportionate? After TimescaleDB compression (8x), this is ~4 GB/year — fits in a single Postgres instance | 13-month retention. After 13 months, only monthly aggregates (total kWh, peak W, cost in ETB) are retained indefinitely |
| 8. Control history | Audit trail, automation debug | Necessary for "why did my light turn on?" debug. Proportionate? 50 events/user/day × 5,000 users = 250K events/day — manageable | 90-day retention at full granularity; after 90 days, only hourly aggregates (on/off counts per device) are retained for 12 months |
| 9. Audit log | Security forensics | Mandatory under PDPP Art. 32 | 24-month retention (mandated by policy, not minimized further) |
| 10. Payment metadata | Billing | Mandatory for tax compliance (7 years) | Not minimized — legal obligation |
| 11. Network metadata | Fraud + abuse | Source IP is needed for failed-login rate-limiting and geographic anomaly detection | 30-day retention in audit_logs; Cloudflare edge logs 24h hot + 7d cold per their policy |
| 12. Support interactions | Service delivery | Necessary for ticket continuity | 12-month retention; transcripts are deleted after 12 months unless linked to an open legal matter |

**Verdict:** The data collection is necessary and proportionate. The two main minimization levers — telemetry retention (30 days, down from indefinite) and energy reading granularity (5s raw, 13-month retention, indefinite monthly aggregate) — are documented as policy decisions and enforced by nightly `drop_chunks` jobs (V3-DATABASE-DESIGN.md §6).

---

## 3. Risk assessment

Five identified risks, each scored on likelihood × impact = inherent risk, then residual risk after mitigation.

Risk scoring scale: 1 (low) to 5 (high). Risk = likelihood × impact (max 25).

### 3.1 Risk: Unauthorized access to PII

| Field | Value |
|---|---|
| Description | Attacker gains access to Postgres and exfiltrates user table (email, phone, password hash) |
| Likelihood | 3 (medium — public internet exposure, frequent target) |
| Impact | 5 (high — 5,000+ users' PII exposed, password hash cracking risk) |
| Inherent risk | 15 (HIGH) |
| Mitigations | (1) Postgres bound to private network only, no public IP; (2) Row-Level Security enforced (FORCE) on all PII tables — even a SQL injection that gets past parameterized queries cannot read other tenants' rows (V3-DATABASE-DESIGN.md §7); (3) Argon2id password hashing (memory-hard, GPU-resistant); (4) MFA enforced for all admin accounts (V3-SECURITY-MODEL.md §4); (5) Encryption at rest (LUKS on Ethio Telecom Cloud volumes); (6) Cloudflare WAF in front of all HTTP endpoints with managed ruleset + custom rule blocking SQLi patterns; (7) Quarterly third-party penetration test starting 2025-Q1 |
| Residual likelihood | 1 (low) |
| Residual impact | 5 (high — if it happens, PII is exposed) |
| Residual risk | 5 (MEDIUM) |
| Acceptance | Lead Engineer accepts residual risk; mitigation budget allocated for pen test |

### 3.2 Risk: Push token leakage to Google/Apple

| Field | Value |
|---|---|
| Description | Google (FCM) or Apple (APNs) is compromised, or their data is subpoenaed, exposing SHE user push tokens and notification payloads |
| Likelihood | 2 (low — both companies have strong security; subpoena risk is jurisdiction-specific) |
| Impact | 2 (low — push tokens alone are not PII; payloads contain no PII by design) |
| Inherent risk | 4 (LOW) |
| Mitigations | (1) Push payloads contain only: title (e.g., "SHE"), body (e.g., "Living Room Light turned on"), and a deep-link (e.g., `she://homes/{homeId}/nodes/{nodeId}`). No user PII in payload. (2) Push tokens are scoped to SHE's Firebase project / APNs certificate — they cannot be used to send notifications from another app. (3) Tokens are rotated by Google/Apple on their schedule (typically every 6-12 months) and we delete the old token on rotation. (4) Users can opt out of all push notifications via `/consent` — they retain core service |
| Residual likelihood | 2 (low) |
| Residual impact | 2 (low) |
| Residual risk | 4 (LOW) |
| Acceptance | Lead Engineer accepts; risk is unavoidable if push notifications are offered as a feature |

### 3.3 Risk: Cloudflare edge sees TLS traffic metadata

| Field | Value |
|---|---|
| Description | Cloudflare, as the TLS-terminating edge, can see source IPs, request paths, and request headers for all SHE API traffic. If Cloudflare is compromised or subpoenaed, this metadata is exposed |
| Likelihood | 2 (low) |
| Impact | 3 (medium — metadata can reveal usage patterns, e.g., "user X called /nodes/{id}/devices/{id}/params at 2am, suggesting they were controlling a device then") |
| Inherent risk | 6 (MEDIUM) |
| Mitigations | (1) Cloudflare cannot see request bodies (POST/PUT/PATCH payloads) — these are re-encrypted after edge inspection and forwarded to origin (Addis Ababa). (2) Cloudflare cannot see WebSocket payloads or MQTT (MQTT does not transit Cloudflare). (3) The `Authorization: Bearer <jwt>` header transits Cloudflare, but the JWT is opaque to Cloudflare (it cannot read user identity from the JWT — it only forwards it). (4) Cloudflare's own data retention: 24h hot logs, 7d cold logs per their privacy policy — metadata is not stored long-term. (5) Geo-block at Cloudflare restricts API access to Ethiopian IPs only (with whitelist exceptions for Chapa callback IPs, FCM/APNs callback IPs — V3-CONFIGURATION.md §6). This means even if Cloudflare metadata leaks, the leak is scoped to Ethiopian IP space |
| Residual likelihood | 1 (low — Cloudflare has not had a major breach in 10+ years) |
| Residual impact | 3 (medium) |
| Residual risk | 3 (LOW) |
| Acceptance | Lead Engineer accepts; trade-off vs. losing DDoS protection is unfavorable (a single DDoS attack would take the platform offline without Cloudflare) |

### 3.4 Risk: Device telemetry reveals occupancy patterns

| Field | Value |
|---|---|
| Description | Relay on/off events + energy readings can infer when the home is occupied (lights on, microwave running) vs. empty. A B2B tenant admin (e.g., a hotel) could use this to monitor employee presence, or a malicious actor with admin access could plan a burglary |
| Likelihood | 3 (medium — the data inherently reveals this; the question is who sees it) |
| Impact | 4 (high — privacy of home life is the core PDPP concern) |
| Inherent risk | 12 (HIGH) |
| Mitigations | (1) Raw telemetry is only visible to the user themselves (B2C) or the tenant admin (B2B). Tenant admins see **aggregate** reports only (daily kWh, peak W, device online %) — not per-event timestamps. (2) B2B tenant admins do not see individual tenant-user activity — they see device-level data only. (3) Audit log alerts on bulk export queries (a tenant admin querying >1000 events in 5 minutes triggers an alert to platform admin). (4) The 30-day telemetry retention means long-term pattern inference is bounded. (5) Energy readings are retained at 5s granularity for 13 months but exposed to the user as hourly/daily aggregates by default — 5s granularity requires explicit "expert mode" toggle in-app, which is itself audit-logged |
| Residual likelihood | 2 (low — mitigations meaningfully restrict who can do pattern inference) |
| Residual impact | 4 (high — if a malicious admin does get access, the inference is still possible) |
| Residual risk | 8 (MEDIUM) |
| Acceptance | Lead Engineer + DPO (when hired) accept; the feature cannot exist without this data, and the mitigations restrict access appropriately |

### 3.5 Risk: Payment data exposure

| Field | Value |
|---|---|
| Description | Card PAN data, CVV, or cardholder name is exposed in a breach |
| Likelihood | 1 (very low — SHE does not handle this data; Chapa does) |
| Impact | 5 (high — if it happened, PCI-DSS implications + reputational damage) |
| Inherent risk | 5 (MEDIUM) |
| Mitigations | (1) SHE never sees PAN, CVV, or cardholder name — Chapa hosts the checkout page, the user enters card details on Chapa's domain, and only a transaction reference is returned to SHE. (2) SHE stores only: Chapa transaction ref (string), amount in ETB, plan, status, paid_at timestamp. (3) The Chapa checkout URL is opened in an in-app browser (Flutter `url_launcher`), which is sandboxed from the SHE app's storage. (4) Chapa is regulated by the National Bank of Ethiopia and is contractually responsible for PCI-DSS compliance on its side. (5) SHE does not seek PCI-DSS certification (not required — we are not a payment processor) |
| Residual likelihood | 1 (very low) |
| Residual impact | 1 (very low — even if Chapa is breached, SHE has no card data to lose) |
| Residual risk | 1 (LOW) |
| Acceptance | Lead Engineer accepts; risk is transferred to Chapa by design |

### 3.6 Risk register summary

| # | Risk | Inherent | Residual | Owner |
|---|---|---|---|---|
| 3.1 | Unauthorized access to PII | 15 (HIGH) | 5 (MEDIUM) | Lead Engineer |
| 3.2 | Push token leakage to Google/Apple | 4 (LOW) | 4 (LOW) | Lead Engineer |
| 3.3 | Cloudflare edge sees TLS metadata | 6 (MEDIUM) | 3 (LOW) | Lead Engineer |
| 3.4 | Telemetry reveals occupancy patterns | 12 (HIGH) | 8 (MEDIUM) | Lead Engineer + DPO |
| 3.5 | Payment data exposure | 5 (MEDIUM) | 1 (LOW) | Lead Engineer (transferred to Chapa) |

**Net residual risk: MEDIUM.** Acceptable for production launch subject to §7 review cadence.

---

## 4. Data subject rights implementation (end-to-end)

How each PDPP right works end-to-end, from user request to verified completion.

### 4.1 Access (PDPP Art. 15)

```
User taps "Export my data" in Settings → app calls POST /api/v3/auth/data-export
  → Spring Boot enqueues export job (async, queued in Redis)
  → Worker queries (in transaction, RLS-scoped):
       • users WHERE id = current_user
       • homes WHERE owner_id = current_user
       • rooms (via home_id IN ...)
       • node_devices (via node_id IN ...)
       • telemetry (last 30 days, via node_id IN ...)
       • energy_readings (last 12 months, via node_id IN ...)
       • audit_logs WHERE user_id = current_user
       • payments WHERE tenant_id = current_user's tenant_id
       • support_tickets WHERE user_id = current_user
  → Worker writes JSON archive to MinIO (signed URL, 24h expiry)
  → Spring Boot sends email + push notification with download link
  → User downloads JSON file
  → Worker deletes the archive from MinIO after 24h
```

**SLA:** 5 minutes (median), 30 minutes (p95) for users with extensive telemetry history.

**Limit:** if the user has >50 nodes or >5 years of history (rare), the export is split into multiple files (identity + payments in one, telemetry + energy in another) and a zip is delivered.

### 4.2 Rectification (PDPP Art. 16)

Direct in-app edits. No backend job needed. Changes are immediate.

### 4.3 Erasure (PDPP Art. 17)

```
Day 0: User taps "Delete my account" → app calls POST /api/v3/auth/delete-me
  → Spring Boot sets users.scheduled_deletion_at = NOW() + 7 days
  → User can cancel during 7-day grace period (PUT /api/v3/auth/cancel-deletion)

Day 7 (if not cancelled): Scheduled job fires:
  → Revokes device X.509 certs via step-ca CRL (certs.she.et  →  EMQX reloads CRL)
  → CASCADE DELETE on:
       • user row
       • home_memberships (but NOT homes if other members exist — home is preserved)
       • homes WHERE owner_id = user AND no other members
       • nodes WHERE home_id IN (deleted homes)
       • node_devices, node_params (cascade from nodes)
       • push_tokens
       • profile photo in MinIO (deleted)
  → TimescaleDB chunks for deleted nodes: drop_chunks (immediate — energy + telemetry gone)
  → audit_logs: UPDATE SET user_id = NULL WHERE user_id = deleted_user
       (event record retained for 24 months; only the user link is severed)
  → payments: retained (legal obligation, 7 years)
  → factory_audit_log: retained for devices (legal obligation, 10 years)
  → support_tickets: anonymized (user_id = NULL), retained 12 months then deleted
  → User receives final confirmation email (sent BEFORE the email itself is deleted)
```

**SLA:** 14 days end-to-end (7-day grace + 7-day processing). Actual processing time is <5 minutes; the 7-day processing budget covers cert revocation propagation + CRL reload.

### 4.4 Portability (PDPP Art. 18)

Same as §4.1 — the JSON export is in a documented schema (V3-API-SPECIFICATION.md §11) and can be imported into any compatible system. No proprietary lock-in.

### 4.5 Objection (PDPP Art. 19)

Direct in-app toggles for marketing email, push notifications, and aggregated analytics. Changes immediate. Cannot opt out of: identity verification, payment processing, audit logging (these are contractual necessity or legal obligation per V3-PRIVACY-COMPLIANCE.md §6).

---

## 5. Subprocessor list

Cross-reference: V3-PRIVACY-COMPLIANCE.md §4 (authoritative table).

Summary:
1. Ethio Telecom Cloud — infrastructure hosting (Addis Ababa)
2. Cloudflare — DDoS + DNS + WAF (global edge)
3. Chapa — payment processing (Addis Ababa)
4. Google FCM — push notifications, Android (global)
5. Apple APNs — push notifications, iOS (global)

**Subprocessor risk per §3:** risks 3.2 (FCM/APNs) and 3.3 (Cloudflare) cover the cross-border subprocessors. Risks 3.1 (Postgres on Ethio Telecom) and 3.5 (Chapa) cover the in-country subprocessors.

**Subprocessor change procedure:** see V3-PRIVACY-COMPLIANCE.md §4. New subprocessor requires update to this document (§5) and a fresh risk assessment in §3.

---

## 6. Breach response procedure

Cross-reference: V3-PRIVACY-COMPLIANCE.md §5 (authoritative procedure).

Summary of the 72-hour notification chain:
- T+0: Detect
- T+30min: Triage
- T+4h: Contain
- T+24h: Assess scope
- T+72h: Notify ECA + affected users
- T+7d: Remediate
- T+30d: Post-incident review (this document updated if warranted)

---

## 7. Review cadence

| Trigger | Owner | Action |
|---|---|---|
| Annual (calendar Q1) | Lead Engineer + DPO | Full review of this DPIA. Re-score all risks in §3. Verify §1 inventory still matches actual schema. Verify §5 subprocessor list still matches actual vendor list. |
| New subprocessor added | Lead Engineer | Update §5. Add new risk to §3 if the subprocessor processes PII. |
| New data type collected | Lead Engineer | Update §1.1. Add to V3-PRIVACY-COMPLIANCE.md §1 with retention + lawful basis. Add to §2 (necessity assessment). |
| Architecture change | Lead Engineer | Re-assess §3 risks affected by the change. Update V3-PRIVACY-COMPLIANCE.md §3 if data flow changed. |
| Material change to PDPP or subordinate regulation | DPO | Full review. Consult ECA if interpretation is unclear. |
| Breach incident | Lead Engineer + DPO | Per §6, post-incident review at T+30d. This document updated if architectural or procedural change is warranted. |

**Last review:** 2024-Q4 (this version — first formal DPIA)
**Next scheduled review:** 2025-Q1
**Review log:** maintained in `/compliance/dpia-review-log.md`

---

## 8. Sign-off

| Role | Name | Date | Signature |
|---|---|---|---|
| Lead Engineer (interim DPO) | TBD at launch | 2024-Q4 | (signed in `/compliance/dpia-signoff.pdf`) |
| Data Protection Officer (when hired) | TBD | TBD | TBD |
| External reviewer (recommended annually from 2025-Q1) | TBD | TBD | TBD |

**Note on DPO role:** PDPP does not mandate a DPO for all data controllers, but it is best practice for a controller processing the volume and sensitivity of data SHE handles. The Lead Engineer serves as interim DPO until a dedicated hire is made (target: 2025-Q2, contingent on Series A funding). The DPO hire is tracked in V3-ROADMAP.md.

---

## 9. References

- Personal Data Protection Proclamation No. 1232/2021, Federal Democratic Republic of Ethiopia — Arts. 5 (principles), 6 (lawful basis), 15–22 (data subject rights), 24–26 (DPIA), 28 (subprocessors), 32 (security), 33 (breach notification)
- V3-PRIVACY-COMPLIANCE.md — operational control sheet (companion to this document)
- V3-SECURITY-MODEL.md — technical controls inventory
- V3-DATABASE-DESIGN.md §7 — RLS implementation
- V3-FACTORY-OPS.md §8 — factory audit log (10-year retention)
- V3-PAYMENTS.md — Chapa payment flow
- ENISA DPIA methodology (reference framework, adapted for PDPP)
