-- =============================================================================
-- SHE V3 — Flyway migration V8: home_members (RBAC)
-- =============================================================================
-- V3-DATABASE-DESIGN §4.5. Multi-tenant RBAC per home.
-- Roles: OWNER (1 per home, transferable), ADMIN, MEMBER, GUEST.
-- =============================================================================
CREATE TABLE home_members (
    id                  UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id           UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id             UUID          NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    user_id             UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role                VARCHAR(20)   NOT NULL CHECK (role IN ('OWNER','ADMIN','MEMBER','GUEST')),
    granted_by_user_id  UUID          REFERENCES users(id) ON DELETE SET NULL,
    granted_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    revoked_at          TIMESTAMPTZ,
    UNIQUE (home_id, user_id)
);

COMMENT ON TABLE home_members IS 'Multi-tenant RBAC per home: OWNER / ADMIN / MEMBER / GUEST.';
COMMENT ON COLUMN home_members.role IS 'OWNER (1 per home, transferable), ADMIN, MEMBER, GUEST';

ALTER TABLE home_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE home_members FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON home_members
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_home_members_home_user ON home_members (home_id, user_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_home_members_user      ON home_members (user_id)          WHERE revoked_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON home_members TO she_app;
