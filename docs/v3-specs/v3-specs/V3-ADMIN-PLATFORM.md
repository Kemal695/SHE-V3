# V3 — Admin Platform (Roles, Endpoints, Audit)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Lead Engineer + Backend Engineer

---

## 0. Scope

V3 has three admin layers: **platform-level** (SUPER_ADMIN, PLATFORM_ADMIN), **tenant-level** (TENANT_ADMIN, TENANT_INSTALLER, TENANT_VIEWER), and **home-level** (OWNER, ADMIN, MEMBER, GUEST). This document covers platform + tenant admin roles, admin REST API surface, impersonation, and audit logging.

> **Update from original V3-ADMIN-PLATFORM.md (Proposed):**
> - Cross-references updated to point to the corrected V3-ADMIN-WEB-APP.md (9 screens, reduced from 16)
> - Cross-references updated to point to V3-SECURITY-MODEL.md (10 roles — was "8" in some original docs)
> - `/admin/ca/*` endpoints retained here as the Spring Boot API surface (the admin web `/ca` screen was removed — CA ops are now CLI/runbook procedures per V3-OPS-RUNBOOK.md §6)

---

## 1. Platform roles

Per V3-SECURITY-MODEL.md §2.1 — 3 platform-level roles:

| Role | Scope | Capabilities |
|---|---|---|
| `USER` | Own home (B2C) | Default for B2C users. Full CRUD on own home + devices + scenes + automations. No admin access. |
| `PLATFORM_ADMIN` | All tenants (read-only) | Read-only across all tenants for support/audit. Cannot create tenants or modify data. Can impersonate users for support. |
| `SUPER_ADMIN` | Platform | Everything — create tenants, manage admins, rotate CA, force-logout, impersonate, global OTA batches, terminate tenants. |

## 2. Tenant roles

Per V3-SECURITY-MODEL.md §2.2 — 3 tenant-level roles:

| Role | Scope | Capabilities |
|---|---|---|
| `TENANT_ADMIN` | Tenant | Manage tenant's users, devices, billing, branding. Cannot manage other tenants. Can impersonate tenant users. |
| `TENANT_INSTALLER` | Tenant | Provision devices via BLE, assign to homes. No billing or user management. |
| `TENANT_VIEWER` | Tenant | Read-only access to tenant's devices + telemetry + audit logs. |

## 3. Home roles

Per V3-SECURITY-MODEL.md §2.3 — 4 home-level roles (scoped to a single home via `home_members` join table):

| Role | Scope | Capabilities |
|---|---|---|
| `OWNER` | One home | Full control + can invite/remove members + can delete home + can transfer ownership |
| `ADMIN` | One home | Control devices + scenes + automations + invite members (cannot remove OWNER or delete home) |
| `MEMBER` | One home | Control devices + trigger scenes (cannot edit automations or manage members) |
| `GUEST` | One home | Limited device control (subset of devices selected by ADMIN) + scheduled access |

**Total: 10 roles** (3 platform + 3 tenant + 4 home). This corrects the "8 roles" inconsistency in the original V3 draft.

---

## 4. Admin REST API

Base path: `/api/admin/*`. Requires `platform_role` ∈ {`PLATFORM_ADMIN`, `SUPER_ADMIN`} OR `tenant_role` ∈ {`TENANT_ADMIN`, `TENANT_INSTALLER`, `TENANT_VIEWER`}. JWT must be valid + MFA-verified (for SUPER_ADMIN and TENANT_ADMIN).

### 4.1 Tenant management (SUPER_ADMIN only)

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/tenants` | List all tenants (paginated, filterable by status/plan) |
| POST | `/admin/tenants` | Create tenant (name, subdomain, plan, branding) |
| GET | `/admin/tenants/{id}` | Tenant detail (metrics: device count, user count, MRR) |
| PUT | `/admin/tenants/{id}/branding` | Update branding config (rejects indigo/blue-purple primary colors) |
| PUT | `/admin/tenants/{id}/status` | Suspend / terminate / reactivate tenant |
| GET | `/admin/tenants/{id}/audit-log` | Tenant-scoped audit log (RLS enforced) |

### 4.2 User management (TENANT_ADMIN+)

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/users` | List users (scoped to tenant via RLS; SUPER_ADMIN can list across tenants) |
| GET | `/admin/users/{id}` | User detail |
| PATCH | `/admin/users/{id}/role` | Change tenant_role (TENANT_ADMIN → TENANT_INSTALLER, etc.) |
| POST | `/admin/users/{id}/disable` | Disable account (login blocked; devices still work) |
| POST | `/admin/users/{id}/enable` | Re-enable |
| DELETE | `/admin/users/{id}` | Delete + anonymize (cascade per V3-PRIVACY-COMPLIANCE.md — personal data wiped, audit log retained with `actor_user_id = NULL`) |
| POST | `/admin/users/{id}/reset-mfa` | Reset MFA (forces re-enrollment on next login) — SUPER_ADMIN only |

