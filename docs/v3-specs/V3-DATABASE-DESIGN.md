# V3 — Database Design

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Backend Engineer

---

## 1. Purpose

This document defines the canonical PostgreSQL 16 + TimescaleDB schema for the SHE V3 platform. The schema mirrors the **ESP RainMaker device hierarchy** (Node → Device → Service → Parameter → Attribute) defined in `V3-DEVICE-MODEL.md`:

| RainMaker level | Postgres table | Cardinality |
|---|---|---|
| Node (one ESP32 board) | `nodes` | 1 row per physical board |
| Device (logical, user-controllable entity) | `node_devices` | 1-N per node |
| Service (background functionality) | `node_devices` (`device_type LIKE 'esp.service.%'`) | 0-N per node |
| Parameter (controllable/measurable value) | `node_params` | 1-N per device/service |
| Attribute (read-only metadata) | `node_devices.attributes JSONB` | 0-N per device |

**Multi-tenant isolation** is enforced at the database layer via Row-Level Security (RLS) on every tenant-scoped table (ADR-003). Every table carries `tenant_id UUID` and the canonical RLS policy is `USING (tenant_id = current_setting('app.tenant_id')::uuid OR current_setting('app.is_platform_admin', true)::boolean)` (see §8, P0-5 — no `BYPASSRLS` role, no `app.bypass_rls` GUC).

All tables use UUID primary keys (`uuid_generate_v4()`), `TIMESTAMPTZ` timestamps in UTC, and forward-only migrations managed by Flyway.

---

## 2. Migrations (V1 → V28)

V3 migrations are forward-only and never edited after release. V1-V25 establish the legacy flat schema; V26-V28 migrate to the RainMaker hierarchy (see §3 for the new tables).

| # | Migration | Effect |
|---|---|---|
| V1 | `tenants` | Root of multi-tenant hierarchy |
| V2 | `users` | `tenant_id`, `oauth_subject`, MFA fields |
| V3 | `homes` | `tenant_id` FK |
| V4 | `rooms` | `tenant_id` FK |
| V5 | `device_types` | Lookup table seeded with SHE-R4/R8/R16 + sensor types |
| V6 | `devices` *(legacy — dropped in V28)* | Original flat table with `reported_state` / `desired_state` JSONB |
| V7 | `home_members` | Multi-tenant RBAC (OWNER / ADMIN / MEMBER / GUEST) |
| V8 | `automations` + `automation_rules` | Triggers, conditions, actions |
| V9 | `scenes` + `scene_actions` | Grouped actions |
| V10 | `node_groups` + `node_group_members` | Logical device groups (renamed `groups` → `node_groups`) |
| V11 | `notification_preferences` + `notification_log` | Per-user per-category mute |
| V12 | `user_devices` | FCM / APNs push token registration |
| V13 | `ota_batches` + `ota_approvals` | Self-hosted OTA orchestration |
| V14 | `payments` + `subscriptions` | Telebirr / Chapa billing |
| V15 | `oauth_identities` | GitHub / Google OAuth linkage |
| V16 | `blacklisted_tokens` | JWT refresh token rotation |
| V17 | `audit_log` | All admin actions, 2-year Postgres retention + 7-year CSV archive (P1-19 — TimescaleDB hypertable, NOT pg_partman; tamper-evident hash chain via `hash`/`prev_hash`/`sequence_number` columns) |
| V18 | `device_ca_certs` | Certificate authority records (own CA, step-ca) |
| V19 | `device_certs` | Per-device issued certs (CN = MAC, serial, status) |
| V20 | `api_keys` | B2B tenant API keys |
| V21 | `feature_flags` | Per-tenant feature toggles |
| V22 | TimescaleDB extension + `device_telemetry` hypertable | Telemetry time series |
| V23 | `device_energy_readings` hypertable | Energy monitoring |
| V24 | `energy_hourly` continuous aggregate | Roll-up view |
| V25 | `energy_daily` continuous aggregate | Roll-up view |
| **V26** | **`nodes` + `node_devices` + `node_params`** | **Creates the RainMaker hierarchy tables — see §3** |
| **V27** | **Backfill from `devices`** | **One `nodes` row + N `node_devices` rows + N×M `node_params` rows per legacy `devices` row (channel count from `device_types` lookup)** |
| **V28** | **Drop legacy `devices` columns + `device_types`** | **Drops `devices.reported_state`, `devices.desired_state`, `devices.device_type_id`, then renames `devices` → `devices_legacy` (kept 90 days for rollback) and finally drops it** |

