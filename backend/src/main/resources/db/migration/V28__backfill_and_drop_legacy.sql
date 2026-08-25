-- =============================================================================
-- SHE V3 — Flyway migration V28: backfill from devices + drop legacy
-- =============================================================================
-- V3-DATABASE-DESIGN §2 (V27+V28 canonical).
-- Coordinate with a maintenance window (V3-OPS-RUNBOOK §migration-runbook).
-- After V28, every API path that previously referenced `devices` reads from
-- nodes + node_devices + node_params.
-- =============================================================================

-- ─── Step 1: Backfill `nodes` from `devices` ───────────────────────────────
INSERT INTO nodes (
    id, tenant_id, home_id, room_id, node_id, mac_address, normalized_mac,
    sku, name, firmware_version, hardware_revision,
    cert_serial, cert_fingerprint, is_online, last_seen_at, provisioned_at,
    created_at, updated_at, deleted_at
)
SELECT
    d.id,
    d.tenant_id,
    d.home_id,
    d.room_id,
    d.node_id,
    d.mac_address,
    LOWER(REPLACE(d.mac_address, ':', '')) AS normalized_mac,
    dt.sku,
    d.name,
    d.firmware_version,
    d.hardware_revision,
    d.cert_serial,
    d.cert_fingerprint,
    d.is_online,
    d.last_seen_at,
    d.provisioned_at,
    d.created_at,
    d.updated_at,
    d.deleted_at
FROM devices d
LEFT JOIN device_types dt ON dt.id = d.device_type_id
ON CONFLICT (node_id) DO NOTHING;

-- ─── Step 2: Backfill `node_devices` + `node_params` from `devices` ─────────
-- For each legacy device, create N node_devices rows (N = channel_count from device_types)
-- + the canonical services: esp.service.ota + esp.service.diag
-- + N×M node_params rows (M = default params per device type, typically Power)
-- This is best done via Spring Boot CommandLineRunner because the channel
-- count + default param templates come from device_types.default_config JSONB.
-- The runner is: et.she.v3.migration.V28BackfillRunner (runs once, guarded by --run.v28-backfill=true)

-- ─── Step 3: Drop legacy `devices` columns ─────────────────────────────────
ALTER TABLE devices
    DROP COLUMN IF EXISTS reported_state,
    DROP COLUMN IF EXISTS desired_state,
    DROP COLUMN IF EXISTS device_type_id;

-- ─── Step 4: Rename devices → devices_legacy (kept 90 days for rollback) ──
ALTER TABLE devices RENAME TO devices_legacy;
DROP POLICY IF EXISTS tenant_isolation ON devices_legacy;
DROP TRIGGER IF EXISTS trg_devices_set_updated_at ON devices_legacy;

-- devices_legacy is read-only for rollback investigation
REVOKE SELECT, INSERT, UPDATE, DELETE ON devices_legacy FROM she_app;
GRANT SELECT ON devices_legacy TO she_app;

-- ─── Step 5: Drop `device_types` (no longer needed) ────────────────────────
DROP TABLE IF EXISTS device_types CASCADE;

-- ─── Step 6: Schedule final drop of devices_legacy (90 days out) ──────────
-- Create a calendar reminder / Spring Boot @Scheduled job to run after 90 days:
--   DROP TABLE devices_legacy;
-- Until then, devices_legacy is read-only.
