# V3 — Privacy & Compliance

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Lead Engineer (Data Protection Officer role until dedicated hire — see V3-DPIA.md §8)
**Authority:** Personal Data Protection Proclamation (PDPP) No. 1232/2021, Federal Democratic Republic of Ethiopia

---

## 0. Document scope

This document replaces the original thin V3-PRIVACY-COMPLIANCE.md, which contained the false claim that "no data leaves Ethiopia." That claim is incorrect: push notification tokens transit Google FCM and Apple APNs, and Cloudflare terminates TLS at the edge for DDoS protection. This rewrite documents the actual data flows honestly, adds a subprocessor inventory, and maps each PDPP data-subject right to a concrete API endpoint.

The full risk assessment for these processing operations lives in V3-DPIA.md. This document is the operational control sheet; the DPIA is the analytical companion.

### 0.1 What changed from the previous version

| Section | Previous (false) | This version (corrected) |
|---|---|---|
| §3 Data residency | "All data hosted in Addis Ababa. No data leaves Ethiopia. No cross-border transfers." | Primary data in Addis Ababa; push tokens transit FCM/APNs; Cloudflare sees traffic metadata at edge; no other cross-border transfers |
| §4 Subprocessors | Missing entirely | 5 subprocessors enumerated: Ethio Telecom Cloud, Cloudflare, Chapa, Google FCM, Apple APNs — with explicit "not used" list |
| §1 PII inventory | 11 data types, no lawful-basis column, no cross-border column | 12 data types (added profile photo) + cross-border flag + retention + lawful basis per PDPP Art. 6 |
| §2 Data subject rights | 5 rights, no API endpoint mapping | 5 rights mapped to concrete endpoints + erasure exceptions + children policy |
| §5 Breach response | 6-step table only | 8-step table + tabletop exercise history + ECA notification template |
| §6 Lawful basis | Missing entirely | 3 lawful bases (contractual / consent / legal obligation) mapped to data types + special category statement |
| New §7 cross-refs DPIA | n/a | Mandated cross-reference to V3-DPIA.md for risk analysis |

### 0.2 Authority and applicability

This document is the SHE V3 controller's record of processing activities per PDPP Art. 30. It applies to:
- All personal data processed by SHE V3 (B2C and B2B segments)
- All subprocessors listed in §4
- All geographic regions where SHE operates (Ethiopia-only at GA; future expansion requires a fresh DPIA)

The Data Protection Officer (DPO) — currently the Lead Engineer in an interim capacity until a dedicated hire is made per V3-DPIA.md §8 — owns this document and is the contact point for data subjects, the ECA, and subprocessors on all PDPP matters.

---

## 1. PII inventory

Every data type SHE collects, where it is stored, whether it crosses the Ethiopian border, how long it is kept, and the lawful basis under PDPP Art. 5.