V26-V28 are run as a single coordinated deployment during a maintenance window (see `V3-OPS-RUNBOOK.md` §migration-runbook). After V28, every API path that previously referenced `devices` reads from `nodes` + `node_devices` + `node_params`.

---

## 3. Core tables (RainMaker hierarchy)

### 3.1 `nodes`

Mirrors the RainMaker **Node** concept — one physical ESP32 board.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | `uuid_generate_v4()` |
| `tenant_id` | UUID FK → tenants | RLS column |
| `home_id` | UUID FK → homes | Nullable during provisioning |
| `room_id` | UUID FK → rooms | Nullable |
| `node_id` | VARCHAR(64) UNIQUE | `SHE-R8-AABBCC` (our naming — see `V3-DEVICE-MODEL.md` §2.2) |
| `mac_address` | VARCHAR(17) UNIQUE | Colon-separated, uppercase |
| `normalized_mac` | VARCHAR(12) UNIQUE | Lowercase, colons removed (for MQTT lookup) |
| `sku` | VARCHAR(20) | `SHE-R4` / `SHE-R8` / `SHE-R16` |
| `name` | VARCHAR(100) | User-assigned, default = `node_id` |
| `firmware_version` | VARCHAR(50) | Current firmware version (reported via MQTT `config` payload) |
| `hardware_revision` | VARCHAR(20) | `rev-a` / `rev-b` / `rev-c` |
| `cert_serial` | VARCHAR(64) | X.509 cert serial number |
| `cert_fingerprint` | VARCHAR(64) | SHA-256 of DER cert (EMQX auth backend lookup) |
| `is_online` | BOOLEAN | Updated via MQTT LWT (retained `status` topic) |
| `last_seen_at` | TIMESTAMPTZ | Heartbeat timestamp |
| `provisioned_at` | TIMESTAMPTZ | When cert was claimed |
| `created_at` | TIMESTAMPTZ | |
| `deleted_at` | TIMESTAMPTZ | Soft delete |

**Indexes:** `(tenant_id, home_id) WHERE deleted_at IS NULL`, `normalized_mac UNIQUE`, `cert_fingerprint`, `(tenant_id, is_online) WHERE deleted_at IS NULL`

### 3.2 `node_devices`

Mirrors the RainMaker **Device** concept — a logical, user-controllable entity ("Kitchen Light") or background service ("OTA").

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `tenant_id` | UUID FK → tenants | RLS column (denormalized for fast filtering) |
| `node_id` | UUID FK → nodes | ON DELETE CASCADE |
| `device_name` | VARCHAR(64) | `Relay 1` (matches MQTT payload key — V3-DEVICE-MODEL.md §5) |
| `device_type` | VARCHAR(64) | `esp.device.switch` / `esp.service.ota` / `esp.service.diag` |
| `display_name` | VARCHAR(100) | User-assigned: `Kitchen Light` |
| `channel_index` | SMALLINT | 0-15, maps to GPIO via PCF8574 |
| `attributes` | JSONB | `{"Label": "Kitchen Light", "Channel": "0", "Serial": "SHE-R8-2024-00142"}` |
| `is_service` | BOOLEAN | TRUE if `device_type LIKE 'esp.service.%'` |
| `created_at` | TIMESTAMPTZ | |
| `updated_at` | TIMESTAMPTZ | |

