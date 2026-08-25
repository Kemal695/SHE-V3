# V3 — Support & RMA

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Customer Support Lead
**Cross-references:** V3-HARDWARE.md (hardware warranty scope), V3-UNIT-ECONOMICS.md §7.4 (RMA cost sensitivity), V3-B2B-WHITELABEL.md §4 (B2B-UNLIMITED SLA), V3-FACTORY-OPS.md §9 (recovery + quarantine), V3-OPS-RUNBOOK.md (incident escalation), V3-API-SPECIFICATION.md §10 (notification + support endpoints)

---

## 0. Document purpose

This document defines the post-sale customer experience for SHE V3: warranty terms, support tiers and SLAs, the RMA (Return Merchandise Authorization) process, RMA cost model, escalation matrix, and knowledge base. The goal is to deliver **predictable, locally-supported customer service** that is a competitive moat against imported Tuya/Sonoff products (which have no local support — V3-GO-TO-MARKET.md §6.2).

All SLA clocks run in **East Africa Time (EAT, UTC+3)** unless explicitly noted. Business hours are 9:00 AM – 6:00 PM EAT, Monday through Saturday. Sunday is non-business hours except for B2B-UNLIMITED customers (24/7 SLA).

---

## 1. Warranty terms

### 1.1 Hardware warranty

| Scope | Coverage | Duration | Exclusions |
|---|---|---|---|
| Manufacturing defects (component failure, solder joint failure, PCB trace break) | Free repair or replacement | **24 months** from purchase date (per original retail receipt) | See §1.3 |
| Firmware defects (causing device instability) | Free OTA update | Life of product (until End-of-Support, see §1.2) | |
| Enclosure defects (cracking, warping under normal use) | Free replacement enclosure | 12 months | |

### 1.2 Software support lifecycle

| Phase | Duration | What's included |
|---|---|---|
| Active support | 36 months from product launch | Feature updates, security patches, bug fixes, OTA updates |
| Maintenance support | 24 months after Active ends | Security patches + critical bug fixes only; no new features |
| End-of-Support | 60 months after Active ends | No further updates; device continues to function with last firmware |
| End-of-Life | After End-of-Support | Device may be remotely disabled (with 90-day notice) if it poses a security risk |

### 1.3 Warranty exclusions

The 24-month hardware warranty does **not** cover:

| Exclusion | Why | Recommended prevention |
|---|---|---|
| Water damage (submersion, heavy rain ingress) | Enclosure is IP54 (splash-resistant, not waterproof) | Install indoors or in weather-protected enclosure; do not install outdoors without additional IP65+ housing |
| Physical impact (dropped, crushed, hit by tool) | Enclosure is ABS plastic, not impact-rated | Mount out of reach of children + tools |
| Unauthorized modification (firmware replaced, enclosure opened, soldering on PCB) | Voids Secure Boot chain-of-trust; cannot verify integrity | Use only SHE-provided firmware; do not open enclosure (warranty void sticker) |
| Lightning surge (overvoltage from mains) | Beyond MOV rating (275V MOV clamps typical surges; direct lightning strike exceeds any protection) | Install UPS + surge protector at distribution board; use grounded outlet |
| Overcurrent (load exceeds 10A per relay channel) | Beyond relay rating | Verify load amps before connecting; do not stack high-draw appliances on one channel |
| Improper wiring (mains connected to wrong terminal) | User installation error | Use certified electrician for first install; refer to wiring diagram in quick-start card |
| Use outside rated voltage (110V grid, or >260V) | Component stress | Designed for 220V/50Hz Ethiopian grid only |
| Cosmetic wear (scratches, discoloration) | Normal wear-and-tear | — |
| Battery (not applicable — no battery in SHE devices) | n/a | n/a |

### 1.4 Warranty claim requirements

To file a warranty claim, the customer must provide:
1. Original purchase receipt (retail receipt or Chapa transaction ID)
2. Device serial number (laser-etched on enclosure, format: `SHE-R8-2024-00142`)
3. Description of defect + photos/videos
4. Date of first failure

