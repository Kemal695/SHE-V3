-- =============================================================================
-- SHE V3 — Flyway migration V32: RLS for automation_rules (inherited scope)
-- =============================================================================
-- V31 covered every table with its own tenant_id column. automation_rules is the
-- last tenant-scoped table and does NOT have one: it hangs off
-- automation_id -> automations(id), and automations is already RLS-protected.
--
-- So it needs an inherited-scope policy: a rule is visible iff its parent
-- automation is visible. The subquery runs against automations, whose own
-- tenant_isolation policy applies to it — so the two compose correctly instead
-- of duplicating the tenant predicate:
--
--   * no GUC            -> the subquery itself matches nothing -> deny
--   * tenant GUC        -> only that tenant's automations -> only their rules
--   * platform-admin    -> the OR branch short-circuits to true
--
-- No recursion risk: automation_rules' policy references automations, never
-- itself.
--
-- The table is unused by application code today, so this is purely defence in
-- depth — the same argument that justified V31 for node_group_members and
-- scene_actions. The subquery is evaluated per row; acceptable for a table this
-- size, and it is the only way to express "same tenant as my parent" without
-- denormalising tenant_id onto the child.
--
-- Canonical references: V3-SECURITY-MODEL §10.5, V3-ARCHITECTURE §5.1, P0-5.
-- =============================================================================

DO $$
DECLARE
    using_sql text;
    check_sql text;
BEGIN
    IF to_regclass('public.automation_rules') IS NULL THEN
        RAISE NOTICE 'V32: skipping automation_rules (table does not exist)';
        RETURN;
    END IF;

    using_sql :=
        'automation_id IN (SELECT id FROM public.automations)'
        || ' OR COALESCE(NULLIF(current_setting(''app.is_platform_admin'', true), '''')::boolean, false)';
    check_sql := using_sql;

    EXECUTE 'ALTER TABLE public.automation_rules ENABLE ROW LEVEL SECURITY';
    EXECUTE 'ALTER TABLE public.automation_rules FORCE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS tenant_isolation ON public.automation_rules';
    EXECUTE format('CREATE POLICY tenant_isolation ON public.automation_rules USING (%s) WITH CHECK (%s)',
                   using_sql, check_sql);

    RAISE NOTICE 'V32: enabled RLS + inherited-scope policy on automation_rules';
END $$;