**Indexes:** `(tenant_id, node_id)`, `(node_id, channel_index)`, `UNIQUE (node_id, device_name)`

### 3.3 `node_params`

Mirrors the RainMaker **Parameter** concept — a controllable or measurable value (e.g., `Power` bool, `Brightness` int). The `last_value` column is a cache for fast UI reads without hitting the hypertable.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `tenant_id` | UUID FK → tenants | RLS column (denormalized) |
| `node_id` | UUID FK → nodes | Denormalized for fast filtering |
| `node_device_id` | UUID FK → node_devices | ON DELETE CASCADE |
| `param_name` | VARCHAR(64) | `Power`, `Brightness`, `Temperature` (RainMaker name) |
| `param_type` | VARCHAR(64) | `esp.param.power`, `esp.param.brightness` (RainMaker type URI) |
| `data_type` | VARCHAR(10) | `bool` / `int` / `float` / `string` |
| `ui_hint` | VARCHAR(20) | `toggle` / `slider` / `segmented` / `read_only` (used by mobile app for dynamic UI) |
| `properties` | JSONB | `["read", "write", "persist"]` (PROP_* bitmask in firmware — V3-DEVICE-MODEL.md §4) |
| `min_value` | DOUBLE PRECISION | Nullable — for slider bounds |
| `max_value` | DOUBLE PRECISION | Nullable |
| `last_value` | JSONB | Cached value — `true` / `75` / `"2024-12-01T..."` (updated on every MQTT `params/local` message) |
| `last_reported_at` | TIMESTAMPTZ | When `last_value` was last refreshed from MQTT |
| `created_at` | TIMESTAMPTZ | |

**Indexes:** `UNIQUE (node_device_id, param_name)`, `(tenant_id, node_id)`, `(node_id, param_name)`

**Why `last_value JSONB` instead of typed columns:** Different params have different types (bool/int/float/string). JSONB gives us type-flexibility + a single cache lookup for the dashboard. For typed queries (charts), use the `device_energy_readings` and `device_telemetry` hypertables.

---

## 4. Supporting tables

### 4.1 `tenants`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `name` | VARCHAR(100) | e.g., `Ethio Telecom Smart Home` |
| `subdomain` | VARCHAR(50) UNIQUE | e.g., `ethiotelecom` |
| `plan` | VARCHAR(20) | `B2B-100`, `B2B-1000`, `B2B-UNLIMITED`, `B2C-FREE`, `B2C-PREMIUM`, `B2C-FAMILY` |
| `status` | VARCHAR(20) | `TRIAL`, `ACTIVE`, `SUSPENDED`, `TERMINATED` |
| `branding_config` | JSONB | `{"logo_url": "...", "primary_color": "#0B1D37", "accent_color": "#56B4FA", "app_name": "..."}` — NO indigo/blue palette (see V3-B2B-WHITELABEL.md) |
| `created_at` | TIMESTAMPTZ | |

### 4.2 `users`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `tenant_id` | UUID FK → tenants | |
| `email` | VARCHAR(255) | Unique within tenant |
| `password_hash` | VARCHAR(255) | BCrypt, cost 12 |
| `platform_role` | VARCHAR(20) | `USER`, `PLATFORM_ADMIN`, `SUPER_ADMIN` |
| `tenant_role` | VARCHAR(20) | `TENANT_ADMIN`, `TENANT_INSTALLER`, `TENANT_VIEWER`, NULL |
| `totp_secret_encrypted` | BYTEA | MFA secret (AES-GCM) |
| `oauth_subject` | VARCHAR(200) | GitHub/Google OAuth |
| `oauth_provider` | VARCHAR(20) | `GITHUB`, `GOOGLE` |
| `phone_number` | VARCHAR(20) | `+2519XXXXXXXX` |
| `preferred_language` | VARCHAR(5) | `am` / `en` |
| `created_at` | TIMESTAMPTZ | |
| `deleted_at` | TIMESTAMPTZ | Soft delete |

