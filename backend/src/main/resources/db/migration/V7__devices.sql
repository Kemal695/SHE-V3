-- =============================================================================
-- SHE V3 — Flyway migration V7: devices (LEGACY flat table — dropped in V28)
-- =============================================================================
-- This is the legacy flat device table. It will be renamed to devices_legacy
-- in V28 after backfill to nodes/node_devices/node_params.
-- Kept for forward-only migration compatibility.
-- =============================================================================
CREATE TABLE devices (
    id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id           UUID          REFERENCES homes(id) ON DELETE SET NULL,
    room_id           UUID          REFERENCES rooms(id) ON DELETE SET NULL,
    device_type_id    UUID          REFERENCES device_types(id) ON DELETE RESTRICT,
    name              VARCHAR(100)  NOT NULL,
    mac_address       VARCHAR(17)   NOT NULL UNIQUE,
    node_id           VARCHAR(64)   UNIQUE,
    firmware_version  VARCHAR(50),
    hardware_revision VARCHAR(20),
    cert_serial       VARCHAR(64),
    cert_fingerprint  VARCHAR(64),
    is_online         BOOLEAN       NOT NULL DEFAULT false,
    last_seen_at      TIMESTAMPTZ,
    provisioned_at    TIMESTAMPTZ,
    reported_state    JSONB,
    desired_state     JSONB,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

COMMENT ON TABLE devices IS 'LEGACY flat device table. Dropped in V28 after backfill to nodes/node_devices/node_params.';

CREATE TRIGGER trg_devices_set_updated_at
    BEFORE UPDATE ON devices
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON devices
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_devices_tenant_home      ON devices (tenant_id, home_id)    WHERE deleted_at IS NULL;
CREATE INDEX idx_devices_node_id          ON devices (node_id)               WHERE deleted_at IS NULL;
CREATE INDEX idx_devices_mac_address      ON devices (mac_address);
CREATE INDEX idx_devices_cert_fingerprint ON devices (cert_fingerprint);

GRANT SELECT, INSERT, UPDATE, DELETE ON devices TO she_app;
