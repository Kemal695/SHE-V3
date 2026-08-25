# V3 — Admin Web App (Next.js Console)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Mobile/Frontend Engineer

---

## 0. Scope

This document defines the admin web console for SHE V3 — a Next.js 16 application hosted at `admin.she.et` (platform-level, SUPER_ADMIN + PLATFORM_ADMIN) and `{tenant}.she.et/admin` (tenant-level, TENANT_ADMIN + TENANT_INSTALLER + TENANT_VIEWER). Per ADR-009, dark-mode is the default.

> **Two corrections from the original V3-ADMIN-WEB-APP.md (Proposed):**
>
> 1. **`/ca` row removed** — the original doc had a self-contradictory entry: "`/ca` (cert management) | Not used in V3 (replaced by /ca for cert management)". This made no sense (it claimed `/ca` was replaced by `/ca`). The `/ca` route is removed entirely from the admin console; CA management lives in the Spring Boot internal tooling (CLI / API only) and is documented in V3-CONFIGURATION.md §4 + V3-ADMIN-PLATFORM.md §3.8.
>
> 2. **Screen count reduced from 16 to 9** — the original claimed "16 pages" but the table had 18 rows, and many were redundant (device management, OTA, Matter DAC, homes, users/{id}, ota/new, ota/{id} were all duplicates of functionality better served by EMQX Dashboard or Spring Boot internal tools). The corrected console has **9 screens**, focused on platform administration that is unique to the admin role.

---

## 1. Tech stack

| Component | Version | Why |
|---|---|---|
| Next.js | 16 (App Router) | Server components, server actions, edge runtime for middleware |
| React | 19 | Concurrent rendering, `use()` hook for async data |
| TypeScript | 5.5+ | Type safety end-to-end |
| Tailwind CSS | 4 | Styling |
| shadcn/ui | latest | Component library (Radix UI primitives) |
| TanStack Query | 5.x | Client-side data fetching + cache |
| Recharts | 2.x | Billing + energy charts |
| Auth | HTTP-only cookies (no localStorage) | Per V3-SECURITY-MODEL.md §1.4 |
| Deployment | Vercel-compatible Node hosting (Ethio Telecom Cloud) | Docker container, Node 20 runtime |
| Dark mode | Default (ADR-009) | Deep Navy `#0B1D37`, Bright Sky Blue `#56B4FA` |

---

## 2. Screens (9 — reduced from 16)

| # | Route | Purpose | Roles |
|---|---|---|---|
| 1 | `/login` | Login with email + password + MFA (TOTP) | All |
| 2 | `/dashboard` | Overview: Spring Boot health + EMQX cluster status + total device count + tenant count + billing MRR summary | All |
| 3 | `/tenants` | SUPER_ADMIN — list + create + suspend + terminate tenants | SUPER_ADMIN |
| 4 | `/tenants/{id}` | SUPER_ADMIN — tenant detail + branding config editor + plan change + API key management | SUPER_ADMIN |
| 5 | `/users` | User management (scoped to tenant via RLS) — list, search, filter by role | TENANT_ADMIN + |
| 6 | `/audit-log` | Searchable audit log with filters (event type, actor, date range) + CSV export (≤ 100k rows) | TENANT_ADMIN + |
| 7 | `/billing` | TENANT_ADMIN — invoices, payments, MRR chart, download invoices | TENANT_ADMIN + |
| 8 | `/feature-flags` | Feature flag toggles (per-tenant + global) | SUPER_ADMIN + TENANT_ADMIN |
| 9 | `/settings` | Profile + password change + MFA management | All |

### 2.1 What was removed (and why)

| Removed screen | Where it lives now | Why |
|---|---|---|
| `/users/{id}` (user detail) | Folded into `/users` (drawer/modal) | One screen for list + detail is faster than two routes |
| `/homes` + `/homes/{id}` | Spring Boot internal tool (admin API only) | Homes are managed by users via the mobile app, not admins |
| `/devices` + `/devices/{id}` | EMQX Dashboard (live MQTT state) + Spring Boot admin API (cert info) | Device-level operations belong in operational tooling, not the admin console. EMQX Dashboard at `https://she.et:18083` already shows live device connections, subscriptions, message rates. |
| `/ota` + `/ota/new` + `/ota/{id}` | Spring Boot internal CLI / API | OTA batch creation is a scripted operation done by the firmware team, not a daily admin task. Surface via `/api/admin/ota/*` and a CLI tool. |
| `/ca` (cert management) | Spring Boot internal CLI + admin API | CA operations (intermediate rotation, CRL generation) are runbook procedures (V3-OPS-RUNBOOK.md), not interactive admin UI. |
| `/ca` (duplicate row) | Removed — was self-contradictory | See §0 above |

### 2.2 What stays where (cross-ref)

- **Device live state** → EMQX Dashboard at `https://she.et:18083` (mTLS-protected, admin-only)
- **OTA batch management** → Spring Boot CLI: `./she-ota create --sku R8 --version 1.5.0 --rollout 10%`
- **CA rotation** → step-ca CLI: `step ca root ... && step ca intermediate ...` (per V3-OPS-RUNBOOK.md §6)
- **Matter DAC issuance** → Spring Boot CLI (V3.1, when Matter ships)

---

## 3. Screen specs

### 3.1 `/login`
- Email + password + MFA (TOTP 6-digit code)
- After MFA verify: HTTP-only cookies set (`she_admin_access` 15 min + `she_admin_refresh` 8 h)
- Branded per tenant (logo + colors from `tenants.branding_config`)
- Rate-limited: 5 failed attempts per email per 5 min → `RATE_LIMIT_LOGIN` (V3-ERROR-CODES.md)

