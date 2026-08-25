-- =============================================================================
-- SHE V3 — Flyway migration V10: scenes + scene_actions
-- =============================================================================
-- V3-DATABASE-DESIGN §4.7.
-- node_id/node_device_id FKs added in V27 (deferred — nodes table doesn't exist yet).
-- =============================================================================
CREATE TABLE scenes (
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

COMMENT ON TABLE scenes IS 'Grouped actions (one-click scene activation).';

CREATE TRIGGER trg_scenes_set_updated_at
    BEFORE UPDATE ON scenes
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE scenes ENABLE ROW LEVEL SECURITY;
ALTER TABLE scenes FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON scenes
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_scenes_tenant_home ON scenes (tenant_id, home_id) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON scenes TO she_app;

-- ─── scene_actions ──────────────────────────────────────────────────────────
CREATE TABLE scene_actions (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    scene_id        UUID          NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
    node_id         UUID,
    node_device_id  UUID,
    param_name      VARCHAR(64)   NOT NULL,
    value           JSONB         NOT NULL,
    sort_order      INTEGER       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE scene_actions IS 'One row per (device, param) write within a scene.';

CREATE INDEX idx_scene_actions_scene ON scene_actions (scene_id, sort_order);

GRANT SELECT, INSERT, UPDATE, DELETE ON scene_actions TO she_app;
