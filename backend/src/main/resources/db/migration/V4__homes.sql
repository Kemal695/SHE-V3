-- =============================================================================
-- SHE V3 — Flyway migration V4: homes
-- =============================================================================
-- V3-DATABASE-DESIGN §4.3. RLS-enforced per P0-5.
-- =============================================================================
CREATE TABLE homes (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    owner_user_id   UUID          NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    name            VARCHAR(100)  NOT NULL,
    address         TEXT,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

COMMENT ON TABLE homes IS 'One home per physical household. RLS-enforced per P0-5.';
COMMENT ON COLUMN homes.owner_user_id IS 'User who owns the home (OWNER role in home_members).';

CREATE TRIGGER trg_homes_set_updated_at
    BEFORE UPDATE ON homes
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE homes ENABLE ROW LEVEL SECURITY;
ALTER TABLE homes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON homes
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_homes_tenant_id       ON homes (tenant_id)               WHERE deleted_at IS NULL;
CREATE INDEX idx_homes_owner_user_id   ON homes (owner_user_id)           WHERE deleted_at IS NULL;
CREATE INDEX idx_homes_tenant_owner    ON homes (tenant_id, owner_user_id) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON homes TO she_app;