| # | Data type | Where stored | Cross-border? | Retention | Lawful basis (PDPP Art. 6) |
|---|---|---|---|---|---|
| 1 | Email address | Postgres `users.email` (Addis Ababa) | No | Until account deletion + 30-day grace | Contractual necessity (service delivery) |
| 2 | Password hash (Argon2id) | Postgres `users.password_hash` | No | Until account deletion | Contractual necessity (authentication) |
| 3 | Phone number (E.164) | Postgres `users.phone` | No (in-country only) | Until account deletion | Contractual necessity (payment reconciliation via Telebirr) |
| 4 | Push notification token (FCM / APNs) | Postgres `users.push_token` + Google FCM or Apple APNs delivery infrastructure | **Yes — token transits Google (Android) or Apple (iOS) for delivery.** Token itself is stored in Addis Ababa; the push payload is sent through FCM/APNs to reach the device. | Until user logs out or uninstalls app | Contractual necessity (notification delivery) |
| 5 | Home name, room name, device display name | Postgres `homes.name`, `rooms.name`, `node_devices.display_name` | No | Until account deletion | Contractual necessity (service personalization) |
| 6 | Device MAC address | Postgres `nodes.mac_address` + factory audit log | No | Lifetime of device + 10 years (factory audit, V3-FACTORY-OPS.md §8) | Legal obligation (manufacturing audit, ECA type approval traceability) |
| 7 | Device telemetry (RSSI, uptime, free heap, reset reason) | TimescaleDB `telemetry` hypertable | No | 30 days (drop_chunks nightly, V3-DATABASE-DESIGN.md §6) | Contractual necessity (device health monitoring) |
| 8 | Energy readings (V, A, W, kWh per node) | TimescaleDB `device_energy_readings` hypertable | No | 365 days (1 year; supports EEU block-tariff annualized reporting) | Contractual necessity (energy monitoring feature); aggregated-only in B2B reports |
| 9 | Audit log events (login, command, payment, admin actions) | Postgres `audit_logs` table | No | 2 years compressed + 7 years CSV archive (S3) | Legal obligation (security incident response, PDPP Art. 32) |
| 10 | IP address (request source) | Postgres `audit_logs.ip_address` + Cloudflare edge logs | **Cloudflare edge sees source IP for TLS termination; only metadata, no payload.** Cloudflare does not persist SHE customer IPs beyond standard edge-log retention (24h hot, 7d cold). | 30 days in `audit_logs`; Cloudflare 24h/7d per their privacy policy | Legitimate interest (fraud + abuse prevention) |
| 11 | Payment data (Chapa transaction ref, amount, status) | Postgres `payments` table (Addis Ababa) | **No** — Chapa is an Ethiopian payment aggregator (Addis Ababa). All card PAN data is held by Chapa; SHE never sees or stores PAN, CVV, or cardholder name. | 7 years (financial record-keeping, Ethiopian tax law) | Legal obligation (tax + financial regulation) |
| 12 | User-uploaded profile photo (optional) | MinIO object storage (Addis Ababa) | No | Until account deletion | Consent (user explicitly uploads) |

**PII not collected (intentional):** National ID number, passport, date of birth, gender, religion, ethnicity, precise geolocation (only city-level inferred from IP for fraud scoring).

---

## 2. Data subject rights

PDPP Arts. 15–22 grants data subjects five rights. Each is mapped to a SHE API endpoint or operational procedure.

| Right | PDPP article | SHE implementation | API endpoint | SLA |
|---|---|---|---|---|
| Access | Art. 15 | User requests data export → Spring Boot queries all tables scoped by `user_id` → returns JSON archive (profile, homes, devices, telemetry sample last 30d, energy readings last 12mo, audit log entries, payments) | `POST /api/v3/auth/data-export` (returns signed download URL valid 24h) | 5 minutes (automated) |
| Rectification | Art. 16 | User edits profile (email, phone, display name, home/room/device names) in-app; admin edits role assignments in admin console | `PATCH /api/v3/users/me`, `PATCH /api/v3/homes/{id}`, `PATCH /api/v3/nodes/{id}/devices/{id}` | Real-time |
| Erasure | Art. 17 | User submits erasure request → 7-day cooling-off period (cancel option) → cascade delete: user row, home memberships, owned homes, devices (factory cert revoked via step-ca CRL), telemetry chunks, energy readings, audit log anonymized (kept as `user_id = NULL` for security forensics) | `POST /api/v3/auth/delete-me` | 14 days end-to-end (7-day grace + 7-day processing) |
| Portability | Art. 18 | Same as access — JSON export in machine-readable format (no proprietary lock-in) | `POST /api/v3/auth/data-export` (format: JSON, schema documented in V3-API-SPECIFICATION.md §11) | 5 minutes |
| Objection | Art. 19 | User opts out of marketing emails (off by default), push notifications (off by default), and aggregated anonymized analytics (off by default) | `PUT /api/v3/users/me/consent` body: `{"marketing_email": false, "push_notifications": false, "analytics": false}` | Real-time |

**Erasure exceptions** (PDPP Art. 17(3) — data that must be retained despite erasure request):
- Payment records (7 years — Ethiopian tax law)
- Audit log entries (2 years compressed + 7 years CSV archive — security forensics; `user_id` is anonymized to NULL but the event record itself is retained)
- Factory audit log entries for the device (10 years — ECA type approval traceability, V3-FACTORY-OPS.md §8)

**Children:** SHE is not directed at children under 13. Signup requires explicit age confirmation. If we learn a child under 13 has an account, it is deleted within 24 hours with no grace period.

