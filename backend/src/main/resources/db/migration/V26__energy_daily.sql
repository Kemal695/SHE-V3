-- =============================================================================
-- SHE V3 — Flyway migration V26: energy_daily continuous aggregate
-- =============================================================================
-- V3-DATABASE-DESIGN §5.3. V3-ENERGY-MONITORING §5.2.
-- Daily roll-up built on energy_hourly. Retained 7 years.
-- =============================================================================
CREATE MATERIALIZED VIEW energy_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', bucket) AS day,
    tenant_id, node_id,
    MAX(energy_wh)   AS energy_wh_total,
    SUM(cost_etb)    AS cost_etb_total
FROM energy_hourly
GROUP BY day, tenant_id, node_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('energy_daily',
    start_offset      => INTERVAL '90 days',
    end_offset        => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day');

SELECT add_retention_policy('energy_daily', INTERVAL '7 years');

GRANT SELECT ON energy_daily TO she_app;