### 4.3 `homes` + `rooms` + `home_members`

| Table | Key columns | Notes |
|---|---|---|
| `homes` | `id, tenant_id, name, owner_user_id, address, created_at, deleted_at` | One home per physical household |
| `rooms` | `id, tenant_id, home_id, name, icon, sort_order, created_at, deleted_at` | User-customizable rooms |
| `home_members` | `id, tenant_id, home_id, user_id, role, granted_by_user_id, granted_at, revoked_at` | Roles: `OWNER`, `ADMIN`, `MEMBER`, `GUEST` |

### 4.4 `automations` + `automation_rules`

| Table | Key columns | Notes |
|---|---|---|
| `automations` | `id, tenant_id, home_id, name, description, enabled, trigger_config JSONB, created_at` | Top-level automation entity |
| `automation_rules` | `id, automation_id, action_type, action_config JSONB, sort_order` | Actions executed when trigger fires |

`trigger_config` shapes — see `V3-API-SPECIFICATION.md` §5.

### 4.5 `scenes` + `scene_actions`

| Table | Key columns | Notes |
|---|---|---|
| `scenes` | `id, tenant_id, home_id, name, icon, sort_order, created_at, deleted_at` | Grouped actions |
| `scene_actions` | `id, scene_id, node_id, node_device_id, param_name, value JSONB, sort_order` | One row per (device, param) write |

### 4.6 `ota_batches` + `ota_approvals`

| Table | Key columns | Notes |
|---|---|---|
| `ota_batches` | `id, tenant_id, home_id, firmware_version, firmware_url, firmware_checksum, signature_ed25519, target_sku, rollout_percent, auto_approve, status, created_by_user_id, created_at` | Self-hosted OTA via MinIO |
| `ota_approvals` | `id, batch_id, node_id, status, approved_by_user_id, approved_at, deployment_status, progress INT, last_error, updated_at` | Per-node tracking |

### 4.7 `payments` + `subscriptions`

| Table | Key columns | Notes |
|---|---|---|
| `payments` | `id, tenant_id, amount_etb, plan, status, chapa_ref, checkout_url, paid_at, created_at` | Chapa transaction records |
| `subscriptions` | `id, tenant_id, plan, status, started_at, expires_at, payment_id, created_at` | Active subscription per tenant |

### 4.8 `audit_log`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `tenant_id` | UUID | RLS column (nullable for platform-level events) |
| `actor_user_id` | UUID | Nullable (system events) |
| `actor_type` | VARCHAR(20) | `USER`, `TENANT_ADMIN`, `PLATFORM_ADMIN`, `SYSTEM`, `DEVICE` |
| `action` | VARCHAR(50) | `node.create`, `node.command`, `ota.push`, `user.disable`, etc. |
| `target_type` | VARCHAR(20) | `node`, `user`, `tenant`, `home`, `automation` |
| `target_id` | UUID | |
| `details` | JSONB | Before/after diff |
| `ip_address` | INET | |
| `user_agent` | TEXT | |
| `request_id` | UUID | For tracing across services |
| `sequence_number` | BIGINT | Monotonic per-tenant sequence (P1-19, tamper-evidence) |
| `prev_hash` | BYTEA | SHA-256 of the previous row's `hash` (P1-19) |
| `hash` | BYTEA | SHA-256 of (`prev_hash` || canonical JSON of this row) — chain link |
| `created_at` | TIMESTAMPTZ | |

**Retention (canonical, P1-19):** TimescaleDB hypertable (NOT `pg_partman`). 30 days raw + 2 years compressed + 7-year CSV archive (exported to MinIO `she-audit-exports`). The `hash` + `prev_hash` + `sequence_number` columns form a **tamper-evident hash chain** — any in-place modification of an historical audit row breaks the chain and is detectable by a verification job. See §7.

### 4.9 `device_certs` + `device_ca_certs` (factory-issued)

