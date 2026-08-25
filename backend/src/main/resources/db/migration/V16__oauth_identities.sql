-- =============================================================================
-- SHE V3 — Flyway migration V16: oauth_identities
-- =============================================================================
-- V3-DATABASE-DESIGN §4.13. GitHub / Google OAuth linkage.
-- =============================================================================
CREATE TABLE oauth_identities (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id         UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider        VARCHAR(20)   NOT NULL CHECK (provider IN ('GITHUB','GOOGLE')),
    oauth_subject   VARCHAR(200)  NOT NULL,
    email           VARCHAR(255),
    raw_profile     JSONB,
    linked_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (provider, oauth_subject)
);

COMMENT ON TABLE oauth_identities IS 'GitHub / Google OAuth linkage.';

ALTER TABLE oauth_identities ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_identities FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON oauth_identities
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_oauth_identities_user      ON oauth_identities (user_id);
CREATE INDEX idx_oauth_identities_provider  ON oauth_identities (provider, oauth_subject);

GRANT SELECT, INSERT, UPDATE, DELETE ON oauth_identities TO she_app;