SHE may, at its discretion, request the device be returned for inspection (RMA process per §3).

### 1.5 Warranty transfer

Warranty is tied to the device serial number, not the original purchaser. If a SHE device is resold (used market), the warranty continues for the remaining duration from the original purchase date, provided the new owner can provide the original receipt or proof of the device's first activation date (verifiable via factory audit log — V3-FACTORY-OPS.md §8).

---

## 2. Support tiers

### 2.1 Tier 0 — Self-service

| Channel | Audience | Coverage | Content |
|---|---|---|---|
| In-app help center | All users (B2C + B2B) | 24/7 | Searchable FAQ, troubleshooting flows, video tutorials (Amharic + English), wiring diagrams, energy monitoring explainer, automation recipes |
| she.et/help | Public web | 24/7 | Same content as in-app, indexed by Google for SEO |
| YouTube channel | Public | 24/7 | Installation videos, feature walkthroughs, customer testimonials, "Day in the Life" demos |
| Telegram channel (public) | All users | Community-moderated, SHE staff check 9-9 EAT | User-to-user help; SHE staff intervene only when community cannot resolve |
| Quick-start card (in box) | Hardware purchasers | Always available | 1-page wiring + first-boot guide in Amharic + English |

**Goal:** 60% of all support issues resolved at Tier 0 (no human intervention).

### 2.2 Tier 1 — Chat support

| Attribute | Value |
|---|---|
| Channels | Telegram bot (`@SHEsupport_bot`), in-app chat widget |
| Audience | All users (B2C Free + Premium + Family, B2B-100) |
| Coverage | 9:00 AM – 9:00 PM EAT, 7 days/week |
| Response SLA | <2 hours (median ~15 minutes) |
| Resolution SLA | <24 hours for non-hardware issues |
| Staffing | 1 support agent (months 3-9), 2 support agents (months 10+) |
| Tools | Helpscout or Freshchat (under evaluation); access to user's device telemetry (with user consent via in-app permission grant); ability to trigger OTA reflash; ability to issue RMA numbers |
| Languages | Amharic (primary), English (secondary) |

**Tier 1 responsibilities:**
- Diagnose connectivity issues (Wi-Fi RSSI, MQTT connection, broker reachability)
- Guide users through provisioning (BLE pairing, QR code scan)
- Explain features (automations, scenes, energy monitoring)
- Trigger OTA reflash for firmware issues
- Issue RMA numbers for confirmed hardware faults
- Escalate to Tier 2 for phone-based or complex technical issues

### 2.3 Tier 2 — Phone support

| Attribute | Value |
|---|---|
| Channels | Phone (+251 11 6XX XXXX — final number assigned at GA), scheduled callback |
| Audience | Premium + Family + B2B-100 + B2B-1000 customers |
| Coverage | 9:00 AM – 6:00 PM EAT, Monday – Saturday |
| Response SLA | <4 hours (callback within 4h of request) |
| Resolution SLA | <48 hours for non-hardware issues |
| Staffing | 1 senior support engineer (Lead Engineer backup during launch) |
| Languages | Amharic, English, Oromo (if hire is bilingual) |

**Tier 2 responsibilities:**
- All Tier 1 responsibilities
- Phone-based troubleshooting (walking customer through wiring + configuration)
- Complex automation / scene configuration
- Multi-device issues (whole-home not responding)
- B2B-1000 tenant admin support
- Escalate to Tier 3 for field visit or Engineering for bug investigation

### 2.4 Tier 3 — Field service

| Attribute | Value |
|---|---|
| Channels | On-site visit (Addis Ababa + 30km radius) |
| Audience | B2B-UNLIMITED customers + Premium/Family customers with field-service add-on (500 ETB/visit) |
| Coverage | 48-hour SLA in Addis Ababa (B2B-UNLIMITED); 7-day SLA for field-service add-on |
| Response SLA | <24 hours (visit scheduled within 24h of dispatch) |
| Resolution SLA | <48 hours on-site for B2B-UNLIMITED; on-site resolution for field-service add-on |
| Staffing | 1 field service engineer (contractor model); 2 by month 12 |
| Languages | Amharic (primary) |