### 4.3 Device management (TENANT_ADMIN+)

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/devices` | All tenant devices (paginated) |
| GET | `/admin/devices/{id}` | Device detail + cert info (serial, fingerprint, status) |
| POST | `/admin/devices/{id}/quarantine` | Block commands (compromised device — relay stays in last state for safety, but no new commands accepted) |
| POST | `/admin/devices/{id}/unquarantine` | Release quarantine |
| DELETE | `/admin/devices/{id}` | Force-delete + revoke cert via step-ca CRL |
| GET | `/admin/devices/{id}/cert` | View cert details (serial, issuer, valid_from, valid_to, fingerprint) |
| POST | `/admin/devices/{id}/revoke-cert` | Revoke device cert (updates CRL; EMQX blocks within 6 h on next CRL refresh) |

> **Note:** Live device state (online/offline, current parameter values) is NOT in this admin API — that lives in the EMQX Dashboard at `https://she.et:18083` (mTLS-protected). This admin API covers lifecycle management only.

### 4.4 Impersonation (TENANT_ADMIN+)

| Method | Path | Notes |
|---|---|---|
| POST | `/admin/impersonate/{userId}` | Generate 15-min impersonation JWT (same scopes as target user) |
| DELETE | `/admin/impersonate` | End impersonation (returns to admin JWT) |

