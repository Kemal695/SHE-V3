-- =============================================================================
-- SHE V3 — Flyway migration V18: audit_log (TimescaleDB hypertable + hash chain)
-- =============================================================================
-- V3-DATABASE-DESIGN §4.15. P1-19: TimescaleDB hypertable (NOT pg_partman).
-- Tamper-evident hash chain: hash = SHA-256(prev_hash || canonical_json(this_row)).
-- Retention: 30 days raw + 7-year CSV archive (MinIO).
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE audit_log (
    id              UUID          DEFAULT uuid_generate_v4(),
    tenant_id       UUID,
    actor_user_id   UUID,
    actor_type      VARCHAR(20)   NOT NULL CHECK (actor_type IN ('USER','TENANT_ADMIN','PLATFORM_ADMIN','SYSTEM','DEVICE')),
    action          VARCHAR(50)   NOT NULL,
    target_type     VARCHAR(20),
    target_id       UUID,
    details         JSONB,
    ip_address      INET,
    user_agent      TEXT,
    request_id      UUID,
    sequence_number BIGINT,
    prev_hash       BYTEA,
    hash            BYTEA,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
);

COMMENT ON TABLE audit_log IS 'Tamper-evident audit log (P1-19). TimescaleDB hypertable, NOT pg_partman.';
COMMENT ON COLUMN audit_log.sequence_number IS 'Monotonic per-tenant sequence — chain integrity check.';
COMMENT ON COLUMN audit_log.hash IS 'SHA-256(prev_hash || canonical JSON of this row).';
COMMENT ON COLUMN audit_log.prev_hash IS 'SHA-256 of previous row hash. NULL for first row per tenant.';

SELECT create_hypertable('audit_log', 'created_at', chunk_time_interval => INTERVAL '7 days');

CREATE INDEX idx_audit_log_tenant_created ON audit_log (tenant_id, created_at DESC);
CREATE INDEX idx_audit_log_actor_created  ON audit_log (actor_user_id, created_at DESC);
CREATE INDEX idx_audit_log_target         ON audit_log (target_type, target_id, created_at DESC);
CREATE INDEX idx_audit_log_action         ON audit_log (action, created_at DESC);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON audit_log
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
        OR tenant_id IS NULL
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
        OR tenant_id IS NULL
    );

SELECT add_retention_policy('audit_log', INTERVAL '730 days');

GRANT SELECT, INSERT, UPDATE, DELETE ON audit_log TO she_app;