### 3.2 `/dashboard`
- Top row: 4 KPI cards
  - Spring Boot health (UP/DOWN, last check timestamp)
  - EMQX cluster health (3-node status, connection count)
  - Total devices (count, online %)
  - Billing MRR (current month, trend arrow)
- Middle: alerts feed (last 10 SEV-1/2 incidents from audit log)
- Bottom: tenant count + B2C user count + recent tenant signups

### 3.3 `/tenants` (SUPER_ADMIN only)
- Table: name, subdomain, plan, status, device count, MRR, created_at
- Actions: Create new tenant (modal), suspend, terminate
- Filters: by status (TRIAL/ACTIVE/SUSPENDED/TERMINATED), by plan
- Search: by name or subdomain

### 3.4 `/tenants/{id}` (SUPER_ADMIN only)
- Tabs: Overview | Branding | API Keys | Audit Log | Billing
- **Overview**: tenant info, plan, status, device count, user count, MRR
- **Branding**: edit `branding_config` JSONB (form: app name, logo URL, primary color, support email/phone). Primary color picker rejects indigo/blue-purple hues.
- **API Keys**: list + revoke + create new (B2B-1000+ only)
- **Audit Log**: tenant-scoped audit events (RLS)
- **Billing**: invoice history + mark-paid (manual bank transfer)

### 3.5 `/users`
- Table: email, name, platform_role, tenant_role, last_login, status
- Drawer (click row): user detail + role change + disable + enable + impersonate + delete
- Filters: by role (platform + tenant), by status, by tenant (SUPER_ADMIN only)
- Impersonation: generates 15-min impersonation JWT (V3-ADMIN-PLATFORM.md §3.4)

### 3.6 `/audit-log`
- Table: timestamp, event_type, actor (user or API key), target, details (JSONB)
- Filters: event_type (multi-select), actor (email or API key name), date range
- CSV export (max 100,000 rows per export) — `GET /api/admin/audit-log/export?...`
- 2-year retention (V3-DATABASE-DESIGN.md §2, V17 migration)

### 3.7 `/billing` (TENANT_ADMIN +)
- KPI cards: current MRR, outstanding balance, next invoice date
- Table: invoices (date, amount, status: PAID/PENDING/OVERDUE, download PDF)
- "Mark paid" action for manual bank-transfer reconciliation
- MRR chart (12-month trend, Recharts line chart)

### 3.8 `/feature-flags`
- Table: flag name, description, current state (on/off), scope (global or per-tenant)
- Toggle on/off (PUT `/api/admin/feature-flags/{flag}`)
- Examples of flags: `voice_enabled`, `energy_anomaly_alerts`, `matter_commissioning_v3_1`, `family_plan_visible`

### 3.9 `/settings`
- Profile: name, email (read-only), phone
- Password change (requires current password + MFA code)
- MFA management: enroll TOTP (QR code), regenerate backup codes, disable MFA (requires SUPER_ADMIN approval if user is SUPER_ADMIN)

---

## 4. Auth model

Per V3-SECURITY-MODEL.md §1.4 — HTTP-only cookies, no localStorage tokens:

1. **Login** → server action `POST /api/v3/auth/login` → sets HTTP-only cookies (`she_admin_access` 15 min + `she_admin_refresh` 8 h for TENANT_ADMIN+, 4 h for SUPER_ADMIN)
2. **Middleware** checks access cookie on every request; if expired, tries refresh; if refresh expired, redirect to `/login`
3. **Server-side API client** reads cookies via `next/headers` (async in Next.js 16) and forwards to Spring Boot with `Cookie:` header
4. **Logout** → clears cookies + calls `POST /api/v3/auth/logout` to revoke refresh token (`jti` blacklisted in Redis)

**CSRF protection:** All state-changing server actions require a CSRF token in the `X-CSRF-Token` header, set as a non-HTTP-only cookie on login and rotated every 24 hours.

**Session timeout:** Idle timeout 30 min (configurable per tenant). Activity (any request) resets the timer.

---

## 5. White-label tenant portal

Each tenant gets their own admin portal at `{tenant}.she.et/admin`:
- Branded login page (tenant logo + colors from `tenants.branding_config`)
- Their users, devices, billing only (RLS scoped — `current_setting('app.tenant_id')`)
- Their audit log (RLS scoped)
- Their feature flags (per-tenant overrides)
- **No access to:** `/tenants` (SUPER_ADMIN only), `/dashboard` platform-wide metrics (they see tenant-scoped dashboard instead), other tenants' data (RLS blocks)

Platform-level admin (`admin.she.et`) sees all tenants — full `/dashboard` + `/tenants` access.

---

## 6. Build + deploy

```bash
# Local dev
cd admin-web
cp .env.example .env.local
npm ci
npm run dev  # → http://localhost:3000

# Production build
npm run build
npm run start  # → port 3000, behind Nginx

# Docker
docker build -t she-admin-web:1.4.2 .
docker run -d -p 3000:3000 --name admin-web she-admin-web:1.4.2
```

CI/CD: GitHub Actions builds + pushes Docker image to registry; Ethio Telecom Cloud deploys via docker-compose with health check on `http://localhost:3000/api/health`.

---

## 7. References

- V3-ADMIN-PLATFORM.md §3 — admin REST API endpoints (called by this console)
- V3-SECURITY-MODEL.md §1 — JWT auth + cookie model
- V3-SECURITY-MODEL.md §2 — 10-role RBAC (which screens each role sees)
- V3-DESIGN-SYSTEM.md — design tokens (Deep Navy + Bright Sky Blue, NO indigo/blue-purple)
- V3-CONFIGURATION.md §4 — CA management (replaces the removed `/ca` screen)
- V3-OPS-RUNBOOK.md §6 — CA rotation procedure (CLI-based, not UI)
- ADR-009 — dark-mode-first decision