### 2.1 Example: data export response shape

The `POST /api/v3/auth/data-export` endpoint produces a signed MinIO URL. The downloaded JSON archive has this shape (truncated for illustration):

```json
{
  "exported_at": "2024-12-15T09:42:00+03:00",
  "user": {
    "email": "abebe@example.et",
    "phone": "+251911234567",
    "display_name": "Abebe Bekele",
    "language": "am",
    "created_at": "2024-03-12T..."
  },
  "homes": [
    {"id": "...", "name": "Bole Apartment", "address_city": "Addis Ababa", "rooms": [...]}
  ],
  "nodes": [
    {"node_id": "SHE-R8-AABBCC", "mac": "24:6F:28:AA:BB:CC", "sku": "SHE-R8",
     "firmware": "1.4.2", "devices": [...], "installed_at": "..."}
  ],
  "telemetry_sample_30d": [...],
  "device_energy_readings_365d": [...],
  "audit_log_entries": [...],
  "payments": [...],
  "support_tickets": [...]
}
```

Schema is documented in V3-API-SPECIFICATION.md §11. The export is generated asynchronously (typically 5 minutes) and the signed URL is valid for 24 hours, after which the archive is deleted from MinIO.

### 2.2 Example: erasure cascade

When a user submits `POST /api/v3/auth/delete-me`, the following cascade executes over a 7-day grace + 7-day processing window:

```
Day 0 (request received):
  users.scheduled_deletion_at = NOW() + 7d
  User receives confirmation email with cancel link
  User can cancel via PUT /api/v3/auth/cancel-deletion

Day 7 (scheduled deletion job fires):
  1. Revoke all device X.509 certs owned by user → step-ca CRL update → EMQX reloads CRL
  2. CASCADE DELETE:
     - user row
     - home_memberships WHERE user_id = ?
     - homes WHERE owner_id = ? AND no other members
     - nodes WHERE home_id IN (deleted homes)
     - node_devices, node_params (cascade from nodes)
     - push_tokens WHERE user_id = ?
     - profile photo in MinIO (deleted)
  3. TimescaleDB: drop_chunks for any chunks containing telemetry or energy for deleted nodes
  4. audit_logs: UPDATE SET user_id = NULL WHERE user_id = ?
     (event record retained for 2 years compressed + 7 years CSV archive; only the user link is severed)
  5. payments: retained (legal obligation, 7 years)
  6. factory_audit_log: retained for devices (legal obligation, 10 years)
  7. support_tickets: anonymized (user_id = NULL), retained 12 months then deleted

Day 14 (or earlier if processing completes):
  Final confirmation email sent (BEFORE the user's email is deleted in step 2)
  Deletion complete; user record no longer exists in any PII table
```

The full erasure flow is also documented in V3-DPIA.md §4.3 with the same day-by-day breakdown.

---

## 3. Data residency

**Primary residency:** All user PII, device telemetry, energy readings, audit logs, and payment metadata are hosted in the SHE-operated Addis Ababa data center on **Ethio Telecom Cloud** infrastructure. The Spring Boot application, Postgres + TimescaleDB, EMQX MQTT cluster, MinIO object storage, and Redis cache all run in this facility.

**Cross-border transfers (honest disclosure):**

1. **Push notification tokens transit Google FCM (Android) and Apple APNs (iOS).** When the SHE backend needs to deliver a push notification, it sends a request to FCM or APNs containing the device's push token and the notification payload. The token and payload traverse Google's or Apple's global infrastructure. **Mitigation:** push payloads contain only the notification title, body, and a deep-link to in-app content — no PII, no device state, no telemetry. The user's name does not appear in push payloads; only "SHE" as the sender.

2. **Cloudflare terminates TLS at the edge.** Cloudflare provides DDoS protection, DNS, and WAF for the SHE API and admin console. To inspect and filter HTTP requests, Cloudflare terminates the TLS connection at its edge PoP (the closest to the Ethiopian user is Frankfurt or Mumbai — there is no Cloudflare PoP in Ethiopia as of 2024). Cloudflare sees: source IP, destination hostname, request path, request headers (including `Authorization: Bearer <jwt>` — but the JWT itself is opaque to Cloudflare, only the signature is verified by Spring Boot). Cloudflare does **not** see: request body contents for POST/PUT/PATCH (these are re-encrypted after edge inspection and forwarded to origin), WebSocket frame payloads, MQTT payloads (MQTT does not transit Cloudflare). **Mitigation:** this is acceptable per PDPP because Cloudflare only sees traffic metadata, not payload content. The TLS re-encryption between Cloudflare and origin (Addis Ababa) uses a separate cert (origin pull cert), so payload integrity is preserved.

