-- =============================================================================
-- SHE V3 — Flyway migration V5: rooms
-- =============================================================================
-- V3-DATABASE-DESIGN §4.4.
-- =============================================================================
CREATE TABLE rooms (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id         UUID          NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    name            VARCHAR(100)  NOT NULL,
    icon            VARCHAR(50),
    sort_order      INTEGER       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

COMMENT ON TABLE rooms IS 'User-customizable rooms within a home. RLS-enforced per P0-5.';

CREATE TRIGGER trg_rooms_set_updated_at
    BEFORE UPDATE ON rooms
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE rooms FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON rooms
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_rooms_tenant_home ON rooms (tenant_id, home_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_rooms_home_sort   ON rooms (home_id, sort_order) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON rooms TO she_app;
