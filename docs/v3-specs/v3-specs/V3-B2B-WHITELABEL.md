# V3 — B2B White-Label Multi-Tenant Platform

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Backend Engineer

---

## 1. Tenancy model

V3 is a multi-tenant platform. Each tenant (ISP, property developer, hotel chain, solar installer, B2B reseller) gets their own branded instance — white-label app, custom subdomain, isolated user pool, independent billing — while sharing the same underlying physical infrastructure (one Postgres cluster, one EMQX cluster, one Spring Boot deployment).

**Isolation mechanism:** Postgres Row-Level Security (RLS), per ADR-003.

- All tenant-scoped tables carry a `tenant_id UUID` column (FK → `tenants.id`)
- Every RLS policy is `USING (tenant_id = current_setting('app.tenant_id')::uuid)`
- Spring Boot's `TenantContextFilter` sets the `app.tenant_id` session variable on every connection acquired from the pool, derived from the JWT `tenant_id` claim
- A tenant A user querying `SELECT * FROM nodes` automatically sees only their tenant's rows — there is no code path that can return tenant B's data even with a SQL bug, because RLS is enforced at the Postgres layer
- RLS test suite (V3-INTEGRATION-TEST-PLAN.md) verifies cross-tenant queries return 0 rows

**Shared RainMaker hierarchy:** All tenants share the same device data model (Node → Device → Service → Parameter → Attribute per V3-DEVICE-MODEL.md). A tenant's devices are scoped by `nodes.tenant_id`; the hierarchy structure (`node_devices`, `node_params`) is identical across tenants.

### 1.1 Tenant table

```sql
CREATE TABLE tenants (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name              VARCHAR(120) NOT NULL,
    subdomain         VARCHAR(60) UNIQUE NOT NULL,         -- 'ethiotelecom.she.et'
    plan              VARCHAR(20) NOT NULL,                 -- 'B2B-100' | 'B2B-1000' | 'B2B-UNLIMITED'
    status            VARCHAR(20) NOT NULL DEFAULT 'TRIAL', -- TRIAL | ACTIVE | SUSPENDED | TERMINATED
    branding_config   JSONB NOT NULL DEFAULT '{}',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    terminated_at     TIMESTAMPTZ
);
```

---

## 2. Tenant onboarding flow

```
B2B customer signs contract (sales team)
    │
    ▼
Platform admin creates tenant via admin web (`/tenants` → "New Tenant"):
    - name: "Ethio Telecom Smart Home"
    - subdomain: "ethiotelecom"  → ethiotelecom.she.et
    - plan: B2B-1000 (≤1,000 devices, $800/month)
    - branding: app_name, logo_url, primary_color, support_email, support_phone
    │
    ▼
Spring Boot (POST /api/admin/tenants):
    1. INSERT INTO tenants (...) — record created
    2. INSERT INTO users (...) — first TENANT_ADMIN user created with temp password (emailed)
    3. Spring Boot provisions TLS cert for subdomain (via step-ca HTTP API, or via Cloudflare for edge termination)
    4. Sends welcome email to tenant admin with temp password + login link
    │
    ▼
Tenant admin logs in at ethiotelecom.she.et:
    - Sees branded login page (tenant logo + colors)
    - Forced password change on first login
    - MFA enrollment required (TOTP — Google Authenticator / Authy)
    │
    ▼
Tenant admin creates sub-users:
    - TENANT_INSTALLER (provisions devices via BLE, assigns to homes)
    - TENANT_VIEWER (read-only access for property managers)
    │
    ▼
Device onboarding:
    - BLE provisioning (single device) — V3-MOBILE-APP.md §4
    - Bulk import (CSV upload of MAC addresses → pre-registered in `nodes` table for installer claim)
    - API-based registration for B2B-1000+ tenants (POST /api/v3/tenant/devices with API key)
    │
    ▼
Tenant admin manages:
    - Homes + rooms + members
    - Automations + scenes
    - Billing (invoices, payment method, MRR chart)
    - Audit log (their tenant's events only — RLS scoped)
```

---

## 3. White-label branding

Each tenant configures branding via `tenants.branding_config` JSONB:

```json
{
  "app_name": "Ethio Telecom Smart Home",
  "logo_url": "https://storage.she.et/tenants/ethiotelecom/logo.png",
  "primary_color": "#0066CC",
  "login_bg_url": "https://storage.she.et/tenants/ethiotelecom/login-bg.jpg",
  "domain": "ethiotelecom.she.et",
  "support_email": "smart@ethiotelecom.et",
  "support_phone": "+251911234567",
  "primary_language": "am"
}
```

### 3.1 Branding restrictions

The Flutter app reads branding config on login and dynamically applies app name, logo, primary color, and login background. However:

