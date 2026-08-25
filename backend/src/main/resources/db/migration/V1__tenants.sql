-- =============================================================================
-- SHE V3 — Flyway migration V1: tenants
-- =============================================================================
-- Creates the `tenants` table — root of the multi-tenant hierarchy.
-- Also installs the canonical RLS policy (P0-5):
--   tenant_id = current_setting('app.tenant_id')::uuid
--   OR current_setting('app.is_platform_admin', true)::boolean
--
-- The `she_app` Postgres role does NOT have BYPASSRLS (P0-5).
-- Spring Boot `TenantContextFilter` sets `app.tenant_id` + `app.is_platform_admin`
-- per request via `SET LOCAL`.
--
-- Reference: V3-DATABASE-DESIGN §4.1, V3-SECURITY-MODEL §10.5, V3-ARCHITECTURE §5.1
-- =============================================================================

-- Required extensions (also created by 01-bootstrap-roles.sql, but defensive)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- tenants table
-- =============================================================================
CREATE TABLE tenants (
    id              UUID         PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(100) NOT NULL,
    subdomain       VARCHAR(50)  NOT NULL UNIQUE,
    plan            VARCHAR(20)  NOT NULL CHECK (plan IN (
                                    'B2B-100', 'B2B-1000', 'B2B-UNLIMITED',
                                    'B2C-FREE', 'B2C-PREMIUM', 'B2C-FAMILY'
                                  )),
    status          VARCHAR(20)  NOT NULL DEFAULT 'TRIAL' CHECK (status IN (
                                    'TRIAL', 'ACTIVE', 'SUSPENDED', 'TERMINATED'
                                  )),
    branding_config JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

COMMENT ON TABLE tenants IS 'Multi-tenant root. RLS-enforced per P0-5.';
COMMENT ON COLUMN tenants.subdomain IS 'Unique per-tenant subdomain e.g. ethiotelecom → ethiotelecom.she.et';
COMMENT ON COLUMN tenants.plan IS 'B2C: FREE/PREMIUM/FAMILY. B2B: per-device tiers (100/1000/unlimited)';
COMMENT ON COLUMN tenants.branding_config IS '{"logo_url","primary_color","accent_color","app_name"}';

-- =============================================================================
-- Updated_at trigger (shared by all tables with updated_at column)
-- =============================================================================
CREATE OR REPLACE FUNCTION she_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tenants_set_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION she_set_updated_at();

-- =============================================================================
-- Canonical RLS policy (P0-5)
-- =============================================================================
-- The policy itself checks `current_setting('app.is_platform_admin', true)`.
-- `true` as 2nd arg = missing_ok; returns NULL/false if GUC unset (defaults to deny).
-- `she_app` does NOT have BYPASSRLS — the policy is the only bypass mechanism.

ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON tenants
    USING (
        id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    )
    WITH CHECK (
        id = current_setting('app.tenant_id', true)::uuid
        OR current_setting('app.is_platform_admin', true)::boolean
    );

-- =============================================================================
-- Seed: default B2C tenant (so users created via /auth/register can attach)
-- =============================================================================
-- In production, the first SUPER_ADMIN creates tenants via admin API.
-- In local dev, we pre-create a default B2C tenant so registration works.
INSERT INTO tenants (id, name, subdomain, plan, status, branding_config)
VALUES (
    '00000000-0000-0000-0000-000000000001'::uuid,
    'SHE B2C Default',
    'default',
    'B2C-FREE',
    'ACTIVE',
    '{"logo_url":null,"primary_color":"#0B1D37","accent_color":"#56B4FA","app_name":"Smart Home Ethiopia"}'::jsonb
)
ON CONFLICT (subdomain) DO NOTHING;

-- =============================================================================
-- Grants — she_app gets standard DML; she_migrate owns DDL
-- =============================================================================
GRANT SELECT, INSERT, UPDATE, DELETE ON tenants TO she_app;

-- =============================================================================
-- Indexes (V3-DATABASE-DESIGN §9)
-- =============================================================================
CREATE INDEX idx_tenants_subdomain ON tenants (subdomain) WHERE deleted_at IS NULL;
CREATE INDEX idx_tenants_status    ON tenants (status)    WHERE deleted_at IS NULL;