3. **No other cross-border transfers.** No data flows to RainMaker, AWS IoT, Azure IoT, Google Cloud (other than FCM push delivery), or any other third-party cloud. Chapa is Ethiopian and hosted in Addis Ababa. Ethio Telecom Cloud is Ethiopian. MinIO is operated by SHE in Addis Ababa.

**Original false claim corrected:** the prior version of this document stated "All data stays in Ethiopia. No cross-border transfers." That was incorrect. The corrected statement is: "All primary data is hosted in Addis Ababa. Push notification tokens and payloads transit Google FCM / Apple APNs for delivery. Cloudflare sees traffic metadata at the edge for DDoS protection. No other cross-border transfers occur."

### 3.1 Transfer impact assessment (TIA)

PDPP Art. 26 permits cross-border transfers subject to adequacy or safeguards. For each cross-border transfer identified above:

| Transfer | Receiving country | Adequacy finding | Safeguard relied upon |
|---|---|---|---|
| Push payload to Google FCM | EU/US (Google data center, region varies) | No Ethiopian adequacy finding for the US (EU has CLOUD Act concerns) | Google Firebase Data Processing Terms (GDPR-standard Art. 28 SCCs); payload minimized to no PII (title + body + deep-link only) |
| Push payload to Apple APNs | US (Apple data center) | No | Apple Developer Agreement + Apple Privacy Policy; same payload minimization |
| TLS metadata to Cloudflare edge | Global (Frankfurt or Mumbai PoP, typically) | No | Cloudflare DPA (GDPR-standard SCCs); metadata only, no payload |

The TIA concludes that all three transfers are **acceptable** because (a) the data transferred is minimized to the lowest possible sensitivity (no PII in push payloads; no request bodies visible to Cloudflare), and (b) the subprocessors' contractual terms include GDPR-equivalent protections that, while not PDPP-specific, are recognized internationally as meeting the spirit of PDPP Arts. 28 + 32.

### 3.2 Future expansion (out of Ethiopia)

If SHE expands to other African markets (planned V4 — see V3-ROADMAP.md), each new region requires:
1. A fresh DPIA covering the new processing context
2. Verification of in-country hosting (replicated architecture in the new region)
3. New subprocessor review if local payment aggregators are required
4. Legal review of the new country's data protection regime vs PDPP

This document covers **Ethiopia-only processing** at GA. Any expansion triggers a full review.

---

## 4. Subprocessor inventory

SHE uses the following subprocessors. Each is reviewed annually for PDPP compliance and contractual data-protection terms (PDPP Art. 28).

| # | Subprocessor | Purpose | Location | Data accessed | Contractual basis |
|---|---|---|---|---|---|
| 1 | **Ethio Telecom Cloud** | Infrastructure hosting (compute, storage, network) for all SHE primary systems | Addis Ababa, Ethiopia | Full access to all hosted data (Ethio Telecom operates the underlying VMs and storage) | Data Processing Agreement (DPA) executed 2024-Q2; Ethio Telecom is a state-owned Ethiopian entity, subject to PDPP |
| 2 | **Cloudflare** | DDoS protection, DNS resolution, WAF, edge TLS termination | Global edge network (no PoP in Ethiopia as of 2024; closest: Frankfurt, Mumbai) | Source IP, destination hostname, request path, request headers (metadata only — no request body, no WebSocket payloads, no MQTT payloads) | Cloudflare DPA (GDPR-standard, applied globally); Cloudflare Data Processing Addendum covers PDPP-equivalent obligations |
| 3 | **Chapa** | Payment processing (Telebirr + CBE Birr + cards) | Addis Ababa, Ethiopia | Payment amount, customer phone number (for Telebirr lookup), Chapa transaction reference. **Card PAN, CVV, cardholder name never reach SHE.** | Chapa merchant agreement (2024); Chapa is Ethiopian, regulated by National Bank of Ethiopia |
| 4 | **Google Firebase Cloud Messaging (FCM)** | Push notification delivery (Android) | Global (Google data centers, typically EU/US for Ethiopian traffic) | FCM registration token, push notification payload (title + body + deep-link, no PII) | Google Cloud Platform Terms + Firebase Data Processing Terms (GDPR-standard) |
| 5 | **Apple Push Notification service (APNs)** | Push notification delivery (iOS) | Global (Apple data centers, typically US) | APNs device token, push notification payload (title + body + deep-link, no PII) | Apple Developer Agreement + Apple Privacy Policy |