**Tier 3 responsibilities:**
- All Tier 2 responsibilities
- Physical inspection of install (wiring, mounting, environmental)
- On-site hardware replacement (RMA processed after)
- B2B-UNLIMITED on-site emergency response
- New B2B deployment supervision (commissioning visit)

### 2.5 Support tier matrix (by customer segment)

| Segment | Tier 0 | Tier 1 (chat) | Tier 2 (phone) | Tier 3 (field) |
|---|---|---|---|---|
| B2C Free | ✓ | — | — | — (paid add-on only) |
| B2C Premium | ✓ | ✓ | ✓ | — (paid add-on: 500 ETB/visit) |
| B2C Family | ✓ | ✓ | ✓ (priority queue) | — (paid add-on: 500 ETB/visit) |
| B2B-100 | ✓ | ✓ | ✓ (priority queue) | — (paid add-on) |
| B2B-1000 | ✓ | ✓ | ✓ (priority queue) | — (paid add-on) |
| B2B-UNLIMITED | ✓ | ✓ (24/7) | ✓ (24/7) | ✓ (48h SLA, included) |

---

## 3. RMA process

### 3.1 Standard RMA flow (B2C + B2B-100 + B2B-1000)

```
Step 1: User reports issue via app
   → In-app: "Report a problem" form
   → Captures: device serial, issue category, description, photos/videos
   → Routes to Tier 1 chat queue

Step 2: Tier 1 diagnoses remotely (target: <2h response, <24h resolution)
   → Tier 1 reviews device telemetry (last 7 days):
       • RSSI trend (Wi-Fi issue?)
       • Reset reason history (firmware crash?)
       • Relay feedback circuit status (relay welding?)
       • PZEM readings (sensor failure?)
   → Tier 1 attempts remote fixes:
       • OTA reflash (latest stable firmware)
       • Re-send MQTT credentials
       • Factory reset (with user permission)
       • Re-provision Wi-Fi (BLE re-pair)

Step 3: If hardware fault confirmed (cannot resolve remotely)
   → Tier 1 issues RMA number (format: RMA-2024-00142)
   → RMA record created in Postgres `rma_tickets` table:
       • rma_number, device_serial, customer_id, issue_category, tier1_diagnosis,
         status=ISSUED, created_at, sla_due_at
   → Customer chooses return method:
       Option A: Ship to SHE HQ (Bole address, customer pays shipping both ways
                  if outside warranty; SHE pays if in-warranty)
       Option B: Drop-off at retail partner (Bole or Sarbet; free for in-warranty)

Step 4: HQ receives unit
   → Logged in `rma_tickets` (status=RECEIVED)
   → Tested within 48 hours (Tier 2 or Hardware Lead):
       • Visual inspection (water damage, impact, modification — exclusions per §1.3)
       • Power-on test
       • Full factory QC test (V3-HARDWARE.md §7.3, 10-test 90s cycle)
       • Compare against reported issue

Step 5: Resolution (within 48h of receipt)
   → If confirmed manufacturing defect + in-warranty:
       • Repair (component-level) OR replace with refurbished unit OR replace with new unit
       • Resolution decision based on cost: <50% of BOM = repair; >50% = replace
       • Customer data (device config) restored from cloud to replacement unit
       → status=RESOLVED, resolution_type=REPAIR/REPLACE/REFURBISH
   → If user damage (exclusion applies):
       → Customer notified, repair quote provided (typically $10-25)
       → Customer approves → repair → return shipment
       → Customer declines → unit returned as-is (customer pays shipping)
       → status=CUSTOMER_DECLINED
   → If no fault found:
       → Unit returned with diagnostic report
       → Customer charged $5 diagnostic fee (waived for Premium + B2B)
       → status=NO_FAULT_FOUND

Step 6: Return shipment (3-5 business days in Addis Ababa)
   → Unit shipped via local courier (DHL Ethiopia or local equivalent)
   → Tracking number provided to customer
   → Customer confirms receipt
   → status=CLOSED, closed_at=NOW()
```

