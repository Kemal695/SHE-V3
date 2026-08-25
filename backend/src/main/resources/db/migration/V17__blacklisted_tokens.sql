-- =============================================================================
-- SHE V3 — Flyway migration V17: blacklisted_tokens
-- =============================================================================
-- V3-DATABASE-DESIGN §4.14. JWT refresh token rotation blacklist.
-- TTL via expires_at (for purge). tenant_id nullable for platform tokens.
-- =============================================================================
CREATE TABLE blacklisted_tokens (
    id              UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID          REFERENCES tenants(id) ON DELETE CASCADE,
    jti             VARCHAR(100)  NOT NULL UNIQUE,
    user_id         UUID          REFERENCES users(id) ON DELETE CASCADE,
    token_type      VARCHAR(10)   NOT NULL CHECK (token_type IN ('ACCESS','REFRESH')),
    revoked_reason  VARCHAR(50),
    blacklisted_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ   NOT NULL
);

COMMENT ON TABLE blacklisted_tokens IS 'JWT refresh token rotation blacklist. TTL via expires_at.';

CREATE INDEX idx_blacklisted_tokens_jti     ON blacklisted_tokens (jti);
CREATE INDEX idx_blacklisted_tokens_user    ON blacklisted_tokens (user_id);
CREATE INDEX idx_blacklisted_tokens_expires ON blacklisted_tokens (expires_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON blacklisted_tokens TO she_app;