Impersonation JWTs carry an `impersonated_by` claim (the admin's user_id). All actions taken during impersonation are audit-logged with BOTH the admin user_id and the target user_id. The mobile app shows a yellow banner: "You are impersonating {target user}. [End session]".

**Restrictions:**
- Cannot impersonate while already impersonating (no chains) → `RBAC_IMPERSONATION_CHAIN` error
- SUPER_ADMIN can impersonate any user across any tenant
- TENANT_ADMIN can only impersonate users in their own tenant (RLS enforced)
- Impersonation JWTs have 15-min TTL (shorter than normal 15-min access — actually the same, but the banner makes it clear)

### 4.5 Audit log (TENANT_ADMIN+)

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/audit-log` | Search: eventType, actorUserId, from, to (paginated, max 10k rows per page) |
| GET | `/admin/audit-log/export` | CSV export (max 100k rows per export; async — returns job_id, email when ready) |

### 4.6 Billing (TENANT_ADMIN+)

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/billing/overview` | MRR, active subscriptions, outstanding invoices, churn rate |
| GET | `/admin/billing/invoices` | List invoices (paginated, filterable by status) |
| GET | `/admin/billing/invoices/{id}` | Invoice detail (line items, payments) |
| POST | `/admin/billing/invoices/{id}/mark-paid` | Manual mark paid (bank transfer reconciliation) — SUPER_ADMIN only |
| GET | `/admin/billing/invoices/{id}/pdf` | Download invoice PDF |

### 4.7 Feature flags (TENANT_ADMIN+)

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/feature-flags` | List all flags + current state + scope (global or per-tenant) |
| PUT | `/admin/feature-flags/{flag}` | Toggle flag (TENANT_ADMIN can toggle per-tenant flags only; SUPER_ADMIN can toggle global) |

Examples of feature flags: `voice_enabled`, `energy_anomaly_alerts`, `matter_commissioning_v3_1`, `family_plan_visible`, `ota_anti_rollback_enforced`.

### 4.8 CA management (SUPER_ADMIN only)

> **Note:** These endpoints exist but are NOT surfaced in the admin web console (V3-ADMIN-WEB-APP.md §2.1 removed the `/ca` screen). They are used by the Spring Boot CLI + runbook procedures (V3-OPS-RUNBOOK.md §6). Documented here for completeness.

| Method | Path | Notes |
|---|---|---|
| GET | `/admin/ca/status` | CA health: root + intermediate cert info (issuer, serial, valid_from, valid_to, fingerprint) |
| GET | `/admin/ca/crl` | Download CRL (Certificate Revocation List) — published at `https://she.et/ca.crl` |
| POST | `/admin/ca/rotate-intermediate` | Initiate intermediate CA rotation (yearly procedure — V3-OPS-RUNBOOK.md §6.1). Async — returns job_id. |
| GET | `/admin/ca/rotation-status/{job_id}` | Check rotation progress |

---

## 5. Audit logging

All admin actions are logged asynchronously to the `audit_log` table with 2-year retention (V3-DATABASE-DESIGN.md §2, V17 migration). Audit log is append-only + hash-chained for tamper detection (V3-PRIVACY-COMPLIANCE.md §6).

### 5.1 Event types

| Event | Fields logged |
|---|---|
| `admin.tenant.created` | actor, tenant_id, name, plan, subdomain |
| `admin.tenant.suspended` | actor, tenant_id, reason |
| `admin.tenant.terminated` | actor, tenant_id, reason, data_export_url |
| `admin.tenant.reactivated` | actor, tenant_id |
| `admin.user.role_changed` | actor, target_user_id, old_role, new_role |
| `admin.user.disabled` | actor, target_user_id, reason |
| `admin.user.deleted` | actor, target_user_id, cascade_summary (rows affected per table) |
| `admin.user.mfa_reset` | actor, target_user_id |
| `admin.device.quarantined` | actor, device_id, reason |
| `admin.device.cert_revoked` | actor, device_id, cert_serial, crl_updated |
| `admin.impersonate.started` | actor, target_user_id, expires_at, ip_address |
| `admin.impersonate.ended` | actor, target_user_id, duration_seconds |
| `admin.ota.batch_created` | actor, batch_id, target_sku, target_version, rollout_percent |
| `admin.ota.batch_paused` | actor, batch_id, reason |
| `admin.ota.batch_aborted` | actor, batch_id, reason |
| `admin.payment.marked_paid` | actor, invoice_id, amount_etb, payment_method |
| `admin.feature_flag.toggled` | actor, flag_name, old_value, new_value, scope |
| `admin.ca.intermediate_rotated` | actor, old_serial, new_serial, old_valid_to, new_valid_to |
| `admin.login.success` | user_id, ip_address, user_agent, mfa_used (bool) |
| `admin.login.failed` | email, ip_address, user_agent, reason (bad_password / mfa_invalid / account_disabled) |

### 5.2 Retention + integrity

- **Retention:** 2 years from `created_at`. Older rows are deleted by nightly `@Scheduled` task (V3-OPS-RUNBOOK.md §8).
- **Integrity:** Each row carries `prev_hash` = SHA-256 of previous row's hash + payload. Tampering with any row breaks the chain — detected by V3-INTEGRATION-TEST-PLAN.md §7.3 test.
- **Export:** CSV export via `/admin/audit-log/export` (max 100k rows, async, emailed).
- **PII:** Audit log contains user IDs + IP addresses (considered PII under PDPP). Retained 2 years per V3-PRIVACY-COMPLIANCE.md §4 — justified as legitimate security interest.

---

## 6. Auth requirements

- All `/api/admin/*` endpoints require a valid JWT with appropriate role claim
- SUPER_ADMIN and TENANT_ADMIN endpoints additionally require MFA-verified session (recent MFA challenge within 15 min for sensitive actions: tenant termination, cert revocation, intermediate rotation, mark-paid)
- Rate-limited: 100 req/min per admin user → `RATE_LIMIT_ADMIN` (V3-ERROR-CODES.md §6)
- All requests audit-logged (including 4xx errors — useful for detecting reconnaissance)

---

## 7. References

- V3-ADMIN-WEB-APP.md §2 — 9 admin screens (UI surface for this API)
- V3-SECURITY-MODEL.md §2 — 10-role RBAC (3 platform + 3 tenant + 4 home)
- V3-SECURITY-MODEL.md §1 — JWT auth + MFA
- V3-B2B-WHITELABEL.md §2 — tenant onboarding flow (uses these endpoints)
- V3-CONFIGURATION.md §4 — step-ca CA setup (underlying these endpoints)
- V3-OPS-RUNBOOK.md §6 — CA rotation runbook (uses `/admin/ca/rotate-intermediate`)
- V3-PRIVACY-COMPLIANCE.md §4 — audit log retention policy + data subject rights
- V3-DATABASE-DESIGN.md §2 (V17) — `audit_log` table migration
- V3-ERROR-CODES.md §2 — `RBAC_*` error codes
- ADR-003 — multi-tenant RLS decision (underlies tenant-scoped endpoints)
- ADR-004 — cert-based MQTT auth (underlies `/admin/devices/{id}/cert` + `/revoke-cert`)
