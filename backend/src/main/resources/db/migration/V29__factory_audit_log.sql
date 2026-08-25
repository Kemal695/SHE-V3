-- =============================================================================
-- SHE V3 — Flyway migration V29: factory_audit_log
-- =============================================================================
-- V3-FACTORY-OPS §8.1. NOT tenant-scoped (devices are pre-tenant until claimed).
-- TimescaleDB hypertable with 10-year retention (PDPP + ECA compliance).
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE factory_audit_log (
    id                UUID          DEFAULT uuid_generate_v4(),
    event_type        VARCHAR(30)   NOT NULL,
    batch_id          VARCHAR(50)   NOT NULL,
    mac               VARCHAR(17)   NOT NULL,
    node_id           VARCHAR(64)   NOT NULL,
    sku               VARCHAR(20)   NOT NULL,
    serial_number     VARCHAR(50),
    cert_serial       VARCHAR(64),
    cert_fingerprint  VARCHAR(64),
    operator_id       VARCHAR(50)   NOT NULL,
    workstation_id    VARCHAR(50)   NOT NULL,
    firmware_version  VARCHAR(50),
    hardware_revision VARCHAR(20),
    qc_report         JSONB,
    qc_status         VARCHAR(10),
    failure_reason    TEXT,
    details           JSONB,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
);

COMMENT ON TABLE factory_audit_log IS 'Factory flashing audit log. NOT tenant-scoped. TimescaleDB hypertable. 10-yr retention.';

SELECT create_hypertable('factory_audit_log', 'created_at', chunk_time_interval => INTERVAL '90 days');

SELECT add_retention_policy('factory_audit_log', INTERVAL '3650 days');

CREATE INDEX idx_factory_audit_batch     ON factory_audit_log (batch_id, created_at DESC);
CREATE INDEX idx_factory_audit_mac       ON factory_audit_log (mac, created_at DESC);
CREATE INDEX idx_factory_audit_node_id   ON factory_audit_log (node_id);
CREATE INDEX idx_factory_audit_qc      ON factory_audit_log (qc_status, created_at DESC);
CREATE INDEX idx_factory_audit_event     ON factory_audit_log (event_type, created_at DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON factory_audit_log TO she_app;
