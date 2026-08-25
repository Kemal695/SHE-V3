-- =============================================================================
-- SHE V3 — Flyway migration V12: notification_preferences + notification_log
-- =============================================================================
-- V3-DATABASE-DESIGN §4.9.
-- =============================================================================
CREATE TABLE notification_preferences (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id         UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category        VARCHAR(30)   NOT NULL CHECK (category IN ('AUTOMATION','OTA','SECURITY','ENERGY','SYSTEM')),
    push_enabled    BOOLEAN       NOT NULL DEFAULT true,
    sms_enabled     BOOLEAN       NOT NULL DEFAULT false,
    email_enabled   BOOLEAN       NOT NULL DEFAULT false,
    muted_until     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (user_id, category)
);

COMMENT ON TABLE notification_preferences IS 'Per-user per-category mute/push prefs.';

CREATE TRIGGER trg_notification_preferences_set_updated_at
    BEFORE UPDATE ON notification_preferences
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON notification_preferences
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_notif_prefs_user ON notification_preferences (user_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON notification_preferences TO she_app;

-- ─── notification_log ───────────────────────────────────────────────────────
CREATE TABLE notification_log (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id         UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category        VARCHAR(30)   NOT NULL,
    title           VARCHAR(200)  NOT NULL,
    body            TEXT,
    channel         VARCHAR(10)   NOT NULL CHECK (channel IN ('PUSH','SMS','EMAIL')),
    status          VARCHAR(20)   NOT NULL DEFAULT 'PENDING'
                                  CHECK (status IN ('PENDING','SENT','DELIVERED','FAILED','SUPPRESSED')),
    fcm_message_id  VARCHAR(100),
    sent_at         TIMESTAMPTZ,
    delivered_at    TIMESTAMPTZ,
    failed_reason   TEXT,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE notification_log IS 'Audit of every push/SMS/email notification.';

ALTER TABLE notification_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_log FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON notification_log
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_notif_log_user_created   ON notification_log (user_id, created_at DESC);
CREATE INDEX idx_notif_log_tenant_created ON notification_log (tenant_id, created_at DESC);
CREATE INDEX idx_notif_log_status         ON notification_log (status) WHERE status IN ('PENDING','SENT');

GRANT SELECT, INSERT, UPDATE, DELETE ON notification_log TO she_app;
