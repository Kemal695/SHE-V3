-- =============================================================================
-- SHE V3 — Flyway migration V23: TimescaleDB + device_telemetry hypertable
-- =============================================================================
-- V3-DATABASE-DESIGN §5.1. V3-ARCHITECTURE §5.2.
-- Per-parameter telemetry hypertable. Polled by MqttSubscriberService.
-- Retention: 30 days raw (drop_chunks).
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE device_telemetry (
    time            TIMESTAMPTZ   NOT NULL,
    tenant_id       UUID          NOT NULL,
    node_id         UUID          NOT NULL,
    node_device_id  UUID,
    param_name      VARCHAR(64)   NOT NULL,
    value           DOUBLE PRECISION NOT NULL,
    unit            VARCHAR(10)
);

COMMENT ON TABLE device_telemetry IS 'Per-parameter telemetry hypertable. V3-DATABASE-DESIGN §5.1.';

SELECT create_hypertable('device_telemetry', 'time', chunk_time_interval => INTERVAL '1 day');

CREATE INDEX idx_device_telemetry_node_time   ON device_telemetry (node_id, time DESC);
CREATE INDEX idx_device_telemetry_tenant_time ON device_telemetry (tenant_id, time DESC);

ALTER TABLE device_telemetry ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_telemetry FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON device_telemetry
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

SELECT add_retention_policy('device_telemetry', INTERVAL '30 days');

GRANT SELECT, INSERT, UPDATE, DELETE ON device_telemetry TO she_app;