- **Primary color must NOT be indigo or blue-purple** (per V3-DESIGN-SYSTEM.md system rule). Tenant admins selecting indigo/blue-purple (`#4F46E5`, `#6366F1`, `#7C3AED`, `#8B5CF6` and similar hues) are blocked at the form-validation layer with the message: "This hue is reserved for the SHE platform. Please choose a different brand color."
- Allowed overrides: logo, app name, subdomain, login background, support contact
- Non-overridable: typography (Inter + Noto Sans Ethiopic), iconography (Lucide), layout (Bento grid), micro-interactions
- B2C users (no `tenant_id`) get the default SHE branding (Deep Navy + Bright Sky Blue)

### 3.2 Tenant portal URL scheme

- Platform admin: `https://admin.she.et` (SUPER_ADMIN + PLATFORM_ADMIN)
- Tenant admin: `https://{tenant}.she.et/admin` (TENANT_ADMIN + TENANT_INSTALLER + TENANT_VIEWER)
- B2C users: `https://app.she.et` (no admin portal — they use the Flutter mobile app only)

Cloudflare terminates TLS for all `*.she.et` subdomains; cert provisioning is automated via step-ca (V3-CONFIGURATION.md §4).

---

## 4. Pricing model

> **Family plan added** — the original V3-B2B-WHITELABEL.md was missing the Family plan (it was in V3-PAYMENTS.md but not here). Corrected below.

### 4.1 B2C plans (consumer)

| Plan | Price (ETB/mo) | Price (USD/mo, ~55 ETB/$) | Devices | Features |
|---|---|---|---|---|
| **B2C Free** | 0 | $0 | Up to 10 | Basic control (on/off), local control, no automations, no OTA, no energy |
| **B2C Premium** | 150 ETB | ~$2.73 | Unlimited | All features: automations, scenes, OTA, energy monitoring, anomaly alerts |
| **B2C Family** | 300 ETB | ~$5.45 | Unlimited | Premium + 5 home members + shared homes + priority support (Tier 1 → 2 → Eng escalation) |

B2C users pay via Telebirr/CBE Birr in the mobile app (Chapa checkout, instant activation).

### 4.2 B2B plans (commercial)

| Plan | Devices | Price/mo (USD) | Price/mo (ETB, ~55 ETB/$) | Features |
|---|---|---|---|---|
| **B2B-100** | ≤ 100 | $100 | ~5,500 ETB | All features, 1 tenant admin, no API access |
| **B2B-1000** | ≤ 1,000 | $800 | ~44,000 ETB | All features, 5 admins, API access, white-label branding |
| **B2B-UNLIMITED** | Unlimited | $2,000+ | ~110,000 ETB+ | All features, unlimited admins, SLA (99.5% uptime), dedicated support |

B2B billing is monthly, auto-invoiced on the 25th of each month. Payment via Chapa (Telebirr/CBE Birr) or bank transfer (large B2B). 7-day grace period before SUSPENDED.

### 4.3 Plan change + proration

- B2C: upgrade/downgrade takes effect immediately; next billing cycle charges the new rate. Mid-cycle upgrades: prorated credit applied to next invoice.
- B2B: plan changes take effect at the start of the next billing cycle (no mid-cycle upgrades — prevents billing complexity). Device count overage: if a B2B-100 tenant adds device 101, the system blocks provisioning with `TENANT_QUOTA_EXCEEDED` (V3-ERROR-CODES.md) and emails the tenant admin to upgrade.

---

## 5. API access for B2B integrations

Tenants on B2B-1000 and B2B-UNLIMITED plans get API keys for integration with their own systems (property management software, energy dashboards, custom apps):

```
POST /api/v3/tenant/api-keys
   Authorization: Bearer <tenant admin JWT>
   Body: { "name": "PMS integration", "scopes": ["devices:read", "energy:read"] }
   → Returns: { "api_key": "she_live_8a3b1c2e...", "expires_at": "2025-12-31T..." }

GET  /api/v3/tenant/devices?api_key=she_live_...
   → List all devices (RLS scoped to tenant_id)

POST /api/v3/tenant/devices/{id}/command?api_key=she_live_...
   Body: { "Power": true }
   → Send command (audit-logged)

GET  /api/v3/tenant/energy?api_key=she_live_...&from=2024-12-01&to=2024-12-31
   → Energy data (CSV or JSON)
```

API keys are:
- Scoped to `tenant_id` (RLS enforced)
- Scope-limited (`devices:read`, `devices:write`, `energy:read`, `users:read`)
- Rate-limited (1,000 req/min default; configurable per tenant)
- Revocable by tenant admin via the admin web (`/tenants/{id}` → API keys tab)
- Audit-logged (every API call writes to `audit_log` with `actor = api_key:{name}`)

---

## 6. B2B SLA

B2B-UNLIMITED tenants get a formal Service Level Agreement. B2B-100 and B2B-1000 get a "best-effort" SLA (same operational targets, no contractual penalties).

