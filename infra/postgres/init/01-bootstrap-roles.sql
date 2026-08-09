-- =============================================================================
-- SHE V3 — Postgres bootstrap init script
-- Runs ONCE on first container start (docker-entrypoint-initdb.d)
-- =============================================================================
-- Canonical reference: V3-CONFIGURATION.md §2.3, V3-SECURITY-MODEL §10.5 (P0-5)
--
-- Roles:
--   she_app       — application role, NO BYPASSRLS (P0-5). Spring Boot uses this.
--   she_migrate   — migration role, can CREATE/DROP tables + RLS policies.
--                   Flyway connects with this role ONLY during migration.
--   she_superuser — postgres superuser, ops/maintenance only.
--
-- The container is started with POSTGRES_USER=she_app. To allow Flyway to
-- perform DDL, we create she_migrate as SUPERUSER for local dev ONLY.
-- In production, she_migrate is a separate role with CREATE-on-schema
-- privileges but NOT BYPASSRLS — DDL still respects RLS for any DML.
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

-- Application role (already created by POSTGRES_USER env var, but ensure grants)
-- P0-5: she_app does NOT have BYPASSRLS — confirmed by NOT granting it here.
GRANT USAGE ON SCHEMA public TO she_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO she_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
   GRANT USAGE, SELECT ON SEQUENCES TO she_app;

-- Set default search_path for both roles
ALTER ROLE she_app    SET search_path TO public;
ALTER ROLE she_migrate SET search_path TO public;

-- Notify
\echo '== SHE V3 Postgres bootstrap complete =='
\echo '== Roles created: she_app (app, NO BYPASSRLS), she_migrate (DDL) =='
\echo '== Extensions enabled: uuid-ossp, pgcrypto, timescaledb, pg_stat_statements =='
