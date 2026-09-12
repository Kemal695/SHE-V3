-- =============================================================================
-- SHE V3 — Flyway migration V31: close the remaining RLS gaps
-- =============================================================================
-- V30 made the 25 existing tenant_isolation policies NULL-safe, but it could only
-- rebuild policies on tables that already had RLS turned on. A sweep of the
-- catalogue shows four tables that carry a tenant_id column yet have
-- relrowsecurity = false, i.e. NO row-level security at all:
--
--     device_energy_readings   tenant_id NOT NULL   40 rows   <- real data
--     blacklisted_tokens       tenant_id NULLABLE    0 rows
--     node_group_members       tenant_id NOT NULL    0 rows
--     scene_actions            tenant_id NOT NULL    0 rows
--
-- device_energy_readings is the material one. It is a hypertable holding
-- per-device energy/cost telemetry, queried only through raw JdbcTemplate SQL in
-- EnergyService (there is no JPA entity, so RLS is the ONLY thing that can
-- constrain it). Every current query does remember to say `WHERE tenant_id = ?`,
-- so this is not an active leak — but it is one forgotten predicate away from
-- being one, and the other 26 tenant tables are all protected. Defence in depth.
--
-- The other three are currently unused by application code; they are included so
-- that a future repository cannot be written against an unprotected table.
--
-- blacklisted_tokens.tenant_id is nullable on purpose (a global blacklist entry
-- applies to every tenant), so its policy keeps `OR tenant_id IS NULL` on the
-- USING side. The WITH CHECK side deliberately does NOT: minting a global entry
-- must require the platform-admin GUC.
--
-- Policy text matches V30 exactly (NULLIF(...,'') + COALESCE(...,false)) so a
-- warmed pooled connection denies instead of raising 22P02.
--
-- Note: FORCE ROW LEVEL SECURITY is applied to match the other 26 tables.
-- Under it the table owner is also subject to the policy unless it holds
-- BYPASSRLS; the owner here is she_migrate (used by Flyway), so migrations and
-- the TimescaleDB background jobs are unaffected.
--
-- Not covered here (no tenant_id column, not tenant-scoped): factory_audit_log
-- (factory workstation scope) and automation_rules (reachable only through its
-- RLS-protected parent, automations).
--
-- Canonical references: V3-SECURITY-MODEL §10.5, V3-ARCHITECTURE §5.1, P0-5.
-- =============================================================================

DO $$
DECLARE
    spec      record;
    using_sql text;
    check_sql text;
    n_enabled int := 0;
BEGIN
    FOR spec IN
        SELECT * FROM (VALUES
            -- table                       tenant col    null_using  null_check
            ('device_energy_readings',   'tenant_id', false, false),
            ('blacklisted_tokens',       'tenant_id', true,  false),
            ('node_group_members',       'tenant_id', false, false),
            ('scene_actions',            'tenant_id', false, false)
        ) AS v(tbl, col, null_using, null_check)
    LOOP
        IF to_regclass('public.' || quote_ident(spec.tbl)) IS NULL THEN
            RAISE NOTICE 'V31: skipping % (table does not exist)', spec.tbl;
            CONTINUE;
        END IF;

        using_sql := format(
            '%I = NULLIF(current_setting(''app.tenant_id'', true), '''')::uuid'
            ' OR COALESCE(NULLIF(current_setting(''app.is_platform_admin'', true), '''')::boolean, false)',
            spec.col);
        check_sql := using_sql;

        IF spec.null_using THEN
            using_sql := using_sql || format(' OR %I IS NULL', spec.col);
        END IF;
        IF spec.null_check THEN
            check_sql := check_sql || format(' OR %I IS NULL', spec.col);
        END IF;

        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', spec.tbl);
        EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', spec.tbl);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON public.%I', spec.tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON public.%I USING (%s) WITH CHECK (%s)',
                       spec.tbl, using_sql, check_sql);
        n_enabled := n_enabled + 1;
    END LOOP;

    RAISE NOTICE 'V31: enabled RLS + tenant_isolation policy on % tables', n_enabled;
END $$;
