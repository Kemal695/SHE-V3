-- =============================================================================
-- SHE V3 — Flyway migration V39: user_notifications (in-app notification inbox)
-- =============================================================================
-- V3-API-SPECIFICATION §12 (Notification domain) — GET /notifications/recent.
--
-- V12 already created notification_preferences + notification_log, but
-- notification_log is an audit of OUTBOUND delivery (channel PUSH/SMS/EMAIL,
-- status PENDING/SENT/...): it has no read state and nowhere to hang the device
-- a notification refers to. This table is the per-user INBOX the mobile
-- Notifications screen (design sheet #15) reads from.
-- =============================================================================
CREATE TABLE user_notifications (
    id          UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id   UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id     UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        VARCHAR(20)   NOT NULL DEFAULT 'system',
    category    VARCHAR(30)   NOT NULL DEFAULT 'SYSTEM'
                              CHECK (category IN ('AUTOMATION','OTA','SECURITY','ENERGY','SYSTEM')),
    title       VARCHAR(200)  NOT NULL,
    body        TEXT,
    node_id     UUID,
    home_id     UUID,
    read_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE user_notifications IS 'In-app notification inbox (per user). V3-API-SPECIFICATION §12.';

ALTER TABLE user_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_notifications FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON user_notifications
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_user_notifications_user_created ON user_notifications (user_id, created_at DESC);
CREATE INDEX idx_user_notifications_user_unread  ON user_notifications (user_id) WHERE read_at IS NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON user_notifications TO she_app;