**Subprocessors explicitly NOT used** (correcting ambiguity from earlier V3 docs):
- ❌ ESP RainMaker cloud — not used (SHE is self-hosted; only the RainMaker *data hierarchy* is adopted as a conceptual model — V3-DEVICE-MODEL.md §1)
- ❌ AWS IoT Core — not used
- ❌ Azure IoT Hub — not used
- ❌ Google Cloud IoT — not used
- ❌ Any third-party analytics (no Mixpanel, no Amplitude, no Firebase Analytics) — product analytics are self-hosted in Postgres

**Adding a new subprocessor** requires: (1) Lead Engineer review for necessity, (2) DPA execution with PDPP-equivalent terms, (3) update to this table, (4) update to V3-DPIA.md §5, (5) 30-day advance notice to users via in-app banner (PDPP Art. 28(2)).

---

## 5. Breach response

A personal data breach is "a breach of security leading to the accidental or unlawful destruction, loss, alteration, unauthorized disclosure of, or access to, personal data" (PDPP Art. 2(8)).

| Step | Time from detection | Owner | Action |
|---|---|---|---|
| 1. Detect | T+0 | On-call engineer or monitoring alert | Confirm a security event is in progress (anomalous DB query volume, unauthorized API calls, RLS policy violation, cert misuse, etc.) |
| 2. Triage | T+30 min | On-call + Lead Engineer | Classify: is PII actually exposed, or only metadata? Document in `/incidents/{date}-{slug}.md` |
| 3. Contain | T+4h | On-call + Lead Engineer | Rotate exposed credentials, revoke compromised device certs via step-ca CRL, block offending IPs at Cloudflare WAF, suspend compromised user accounts |
| 4. Assess scope | T+24h | Lead Engineer + Data Protection Officer (or interim) | Determine: which data types (see §1), how many users, what time window. Produce written scope statement. |
| 5. Notify ECA | T+72h | CEO (or delegate) | Submit written breach notification to the Ethiopian Communications Authority per PDPP Art. 33. Notification includes: breach description, approximate number of data subjects affected, data categories exposed, measures taken, contact for further information. |
| 6. Notify affected users | T+72h | CEO (or delegate) | Email + in-app notification to every affected user. Plain Amharic + English. Includes: what happened, what data was exposed, what SHE is doing, what the user should do (change password, etc.). |
| 7. Remediate | T+7d | Lead Engineer | Implement permanent fix (code change, infra change, policy change). Verify fix with penetration test or audit. |
| 8. Post-incident review | T+30d | Lead Engineer + DPO | Written blameless post-mortem. Update V3-DPIA.md if architecture change warranted. Update this document if subprocessor change warranted. File in `/incidents/postmortems/`. |

**Exercises:** A tabletop breach-response exercise is conducted quarterly. The most recent exercise (2024-Q3) simulated a compromised admin credential leading to unauthorized export of 1,200 users' email + phone. Lessons learned: (1) MFA for all admin accounts (now enforced — V3-SECURITY-MODEL.md §4), (2) audit log alerting on bulk export queries (now implemented).

### 5.1 ECA notification template

The T+72h notification to the ECA uses this template (Amharic + English, in written form):