**Total RMA turnaround (in Addis Ababa, in-warranty):** 5-7 business days
- 1 day: customer ships
- 1-2 days: HQ receives + logs
- 48 hours: testing + resolution
- 1-2 days: return shipment + delivery

**Out of Addis Ababa (Adama, Bahir Dar, Hawassa):** +3-5 days each way for shipping = 11-17 business days total.

### 3.2 B2B-UNLIMITED RMA flow (field replacement)

```
Step 1: Tenant admin reports issue via dedicated B2B-UNLIMITED hotline
   → Routes directly to Tier 3 field engineer (skip Tier 1/2)

Step 2: Field engineer dispatches within 24 hours
   → On-site within 48 hours (Addis Ababa) / 5 business days (other cities)

Step 3: Field diagnosis + replacement
   → If hardware fault confirmed on-site: replace with spare unit from field engineer's stock
   → Old unit taken back to HQ for post-mortem
   → RMA number issued AFTER replacement (different from standard flow)
   → status=FIELD_REPLACED, replaced_at=NOW()

Step 4: HQ post-mortem
   → Returned unit tested as in Step 4-5 above
   → If manufacturing defect: refurbish + return to field engineer's stock
   → If user damage: bill tenant per B2B-UNLIMITED contract terms (typically 50% of new unit cost)
   → If no fault found: return to field stock + debrief with tenant admin (root cause was config, not hardware)
```

**B2B-UNLIMITED RMA turnaround:** 24-48 hours on-site (Addis Ababa).

### 3.3 RMA database schema

```sql
CREATE TABLE rma_tickets (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    rma_number      VARCHAR(20) UNIQUE NOT NULL,  -- "RMA-2024-00142"
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    user_id         UUID REFERENCES users(id),     -- nullable for orphaned devices
    device_serial   VARCHAR(30) NOT NULL,           -- "SHE-R8-2024-00142"
    node_id         UUID REFERENCES nodes(id),
    issue_category  VARCHAR(30) NOT NULL,           -- RELAY_FAULT, WIFI, POWER, OTA, OTHER
    issue_description TEXT NOT NULL,
    tier1_diagnosis TEXT,
    tier2_diagnosis TEXT,
    status          VARCHAR(20) NOT NULL DEFAULT 'ISSUED',
        -- ISSUED, RECEIVED, IN_TEST, RESOLVED, NO_FAULT_FOUND,
        -- CUSTOMER_DECLINED, FIELD_REPLACED, CLOSED
    resolution_type VARCHAR(20),                    -- REPAIR, REPLACE, REFURBISH, NONE
    resolution_notes TEXT,
    customer_shipping_cost_etb DECIMAL(10,2),
    she_repair_cost_usd DECIMAL(10,2),
    sla_due_at      TIMESTAMPTZ NOT NULL,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    received_at     TIMESTAMPTZ,
    resolved_at     TIMESTAMPTZ,
    closed_at       TIMESTAMPTZ
);

CREATE INDEX idx_rma_status ON rma_tickets(status);
CREATE INDEX idx_rma_device ON rma_tickets(device_serial);
CREATE INDEX idx_rma_tenant ON rma_tickets(tenant_id);
```

The RMA table is retained for 7 years (financial record-keeping — repair costs are deductible business expenses).

### 3.4 Cert handling during RMA

If a unit is replaced (not repaired), the old unit's X.509 device certificate must be revoked via the step-ca CRL (Certificate Revocation List) and the EMQX cluster must reload the CRL. This prevents a malicious actor from reusing a "broken" unit's cert to access the MQTT broker. See V3-FACTORY-OPS.md §9 (recovery) and V3-SECURITY-MODEL.md (cert lifecycle).

The replacement unit gets a new cert (new MAC, new CN) — it does **not** inherit the old unit's cert. This is by design: certs are bound to MAC, and MAC is bound to physical hardware.

---

## 4. RMA cost model

### 4.1 Assumed RMA rate

