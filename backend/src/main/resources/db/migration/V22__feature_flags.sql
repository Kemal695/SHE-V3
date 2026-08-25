-- =============================================================================
-- SHE V3 — Flyway migration V22: feature_flags
-- =============================================================================
-- V3-DATABASE-DESIGN §4.17. Per-tenant feature toggles.
-- =============================================================================
CREATE TABLE feature_flags (
    id                  UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    flag_key            VARCHAR(50)   NOT NULL,
    enabled             BOOLEAN       NOT NULL DEFAULT false,
    rollout_percent     SMALLINT      NOT NULL DEFAULT 0 CHECK (rollout_percent BETWEEN 0 AND 100),
    config              JSONB,
    updated_by_user_id  UUID          REFERENCES users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, flag_key)
);

COMMENT ON TABLE feature_flags IS 'Per-tenant feature toggles.';

CREATE TRIGGER trg_feature_flags_set_updated_at
    BEFORE UPDATE ON feature_flags
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flags FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON feature_flags
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_feature_flags_tenant_key ON feature_flags (tenant_id, flag_key);

GRANT SELECT, INSERT, UPDATE, DELETE ON feature_flags TO she_app;