See `V3-FACTORY-OPS.md` and `V3-SECURITY-MODEL.md` §4 for full schema. Key columns: `cert_serial`, `cn` (MAC), `fingerprint`, `issued_at`, `expires_at`, `revoked_at`, `ca_id`.

---

## 5. Time-series tables (TimescaleDB hypertables)

### 5.1 `device_telemetry` (high-frequency)

Per-parameter telemetry — voltage, current, temperature, RSSI, free_heap, etc.

| Column | Type | Notes |
|---|---|---|
| `time` | TIMESTAMPTZ | Hypertable partition column |
| `tenant_id` | UUID | RLS column |
| `node_id` | UUID | FK → nodes |
| `node_device_id` | UUID | FK → node_devices |
| `param_name` | VARCHAR(64) | e.g., `Temperature`, `RSSI` |
| `value` | DOUBLE PRECISION | Numeric telemetry only (bools/strings cached in `node_params.last_value`) |
| `unit` | VARCHAR(10) | `°C`, `dBm`, `bytes` |

```sql
SELECT create_hypertable('device_telemetry', 'time', chunk_time_interval => INTERVAL '1 day');
CREATE INDEX ON device_telemetry (node_id, time DESC);
CREATE INDEX ON device_telemetry (tenant_id, time DESC);
```

### 5.2 `device_energy_readings` (energy monitoring)

Per-node energy readings from PZEM-004T (SHE-R8/R16 only — see `V3-HARDWARE.md` §3.4).

| Column | Type | Notes |
|---|---|---|
| `time` | TIMESTAMPTZ | |
| `tenant_id` | UUID | |
| `node_id` | UUID | FK → nodes (was `device_id` in legacy schema — renamed in V27) |
| `voltage` | DOUBLE PRECISION | Volts |
| `current` | DOUBLE PRECISION | Amps |
| `power_w` | DOUBLE PRECISION | Watts (instantaneous) |
| `energy_wh` | DOUBLE PRECISION | Watt-hours (cumulative) |
| `cost_etb` | DOUBLE PRECISION | Calculated at ingest (Ethiopian block tariff — see `V3-ENERGY-MONITORING.md`) |
| `frequency` | DOUBLE PRECISION | Hz |
| `power_factor` | DOUBLE PRECISION | 0.0-1.0 |

```sql
SELECT create_hypertable('device_energy_readings', 'time', chunk_time_interval => INTERVAL '1 day');
CREATE INDEX ON device_energy_readings (node_id, time DESC);
CREATE INDEX ON device_energy_readings (tenant_id, time DESC);
```

### 5.3 Continuous aggregates

```sql
-- Hourly roll-up
CREATE MATERIALIZED VIEW energy_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    tenant_id, node_id,
    AVG(voltage) AS avg_voltage,
    AVG(current) AS avg_current,
    AVG(power_w) AS avg_power_w,
    MAX(energy_wh) - MIN(energy_wh) AS energy_wh,
    SUM(cost_etb) AS cost_etb
FROM device_energy_readings
GROUP BY bucket, tenant_id, node_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('energy_hourly',
    start_offset => INTERVAL '7 days',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');

-- Daily roll-up
CREATE MATERIALIZED VIEW energy_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', time) AS bucket,
    tenant_id, node_id,
    MAX(energy_wh) AS energy_wh_total,
    SUM(cost_etb) AS cost_etb_total
FROM device_energy_readings
GROUP BY bucket, tenant_id, node_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('energy_daily',
    start_offset => INTERVAL '90 days',
    end_offset   => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day');
```

---

## 6. TimescaleDB compression policy

**This was missing in the original V3 docs and is now mandatory.** Without compression, a 5,000-node fleet publishing energy readings every 5s generates ~43M rows/day (~1.3B rows/month) — TimescaleDB compression reduces storage by 8-12x and improves query performance 3-5x for time-range scans.

