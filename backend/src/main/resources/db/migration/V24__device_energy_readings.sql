-- =============================================================================
-- SHE V3 — Flyway migration V24: device_energy_readings hypertable (PZEM)
-- =============================================================================
-- V3-DATABASE-DESIGN §5.2. V3-ENERGY-MONITORING §5.1. P1-20, P1-21.
-- Per-node energy readings from PZEM-004T v3 (SHE-R8/R16 only).
-- Retention: 365 days raw (P1-21).
-- =============================================================================
CREATE TABLE device_energy_readings (
    time            TIMESTAMPTZ   NOT NULL,
    tenant_id       UUID          NOT NULL,
    node_id         UUID          NOT NULL,
    voltage         DOUBLE PRECISION,
    current         DOUBLE PRECISION,
    power_w         DOUBLE PRECISION,
    energy_wh       DOUBLE PRECISION,
    cost_etb        DOUBLE PRECISION,
    tariff_block    INT,
    frequency       DOUBLE PRECISION,
    power_factor    DOUBLE PRECISION
);

COMMENT ON TABLE device_energy_readings IS 'Per-node energy readings from PZEM-004T v3 (SHE-R8/R16 only). V3-ENERGY-MONITORING §5.1.';

SELECT create_hypertable('device_energy_readings', 'time', chunk_time_interval => INTERVAL '1 day');

CREATE INDEX idx_energy_node_time   ON device_energy_readings (node_id, time DESC);
CREATE INDEX idx_energy_tenant_time ON device_energy_readings (tenant_id, time DESC);

SELECT add_retention_policy('device_energy_readings', INTERVAL '365 days');

GRANT SELECT, INSERT, UPDATE, DELETE ON device_energy_readings TO she_app;
