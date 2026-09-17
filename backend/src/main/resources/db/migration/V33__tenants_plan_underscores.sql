-- =============================================================================
-- SHE V3 — Flyway migration V33: Fix tenant plan format (hyphens → underscores)
-- =============================================================================
-- BUG FIX: V1__tenants.sql CHECK constraint uses HYPHENS ('B2B-100', 'B2C-FREE')
-- but all Java code uses UNDERSCORES ('B2B_100', 'B2C_FREE').
-- This causes DataIntegrityViolationException on tenant creation + MRR calc fails.
--
-- Fix: drop old CHECK, add new CHECK with underscores, update seeded rows.
-- =============================================================================

-- Drop the old CHECK constraint (V1 created it as tenants_plan_check)
ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_plan_check;

-- Add new CHECK with underscores (matches Java code: PaymentService, BillingService, etc.)
ALTER TABLE tenants ADD CONSTRAINT tenants_plan_check CHECK (plan IN (
    'B2B_100', 'B2B_1000', 'B2B_UNLIMITED',
    'B2C_FREE', 'B2C_PREMIUM', 'B2C_FAMILY'
));

-- Update seeded B2C tenant (V1 inserted 'B2C-FREE' → change to 'B2C_FREE')
UPDATE tenants SET plan = 'B2C_FREE' WHERE plan = 'B2C-FREE';
UPDATE tenants SET plan = 'B2C_PREMIUM' WHERE plan = 'B2C-PREMIUM';
UPDATE tenants SET plan = 'B2C_FAMILY' WHERE plan = 'B2C-FAMILY';
UPDATE tenants SET plan = 'B2B_100' WHERE plan = 'B2B-100';
UPDATE tenants SET plan = 'B2B_1000' WHERE plan = 'B2B-1000';
UPDATE tenants SET plan = 'B2B_UNLIMITED' WHERE plan = 'B2B-UNLIMITED';

-- Also fix the seed INSERT in V1 (idempotent — ON CONFLICT DO NOTHING)
-- Re-seed with correct plan format (won't conflict since subdomain is the UNIQUE key)
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