| SKU | Assumed RMA rate (first 24 months) | Industry benchmark |
|---|---|---|
| SHE-R4 | 1.5% | Consumer electronics: 1-3% |
| SHE-R8 | 2.0% | |
| SHE-R16 | 2.5% | Slightly higher due to complexity (more relays, more sensors, voice module) |
| **Blended** | **2.0%** | Mid-range of consumer electronics benchmarks |

**Source:** Consumer electronics industry RMA rate benchmarks (Statista 2023, ITIF 2022). SHE uses 2.0% as the conservative reserve basis.

### 4.2 Per-RMA cost breakdown

| Cost line | In-warranty (SHE pays) | Out-of-warranty (customer pays) |
|---|---|---|
| Inbound shipping (customer → HQ) | $1.50 (Addis Ababa local courier) | $1.50 (customer) |
| Diagnostic labor (Tier 2, 1 hour) | $5 (loaded labor cost) | $5 (charged as diagnostic fee, waivable) |
| Repair parts (if repairable) | $2 (typical: relay swap, optocoupler, fuse) | $2 |
| Refurbish parts (if refurbishable) | $4 (PCB touch-up, enclosure swap) | $4 |
| Replacement unit (if not repairable) | $37.69 (SHE-R8 delivered cost — only if in warranty) | $75 (customer pays retail) |
| Outbound shipping (HQ → customer) | $1.50 | $1.50 (customer) |
| **Average per-RMA cost** | **~$8** (most RMAs are repairable; only ~20% require full replacement) | **$10-15** (customer pays) |

The **$8 average per-RMA cost** is the planning number. It assumes 70% repair, 20% refurbish, 10% replace — which matches consumer-electronics industry averages.

### 4.3 RMA reserve

To accrue for future RMA costs, SHE books a **$0.50 per-unit-sold reserve** as part of COGS (Cost of Goods Sold).

**Calculation:** 2.0% RMA rate × $8 average cost = $0.16/unit expected cost. SHE books $0.50/unit — **3.1x the expected cost** — as a conservative reserve. This covers:
- Higher-than-expected RMA rate (e.g., a bad batch triggers 5% RMA rate)
- Higher-than-expected per-RMA cost (e.g., a parts shortage forces more replacements)
- Shipping cost inflation
- Field service calls for B2B-UNLIMITED (which have higher per-incident cost but are absorbed into the reserve)

**Reserve accounting:**
- Each month, $0.50 × units sold = reserve addition (credit to RMA reserve account, debit to COGS)
- Each RMA event: actual cost is debited from RMA reserve account
- Quarterly review: if reserve balance > 2x trailing-12-month actual RMA cost, reduce future accrual rate to $0.40/unit; if <1x, increase to $0.60/unit

### 4.4 Annual RMA cost projection (at 5,000 units sold/year)

