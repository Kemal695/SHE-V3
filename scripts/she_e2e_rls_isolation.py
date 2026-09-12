#!/usr/bin/env python3
"""
SHE V3 — Row-Level Security cross-tenant isolation proof (P0-5).

Why this exists
---------------
Tenant isolation was previously *unverifiable*. Three independent defects
combined to make every RLS policy inert:

  1. `she_app` was the bootstrap superuser (docker-compose set
     POSTGRES_USER=she_app), and superusers skip RLS entirely.
  2. TenantContextAspect ran OUTSIDE the transaction (it was pinned to
     HIGHEST_PRECEDENCE, and Spring's transaction interceptor defaults to
     LOWEST_PRECEDENCE), so its `SET LOCAL` was discarded by Postgres.
  3. The aspect's `@annotation(Transactional)` pointcut only matched @Transactional
     written on the method, so class-level transactional services got no GUCs.

This script proves isolation actually holds now, from two directions:

  A. Through the API — a user in tenant A must not see tenant B's data.
  B. At the database layer — the same query run as `she_app` returns zero rows
     with a tenant GUC set, and the expected rows with platform-admin set.

Run after `scripts/she_e2e_track1.py`; both need the backend up.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("SHE_BASE", "http://localhost:8080")
DEFAULT_TENANT = "00000000-0000-0000-0000-000000000001"
PROBE_SUBDOMAIN = "rls-probe"
PROBE_EMAIL = "rls-probe-b@example.et"

results = []


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def psql(sql):
    """Run as the privileged observer (she_superuser) — for setup/teardown."""
    r = sh(f'docker exec she-postgres psql -U she_superuser -d she_v3 -t -A -c "{sql}"')
    return r.stdout.strip()


def psql_as_app(guc_statements, sql):
    """Run as she_app (NOSUPERUSER NOBYPASSRLS) with RLS GUCs set in one tx.

    Returns just the query result: psql echoes BEGIN / SET / COMMIT, so those
    control lines are stripped and the last remaining line is the real answer.
    """
    body = " ".join(guc_statements + [sql])
    r = sh('docker exec she-postgres psql -U she_app -d she_v3 -t -A -c "BEGIN; '
           + body + ' COMMIT;"')
    lines = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    vals = [ln for ln in lines
            if ln not in ("BEGIN", "COMMIT") and not ln.upper().startswith("SET")]
    return (vals[-1] if vals else ""), r.returncode


def http(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode() or "{}"
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


def record(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))


def main():
    print("=== SHE V3 RLS cross-tenant isolation (P0-5) ===\n")

    # ── 0. Preconditions ───────────────────────────────────────────────
    print("0. Preconditions")
    attrs = psql("SELECT rolsuper || '/' || rolbypassrls FROM pg_roles WHERE rolname='she_app'")
    record("L0.1 she_app is NOSUPERUSER NOBYPASSRLS (else RLS can't be enforced)",
           attrs in ("f/f", "false/false"), f"rolsuper/rolbypassrls={attrs}")

    pol = psql("SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid "
               "JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'")
    record("L0.2 RLS policies installed", pol not in ("0", ""), f"{pol} policies")

    # ── 1. Create a second tenant with data tenant A must never see ─────
    print("\n1. Seed a foreign tenant (tenant B)")
    psql(f"INSERT INTO tenants (name, subdomain, plan, status) VALUES "
         f"('RLS Probe Tenant','{PROBE_SUBDOMAIN}','B2C-FREE','ACTIVE') "
         f"ON CONFLICT (subdomain) DO NOTHING;")
    tenant_b = psql(f"SELECT id FROM tenants WHERE subdomain='{PROBE_SUBDOMAIN}';")
    record("L1.1 tenant B created", bool(tenant_b), f"tenant_b={tenant_b}")

    psql(f"DELETE FROM homes WHERE tenant_id='{tenant_b}';")
    psql(f"DELETE FROM users WHERE tenant_id='{tenant_b}';")
    # homes.owner_user_id is NOT NULL, so tenant B needs a user before a home.
    # Both inserts are written as INSERT...SELECT so no id has to be round-tripped
    # back through the shell.
    psql(f"INSERT INTO users (tenant_id, email, password_hash, platform_role, "
         f"created_at, updated_at) SELECT '{tenant_b}', '{PROBE_EMAIL}', 'not-a-real-hash', "
         f"'USER', now(), now() WHERE NOT EXISTS "
         f"(SELECT 1 FROM users WHERE email='{PROBE_EMAIL}');")
    psql(f"INSERT INTO homes (name, address, tenant_id, owner_user_id, created_at, updated_at)"
         f" SELECT 'Tenant B Secret Home', 'Addis Ababa', '{tenant_b}', u.id, now(), now()"
         f" FROM users u WHERE u.email='{PROBE_EMAIL}';")
    b_homes = psql(f"SELECT count(*) FROM homes WHERE tenant_id='{tenant_b}';")
    record("L1.2 tenant B owns a home", b_homes not in ("0", ""), f"homes={b_homes}")

    # ── 2. Register a user in the default tenant (tenant A) ─────────────
    print("\n2. Register a user in tenant A")
    stamp = int(time.time())
    st, reg = http("POST", "/api/v3/auth/register",
                   body={"email": f"rls-{stamp}@example.et", "password": "E2ePass!12345"})
    token = (reg.get("data") or {}).get("access_token")
    record("L2.1 register user in tenant A", bool(token), f"HTTP {st}")

    if not token:
        print("\n  cannot continue without a token")
        cleanup(tenant_b)
        return summarise()

    # ── 3. API isolation ────────────────────────────────────────────────
    print("\n3. API-level isolation")
    st, homes = http("GET", "/api/v3/homes", token=token)
    names = [h.get("name") for h in (homes.get("data") or [])]
    record("L3.1 GET /homes does not leak tenant B's home",
           "Tenant B Secret Home" not in names, f"HTTP {st} homes={names}")
    record("L3.2 tenant A still sees its own home (positive control)",
           any(n == "My Home" for n in names), f"homes={names}")

    # ── 4. Database-layer isolation (the actual RLS proof) ──────────────
    print("\n4. Database-layer isolation as she_app")
    hidden, rc = psql_as_app(
        [f"SET LOCAL app.tenant_id = '{DEFAULT_TENANT}';"],
        f"SELECT count(*) FROM homes WHERE tenant_id='{tenant_b}';")
    record("L4.1 she_app + tenant A GUC sees 0 rows of tenant B",
           rc == 0 and hidden == "0", f"count={hidden} rc={rc}")

    visible, rc = psql_as_app(
        ["SET LOCAL app.is_platform_admin = 'on';"],
        f"SELECT count(*) FROM homes WHERE tenant_id='{tenant_b}';")
    record("L4.2 she_app + platform-admin GUC sees tenant B's rows (bypass works)",
           rc == 0 and visible != "0", f"count={visible} rc={rc}")

    # Empty-string placeholder case: set the GUC in one transaction, then query
    # again in a LATER transaction of the SAME session without re-setting it.
    # current_setting() then returns '' rather than NULL; before the NULLIF fix
    # that raised 22P02 ('invalid input syntax for type uuid: ""').
    warm = sh('docker exec she-postgres psql -U she_app -d she_v3 -t -A -c "'
              f"BEGIN; SET LOCAL app.tenant_id = '{DEFAULT_TENANT}'; COMMIT; "
              'BEGIN; SET LOCAL app.is_platform_admin = \'on\'; '
              f"SELECT count(*) FROM homes WHERE tenant_id='{tenant_b}'; COMMIT;\"")
    out = (warm.stdout or "") + (warm.stderr or "")
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    vals = [ln for ln in lines
            if ln not in ("BEGIN", "COMMIT") and not ln.upper().startswith("SET")]
    last = vals[-1] if vals else "(empty)"
    record("L4.3 no 22P02 in a later tx of a warmed session (NULL-safe policy)",
           warm.returncode == 0
           and "invalid input syntax" not in out and "22P02" not in out
           and last != "0",
           f"result={last} rc={warm.returncode}")

    cleanup(tenant_b)
    summarise()


def cleanup(tenant_b):
    if tenant_b:
        psql(f"DELETE FROM homes WHERE tenant_id='{tenant_b}';")
        psql(f"DELETE FROM users WHERE tenant_id='{tenant_b}';")
        psql(f"DELETE FROM tenants WHERE id='{tenant_b}';")


def summarise():
    passed = sum(1 for _, ok, _ in results if ok)
    print("\n" + "=" * 68)
    print(f"  {passed}/{len(results)} checks passed")
    print("=" * 68)
    if passed != len(results):
        print("\n  Failures:")
        for name, ok, detail in results:
            if not ok:
                print(f"    - {name}: {detail}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
