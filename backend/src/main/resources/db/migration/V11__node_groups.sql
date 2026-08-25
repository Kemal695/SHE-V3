-- =============================================================================
-- SHE V3 — Flyway migration V11: node_groups + node_group_members
-- =============================================================================
-- V3-DATABASE-DESIGN §4.8. Logical broadcast groups.
-- node_id FK added in V27 (deferred).
-- =============================================================================
CREATE TABLE node_groups (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id         UUID          NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    name            VARCHAR(100)  NOT NULL,
    group_type      VARCHAR(20)   NOT NULL CHECK (group_type IN ('ROOM','CUSTOM','ALL_LIGHTS')),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

COMMENT ON TABLE node_groups IS 'Logical broadcast groups.';

CREATE TRIGGER trg_node_groups_set_updated_at
    BEFORE UPDATE ON node_groups
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE node_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE node_groups FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON node_groups
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_node_groups_tenant_home ON node_groups (tenant_id, home_id) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON node_groups TO she_app;

-- ─── node_group_members ─────────────────────────────────────────────────────
CREATE TABLE node_group_members (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    group_id        UUID          NOT NULL REFERENCES node_groups(id) ON DELETE CASCADE,
    node_id         UUID,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (group_id, node_id)
);

COMMENT ON TABLE node_group_members IS 'Membership rows for node_groups.';

CREATE INDEX idx_node_group_members_group ON node_group_members (group_id);
CREATE INDEX idx_node_group_members_node  ON node_group_members (node_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON node_group_members TO she_app;