```sql
-- Enable compression on energy readings, segmented by node_id
ALTER TABLE device_energy_readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'node_id',
    timescaledb.compress_orderby   = 'time DESC'
);

-- Compress chunks older than 7 days
SELECT add_compression_policy('device_energy_readings', INTERVAL '7 days');

-- Same for telemetry
ALTER TABLE device_telemetry SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'node_id',
    timescaledb.compress_orderby   = 'time DESC'
);

SELECT add_compression_policy('device_telemetry', INTERVAL '7 days');
```

**Why `compress_segmentby = 'node_id'`:** Most queries filter by `node_id` (e.g., "show me energy for this node last week"). Segmenting by `node_id` means the compressor lays out one segment per node per chunk — queries touching a single node only decompress that node's segment.

**`compress_interval` note:** The task spec referenced `compress_interval`, but TimescaleDB 2.x uses `compress_orderby` + `add_compression_policy(older_than)`. The functional intent — "compress chunks once they're 7 days old" — is preserved by `add_compression_policy(..., INTERVAL '7 days')`.

Spring Boot logs every compression run:

```java
@Scheduled(cron = "0 30 2 * * *")  // 2:30 AM daily, after drop_chunks
public void logCompressionStats() {
    Map<String, Object> stats = jdbcTemplate.queryForMap(
        "SELECT * FROM timescaledb_information.compression_settings " +
        "WHERE hypertable_name = 'device_energy_readings'"
    );
    log.info("Compression policy stats: {}", stats);
}
```

---

## 7. Data retention (drop_chunks nightly)

```sql
-- Drop telemetry chunks older than 30 days
SELECT drop_chunks('device_telemetry', INTERVAL '30 days');

-- Drop energy chunks older than 1 year (365 days)
SELECT drop_chunks('device_energy_readings', INTERVAL '365 days');

-- Drop compressed chunks too (drop_chunks only sees uncompressed by default)
SELECT drop_chunks('device_energy_readings', INTERVAL '365 days', cascade_to_materializations => true);
```

Spring Boot runs this nightly via `@Scheduled`:

```java
@Scheduled(cron = "0 0 2 * * *")  // 2 AM daily
public void enforceRetention() {
    jdbcTemplate.queryForObject(
        "SELECT drop_chunks('device_telemetry', INTERVAL '30 days')", Object.class);
    jdbcTemplate.queryForObject(
        "SELECT drop_chunks('device_energy_readings', INTERVAL '365 days', " +
        "cascade_to_materializations => true)", Object.class);
    log.info("Retention executed: telemetry >30d, energy >365d dropped");
}
```

**Audit log retention** is enforced via a **TimescaleDB hypertable** (canonical, P1-19 — NOT `pg_partman` monthly partitioning). Three tiers: 30 days raw, 2 years compressed, 7 years CSV archive in MinIO `she-audit-exports`. The `hash` + `prev_hash` + `sequence_number` columns form a tamper-evident hash chain.

```sql
-- Convert audit_log to a TimescaleDB hypertable (P1-19 — replaces pg_partman monthly partitioning)
SELECT create_hypertable('audit_log', 'created_at', chunk_time_interval => INTERVAL '7 days');

-- Compression: compress chunks older than 30 days (segment by tenant_id for per-tenant verification)
ALTER TABLE audit_log SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'tenant_id',
    timescaledb.compress_orderby   = 'created_at DESC'
);
SELECT add_compression_policy('audit_log', INTERVAL '30 days');

-- Drop raw chunks older than 2 years (compressed chunks are exported to CSV first)
SELECT add_retention_policy('audit_log', INTERVAL '730 days');

-- Tamper-evidence: verify the hash chain nightly (Spring Boot @Scheduled job)
-- For each tenant, walk rows ordered by sequence_number, recompute hash, compare to stored hash.
-- Any mismatch → SECURITY_ALERT event + PagerDuty page.
```

