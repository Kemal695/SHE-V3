-- =============================================================================
-- SHE V3 — Flyway migration V25: energy_hourly continuous aggregate
-- =============================================================================
-- V3-DATABASE-DESIGN §5.3. V3-ENERGY-MONITORING §5.2.
-- Hourly roll-up of device_energy_readings. Retained 7 years (Ethiopian tax law).
-- =============================================================================
CREATE MATERIALIZED VIEW energy_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    tenant_id, node_id,
    AVG(voltage)     AS avg_voltage,
    AVG(current)     AS avg_current,
    AVG(power_w)     AS avg_power_w,
    MAX(energy_wh) - MIN(energy_wh) AS energy_wh,
    SUM(cost_etb)    AS cost_etb
FROM device_energy_readings
GROUP BY bucket, tenant_id, node_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('energy_hourly',
    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');

SELECT add_retention_policy('energy_hourly', INTERVAL '7 years');

GRANT SELECT ON energy_hourly TO she_app;
