-- =============================================================================
-- SHE V3 — Flyway migration V6: device_types (lookup; dropped in V28)
-- =============================================================================
-- SKU lookup table (SHE-R4 / SHE-R8 / SHE-R16). Seeded per tenant.
-- Dropped in V28 after backfill to nodes/node_devices/node_params.
-- =============================================================================
CREATE TABLE device_types (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    sku             VARCHAR(20)   NOT NULL,
    display_name    VARCHAR(100)  NOT NULL,
    channel_count   SMALLINT      NOT NULL,
    has_pzem        BOOLEAN       NOT NULL DEFAULT false,
    default_config  JSONB,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, sku)
);

COMMENT ON TABLE device_types IS 'SKU lookup (SHE-R4/R8/R16). Seeded per tenant. Dropped in V28.';

CREATE TRIGGER trg_device_types_set_updated_at
    BEFORE UPDATE ON device_types
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE device_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_types FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON device_types
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_device_types_tenant_sku ON device_types (tenant_id, sku);

GRANT SELECT, INSERT, UPDATE, DELETE ON device_types TO she_app;

-- Seed default device types for the default B2C tenant (created in V1)
INSERT INTO device_types (tenant_id, sku, display_name, channel_count, has_pzem, default_config)
VALUES
  ('00000000-0000-0000-0000-000000000001'::uuid, 'SHE-R4',  'SHE-R4 4-Channel Relay',  4,  false,
    '{"devices":[{"name":"Relay 1","type":"esp.device.switch","channel":0},{"name":"Relay 2","type":"esp.device.switch","channel":1},{"name":"Relay 3","type":"esp.device.switch","channel":2},{"name":"Relay 4","type":"esp.device.switch","channel":3}]}'::jsonb),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'SHE-R8',  'SHE-R8 8-Channel Relay',  8,  true,
    '{"devices":[{"name":"Relay 1","type":"esp.device.switch","channel":0},{"name":"Relay 2","type":"esp.device.switch","channel":1},{"name":"Relay 3","type":"esp.device.switch","channel":2},{"name":"Relay 4","type":"esp.device.switch","channel":3},{"name":"Relay 5","type":"esp.device.switch","channel":4},{"name":"Relay 6","type":"esp.device.switch","channel":5},{"name":"Relay 7","type":"esp.device.switch","channel":6},{"name":"Relay 8","type":"esp.device.switch","channel":7}]}'::jsonb),
  ('00000000-0000-0000-0000-000000000001'::uuid, 'SHE-R16', 'SHE-R16 16-Channel Relay', 16, true,
    '{"devices":[{"name":"Relay 1","type":"esp.device.switch","channel":0},{"name":"Relay 2","type":"esp.device.switch","channel":1},{"name":"Relay 3","type":"esp.device.switch","channel":2},{"name":"Relay 4","type":"esp.device.switch","channel":3},{"name":"Relay 5","type":"esp.device.switch","channel":4},{"name":"Relay 6","type":"esp.device.switch","channel":5},{"name":"Relay 7","type":"esp.device.switch","channel":6},{"name":"Relay 8","type":"esp.device.switch","channel":7},{"name":"Relay 9","type":"esp.device.switch","channel":8},{"name":"Relay 10","type":"esp.device.switch","channel":9},{"name":"Relay 11","type":"esp.device.switch","channel":10},{"name":"Relay 12","type":"esp.device.switch","channel":11},{"name":"Relay 13","type":"esp.device.switch","channel":12},{"name":"Relay 14","type":"esp.device.switch","channel":13},{"name":"Relay 15","type":"esp.device.switch","channel":14},{"name":"Relay 16","type":"esp.device.switch","channel":15}]}'::jsonb)
ON CONFLICT (tenant_id, sku) DO NOTHING;
