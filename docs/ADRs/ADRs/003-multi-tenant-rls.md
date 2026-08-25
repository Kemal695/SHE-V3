# ADR-003: Multi-Tenant Isolation via Postgres Row-Level Security

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer

## Context

SHE V3 is a B2B platform: ISPs, hotel groups, real-estate developers, and white-label resellers each buy a tenant, and within that tenant they provision homes, devices, and users. A single shared Postgres cluster must serve all tenants, but each tenant's data must be cryptographically and operationally isolated — a tenant admin querying `SELECT * FROM nodes` must never see another tenant's devices, even if the application layer has a bug.

The classic approaches to multi-tenant isolation are: (1) shared database, shared schema, filtered by `tenant_id` in application code (fragile — one missed WHERE clause leaks data); (2) shared database, schema-per-tenant (better isolation, but schema migrations must run N times); (3) database-per-tenant (strongest isolation, but operational cost grows linearly with tenant count); (4) shared database with Postgres Row-Level Security (RLS) policies enforced at the engine level (the application *cannot* bypass the filter even with a bug, because Postgres silently rewrites every query).

For our scale (target: 100 tenants by end of year 2, 1,000 by year 5; no single tenant > 10,000 devices), database-per-tenant is overkill operationally, and schema-per-tenant makes migrations painful. Application-only filtering is unsafe for a B2B platform that will eventually face a security audit. RLS gives us engine-level enforcement with shared-schema simplicity.

## Decision

Use a single shared Postgres 16 database with shared schema and **Postgres Row-Level Security** for tenant isolation. Every tenant-scoped table carries a `tenant_id UUID NOT NULL` column with a btree index. RLS policies are enabled on each table and compare `tenant_id` against the session variable `app.tenant_id`, which Spring Boot sets once per request:

```sql
ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON nodes
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

Spring Boot sets `app.tenant_id` from the JWT `tenant_id` claim at the start of every request, inside a `SET LOCAL` block scoped to the transaction. Tables that are genuinely cross-tenant (e.g., `device_certs` for cert revocation across the whole fleet, `audit_log` for platform admins) are exempt from RLS and instead protected by application-layer RBAC (V3-SECURITY-MODEL.md §2).

The PLATFORM_ADMIN and SUPER_ADMIN roles use `BYPASSRLS` (set per-session via a privileged Spring Boot service account) to read across tenants for support — but never for writes; writes are always scoped to a single tenant via the standard `app.tenant_id` path.

## Alternatives Considered

### Alternative A: Schema-per-tenant (one Postgres schema per tenant)
- **Pros:** Stronger isolation — a `pg_dump` of one schema exports one tenant cleanly; per-tenant backup/restore granularity; a tenant's data can be physically relocated by `pg_dump | psql`.
- **Cons:** Every migration runs N times (N = tenant count); Flyway/Liquibase gets slow at scale; cross-tenant queries (platform admin dashboards, fleet-wide cert revocation) require `UNION ALL` across schemas or a separate analytics replica; connection pool sizing must account for `search_path` complexity; bug-prone when an engineer forgets to switch `search_path` before querying. **Rejected — operational tax too high for our scale.**

### Alternative B: Database-per-tenant (one Postgres cluster per tenant)
- **Pros:** Maximum isolation — physical, contractual, and audit-defensible; per-tenant backup, per-tenant PITR, per-tenant encryption keys possible; a tenant can be sold the database itself as part of an exit/on-prem deployment.
- **Cons:** Cost scales linearly with tenant count — 100 tenants × 1 Postgres cluster each = 100 HA pairs = ~$8k/month hosting at Ethio Telecom pricing; connection pooling across clusters is complex; cross-tenant analytics requires ETL into a separate warehouse; migrations run on N clusters; on-call complexity explodes. **Rejected for V3 — revisit only if a single tenant's data-volume or compliance requirement demands it (e.g., a government tenant with a contractual on-prem clause).**

### Alternative C: Application-layer filtering only (no RLS, just `WHERE tenant_id = ?`)
- **Pros:** Simplest implementation; no Postgres-level policy complexity; debuggable queries; ORM-friendly (Hibernate/Tyk don't fight RLS).
- **Cons:** Unsafe — one missed `WHERE` clause, one unfiltered JPA repository method, one raw-SQL query and a tenant sees another tenant's data; fails any B2B security audit; no defense-in-depth; a single SQL injection in any endpoint bypasses all isolation. **Rejected — the entire point of B2B is that this can never happen.**

### Alternative D: Postgres RLS + per-tenant encrypted columns (column-level encryption)
- **Pros:** Defense-in-depth — even a DBA with `SELECT` access cannot read PII without the per-tenant key.
- **Cons:** Massive complexity — key management per tenant, query planning becomes opaque, indexes on encrypted columns impossible, performance penalty on every PII read. **Deferred — revisit in V4 if a specific tenant demands it contractually.**

## Consequences

### Positive
- One shared schema, one migration path, one connection pool — operations stay simple as tenants grow from 1 to 1,000
- Engine-level enforcement: even if Spring Boot has a missing-`WHERE` bug, Postgres silently filters the result — defense-in-depth at no application cost
- Cross-tenant queries (platform admin dashboards, fleet OTA, cert revocation) work naturally with `BYPASSRLS` for the privileged service account
- Audit story is defensible — a security reviewer can read the RLS policies and confirm isolation is enforced at the engine, not the application
- RLS plays well with Postgres 16 features we already use: TimescaleDB hypertables, JSONB, partial indexes

### Negative
- ~5% query overhead on tenant-scoped tables (measured: a `SELECT * FROM nodes WHERE home_id = ?` with RLS adds ~0.2 ms at 100k rows) — acceptable for our query patterns
- Risk of misconfigured policy — if a future table is added without `ENABLE ROW LEVEL SECURITY`, it silently becomes cross-tenant readable. Mitigation: CI check that asserts every table in `tenants` schema has RLS enabled
- `BYPASSRLS` is a footgun — if the privileged service account is ever used for a tenant-scoped write, isolation is bypassed. Mitigation: privileged account is read-only by policy; all writes go through the tenant-scoped path
- No per-tenant backup granularity — `pg_dump` produces the whole shared database; restoring a single tenant requires a logical filter on restore. Mitigation: nightly logical export per tenant via `pg_dump --table=...` with a `WHERE tenant_id = ?` script
- Postgres `SET LOCAL` must be called inside the transaction — if a Spring Boot method annotates `@Transactional(readOnly = true)` but does not actually open a transaction (common bug), `app.tenant_id` is not set and the query fails closed (good) or returns nothing (confusing)
- Hibernate / JPA may emit queries outside the application-managed transaction (e.g., lazy-loading after the controller returns) — these queries run without `app.tenant_id` set and either fail or return cross-tenant data. Mitigation: Open Session in View is disabled; all data access is in the service layer

### Neutral
- RLS is a Postgres-specific feature — if we ever migrate to another RDBMS (MySQL, CockroachDB, Yugabyte), this ADR forces a re-architecture. We accept this lock-in because Postgres 16 + TimescaleDB is the chosen stack for the foreseeable future (V3-ARCHITECTURE.md §3)
- The 10-role RBAC model in V3-SECURITY-MODEL.md §2 layers on top of RLS, not instead of it — RLS is the data-plane filter, RBAC is the action-plane filter
- The performance overhead of RLS (~5% on tenant-scoped queries) is measurable but immaterial at our query volumes; at 10× the scale (100k devices) we would revisit index strategy but not the isolation model
- Cross-tenant analytics (platform admin dashboards, fleet-wide OTA targeting, cert-revocation sweeps) require the privileged `BYPASSRLS` service account — this is a deliberate escape hatch, audited and read-only by policy
- The "one shared database" choice is the conceptual inverse of the "one tenant per database" choice — both are defensible, but for our scale (100s of tenants, not 10s) shared-with-RLS is the right call

## References
- V3-SECURITY-MODEL.md §2 (10-role RBAC layered on top of RLS)
- V3-DATABASE-DESIGN.md §3 (every tenant-scoped table has `tenant_id` + RLS policy)
- V3-B2B-WHITELABEL.md (tenant onboarding, per-tenant branding, per-tenant billing)
- V3-PRIVACY-COMPLIANCE.md (tenant isolation as a PDPP control)
- ADR-001 (self-hosted cloud — Postgres runs in our own DC, no RDS managed alternative)
- ADR-008 (Addis Ababa hosting — where this Postgres cluster physically lives)
- V3-ARCHITECTURE.md §3 (Postgres 16 + TimescaleDB stack, sizing)
- V3-DPIA.md (tenant isolation as a personal-data-protection control)