| Line | Value |
|---|---|
| Units sold | 5,000 |
| RMA reserve accrued (5,000 × $0.50) | $2,500 |
| Expected RMA events (5,000 × 2.0%) | 100 |
| Expected actual RMA cost (100 × $8) | $800 |
| **Reserve surplus** | **$1,700** (carried forward to next year's reserve) |

The surplus provides buffer for a bad year (e.g., a defective relay supplier causes 5% RMA rate = 250 RMAs × $8 = $2,000 actual cost; covered by the $2,500 reserve + carried-forward surplus from prior year).

### 4.5 RMA cost sensitivity

Cross-reference: V3-UNIT-ECONOMICS.md §7.4.

| Scenario | RMA rate | Annual RMA cost (5,000 units) | Reserve coverage |
|---|---|---|---|
| Baseline | 2.0% | $800 | $2,500 reserve (3.1x coverage) |
| Stress (4%) | 4.0% | $1,600 | $2,500 reserve (1.6x coverage) |
| Crisis (8%) | 8.0% | $3,200 | $2,500 reserve (0.78x — would consume prior-year surplus) |
| Quality collapse (15%) | 15.0% | $6,000 | $2,500 reserve (0.42x — would require emergency accrual increase) |

The 15% RMA rate scenario is a true quality crisis — at that point, the issue is not the reserve but the underlying manufacturing quality, which would trigger a factory partner review and potentially a recall.

---

## 5. SLA for B2B customers

### 5.1 SLA definitions

- **Response SLA:** Time from ticket creation to first human response (not auto-acknowledgment).
- **Resolution SLA:** Time from ticket creation to issue resolved (device working) or RMA issued.
- **Business hours:** 9:00 AM – 6:00 PM EAT, Monday – Saturday (Sunday excluded unless 24/7 plan).
- **Severity classification:**
  - **Severity 1 (Critical):** All devices in tenant offline; complete service outage; data loss
  - **Severity 2 (Major):** Single device offline; core feature broken (cannot control devices, cannot view energy)
  - **Severity 3 (Minor):** Feature degradation (slow response, missing non-critical feature); how-to questions

### 5.2 SLA matrix

| Plan | Severity 1 | Severity 2 | Severity 3 | Coverage |
|---|---|---|---|---|
| **B2B-100** | Response: 8 business hours<br>Resolution: 48 business hours | Response: 8 business hours<br>Resolution: 5 business days | Response: 1 business day<br>Resolution: 10 business days | Business hours only |
| **B2B-1000** | Response: 4 hours<br>Resolution: 24 hours | Response: 4 business hours<br>Resolution: 2 business days | Response: 4 business hours<br>Resolution: 5 business days | Business hours only |
| **B2B-UNLIMITED** | Response: 1 hour<br>Resolution: 8 hours<br>On-site field dispatch included | Response: 2 hours<br>Resolution: 24 hours | Response: 4 hours<br>Resolution: 3 business days | **24/7** |

### 5.3 SLA credits (B2B-UNLIMITED only)

If SHE misses an SLA, the customer is entitled to a service credit on the next monthly invoice:

| Miss type | Credit |
|---|---|
| Severity 1 response >1 hour | 10% of monthly fee ($200) |
| Severity 1 resolution >8 hours | 25% of monthly fee ($500) |
| Severity 2 response >2 hours | 5% of monthly fee ($100) |
| Severity 2 resolution >24 hours | 15% of monthly fee ($300) |
| 3+ SLA misses in a calendar month | 50% of monthly fee ($1,000) + escalation to Lead Engineer for root cause review |

**SLA exclusions (no credit owed):**
- Customer-caused issues (incorrect config, network outage at customer site, power outage)
- Force majeure (natural disaster, civil unrest, government-mandated internet shutdown)
- Scheduled maintenance (communicated ≥72 hours in advance, performed 1-5 AM EAT Sunday)
- Third-party dependencies (Chapa outage affecting payment feature; Ethio Telecom internet outage)

### 5.4 SLA tracking

SLA clocks are tracked in the `rma_tickets` and `support_tickets` tables:
- `sla_due_at` computed at ticket creation based on severity + plan
- `responded_at`, `resolved_at` timestamps captured
- Daily job reports SLA misses to support lead + Lead Engineer
- Monthly SLA report shared with each B2B tenant admin

---

## 6. Escalation matrix

### 6.1 Tier escalation

```
Tier 0 (self-service) → Tier 1 (chat) → Tier 2 (phone) → Tier 3 (field) → Engineering → Lead Engineer
       ↓                      ↓                  ↓                ↓               ↓              ↓
   Help center            Support           Senior           Field          Backend/      Final
   FAQ, videos            agent             support          engineer       Firmware      authority
                          (Amharic,         engineer         (on-site)      engineers     on product
                          Telegram)         (phone)                         (bug          decisions
                                                                            diagnosis)
```

### 6.2 Escalation triggers

| From → To | Trigger | Time budget |
|---|---|---|
| Tier 0 → Tier 1 | User clicks "Contact support" in help center | Immediate |
| Tier 1 → Tier 2 | Issue not resolved in 24 hours, OR user requests phone support, OR issue is B2B-1000+ tenant | Within 4 hours |
| Tier 2 → Tier 3 | Confirmed hardware fault requiring on-site visit, OR user is B2B-UNLIMITED, OR issue is Severity 1 | Within 24 hours (Tier 3 dispatch) |
| Tier 2 → Engineering | Suspected bug (firmware crash, RLS violation, API 500 error, MQTT broker issue) | Within 4 hours (Engineering ticket created) |
| Engineering → Lead Engineer | Bug affects >1% of fleet, OR security-related, OR SLA at risk for B2B-UNLIMITED | Within 1 hour |
| Any → CEO | Severity 1 outage affecting >25% of fleet, OR media inquiry, OR data breach | Within 1 hour |

### 6.3 Escalation communication

| Audience | Channel | Cadence during Severity 1 |
|---|---|---|
| Affected B2B-UNLIMITED tenant admin | Phone + email + SMS | Every 1 hour until resolved |
| Affected B2B-100/1000 tenant admins | Email + in-app banner | Every 4 hours until resolved |
| All B2C users (if outage is fleet-wide) | she.et/status page + Telegram channel + Twitter | Initial within 30 minutes, updates every 2 hours |
| Internal team | Slack #incidents channel + PagerDuty | Real-time |
| ECA (if PDPP-notifiable breach, V3-PRIVACY-COMPLIANCE.md §5) | Formal written notification | Within 72 hours |

### 6.4 On-call rotation

| Role | On-call schedule | Pager |
|---|---|---|
| Tier 1 support agent | 9 AM – 9 PM EAT, 7 days/week (rotating 5-day shifts) | Telegram |
| Tier 2 senior support engineer | 9 AM – 6 PM EAT, Mon-Sat (after-hours on-call for Sev 1 only) | PagerDuty |
| Backend engineer (on-call) | 24/7 weekly rotation (with Tier 2 backup) | PagerDuty |
| Lead Engineer (final escalation) | 24/7 always | PagerDuty (high urgency) |

---

## 7. Knowledge base

### 7.1 Content scope

The knowledge base (KB) at help.she.et covers the following categories, with the article count target by end of year 1:

| Category | Target article count | Sample articles |
|---|---|---|
| Getting started | 8 | "Unboxing your SHE-R8", "Wiring the SHE-R16 to your distribution board", "First-time setup via BLE", "Connecting to Wi-Fi", "Adding your first device to a room" |
| Installation (electrician-facing) | 12 | "Single-phase vs three-phase wiring", "Load calculation per channel", "Surge protection best practices", "Installation in metal vs plastic enclosure", "Cable routing for FCC compliance" |
| Daily use | 15 | "Creating an automation", "Setting up the 'Away' scene", "Using voice control on SHE-R16", "Sharing a home with family members", "Viewing your energy usage" |
| Troubleshooting | 20 | "Device shows offline — what to check", "Relay not responding to commands", "Wi-Fi disconnects frequently", "PZEM showing 0V", "OTA update failed", "Cannot log in to app", "Push notifications not arriving" |
| Energy monitoring | 8 | "Understanding EEU block tariff", "Reading your energy dashboard", "Setting an energy budget alert", "Comparing this month vs last month", "Exporting energy data" |
| B2B admin guides | 10 | "Onboarding tenant users", "Bulk device import", "Setting API key permissions", "White-label branding configuration", "Billing + invoice download" |
| Account + billing | 7 | "Changing your phone number", "Upgrading from Premium to Family", "Cancelling your subscription", "Data export (PDPP right of access)", "Deleting your account" |
| Voice + Matter | 5 | "Training 'Hey Sheba' wake word", "Setting up Amharic intents", "Connecting SHE to Apple Home (Matter, V3.1)", "Connecting SHE to Google Home (V3.1)" |
| Security + privacy | 5 | "How your data is protected", "Subprocessor list", "PDPP rights explained", "What to do if you suspect unauthorized access", "Audit log explanation" |
| **Total** | **90 articles** | |

Stretch goal: 50+ articles by month 6, 90+ by month 12.

### 7.2 Languages

Each article is written in **both Amharic and English**. The Amharic version is the canonical (original) — English is the translation. This ensures Amharic-first quality and avoids the common pitfall of stilted machine translation.

Where possible, articles include screenshots in both Amharic UI and English UI.

### 7.3 Video tutorials

| Topic | Length | Language | Status |
|---|---|---|---|
| Unboxing + first-time setup | 5 min | Amharic + English subtitles | Filming month 2 |
| Wiring the SHE-R8 | 8 min | Amharic | Filming month 3 |
| Setting up your first automation | 4 min | Amharic + English | Filming month 4 |
| Energy monitoring walkthrough | 6 min | Amharic + English | Filming month 5 |
| Voice control demo (SHE-R16) | 5 min | Amharic | Filming month 6 |
| B2B tenant admin onboarding | 10 min | English | Filming month 7 |

All videos published on YouTube + embedded in the in-app help center.

### 7.4 KB maintenance

- Articles reviewed quarterly for accuracy (firmware updates may change UI)
- New articles added based on Tier 1 support trends — if 5+ tickets on the same topic in a month, write a KB article
- Customer feedback widget on each article (👍 / 👎 + optional comment) — articles with <70% positive rating are revised
- Article versioning tracked in Git (help.she.et repo) — full history of changes

---

## 8. Continuous improvement

### 8.1 Support metrics dashboard

Tracked daily, reviewed weekly with support team:

| Metric | Target | Stretch |
|---|---|---|
| Tier 0 deflection rate (issues resolved without Tier 1) | 60% | 70% |
| Tier 1 first-response time (median) | <2 hours | <30 minutes |
| Tier 1 resolution time (median, non-RMA) | <24 hours | <8 hours |
| Tier 1 escalation rate to Tier 2 | <15% | <10% |
| Tier 2 escalation rate to Engineering | <5% | <3% |
| RMA turnaround (median, Addis Ababa, in-warranty) | <7 business days | <5 business days |
| Customer satisfaction (CSAT) post-resolution | ≥8/10 | ≥9/10 |
| Repeat issue rate (same customer + same device within 30 days) | <5% | <3% |

### 8.2 Quarterly review

Each quarter, the support team produces a report covering:
- Top 10 issues by volume (with KB gap analysis — was there a KB article that should have prevented this?)
- RMA root cause analysis (any pattern? bad supplier batch? firmware regression?)
- SLA performance vs targets (any B2B-UNLIMITED SLA credits issued?)
- Customer satisfaction trends (any segments with lower CSAT? why?)
- Knowledge base performance (article views, deflection rate, feedback)

The report is shared with the Lead Engineer + the engineering team. Material findings result in:
- Firmware bug tickets (if issues are firmware-related)
- Hardware revision proposals (if RMAs point to a recurring hardware weakness)
- KB article additions (if issues are user-confusion-related)
- Process changes (if issues are support-process-related)

### 8.3 Customer feedback loop

- Every closed support ticket triggers a CSAT survey (1-tap, in-app: 😊 😐 😞 + optional comment)
- Every RMA closure triggers a longer survey (5 questions: timeliness, communication, resolution quality, would-you-recommend, free-text)
- Monthly: 5 random customers (mix of B2C Premium + B2B) get a 15-minute phone call from the Lead Engineer — qualitative feedback
- Quarterly: NPS-style survey to entire user base (Net Promoter Score: 0-10 likelihood to recommend)

---

## 9. References

- V3-HARDWARE.md §1, §7.3 — hardware warranty scope + factory QC test procedure
- V3-UNIT-ECONOMICS.md §7.4 — RMA cost sensitivity analysis
- V3-B2B-WHITELABEL.md §4 — B2B plan definitions (drives SLA tiers in §5)
- V3-FACTORY-OPS.md §9 — recovery + quarantine procedure (overlaps with §3 RMA process)
- V3-OPS-RUNBOOK.md — incident escalation (overlaps with §6 escalation matrix)
- V3-API-SPECIFICATION.md §10 — notification + support ticket endpoints
- V3-PRIVACY-COMPLIANCE.md §2 — PDPP data subject rights (informs §7.1 KB articles on privacy)
- V3-SECURITY-MODEL.md — cert lifecycle (relevant to §3.4 cert handling during RMA)
- ISO 9001:2015 — Quality Management (SHE targets certification by 2025-Q4)
- ITIL v4 — Service Management framework (informal adoption, not full certification)
