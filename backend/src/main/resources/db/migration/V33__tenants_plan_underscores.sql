-- =============================================================================
-- SHE V3 — Flyway migration V33: Fix tenant plan format (hyphens → underscores)
-- =============================================================================
-- BUG FIX: V1__tenants.sql CHECK constraint uses HYPHENS ('B2B-100', 'B2C-FREE')
-- but all Java code uses UNDERSCORES ('B2B_100', 'B2C_FREE').
-- This causes DataIntegrityViolationException on tenant creation + MRR calc fails.
--
-- ORDER IS LOAD-BEARING. The original ordering was DROP → ADD → UPDATE, which
-- cannot work: ADD CONSTRAINT validates every existing row, and the seeded row
-- still holds 'B2C-FREE' at that point, so it aborts with
--   "check constraint 'tenants_plan_check' is violated by some row".
-- The rows must be normalised while no constraint is in force — hence
-- DROP → UPDATE → ADD, in that order.
--
-- RLS: tenants has row level security enabled AND forced, so the UPDATEs below
-- would silently match zero rows under a non-superuser migration role. Flyway
-- runs as she_migrate (spring.flyway.user), which is superuser and bypasses RLS;
-- the GUC is set anyway so this stays correct if that ever changes.
-- =============================================================================

SET LOCAL app.is_platform_admin = 'on';

-- 1. Drop the old CHECK constraint (V1 created it as tenants_plan_check, hyphens)
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_plan_check;

-- 2. Normalise existing rows while no constraint is in force.
UPDATE tenants SET plan = 'B2C_FREE'       WHERE plan = 'B2C-FREE';
UPDATE tenants SET plan = 'B2C_PREMIUM'    WHERE plan = 'B2C-PREMIUM';
UPDATE tenants SET plan = 'B2C_FAMILY'     WHERE plan = 'B2C-FAMILY';
UPDATE tenants SET plan = 'B2B_100'        WHERE plan = 'B2B-100';
UPDATE tenants SET plan = 'B2B_1000'       WHERE plan = 'B2B-1000';
UPDATE tenants SET plan = 'B2B_UNLIMITED'  WHERE plan = 'B2B-UNLIMITED';

-- 3. Add the new CHECK with underscores (matches PaymentService, BillingService).
--    Safe now: every remaining row already uses underscores.
ALTER TABLE tenants ADD CONSTRAINT tenants_plan_check CHECK (plan IN (
    'B2B_100', 'B2B_1000', 'B2B_UNLIMITED',
    'B2C_FREE', 'B2C_PREMIUM', 'B2C_FAMILY'
));

-- 4. Re-seed with the correct format (idempotent — subdomain is the UNIQUE key)
INSERT INTO tenants (id, name, subdomain, plan, status, branding_config)
VALUES (
    '00000000-0000-0000-0000-000000000001'::uuid,
    'SHE B2C Default',
    'default',
    'B2C_FREE',
    'ACTIVE',
    '{"logo_url":null,"primary_color":"#0B1D37","accent_color":"#56B4FA","app_name":"Smart Home Ethiopia"}'::jsonb
)
ON CONFLICT (subdomain) DO UPDATE SET plan = 'B2C_FREE';