**7-year CSV archive:** Before chunks are dropped by the retention policy, a nightly `@Scheduled` job exports compressed chunks to MinIO `she-audit-exports` (one CSV per tenant per month, schema-stable, gzip-compressed). The CSV archive satisfies the 7-year retention requirement for financial/audit records under PDPP without keeping 7 years of Postgres data online.

---

## 8. Row-Level Security (RLS)

Every tenant-scoped table has RLS enabled with the **canonical policy** (P0-5 — checked by the policy itself, NOT a `BYPASSRLS` role and NOT a fictional `app.bypass_rls` GUC):

```sql
-- Canonical RLS policy (P0-5) — applied to every tenant-scoped table
ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes FORCE ROW LEVEL SECURITY;  -- applies even to table owner

CREATE POLICY tenant_isolation ON nodes
  USING (
    tenant_id = current_setting('app.tenant_id')::uuid
    OR current_setting('app.is_platform_admin', true)::boolean
  );

ALTER TABLE node_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_devices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON node_devices
  USING (
    tenant_id = current_setting('app.tenant_id')::uuid
    OR current_setting('app.is_platform_admin', true)::boolean
  );

ALTER TABLE node_params ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_params FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON node_params
  USING (
    tenant_id = current_setting('app.tenant_id')::uuid
    OR current_setting('app.is_platform_admin', true)::boolean
  );
-- ... applied to: users, homes, rooms, home_members, automations, scenes,
--                 ota_batches, ota_approvals, payments, subscriptions, audit_log
```

**Critical (P0-5):** `FORCE ROW LEVEL SECURITY` ensures the policy applies even to the table owner (the Postgres role Spring Boot uses). **The `she_app` role does NOT need `BYPASSRLS` and does NOT have it.** Platform-admin cross-tenant read-only operations (PLATFORM_ADMIN, SUPER_ADMIN) are handled by setting `SET LOCAL app.is_platform_admin = 'on'` per transaction — the RLS policy itself evaluates this GUC. There is **no** dedicated `app_bypass_rls` role and **no** `app.bypass_rls` GUC. This is safer than `BYPASSRLS` because there is no privilege-escalation path — the bypass is per-transaction, GUC-scoped, and auditable in `pg_stat_statements`.

Spring Boot sets the session variables on every request:

```java
@Component
public class TenantContextInterceptor implements HandlerInterceptor {
    @Override
    public boolean preHandle(HttpServletRequest req, HttpServletResponse resp, Object h) {
        UUID tenantId = ((AuthenticatedUser) SecurityContextHolder.getContext()
            .getAuthentication().getPrincipal()).tenantId();
        jdbcTemplate.execute("SET LOCAL app.tenant_id = '" + tenantId + "'");
        // P0-5: platform-admin bypass is a GUC checked by the policy itself — not a BYPASSRLS role
        boolean isPlatformAdmin = user.hasRole(PLATFORM_ADMIN) || user.hasRole(SUPER_ADMIN);
        jdbcTemplate.execute("SET LOCAL app.is_platform_admin = "
            + (isPlatformAdmin ? "'on'" : "'off'"));
        return true;
    }
}
```

`SET LOCAL` (not `SET`) scopes the variable to the current transaction, preventing leakage across pooled connections. All JPA/JDBC queries auto-filter by `tenant_id` — no risk of cross-tenant data leakage even on a missed `WHERE` clause.

---

## 9. Index strategy (consolidated)

