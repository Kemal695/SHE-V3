#!/usr/bin/env python
"""
SHE V3 - Phase-1 exit criterion: certificate revocation, end to end.

Closes the one outstanding Phase-0/Phase-1 exit criterion from
docs/PHASE0-SIGNOFF.md:

    "CA operational - can issue AND REVOKE device certs via step-ca;
     CRL endpoint serves"

This exercises the real path, no mocks:

    POST /internal/ca/sign-and-register  ->  step-ca /sign   (fresh cert)
    POST /internal/ca/revoke             ->  step-ca /revoke (ott + 0x serial)
                                         ->  device_certs row -> REVOKED
                                         ->  step-ca regenerates its CRL
    GET  https://localhost:9002/crl      ->  CRL number bumps,
                                             revoked serial is listed
    infra/ca/refresh-crl.sh              ->  published CRL (nginx :8088)
                                             lists the revoked serial

Prerequisites: the local stack is up (docker compose + backend on :8080), and
step-ca's ca.json has `db` and `crl` blocks. Two failure modes to know about:

  * without a `db` block step-ca cannot record a revoked serial; and
  * step-ca 0.27.x implements passive revocation ONLY, so the request body must
    carry `"passive": true` or Validate() rejects it outright.

Both surface as the same, uninformative
"501 The requested method is not implemented by the certificate authority."
(errs.Errorf overwrites the specific reason with that default for every status
code). See docs/PHASE1-BUGFIX-REPORT.md §7.2.

Usage:  python she_e2e_revocation.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8080"
STEP_CA_CRL = "https://localhost:9002/crl"
CRL_SERVER = "http://localhost:8088/ca"
TENANT_ID = "00000000-0000-0000-0000-000000000001"
CA_ID = TENANT_ID
WORK = tempfile.mkdtemp(prefix="she-revoke-")

RESULTS = []


# ───────────────────────────── helpers ─────────────────────────────

def record(test, ok, detail):
    RESULTS.append((test, "PASS" if ok else "FAIL", detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {test}: {detail}", flush=True)


def http(method, path, token=None, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:400]}
    except Exception as e:
        return 0, {"error": str(e)}


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def psql(sql):
    # Verify as a privileged observer, NOT as she_app. Since P0-5 is enforced,
    # she_app is a plain NOSUPERUSER NOBYPASSRLS role: these raw verification
    # queries set no app.tenant_id GUC, so RLS would filter them and report 0
    # rows even when the application wrote the data correctly.
    r = sh(f'docker exec she-postgres psql -U she_superuser -d she_v3 -t -A -c "{sql}"')
    return r.stdout.strip()


def make_csr(cn):
    """ECDSA P-256 keypair + PKCS#10 CSR, as the ESP32 produces on-chip (P0-1)."""
    key = os.path.join(WORK, f"{cn}.key")
    csr = os.path.join(WORK, f"{cn}.csr")
    sh(f'openssl ecparam -name prime256v1 -genkey -noout -out "{key}"')
    sh(f'openssl req -new -key "{key}" -subj "/CN={cn}" -out "{csr}"')
    return open(csr).read()


def fetch_crl():
    """Fetch the CRL step-ca currently serves (DER)."""
    out = os.path.join(WORK, "crl.der")
    r = sh(f'curl -sk -m 10 -o "{out}" -w "%{{http_code}}" {STEP_CA_CRL}')
    code = r.stdout.strip()
    if code != "200":
        return None, code
    return open(out, "rb").read(), code


def parse_crl(der_bytes):
    """Return (crl_number, revoked_serials_upper_hex, last_update, next_update)."""
    path = os.path.join(WORK, "parse.der")
    with open(path, "wb") as fh:
        fh.write(der_bytes)
    r = sh(f'openssl crl -inform DER -in "{path}" -noout -text')
    text = r.stdout

    number = None
    m = re.search(r"X509v3 CRL Number:\s*\n\s*(\d+)", text)
    if m:
        number = int(m.group(1))

    serials = []
    # Lines like:  "    Serial Number: 7756AAEA..."
    for m in re.finditer(r"Serial Number:\s*([0-9A-Fa-f:]+)", text):
        serials.append(m.group(1).replace(":", "").upper())

    last = next_ = None
    m = re.search(r"Last Update:\s*(.+)", text)
    if m:
        last = m.group(1).strip()
    m = re.search(r"Next Update:\s*(.+)", text)
    if m:
        next_ = m.group(1).strip()

    return number, serials, last, next_


def finish():
    print()
    print("=" * 68)
    passed = sum(1 for _, s, _ in RESULTS if s == "PASS")
    print(f"  {passed}/{len(RESULTS)} checks passed")
    print("=" * 68)
    failed = [t for t, s, _ in RESULTS if s != "PASS"]
    if failed:
        print("  FAILED: " + ", ".join(failed))
    sys.exit(0 if not failed else 1)


# ───────────────────────────── main ─────────────────────────────

