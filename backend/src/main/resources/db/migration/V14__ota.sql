-- =============================================================================
-- SHE V3 — Flyway migration V14: ota_batches + ota_approvals
-- =============================================================================
-- V3-DATABASE-DESIGN §4.11. Self-hosted OTA via MinIO. Ed25519-signed firmware.
-- V3-FIRMWARE §6. node_id FK added in V27 (deferred).
-- =============================================================================
CREATE TABLE ota_batches (
    id                    UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id             UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id               UUID          NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    firmware_version      VARCHAR(50)   NOT NULL,
    firmware_url          TEXT          NOT NULL,
    firmware_checksum     VARCHAR(64)   NOT NULL,
    signature_ed25519     TEXT          NOT NULL,
    target_sku            VARCHAR(20)   NOT NULL,
    rollout_percent       SMALLINT      NOT NULL DEFAULT 100 CHECK (rollout_percent BETWEEN 0 AND 100),
    auto_approve          BOOLEAN       NOT NULL DEFAULT false,
    status                VARCHAR(20)   NOT NULL DEFAULT 'DRAFT'
                                        CHECK (status IN ('DRAFT','APPROVED','ROLLING','COMPLETED','ABORTED','FAILED')),
    created_by_user_id    UUID          REFERENCES users(id) ON DELETE SET NULL,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE ota_batches IS 'Self-hosted OTA via MinIO. Ed25519-signed firmware. V3-FIRMWARE §6.';

CREATE TRIGGER trg_ota_batches_set_updated_at
    BEFORE UPDATE ON ota_batches
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE ota_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE ota_batches FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON ota_batches
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_ota_batches_tenant_home ON ota_batches (tenant_id, home_id, created_at DESC);
CREATE INDEX idx_ota_batches_status      ON ota_batches (status);

GRANT SELECT, INSERT, UPDATE, DELETE ON ota_batches TO she_app;

-- ─── ota_approvals ──────────────────────────────────────────────────────────
CREATE TABLE ota_approvals (
    id                    UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id             UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    batch_id              UUID          NOT NULL REFERENCES ota_batches(id) ON DELETE CASCADE,
    node_id               UUID,
    status                VARCHAR(20)   NOT NULL DEFAULT 'PENDING'
                                        CHECK (status IN ('PENDING','APPROVED','DECLINED','IN_PROGRESS','COMPLETED','ROLLED_BACK','FAILED')),
    approved_by_user_id   UUID          REFERENCES users(id) ON DELETE SET NULL,
    approved_at           TIMESTAMPTZ,
    deployment_status     VARCHAR(20),
    progress              INTEGER       NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
    last_error            TEXT,
    created_at            TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE ota_approvals IS 'Per-node OTA deployment tracking. V3-API-SPECIFICATION §9.';

CREATE TRIGGER trg_ota_approvals_set_updated_at
    BEFORE UPDATE ON ota_approvals
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE ota_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE ota_approvals FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON ota_approvals
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_ota_approvals_batch_node ON ota_approvals (batch_id, node_id);
CREATE INDEX idx_ota_approvals_status     ON ota_approvals (status);

GRANT SELECT, INSERT, UPDATE, DELETE ON ota_approvals TO she_app;