| Metric | B2B-UNLIMITED target | B2B-1000 target | B2B-100 target |
|---|---|---|---|
| MQTT uptime | 99.5% monthly | 99.5% monthly | Best-effort |
| API p95 latency | < 500 ms | < 500 ms | < 1 s |
| Command latency p95 | < 2 s | < 2 s | < 5 s |
| SEV-1 response | 5 min (24/7) | 15 min (business hours + on-call) | 1 hour (business hours) |
| SEV-1 resolution | 4 hours | 8 hours | Best-effort |
| Monthly support hours | Unlimited (Tier 1 → 2 → Eng) | 8 hours Tier 2 | Email-only Tier 1 |
| Compensation | 10% MRR credit per 1% below 99.5% uptime | None contractual | None contractual |

Cross-ref **V3-SUPPORT-RMA.md §3** for support tier definitions (Tier 1 = customer service, Tier 2 = engineering ticket, Tier 3 = vendor escalation).

---

## 7. Tenant lifecycle

| State | Description | Actions allowed | Transition trigger |
|---|---|---|---|
| `TRIAL` | First 30 days free, up to 10 devices | All features (full preview) | 30 days elapsed OR tenant upgrades → `ACTIVE` |
| `ACTIVE` | Paid subscription, full device quota per plan | Full access per plan | Payment failed > 7 days → `SUSPENDED`; contract ended → `TERMINATED` |
| `SUSPENDED` | Payment failed > 7 days | Users cannot login (frontend blocks); devices still work (safety — do not turn off lights); MQTT + automations continue | Payment received → `ACTIVE`; 90 days no payment → `TERMINATED` |
| `TERMINATED` | Contract ended | Read-only data export for 30 days, then data deleted per PDPP | Final state — no return |

On `TERMINATED`:
1. Tenant admin receives 30-day data-export window (CSV download of all devices, telemetry, energy, audit log)
2. After 30 days: `DELETE FROM tenants WHERE id = ?` cascades via FK ON DELETE to all tenant-scoped tables
3. Device certs revoked via step-ca CRL (V3-FACTORY-OPS.md §9)
4. Devices factory-reset on next MQTT reconnect (system service `factory_reset` published by Spring Boot)
5. Final audit-log entry: `admin.tenant.terminated` retained 2 years (per audit retention policy)

---

## 8. Architecture diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    SHE platform (single deployment)         │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────┐  │
│  │ Tenant A        │  │ Tenant B        │  │ B2C users  │  │
│  │ (Ethio Telecom) │  │ (Hotel Chain)   │  │ (no tenant)│  │
│  │ branding: blue  │  │ branding: green │  │ default    │  │
│  └────────┬────────┘  └────────┬────────┘  └─────┬──────┘  │
│           │                    │                  │         │
│           ▼                    ▼                  ▼         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Cloudflare (TLS termination, WAF, geo-block)         │  │
│  └────────────────────┬─────────────────────────────────┘  │
│                       │                                     │
│           ┌───────────┴───────────┐                         │
│           ▼                       ▼                         │
│  ┌─────────────────┐     ┌─────────────────┐               │
│  │ Spring Boot ×2  │     │ EMQX cluster    │               │
│  │ (REST + WS)     │     │ (3 nodes, mTLS) │               │
│  └────────┬────────┘     └────────┬────────┘               │
│           │                       │                         │
│           ▼                       ▼                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Postgres 16 + TimescaleDB                           │  │
│  │  ┌─────────────────────────────────────────────┐     │  │
│  │  │ RLS policy: USING (tenant_id =              │     │  │
│  │  │   current_setting('app.tenant_id')::uuid)   │     │  │
│  │  └─────────────────────────────────────────────┘     │  │
│  │  Every tenant-scoped table carries tenant_id         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Single physical Postgres cluster, logical tenant isolation via RLS.** No per-tenant database, no per-tenant schema — RLS at the row level is the isolation boundary. This keeps operational complexity low (one backup, one migration, one monitoring target) while enforcing hard isolation (Postgres RLS is not bypassable by application bugs).

---

## 9. References

- V3-DEVICE-MODEL.md §6 — `nodes`, `node_devices`, `node_params` tables (all carry `tenant_id`)
- V3-DATABASE-DESIGN.md §1 — RLS policy definition; §2 — V1 migration creates `tenants` table
- V3-SECURITY-MODEL.md §2 — 10-role RBAC (3 platform + 3 tenant + 4 home)
- V3-PAYMENTS.md — Chapa integration, invoice flow, B2C + B2B pricing details
- V3-SUPPORT-RMA.md §3 — support tier definitions for B2B SLA
- V3-ADMIN-WEB-APP.md §2 — `/tenants` and `/tenants/{id}` admin screens
- V3-ADMIN-PLATFORM.md §3.1 — tenant management admin API endpoints
- V3-DESIGN-SYSTEM.md §1.3 — white-label branding overrides (no indigo/blue-purple)
- V3-UNIT-ECONOMICS.md §4 — B2B LTV / CAC model
- ADR-003 — multi-tenant RLS decision