def main():
    print("SHE V3 - certificate revocation end-to-end")
    print(f"  backend : {BASE}")
    print(f"  step-ca : {STEP_CA_CRL}")
    print()

    # ---- 1. baseline CRL -------------------------------------------------
    print("1. Baseline CRL from step-ca")
    before_bytes, code = fetch_crl()
    if before_bytes is None:
        record("R1.1 step-ca serves a CRL", False, f"HTTP {code} - is step-ca up?")
        finish()
        return
    num_before, revoked_before, last_b, next_b = parse_crl(before_bytes)
    record("R1.1 step-ca serves a parseable CRL", num_before is not None,
           f"HTTP {code}, {len(before_bytes)} bytes, CRL number={num_before}, "
           f"revoked={len(revoked_before)}, next update={next_b}")

    # ---- 2. issue a fresh cert ------------------------------------------
    print("\n2. Issue a fresh device cert through the backend")
    cn = "e2e" + os.urandom(4).hex()
    csr_pem = make_csr(cn)
    st, signed = http("POST", "/internal/ca/sign-and-register", body={
        "csr_pem": csr_pem, "cn": cn, "tenant_id": TENANT_ID, "ca_id": CA_ID})
    data = signed.get("data") or {}
    serial = data.get("serial")
    record("R2.1 POST /internal/ca/sign-and-register", bool(serial),
           f"HTTP {st} cn={cn} serial={serial}")
    if not serial:
        print(json.dumps(signed)[:500])
        finish()
        return

    db_status = psql(
        f"SELECT status FROM device_certs WHERE cert_serial='{serial}'")
    record("R2.2 cert registered ACTIVE in device_certs", db_status == "ACTIVE",
           f"device_certs.status={db_status!r}")

    # ---- 3. revoke it ----------------------------------------------------
    print("\n3. Revoke it through the backend")
    st, rev = http("POST", "/internal/ca/revoke", body={
        "serial": serial, "reason": "e2e-test", "revoked_by_user_id": None})
    body_txt = json.dumps(rev)
    record("R3.1 POST /internal/ca/revoke accepted by step-ca",
           st == 200, f"HTTP {st} {body_txt[:200]}")
    record("R3.2 no 501 NOT_IMPLEMENTED (CA has a revocation store)",
           "NOT_IMPLEMENTED" not in body_txt.upper(),
           "step-ca accepted the ott + 0x-prefixed serial")

    # ---- 4. device_certs row updated ------------------------------------
    row = psql("SELECT status || '|' || coalesce(revoked_at::text,'') || '|' "
               "|| coalesce(revoke_reason,'') FROM device_certs "
               f"WHERE cert_serial='{serial}'")
    parts = (row.split("|") + ["", "", ""])[:3]
    record("R4.1 device_certs row -> REVOKED + revoked_at + reason",
           parts[0] == "REVOKED" and bool(parts[1]),
           f"status={parts[0]} revoked_at={parts[1]} reason={parts[2]}")

    # ---- 5. CRL now lists the serial ------------------------------------
    print("\n5. step-ca's CRL reflects the revocation")
    # step-ca regenerates the CRL on revoke, but /crl is cached (crl.cacheDuration)
    # and generation is asynchronous, so a single read immediately after the revoke
    # can legitimately still return the previous CRL. Observed once as a 11/13 run
    # with R5.2 + R6.3 failing, then 13/13 on the next three runs. Poll instead of
    # racing it, so a genuine regression is not masked by a timing flake.
    after_bytes, code = None, None
    num_after = revoked_after = last_a = next_a = None
    deadline = time.time() + 20
    while time.time() < deadline:
        after_bytes, code = fetch_crl()
        if after_bytes is not None:
            num_after, revoked_after, last_a, next_a = parse_crl(after_bytes)
            if serial.upper() in revoked_after:
                break
        time.sleep(2)
    if after_bytes is None:
        record("R5.1 CRL refetched after revoke", False, f"HTTP {code}")
        finish()
        return
    record("R5.1 CRL number incremented", num_after is not None
           and num_before is not None and num_after > num_before,
           f"{num_before} -> {num_after}")
    listed = serial.upper() in revoked_after
    record("R5.2 revoked serial is listed in the CRL", listed,
           f"CRL holds {len(revoked_after)} entry/entries: "
           f"{revoked_after if revoked_after else '(none)'}")
    record("R5.3 CRL is signed and time-bounded",
           bool(last_a) and bool(next_a),
           f"last={last_a} next={next_a}")

    # ---- 6. publication + the public (nginx) CRL endpoint ---------------
    print("\n6. Public CRL endpoint (nginx) — simulate the 6h publish cron (P1-22)")
    # The crl-server container mounts the ca-certs volume READ-ONLY, so the
    # published crl.pem is put there by infra/ca/refresh-crl.sh, which normally
    # runs from cron every 6 hours. Run it now so the published artifact
    # reflects the revocation we just performed.
    r = sh("bash infra/ca/refresh-crl.sh")
    record("R6.1 refresh-crl.sh publishes the CRL", r.returncode == 0,
           (r.stdout or r.stderr).strip().replace("\n", " | ")[:200])

    r = sh("docker exec she-step-ca cat /ca-certs-output/intermediate_id.txt")
    intermediate_id = r.stdout.strip() or "4746eb60a64abb7e"
    out = os.path.join(WORK, "nginx.crl")
    url = f"{CRL_SERVER}/{intermediate_id}/crl.pem"
    rc = sh(f'curl -s -m 10 -o "{out}" -w "%{{http_code}}" {url}')
    code = rc.stdout.strip()
    size = os.path.getsize(out) if os.path.exists(out) else 0
    body = open(out, "rb").read() if size else b""
    is_der = body[:1] == b"\x30"
    record("R6.2 nginx serves a real DER CRL", is_der and size > 100,
           f"HTTP {code}, {size} bytes, url={url}, first bytes={body[:16]!r}")

    if is_der:
        num_pub, revoked_pub, last_pub, next_pub = parse_crl(body)
        record("R6.3 published CRL lists the revoked serial",
               serial.upper() in revoked_pub,
               f"CRL number={num_pub}, entries={revoked_pub or '(none)'}")
        record("R6.4 published CRL number matches step-ca's",
               num_pub == num_after, f"published={num_pub} ca={num_after}")
    else:
        record("R6.3 published CRL lists the revoked serial", False,
               "published artifact is not a DER CRL")
        record("R6.4 published CRL number matches step-ca's", False,
               "published artifact is not a DER CRL")

    finish()


if __name__ == "__main__":
    main()
