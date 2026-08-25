-- =============================================================================
-- SHE V3 — Flyway migration V21: api_keys
-- =============================================================================
-- V3-DATABASE-DESIGN §4.16. B2B tenant API keys.
-- V19/V20 SKIPPED — already in V3__device_certs.sql (Phase 0).
-- =============================================================================
CREATE TABLE api_keys (
    id                  UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    name                VARCHAR(100)  NOT NULL,
    key_hash            VARCHAR(128)  NOT NULL UNIQUE,
    key_prefix          VARCHAR(20)   NOT NULL,
    scopes              JSONB         NOT NULL DEFAULT '[]'::jsonb,
    last_used_at        TIMESTAMPTZ,
    last_used_ip        INET,
    expires_at          TIMESTAMPTZ,
    revoked_at          TIMESTAMPTZ,
    revoked_by_user_id  UUID          REFERENCES users(id) ON DELETE SET NULL,
    created_by_user_id  UUID          NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE api_keys IS 'B2B tenant API keys. key_hash = SHA-256(secret). key shown once on create.';
COMMENT ON COLUMN api_keys.key_prefix IS 'First 12 chars of the key shown in UI for identification.';

CREATE TRIGGER trg_api_keys_set_updated_at
    BEFORE UPDATE ON api_keys
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE api_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE api_keys FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON api_keys
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_api_keys_tenant   ON api_keys (tenant_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_api_keys_key_hash ON api_keys (key_hash)  WHERE revoked_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON api_keys TO she_app;
