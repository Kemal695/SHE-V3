-- =============================================================================
-- SHE V3 — Flyway migration V2: users
-- =============================================================================
-- Creates the `users` table — Phase 0's single required CRUD endpoint.
--
-- Schema per V3-DATABASE-DESIGN §4.2 + V3-SECURITY-MODEL §1.2 (JWT claims) + §6 (MFA).
-- Password hashing: BCrypt cost 12 (V3-DATABASE-DESIGN §4.2).
-- TOTP secret: AES-256-GCM encrypted with KEK (V3-SECURITY-MODEL §6).
-- RLS: canonical policy (P0-5).
--
-- Reference: V3-ARCHITECTURE §5.1, V3-SECURITY-MODEL §1, §6, §10.5
-- =============================================================================

CREATE TABLE users (
    -- Identity
    id                       UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id                UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    -- Credentials
    email                    VARCHAR(255)  NOT NULL,
    password_hash            VARCHAR(255)  NOT NULL,        -- BCrypt cost 12

    -- Authorization (10-role RBAC, V3-SECURITY-MODEL §1.2 + §2)
    platform_role            VARCHAR(20)   NOT NULL DEFAULT 'USER'
                                              CHECK (platform_role IN ('USER','PLATFORM_ADMIN','SUPER_ADMIN')),
    tenant_role              VARCHAR(20)   CHECK (tenant_role IN (
                                              'TENANT_ADMIN','TENANT_INSTALLER','TENANT_VIEWER', NULL
                                            )),

    -- MFA / TOTP (V3-SECURITY-MODEL §6)
    totp_secret_encrypted    BYTEA,                          -- AES-256-GCM with KEK
    totp_recovery_codes      JSONB,                          -- 10 bcrypt-hashed single-use codes
    mfa_enabled              BOOLEAN       NOT NULL DEFAULT false,
    mfa_failed_attempts      INTEGER       NOT NULL DEFAULT 0,
    mfa_locked_until         TIMESTAMPTZ,

    -- OAuth linkage (V3-SECURITY-MODEL §6.4 — optional GitHub/Google)
    oauth_subject            VARCHAR(200),
    oauth_provider           VARCHAR(20)   CHECK (oauth_provider IN ('GITHUB','GOOGLE', NULL)),

    -- Profile
    phone_number             VARCHAR(20),                    -- Ethiopian: ^(\+251|0)?9\d{8}$
    preferred_language       VARCHAR(5)    NOT NULL DEFAULT 'en' CHECK (preferred_language IN ('am','en')),
    full_name                VARCHAR(200),

    -- Audit
    created_at               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ   NOT NULL DEFAULT now(),
    last_login_at            TIMESTAMPTZ,
    deleted_at               TIMESTAMPTZ,

    -- Constraints
    UNIQUE (tenant_id, email)
);

COMMENT ON TABLE users IS 'Application users. RLS-enforced per P0-5.';
COMMENT ON COLUMN users.password_hash IS 'BCrypt cost 12 hash';
COMMENT ON COLUMN users.totp_secret_encrypted IS 'AES-256-GCM encrypted TOTP secret (20-byte base32 plaintext)';
COMMENT ON COLUMN users.totp_recovery_codes IS 'JSON array of 10 bcrypt-hashed 8-char codes (no 0/O, 1/I)';
COMMENT ON COLUMN users.platform_role IS 'USER | PLATFORM_ADMIN | SUPER_ADMIN';
COMMENT ON COLUMN users.tenant_role IS 'TENANT_ADMIN | TENANT_INSTALLER | TENANT_VIEWER | NULL (null for B2C)';

-- =============================================================================
-- Updated_at trigger (reuses function from V1)
-- =============================================================================
CREATE TRIGGER trg_users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

-- =============================================================================
-- Canonical RLS policy (P0-5)
-- =============================================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON users
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

-- =============================================================================
-- Indexes (V3-DATABASE-DESIGN §9)
-- =============================================================================
CREATE INDEX idx_users_tenant_email  ON users (tenant_id, email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_platform_role ON users (platform_role)    WHERE deleted_at IS NULL;
CREATE INDEX idx_users_tenant_role   ON users (tenant_role)      WHERE deleted_at IS NULL AND tenant_role IS NOT NULL;
CREATE INDEX idx_users_oauth         ON users (oauth_provider, oauth_subject) WHERE oauth_subject IS NOT NULL;

-- =============================================================================
-- Grants
-- =============================================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON users TO she_app;