| Table | Index | Purpose |
|---|---|---|
| `users` | `(tenant_id, email) WHERE deleted_at IS NULL` | Login lookup |
| `nodes` | `(tenant_id, home_id) WHERE deleted_at IS NULL` | Dashboard query |
| `nodes` | `normalized_mac UNIQUE` | MQTT connect lookup (EMQX → DB) |
| `nodes` | `cert_fingerprint` | EMQX auth backend lookup |
| `nodes` | `(tenant_id, is_online) WHERE deleted_at IS NULL` | Online-count KPI |
| `node_devices` | `(tenant_id, node_id)` | List devices per node |
| `node_devices` | `UNIQUE (node_id, device_name)` | MQTT payload key lookup |
| `node_params` | `UNIQUE (node_device_id, param_name)` | Cache lookup |
| `node_params` | `(tenant_id, node_id)` | Bulk param fetch for dashboard |
| `device_telemetry` | `(node_id, time DESC)` | Time-series query |
| `device_telemetry` | `(tenant_id, time DESC)` | B2B aggregate reports |
| `device_energy_readings` | `(node_id, time DESC)` | Energy chart query |
| `device_energy_readings` | `(tenant_id, time DESC)` | B2B energy report |
| `audit_log` | `(tenant_id, created_at DESC)` | Audit search |
| `audit_log` | `(actor_user_id, created_at DESC)` | Per-user audit |
| `audit_log` | `(target_type, target_id, created_at DESC)` | Per-entity audit trail |
| `home_members` | `(home_id, user_id) WHERE revoked_at IS NULL` | RBAC chokepoint |
| `payments` | `(tenant_id, created_at DESC)` | Invoice listing |
| `payments` | `chapa_ref UNIQUE` | Webhook idempotency |

**Partial indexes** (`WHERE deleted_at IS NULL`) keep index size proportional to live rows, not historical rows.

---

## 10. Backup + disaster recovery

| Artifact | Frequency | Storage | Retention |
|---|---|---|---|
| Full base backup (pg_basebackup) | Daily 1 AM | Addis Ababa DC + offsite replica (Adama, 160km from Addis Ababa — same Ethiopian Rift seismic zone, known limitation; Dire Dawa DR site is a V3.1 deliverable per P1-18) | 30 days |
| WAL archive (continuous) | Continuous | Both sites | 30 days |
| Logical dump (pg_dump) | Weekly Sunday 3 AM | MinIO bucket `db-backups` | 12 weeks |
| TimescaleDB compressed chunks | Continuous (with chunks) | Same as base backup | Matches retention |

PITR (point-in-time recovery) window: 30 days. RPO: <5 minutes. RTO: <2 hours. See `V3-OPS-RUNBOOK.md` §backup-restoration.

---

## 11. Performance budgets

| Query | Target p95 | Index used |
|---|---|---|
| `GET /api/v3/homes/{id}/nodes` (dashboard) | <50ms | `(tenant_id, home_id)` on `nodes` |
| `GET /api/v3/nodes/{id}` (node detail with devices + params) | <30ms | PK + nested loop on `node_devices`/`node_params` |
| `PUT /api/v3/nodes/{id}/devices/{deviceId}/params` (write) | <80ms | PK lookup + MQTT publish |
| `GET /api/v3/nodes/{id}/telemetry?from=...&to=...` (24h) | <200ms | TimescaleDB chunk skip + compression |
| `GET /api/v3/tenant/energy/report` (monthly aggregate) | <500ms | Continuous aggregate `energy_daily` |
| `EMQX → /internal/mqtt/auth` (per MQTT connect) | <20ms | `cert_fingerprint` index |

---

## 12. References

- `V3-DEVICE-MODEL.md` — RainMaker hierarchy (Node / Device / Service / Param / Attr)
- `V3-API-SPECIFICATION.md` — REST endpoints mapped to these tables
- `V3-SECURITY-MODEL.md` §4 — `device_certs` / `device_ca_certs` schema + X.509 auth
- `V3-MQTT-STANDARDS.md` — topic structure that drives `last_value` cache updates
- `V3-FACTORY-OPS.md` — `device_certs` write path during factory flashing
- `V3-ENERGY-MONITORING.md` — `device_energy_readings` ingest + cost calculation
- `V3-OPS-RUNBOOK.md` §backup-restoration, §migration-runbook, §compression-policy
- ADR-003 — multi-tenancy via Postgres RLS
- ADR-011 — adopting the RainMaker device hierarchy
