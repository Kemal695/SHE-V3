-- =============================================================================
-- SHE V3 — Flyway migration V13: user_devices (FCM/APNs push tokens)
-- =============================================================================
-- V3-DATABASE-DESIGN §4.10.
-- =============================================================================
CREATE TABLE user_devices (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id         UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider        VARCHAR(10)   NOT NULL CHECK (provider IN ('FCM','APNs')),
    token           VARCHAR(500)  NOT NULL,
    platform        VARCHAR(20)   NOT NULL CHECK (platform IN ('ANDROID','IOS','WEB')),
    locale          VARCHAR(5)    NOT NULL DEFAULT 'en' CHECK (locale IN ('am','en')),
    device_model    VARCHAR(100),
    app_version     VARCHAR(20),
    last_seen_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (provider, token)
);

COMMENT ON TABLE user_devices IS 'FCM / APNs push token registration.';

CREATE TRIGGER trg_user_devices_set_updated_at
    BEFORE UPDATE ON user_devices
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE user_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_devices FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON user_devices
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_user_devices_user  ON user_devices (user_id)         WHERE revoked_at IS NULL;
CREATE INDEX idx_user_devices_token ON user_devices (provider, token) WHERE revoked_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON user_devices TO she_app;