```
To: Ethiopian Communications Authority — Personal Data Protection Directorate
From: [CEO name], Smart Home Ethiopia PLC
Date: [T+72h]
Re: Personal Data Breach Notification per PDPP Art. 33

1. Nature of the breach: [description, e.g., "Unauthorized database access
   via compromised admin credential resulting in exfiltration of 1,200
   user records containing email and phone numbers."]

2. Data categories affected: [from §1 inventory, e.g., "Email addresses,
   phone numbers (E.164 format). No payment data, no password hashes,
   no device telemetry was exposed."]

3. Approximate number of data subjects: [e.g., "1,200 users, all B2C
   segment, all located in Addis Ababa."]

4. Approximate number of records: [e.g., "1,200 rows from the users table."]

5. Likely consequences: [e.g., "Risk of phishing targeting affected emails;
   risk of unsolicited SMS to affected phones. No risk of account takeover
   as password hashes were not exposed."]

6. Measures taken or proposed: [e.g., "(a) Compromised admin credential
   rotated; (b) MFA enforcement on all admin accounts; (c) Affected users
   notified with password-reset mandate; (d) Cloudflare WAF rule added to
   block the source IP; (e) Audit log alerting added for bulk export queries;
   (f) Penetration test scheduled for [date]."]

7. Contact for further information: [DPO name, email, phone]

Signed: [CEO name], [title], Smart Home Ethiopia PLC
```

### 5.2 User notification template

The T+72h notification to affected users (sent via email + in-app banner) uses this template (Amharic + English):

```
Subject: [Amharic] ስለ መረጃ ጥሰት ማሳወቂያ  //  [English] Notice of Data Incident

Dear [user display name],

We are writing to inform you of a data incident that may have affected
your personal information held by Smart Home Ethiopia (SHE).

What happened: [plain-language description]

What data was involved: [specific to this user, e.g., "Your email address
  abebe@example.et and phone number +251911234567."]

What we are doing: [measures taken per §5.1 template item 6]

What you should do: [specific actions, e.g., "Change your SHE password at
  she.et/settings/security. Be cautious of phishing emails claiming to
  be from SHE — we will never ask for your password."]

For more information: contact our Data Protection Officer at
  dpo@she.et or +251 11 6XX XXXX.

We sincerely apologize for this incident and are committed to
  preventing its recurrence.

Sincerely,
[CEO name], CEO, Smart Home Ethiopia PLC
```

---

## 6. Lawful basis for processing

PDPP Art. 6 requires a lawful basis for every processing operation. SHE relies on three bases:

| Lawful basis | Applies to (data types from §1) | Specific processing | Withdrawal mechanism |
|---|---|---|---|
| **Contractual necessity** (Art. 6(1)(b)) | Email, password hash, phone, push token, home/device names, device MAC, telemetry, energy readings | Provision of the smart home service the user signed up for. Without email/password we cannot authenticate; without push token we cannot send notifications the user requested; without telemetry/energy we cannot display the dashboard. | User closes account → all contractual-necessity processing stops (subject to retention in §1) |
| **Consent** (Art. 6(1)(a)) | Profile photo, marketing email, push notifications, product analytics | All four are **off by default** and require explicit opt-in. User can withdraw consent at any time without losing core service. | `PUT /api/v3/users/me/consent` — toggle each independently |
| **Legal obligation** (Art. 6(1)(c)) | Audit log entries, payment records, factory audit log | Retention is mandated by Ethiopian tax law (payments, 7 years), PDPP Art. 32 (security logs, 2 years compressed + 7 years CSV archive), and ECA type approval (factory audit, 10 years). These records cannot be deleted on user request even if the user requests erasure (see §2 exceptions). | Cannot be withdrawn — retention is legally mandated |

**Special category data (PDPP Art. 9):** SHE does **not** process any special category data (racial/ethnic origin, political opinions, religious beliefs, health data, biometric data for identification). Voice audio for the SHE-R16 wake word is processed **on-device only** (Picovoice Porcupine + Rhino run locally on the ESP32-S3 — V3-VOICE-MATTER.md §1) and is never transmitted to the cloud.

### 6.1 Automated decision-making (PDPP Art. 24)

SHE does not engage in solely-automated decision-making that produces legal or similarly significant effects on data subjects. The closest automated processing is:

