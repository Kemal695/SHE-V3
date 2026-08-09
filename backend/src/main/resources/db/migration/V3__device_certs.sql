-- =============================================================================
-- SHE V3 — Flyway migration V3: device_ca_certs + device_certs
-- =============================================================================
-- Phase 0 needs `device_certs` so the /internal/mqtt/auth endpoint can verify
-- a connecting device's cert fingerprint against the database (V3-SECURITY-MODEL §4.2).
--
-- Canonical references:
--   V3-DATABASE-DESIGN §4.6 (device_certs schema)
--   V3-SECURITY-MODEL §3.2 (cert lifecycle) + §4.2 (EMQX auth backend endpoint)
--   V3-FACTORY-OPS (factory cert issuance workflow)
--   ADR-004 (cert-based MQTT auth)
--   ADR-014 (factory flashing)
--
-- NOTE: The full `nodes` table comes in migration V26 (RainMaker hierarchy — Phase 1+).
-- Phase 0 uses a *minimal* `device_certs` table that doesn't FK to `nodes` yet;
-- the FK is added in V26 when nodes exists.
-- =============================================================================

-- =============================================================================
-- device_ca_certs — CA records (one row per intermediate CA issuance)
-- =============================================================================
CREATE TABLE device_ca_certs (
    id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
    -- The intermediate CA that signed device certs in this batch
    ca_serial         VARCHAR(64)   NOT NULL UNIQUE,         -- X.509 serial of intermediate
    ca_cn             VARCHAR(200)  NOT NULL,                -- e.g. "Smart Home Ethiopia Intermediate CA"
    ca_fingerprint    VARCHAR(64)   NOT NULL,                -- SHA-256 of intermediate DER
    -- Lifecycle
    status            VARCHAR(20)   NOT NULL DEFAULT 'ACTIVE'
                                    CHECK (status IN ('ACTIVE','ROTATING','RETIRED','REVOKED')),
    is_current        BOOLEAN       NOT NULL DEFAULT false,  -- one row should be true at a time
    -- Validity
    issued_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ   NOT NULL,
    rotated_at        TIMESTAMPTZ,
    -- Audit
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE device_ca_certs IS 'CA records (one row per intermediate CA). V3-SECURITY-MODEL §3.1.';

CREATE TRIGGER trg_device_ca_certs_set_updated_at
    BEFORE UPDATE ON device_ca_certs
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE device_ca_certs ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_ca_certs FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON device_ca_certs
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

CREATE INDEX idx_device_ca_certs_status    ON device_ca_certs (status) WHERE status = 'ACTIVE';
CREATE INDEX idx_device_ca_certs_tenant_id ON device_ca_certs (tenant_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON device_ca_certs TO she_app;
GRANT USAGE, SELECT ON SEQUENCE device_ca_certs_id_seq TO she_app;

-- =============================================================================
-- device_certs — per-device issued certs (one row per device cert)
-- =============================================================================
-- EMQX auth backend flow (V3-SECURITY-MODEL §4.2):
--   1. Device connects to EMQX on :8883 with mTLS
--   2. EMQX extracts cert fingerprint (sha256 of DER)
--   3. EMQX POST /internal/mqtt/auth { clientid, cn, fingerprint }
--   4. Spring Boot SELECT * FROM device_certs WHERE fingerprint = ?
--      AND status = 'ACTIVE' AND revoked_at IS NULL
--   5. Returns {result: "allow"} or {result: "deny"}
-- =============================================================================
CREATE TABLE device_certs (
    id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id         UUID          NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,

    -- Cert identity (V3-SECURITY-MODEL §3.2)
    cn                VARCHAR(64)   NOT NULL,                -- normalized MAC (clientid)
    cert_serial       VARCHAR(64)   NOT NULL UNIQUE,         -- X.509 serial
    fingerprint       VARCHAR(64)   NOT NULL UNIQUE,         -- SHA-256 of DER cert

    -- Issuance
    ca_id             UUID          NOT NULL REFERENCES device_ca_certs(id) ON DELETE RESTRICT,
    issued_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ   NOT NULL,

    -- Revocation (V3-SECURITY-MODEL §3.3, P1-22 — CRL refresh 6h)
    status            VARCHAR(20)   NOT NULL DEFAULT 'ACTIVE'
                                    CHECK (status IN ('ACTIVE','REVOKED','EXPIRED','PENDING_REVOCATION')),
    revoked_at        TIMESTAMPTZ,
    revoke_reason     VARCHAR(50)   CHECK (revoke_reason IN (
                                      'key_compromise','ca_compromise','affiliation_changed',
                                      'superseded','cessation_of_operation','certificate_hold',
                                      'privilege_withdrawn','aa_compromise', NULL
                                    )),
    revoked_by_user_id UUID         REFERENCES users(id) ON DELETE SET NULL,

    -- Audit
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE device_certs IS 'Per-device issued X.509 certs. EMQX auth backend looks up by fingerprint.';
COMMENT ON COLUMN device_certs.cn IS 'Cert CN = normalized MAC (lowercase, no colons). Must match clientid.';
COMMENT ON COLUMN device_certs.fingerprint IS 'SHA-256 of DER cert (format: lowercase hex, no colons)';

CREATE TRIGGER trg_device_certs_set_updated_at
    BEFORE UPDATE ON device_certs
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

ALTER TABLE device_certs ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_certs FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON device_certs
    USING (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        tenant_id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

-- Critical indexes for EMQX auth backend lookup (must be <20ms per V3-DATABASE-DESIGN §11)
CREATE INDEX idx_device_certs_fingerprint ON device_certs (fingerprint) WHERE status = 'ACTIVE';
CREATE INDEX idx_device_certs_cn          ON device_certs (cn)          WHERE status = 'ACTIVE';
CREATE INDEX idx_device_certs_ca_id       ON device_certs (ca_id);
CREATE INDEX idx_device_certs_tenant_id   ON device_certs (tenant_id, status);

GRANT SELECT, INSERT, UPDATE, DELETE ON device_certs TO she_app;
GRANT USAGE, SELECT ON SEQUENCE device_certs_id_seq TO she_app;
