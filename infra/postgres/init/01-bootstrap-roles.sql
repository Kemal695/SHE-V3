-- =============================================================================
-- SHE V3 — Postgres bootstrap init script
-- Runs ONCE on first container start (docker-entrypoint-initdb.d)
-- =============================================================================
-- Canonical reference: V3-CONFIGURATION.md §2.3, V3-SECURITY-MODEL §10.5 (P0-5)
--
-- Roles:
--   she_superuser — the POSTGRES_USER bootstrap superuser (OID 10). Ops only.
--   she_app       — application role, NO BYPASSRLS (P0-5). Spring Boot uses this.
--   she_migrate   — migration role, can CREATE/DROP tables + RLS policies.
--                   Flyway connects with this role ONLY during migration.
--
-- WHY she_app IS *NOT* POSTGRES_USER
--   Postgres hard-codes exactly one role as the bootstrap superuser (OID 10)
--   and refuses to let it drop SUPERUSER:
--       ERROR: The bootstrap user must have the SUPERUSER attribute.
--   POSTGRES_USER *is* that role. Setting POSTGRES_USER=she_app therefore made
--   the application a superuser — and superusers bypass RLS unconditionally,
--   so every tenant_isolation policy was silently inert no matter what the
--   policy text said. she_app must be created here as a plain role instead.
--
-- she_migrate is SUPERUSER in local dev ONLY, so Flyway can run DDL. In
-- production it is a separate role with CREATE-on-schema privileges but
-- NOT BYPASSRLS — DDL still respects RLS for any DML.
-- =============================================================================

-- Required extensions (must be created by superuser)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";          -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";           -- gen_random_bytes(), crypt()
CREATE EXTENSION IF NOT EXISTS "timescaledb";        -- hypertables (V3-ARCHITECTURE §5.2)
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- query metrics

-- Migration role (local dev: superuser to allow DDL; prod: scoped to schema)
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'she_migrate') THEN
      CREATE ROLE she_migrate WITH LOGIN PASSWORD 'ChangeMeLocal'
         SUPERUSER CREATEROLE CREATEDB;
   END IF;
END$$;

-- =============================================================================
-- Application role (P0-5)
-- =============================================================================
-- Created explicitly rather than inherited from POSTGRES_USER (see header).
-- A superuser — or any role with BYPASSRLS — skips RLS evaluation entirely,
-- so both attributes have to be denied here.
DO $$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'she_app') THEN
      CREATE ROLE she_app WITH LOGIN PASSWORD 'ChangeMeLocal'
         NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
   END IF;
END$$;

-- Verify rather than assume. If someone points POSTGRES_USER back at she_app,
-- the role becomes OID 10 (bootstrap superuser) and RLS stops being enforced —
-- fail the bootstrap loudly instead of shipping a silently-open database.
DO $$
DECLARE
    r record;
BEGIN
    SELECT oid, rolsuper, rolbypassrls INTO r FROM pg_roles WHERE rolname = 'she_app';

    IF r.oid = 10 THEN
        RAISE EXCEPTION
            'P0-5 violated: she_app is the bootstrap superuser (OID 10). '
            'Set POSTGRES_USER to a dedicated superuser (e.g. she_superuser); '
            'the bootstrap role cannot be demoted and would bypass all RLS.';
    END IF;
    IF r.rolsuper OR r.rolbypassrls THEN
        RAISE EXCEPTION
            'P0-5 violated: she_app has rolsuper=% rolbypassrls=% — RLS would be bypassed',
            r.rolsuper, r.rolbypassrls;
    END IF;

    RAISE NOTICE 'P0-5 OK: she_app (oid %) is NOSUPERUSER NOBYPASSRLS — RLS is enforced', r.oid;
END $$;

-- Grants. Table/sequence privileges are issued by each Flyway migration as well;
-- these defaults cover objects created afterwards.
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO she_app', current_database());
END $$;
GRANT USAGE ON SCHEMA public TO she_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO she_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
   GRANT USAGE, SELECT ON SEQUENCES TO she_app;
-- Migrations run as she_migrate, so its default privileges are the ones that
-- actually apply to migration-created objects.
ALTER DEFAULT PRIVILEGES FOR ROLE she_migrate IN SCHEMA public
   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO she_app;
ALTER DEFAULT PRIVILEGES FOR ROLE she_migrate IN SCHEMA public
   GRANT USAGE, SELECT ON SEQUENCES TO she_app;

-- Set default search_path
ALTER ROLE she_app     SET search_path TO public;
ALTER ROLE she_migrate SET search_path TO public;

-- Notify
\echo '== SHE V3 Postgres bootstrap complete =='
\echo '== Roles: she_app (app, NOSUPERUSER NOBYPASSRLS), she_migrate (DDL) =='
\echo '== Extensions enabled: uuid-ossp, pgcrypto, timescaledb, pg_stat_statements =='