- **Energy budget alerts:** If a user sets an energy budget and consumption exceeds 90% of budget, an automated alert is sent. This is informational only and has no effect on service (the user's devices continue to operate).
- **Failed-payment account suspension:** If a B2B tenant's payment fails for 7 consecutive days, the subscription is auto-suspended (per V3-PAYMENTS.md §4). Devices continue to operate (safety — we do not turn off lights); only user login is suspended. A human reviews the suspension before any permanent termination.
- **Fraud + abuse rate-limiting:** IP addresses making >100 failed login attempts in 5 minutes are auto-blocked at the Cloudflare WAF. This is reversible — the user can contact support to have the block lifted.

None of these constitute Art. 24 automated decision-making with significant effects. A DPIA review is triggered if any new automated processing is added that approaches the Art. 24 threshold.

---

## 7. Cross-references

- **V3-DPIA.md** — full Data Protection Impact Assessment, including risk analysis for each data type and subprocessor (required reading alongside this document)
- V3-SECURITY-MODEL.md — technical controls (RLS, mTLS, X.509, MFA, encryption at rest)
- V3-API-SPECIFICATION.md §11 — API endpoints for data subject rights (data export, deletion, consent management)
- V3-FACTORY-OPS.md §8 — factory audit log (10-year retention, cert revocation)
- V3-PAYMENTS.md — Chapa integration, payment data flow
- ADR-008 — Ethio Telecom Cloud hosting decision
- ADR-003 — Postgres Row-Level Security for multi-tenant isolation

---

## 8. Review cadence

- **Annual review** of this document by Lead Engineer + DPO (when hired).
- **Triggered review** on any of: new subprocessor added, new data type collected, architecture change affecting data flow, material change to PDPP or subordinate regulation, breach incident.
- **Versioning** follows the worklog convention (semver: minor for clarification edits, major for substantive changes).

### 8.1 Review checklist

At each annual review, the reviewer confirms:

- [ ] §1 PII inventory still matches the actual Postgres schema (no new tables or columns added without update here)
- [ ] §3 data residency still accurate (no new subprocessors added)
- [ ] §4 subprocessor inventory matches actual vendor list (check accounting / procurement records)
- [ ] §5 breach response contacts (CEO name, ECA email) still current
- [ ] §6 lawful basis still applicable to all processing operations
- [ ] All DPAs with subprocessors are still in force (renewal dates checked)
- [ ] V3-DPIA.md still in sync with this document (any new risk in DPIA §3 should be reflected here)
- [ ] Any breach incidents in the past 12 months have been reflected in lessons-learned

### 8.2 Audit and assurance

External audit:
- **Annual PDPP compliance audit** by an Ethiopian-licensed auditor (target: 2025-Q4, after first full year of operation). Scope: this document + V3-DPIA.md + V3-SECURITY-MODEL.md technical controls + subprocessor DPAs.
- **ECA Type Approval** includes a data-protection review component (V3-HARDWARE.md §8.3).

Internal audit:
- **Quarterly access-review:** Lead Engineer reviews all admin accounts (who has access, is it still needed) and removes unused accounts.
- **Quarterly cert audit:** Lead Engineer reviews all X.509 device certs issued, confirms none are expired or orphaned (factory_audit_log integrity check per V3-FACTORY-OPS.md §8).
- **Monthly audit log review:** Lead Engineer samples 20 audit log entries per month, verifies each represents a legitimate action.

---

## 9. Contact

| Role | Contact | Purpose |
|---|---|---|
| Data Protection Officer (interim) | Lead Engineer, dpo@she.et, +251 11 6XX XXXX | Data subject requests, subprocessor coordination, breach response |
| Privacy inbox | privacy@she.et | Public-facing inbox for data subject requests (auto-routes to DPO) |
| ECA — Personal Data Protection Directorate | per ECA published contacts | Regulator notifications (breach, complaints) |

---

## References

- Personal Data Protection Proclamation No. 1232/2021, Federal Democratic Republic of Ethiopia
- Ethiopian Communications Authority (ECA) — Type Approval Framework
- Cloudflare Data Processing Addendum — https://www.cloudflare.com/gdpr/
- Google Firebase Data Processing Terms — https://firebase.google.com/support/privacy
- Apple Developer Agreement — https://developer.apple.com/terms/
- Chapa merchant agreement (internal, on file)
- Ethio Telecom Cloud DPA (internal, on file)
