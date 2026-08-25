-- =============================================================================
-- SHE V3 — Flyway migration V15: payments + subscriptions
-- =============================================================================
-- V3-DATABASE-DESIGN §4.12. Chapa/Telebirr billing.
-- P2-4: UNIQUE(idempotency_key, tenant_id) is payment idempotency source of truth.
-- =============================================================================
CREATE TABLE payments (
    id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    user_id           UUID          REFERENCES users(id) ON DELETE SET NULL,
    idempotency_key   UUID          NOT NULL,
    amount_etb        NUMERIC(10,2) NOT NULL,
    plan              VARCHAR(20)   NOT NULL,
    status            VARCHAR(20)   NOT NULL DEFAULT 'PENDING'
                                    CHECK (status IN ('PENDING','PAID','FAILED','REFUNDED')),
    chapa_ref         VARCHAR(100)  UNIQUE,
    checkout_url      TEXT,
    paid_at           TIMESTAMPTZ,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    UNIQUE (idempotency_key, tenant_id)
);

COMMENT ON TABLE payments IS 'Chapa transaction records. UNIQUE(idempotency_key, tenant_id) is payment idempotency source of truth.';

CREATE TRIGGER trg_payments_set_updated_at
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON payments
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_payments_tenant_created ON payments (tenant_id, created_at DESC);

GRANT SELECT, INSERT, UPDATE, DELETE ON payments TO she_app;

-- ─── subscriptions ──────────────────────────────────────────────────────────
CREATE TABLE subscriptions (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    plan            VARCHAR(20)   NOT NULL,
    status          VARCHAR(20)   NOT NULL DEFAULT 'ACTIVE'
                                  CHECK (status IN ('ACTIVE','CANCELLED','EXPIRED','SUSPENDED','TRIALING')),
    started_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    payment_id      UUID          REFERENCES payments(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE subscriptions IS 'Active subscription per tenant.';

CREATE TRIGGER trg_subscriptions_set_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON subscriptions
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_subscriptions_tenant_expires ON subscriptions (tenant_id, expires_at DESC);
CREATE INDEX idx_subscriptions_status          ON subscriptions (status) WHERE status = 'ACTIVE';

GRANT SELECT, INSERT, UPDATE, DELETE ON subscriptions TO she_app;
