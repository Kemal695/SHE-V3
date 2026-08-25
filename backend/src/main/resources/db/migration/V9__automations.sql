-- =============================================================================
-- SHE V3 — Flyway migration V9: automations + automation_rules
-- =============================================================================
-- V3-DATABASE-DESIGN §4.6.
-- =============================================================================
CREATE TABLE automations (
    id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    home_id           UUID          NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    name              VARCHAR(100)  NOT NULL,
    description       TEXT,
    enabled           BOOLEAN       NOT NULL DEFAULT true,
    trigger_config    JSONB         NOT NULL,
    created_by_user_id UUID         REFERENCES users(id) ON DELETE SET NULL,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ
);

COMMENT ON TABLE automations IS 'Top-level automation entity.';
COMMENT ON COLUMN automations.trigger_config IS 'SCHEDULE {type,cron} | NODE_STATE {type,node_id,device_name,param_name,comparator,value} | MANUAL {type}';

CREATE TRIGGER trg_automations_set_updated_at
    BEFORE UPDATE ON automations
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE automations ENABLE ROW LEVEL SECURITY;
ALTER TABLE automations FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON automations
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_automations_tenant_home  ON automations (tenant_id, home_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_automations_home_enabled ON automations (home_id)           WHERE deleted_at IS NULL AND enabled = true;

GRANT SELECT, INSERT, UPDATE, DELETE ON automations TO she_app;

-- ─── automation_rules ────────────────────────────────────────────────────────
CREATE TABLE automation_rules (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    automation_id   UUID          NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    action_type     VARCHAR(30)   NOT NULL,
    action_config   JSONB         NOT NULL,
    sort_order      INTEGER       NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE automation_rules IS 'Actions executed when automation trigger fires.';

CREATE INDEX idx_automation_rules_automation ON automation_rules (automation_id, sort_order);

GRANT SELECT, INSERT, UPDATE, DELETE ON automation_rules TO she_app;
