-- =============================================================================
-- SHE V3 — Flyway migration V30: NULL-safe RLS policies
-- =============================================================================
-- Every `tenant_isolation` policy written in V1..V29 reads the tenant GUC as:
--
--     current_setting('app.tenant_id', true)::uuid
--
-- That is unsafe on a *pooled* connection, because the return value depends on
-- whether the GUC has ever been touched in the session:
--
--   * never touched      -> current_setting(..., true) = NULL   (clean deny)
--   * touched at least once, then the transaction ended
--                        -> current_setting(..., true) = ''     (EMPTY STRING)
--
-- The second case is the normal one under HikariCP: `SET LOCAL app.tenant_id`
-- is issued on a connection, the transaction commits, the GUC reverts to the
-- session value — and for a custom (placeholder) GUC that session value is the
-- empty string, not NULL. The placeholder then lives for as long as the pooled
-- connection does.
--
-- `''::uuid` is a hard error rather than a NULL:
--
--     ERROR:  invalid input syntax for type uuid: ""
--     SQLSTATE: 22P02
--
-- So any statement that runs on a warm pooled connection *without* re-issuing
-- the GUC raises 22P02 instead of simply matching zero rows. With RLS actually
-- enforced that turns a clean "you can't see this tenant's data" into a 500.
--
-- Fix: guard every GUC read with NULLIF(..., ''), and wrap the platform-admin
-- flag in COALESCE(..., false) so an unset/empty GUC is unambiguously "deny"
-- rather than NULL (NULL OR NULL evaluates to NULL, which denies, but relying
-- on three-valued logic here is needlessly fragile).
--
--     col = NULLIF(current_setting('app.tenant_id', true), '')::uuid
--     OR COALESCE(NULLIF(current_setting('app.is_platform_admin', true), '')::boolean, false)
--
-- The per-table `OR <col> IS NULL` allowances are preserved exactly as found in
-- the live catalog — including the USING / WITH CHECK asymmetry on
-- nodes / node_devices / node_params, where tenant_id = NULL is permitted on
-- INSERT (factory pre-claim: the node exists before it is claimed by a tenant)
-- but not on SELECT.
--
-- Canonical references: V3-SECURITY-MODEL §10.5, V3-ARCHITECTURE §5.1, P0-5.
-- =============================================================================

DO $$
DECLARE
    spec      record;
    using_sql text;
    check_sql text;
    n_rebuilt int := 0;
BEGIN
    FOR spec IN
        SELECT * FROM (VALUES
            -- table                       tenant col    null_using  null_check
            ('api_keys',                 'tenant_id', false, false),
            ('audit_log',                'tenant_id', true,  true ),
            ('automations',              'tenant_id', false, false),
            ('device_ca_certs',          'tenant_id', false, false),
            ('device_certs',             'tenant_id', false, false),
            ('device_telemetry',         'tenant_id', false, false),
            ('feature_flags',            'tenant_id', false, false),
            ('home_members',             'tenant_id', false, false),
            ('homes',                    'tenant_id', false, false),
            ('node_devices',             'tenant_id', false, true ),
            ('node_groups',              'tenant_id', false, false),
            ('node_params',              'tenant_id', false, true ),
            ('nodes',                    'tenant_id', false, true ),
            ('notification_log',         'tenant_id', false, false),
            ('notification_preferences', 'tenant_id', false, false),
            ('oauth_identities',         'tenant_id', false, false),
            ('ota_approvals',            'tenant_id', false, false),
            ('ota_batches',              'tenant_id', false, false),
            ('payments',                 'tenant_id', false, false),
            ('rooms',                    'tenant_id', false, false),
            ('scenes',                   'tenant_id', false, false),
            ('subscriptions',            'tenant_id', false, false),
            ('tenants',                  'id',        false, false),
            ('user_devices',             'tenant_id', false, false),
            ('users',                    'tenant_id', false, false)
        ) AS v(tbl, col, null_using, null_check)
    LOOP
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

        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I', spec.tbl);
        EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (%s) WITH CHECK (%s)',
                       spec.tbl, using_sql, check_sql);
        n_rebuilt := n_rebuilt + 1;
    END LOOP;

    RAISE NOTICE 'V30: rebuilt % RLS policies with NULL-safe GUC reads', n_rebuilt;
END $$;
