-- =============================================================================
-- SHE V3 — Flyway migration V27: nodes + node_devices + node_params
-- =============================================================================
-- THE CENTRAL MIGRATION — RainMaker Node → Device → Parameter hierarchy.
-- V3-DATABASE-DESIGN §3.1-3.3. V3-DEVICE-MODEL §1-5. ADR-011.
-- Replaces the legacy flat `devices` table (dropped in V28).
--
-- Also adds deferred FKs from V10 (scene_actions), V11 (node_group_members),
-- V14 (ota_approvals) to nodes/node_devices.
-- =============================================================================

-- ─── nodes ─────────────────────────────────────────────────────────────────
CREATE TABLE nodes (
    id                  UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID          REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id             UUID          REFERENCES homes(id) ON DELETE SET NULL,
    room_id             UUID          REFERENCES rooms(id) ON DELETE SET NULL,
    node_id             VARCHAR(64)   NOT NULL UNIQUE,
    mac_address         VARCHAR(17)   NOT NULL UNIQUE,
    normalized_mac      VARCHAR(12)   NOT NULL UNIQUE,
    sku                 VARCHAR(20)   NOT NULL,
    name                VARCHAR(100)  NOT NULL,
    firmware_version    VARCHAR(50),
    hardware_revision   VARCHAR(20),
    cert_serial         VARCHAR(64),
    cert_fingerprint    VARCHAR(64),
    is_online           BOOLEAN       NOT NULL DEFAULT false,
    last_seen_at        TIMESTAMPTZ,
    provisioned_at      TIMESTAMPTZ,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at          TIMESTAMPTZ
);

COMMENT ON TABLE nodes IS 'RainMaker Node — one physical ESP32 board. V3-DATABASE-DESIGN §3.1.';
COMMENT ON COLUMN nodes.node_id IS 'SHE-R8-AABBCC (SHE naming, V3-DEVICE-MODEL §2.2)';
COMMENT ON COLUMN nodes.normalized_mac IS 'Lowercase MAC, colons removed — for MQTT clientid lookup.';
COMMENT ON COLUMN nodes.cert_fingerprint IS 'SHA-256 of DER cert. Lookup (not FK) into device_certs.';
COMMENT ON COLUMN nodes.tenant_id IS 'NULL until BLE provisioning claim (POST /api/v3/nodes/claim).';

CREATE TRIGGER trg_nodes_set_updated_at
    BEFORE UPDATE ON nodes
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE nodes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON nodes
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
        OR tenant_id IS NULL
    );

CREATE INDEX idx_nodes_tenant_home      ON nodes (tenant_id, home_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_nodes_normalized_mac   ON nodes (normalized_mac) WHERE deleted_at IS NULL;
CREATE INDEX idx_nodes_cert_fingerprint ON nodes (cert_fingerprint) WHERE cert_fingerprint IS NOT NULL;
CREATE INDEX idx_nodes_tenant_online    ON nodes (tenant_id, is_online) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON nodes TO she_app;

-- ─── node_devices ──────────────────────────────────────────────────────────
CREATE TABLE node_devices (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          REFERENCES tenants(id) ON DELETE RESTRICT,
    node_id         UUID          NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    device_name     VARCHAR(64)   NOT NULL,
    device_type     VARCHAR(64)   NOT NULL,
    display_name    VARCHAR(100),
    channel_index   SMALLINT,
    attributes      JSONB,
    is_service      BOOLEAN       NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (node_id, device_name)
);

COMMENT ON TABLE node_devices IS 'RainMaker Device — logical entity per node. V3-DATABASE-DESIGN §3.2.';
COMMENT ON COLUMN node_devices.device_name IS 'Matches MQTT payload key (e.g., "Relay 1", "Diagnostics").';
COMMENT ON COLUMN node_devices.device_type IS 'esp.device.switch | esp.service.ota | esp.service.diag';
COMMENT ON COLUMN node_devices.is_service IS 'TRUE if device_type LIKE esp.service.% (auto-set by trigger).';

CREATE TRIGGER trg_node_devices_set_updated_at
    BEFORE UPDATE ON node_devices
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

-- Auto-set is_service on insert/update
CREATE OR REPLACE FUNCTION set_node_device_is_service() RETURNS TRIGGER AS $$
BEGIN
    NEW.is_service := (NEW.device_type LIKE 'esp.service.%');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_node_devices_set_is_service
    BEFORE INSERT OR UPDATE OF device_type ON node_devices
    FOR EACH ROW EXECUTE FUNCTION set_node_device_is_service();

ALTER TABLE node_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_devices FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON node_devices
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
        OR tenant_id IS NULL
    );

CREATE INDEX idx_node_devices_tenant_node  ON node_devices (tenant_id, node_id);
CREATE INDEX idx_node_devices_node_channel ON node_devices (node_id, channel_index);
CREATE INDEX idx_node_devices_node_type    ON node_devices (node_id, device_type);

GRANT SELECT, INSERT, UPDATE, DELETE ON node_devices TO she_app;

-- ─── node_params ───────────────────────────────────────────────────────────
CREATE TABLE node_params (
    id                  UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID          REFERENCES tenants(id) ON DELETE RESTRICT,
    node_id             UUID          NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    node_device_id      UUID          NOT NULL REFERENCES node_devices(id) ON DELETE CASCADE,
    param_name          VARCHAR(64)   NOT NULL,
    param_type          VARCHAR(64)   NOT NULL,
    data_type           VARCHAR(10)   NOT NULL CHECK (data_type IN ('bool','int','float','string')),
    ui_hint             VARCHAR(20)   CHECK (ui_hint IN ('toggle','slider','segmented','read_only')),
    properties          JSONB         NOT NULL DEFAULT '["read","write"]'::jsonb,
    min_value           DOUBLE PRECISION,
    max_value           DOUBLE PRECISION,
    last_value          JSONB,
    last_reported_at    TIMESTAMPTZ,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (node_device_id, param_name)
);

COMMENT ON TABLE node_params IS 'RainMaker Parameter — controllable/measurable value. V3-DATABASE-DESIGN §3.3.';
COMMENT ON COLUMN node_params.last_value IS 'Cached value (JSONB) updated on every MQTT params/local message.';
COMMENT ON COLUMN node_params.properties IS '["read","write","persist","time_series"] — PROP_* bitmask in firmware.';

ALTER TABLE node_params ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_params FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON node_params
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
        OR tenant_id IS NULL
    );

CREATE INDEX idx_node_params_device_name ON node_params (node_device_id, param_name);
CREATE INDEX idx_node_params_tenant_node  ON node_params (tenant_id, node_id);
CREATE INDEX idx_node_params_node_name    ON node_params (node_id, param_name);

GRANT SELECT, INSERT, UPDATE, DELETE ON node_params TO she_app;

-- ─── Add deferred FKs from V10, V11, V14 ───────────────────────────────────
ALTER TABLE scene_actions
    ADD CONSTRAINT fk_scene_actions_node        FOREIGN KEY (node_id)        REFERENCES nodes(id) ON DELETE SET NULL,
    ADD CONSTRAINT fk_scene_actions_node_device FOREIGN KEY (node_device_id) REFERENCES node_devices(id) ON DELETE SET NULL;

ALTER TABLE node_group_members
    ADD CONSTRAINT fk_ngm_node FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;

ALTER TABLE ota_approvals
    ADD CONSTRAINT fk_ota_approvals_node FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;
