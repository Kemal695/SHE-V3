#!/usr/bin/env bash
# =============================================================================
# SHE V3 — step-ca bootstrap (runs INSIDE the step-ca container on first boot)
# =============================================================================
# Creates the SHE PKI hierarchy per V3-SECURITY-MODEL §3.1 + P0-2 + P1-23/24:
#   Root CA:         RSA 4096-bit, 20 years (offline in production)
#   Intermediate CA: RSA 4096-bit, 10 years (HSM-backed in prod, file in dev)
#   Device cert:     ECDSA P-256, 5 years (issued by intermediate via /sign API)
#
# References:
#   V3-CONFIGURATION.md §3 (step-ca setup), §3.5 (CRL publishing)
#   V3-SECURITY-MODEL.md §3.1 (PKI hierarchy), §3.3 (CRL endpoint)
#   V3-OPS-RUNBOOK.md §6.1 (yearly intermediate rotation)
#   ADR-004: cert-based MQTT auth
#   ADR-013: firmware security
#   ADR-014: factory flashing
# =============================================================================
set -euo pipefail

STEPPATH="${STEPPATH:-/home/step}"
PROVISIONER="${STEP_CA_PROVISIONER_NAME:-she-device-provisioner}"
PASSWORD_FILE="${STEP_CA_PROVISIONER_PASSWORD_FILE:-/provisioner-password.txt}"
CA_URL="https://localhost:9000"
DNS_NAME="step-ca.internal.she.et"

echo "== SHE V3 step-ca bootstrap =="
echo "STEPPATH=${STEPPATH}"
echo "PROVISIONER=${PROVISIONER}"
echo "CA_URL=${CA_URL}"
echo "SPRING_PROFILES_ACTIVE=${SPRING_PROFILES_ACTIVE:-local}"

# -----------------------------------------------------------------------------
# 0. Prod-guard — enforce RSA 4096 root + intermediate in production (P0-2, P1-23)
# -----------------------------------------------------------------------------
# Dev shortcut: local/staging may use ECDSA P-256 for faster bootstrapping.
# Production MUST use RSA 4096-bit root (20yr) + RSA 4096-bit intermediate (10yr)
# per P0-2 and P1-23. This guard prevents accidental prod deployment with weak keys.
# -----------------------------------------------------------------------------
if [ "${SPRING_PROFILES_ACTIVE:-local}" = "prod" ]; then
    echo "== PROD MODE: enforcing RSA 4096 root + intermediate (P0-2, P1-23) =="
    REQUIRED_KTY="RSA"
    REQUIRED_SIZE="4096"
    REQUIRED_ROOT_YEARS="20"
    REQUIRED_INT_YEARS="10"
else
    echo "== DEV/STAGING MODE: using ECDSA P-256 for fast bootstrap (prod requires RSA 4096) =="
    REQUIRED_KTY="EC"
    REQUIRED_SIZE="P-256"
    REQUIRED_ROOT_YEARS="20"
    REQUIRED_INT_YEARS="10"
fi

# -----------------------------------------------------------------------------
# 1. Initialize the CA
# -----------------------------------------------------------------------------
# `step ca init` creates:
#   ${STEPPATH}/certs/root_ca.crt          (RSA 4096, 20-yr, self-signed)
#   ${STEPPATH}/certs/root_ca_key.pem      (RSA 4096, encrypted)
#   ${STEPPATH}/certs/intermediate_ca.crt  (RSA 4096, 10-yr, signed by root)
#   ${STEPPATH}/certs/intermediate_ca_key.pem (encrypted)
#   ${STEPPATH}/config/ca.json
#   ${STEPPATH}/config/defaults.json
step ca init \
  --name "Smart Home Ethiopia Production CA" \
  --dns "${DNS_NAME}" \
  --dns "localhost" \
  --address ":9000" \
  --provisioner "${PROVISIONER}" \
  --password-file "${PASSWORD_FILE}" \
  --provisioner-password-file "${PASSWORD_FILE}" \
  --deployment-type standalone \
  --no-db

echo "== step ca init complete =="

# -----------------------------------------------------------------------------
# 2. Regenerate root + intermediate CAs with profile-appropriate key type
#    - prod:     RSA 4096-bit,  20yr root / 10yr intermediate (P0-2, P1-23)
#    - dev/stg:  ECDSA P-256,   20yr root / 10yr intermediate (fast bootstrap)
#
#    step-ca's `step ca init` defaults to P-256 / 10yr — we override to match
#    the canonical key type for the active profile + always 20yr/10yr validity.
# -----------------------------------------------------------------------------
CA_JSON="${STEPPATH}/config/ca.json"
TMP_ROOT_CRT="/tmp/root_ca.crt"
TMP_ROOT_KEY="/tmp/root_ca_key.pem"
TMP_INT_CRT="/tmp/intermediate_ca.crt"
TMP_INT_KEY="/tmp/intermediate_ca_key.pem"

# Compute not-after hours from years
ROOT_NOT_AFTER="$((REQUIRED_ROOT_YEARS * 365 * 24))h"
INT_NOT_AFTER="$((REQUIRED_INT_YEARS * 365 * 24))h"

echo "== Regenerating root CA (${REQUIRED_KTY} ${REQUIRED_SIZE}, ${REQUIRED_ROOT_YEARS}yr) =="
if [ "${REQUIRED_KTY}" = "RSA" ]; then
    step certificate create "Smart Home Ethiopia Root CA" \
      "${TMP_ROOT_CRT}" "${TMP_ROOT_KEY}" \
      --profile root-ca \
      --kty RSA \
      --size "${REQUIRED_SIZE}" \
      --not-after "${ROOT_NOT_AFTER}" \
      --password-file "${PASSWORD_FILE}" \
      --force
else
    step certificate create "Smart Home Ethiopia Root CA" \
      "${TMP_ROOT_CRT}" "${TMP_ROOT_KEY}" \
      --profile root-ca \
      --kty EC \
      --curve "${REQUIRED_SIZE}" \
      --not-after "${ROOT_NOT_AFTER}" \
      --password-file "${PASSWORD_FILE}" \
      --force
fi

echo "== Regenerating intermediate CA (${REQUIRED_KTY} ${REQUIRED_SIZE}, ${REQUIRED_INT_YEARS}yr, signed by root) =="
if [ "${REQUIRED_KTY}" = "RSA" ]; then
    step certificate create "Smart Home Ethiopia Intermediate CA" \
      "${TMP_INT_CRT}" "${TMP_INT_KEY}" \
      --profile intermediate-ca \
      --kty RSA \
      --size "${REQUIRED_SIZE}" \
      --not-after "${INT_NOT_AFTER}" \
      --ca "${TMP_ROOT_CRT}" \
      --ca-key "${TMP_ROOT_KEY}" \
      --ca-password-file "${PASSWORD_FILE}" \
      --password-file "${PASSWORD_FILE}" \
      --force
else
    step certificate create "Smart Home Ethiopia Intermediate CA" \
      "${TMP_INT_CRT}" "${TMP_INT_KEY}" \
      --profile intermediate-ca \
      --kty EC \
      --curve "${REQUIRED_SIZE}" \
      --not-after "${INT_NOT_AFTER}" \
      --ca "${TMP_ROOT_CRT}" \
      --ca-key "${TMP_ROOT_KEY}" \
      --ca-password-file "${PASSWORD_FILE}" \
      --password-file "${PASSWORD_FILE}" \
      --force
fi

# -----------------------------------------------------------------------------
# 2b. PROD-GUARD: verify the generated root CA matches P0-2 requirements
# -----------------------------------------------------------------------------
if [ "${SPRING_PROFILES_ACTIVE:-local}" = "prod" ]; then
    echo "== PROD-GUARD: verifying root CA key type + size =="
    ROOT_KEY_INFO=$(openssl x509 -in "${TMP_ROOT_CRT}" -noout -text 2>/dev/null | grep -A1 "Public-Key" | head -1)
    if ! echo "${ROOT_KEY_INFO}" | grep -q "4096 bit"; then
        echo "FATAL: Root CA is not RSA 4096-bit — refusing to continue in prod mode." >&2
        echo "Root CA key info: ${ROOT_KEY_INFO}" >&2
        exit 1
    fi
    echo "  ✓ Root CA is RSA 4096-bit (P0-2, P1-23 enforced)"

    INT_KEY_INFO=$(openssl x509 -in "${TMP_INT_CRT}" -noout -text 2>/dev/null | grep -A1 "Public-Key" | head -1)
    if ! echo "${INT_KEY_INFO}" | grep -q "4096 bit"; then
        echo "FATAL: Intermediate CA is not RSA 4096-bit — refusing to continue in prod mode." >&2
        exit 1
    fi
    echo "  ✓ Intermediate CA is RSA 4096-bit (P0-2 enforced)"
fi

# Overwrite the auto-generated ones
cp "${TMP_ROOT_CRT}" "${STEPPATH}/certs/root_ca.crt"
cp "${TMP_ROOT_KEY}" "${STEPPATH}/certs/root_ca_key.pem"
cp "${TMP_INT_CRT}"  "${STEPPATH}/certs/intermediate_ca.crt"
cp "${TMP_INT_KEY}"  "${STEPPATH}/certs/intermediate_ca_key.pem"
chmod 0600 "${STEPPATH}/certs/root_ca_key.pem" "${STEPPATH}/certs/intermediate_ca_key.pem"
chmod 0644 "${STEPPATH}/certs/root_ca.crt" "${STEPPATH}/certs/intermediate_ca.crt"

# -----------------------------------------------------------------------------
# 2c. Patch ca.json — deliberately WITHOUT jq
# -----------------------------------------------------------------------------
# jq is NOT bundled in smallstep/step-ca:0.27.4 (the image is Alpine 3.20.3 and
# ships none) and this container runs as uid 1000 (step), so it cannot `apk add`
# one either. The previous revision piped ca.json through jq, which under
# `set -e` aborted the script the instant jq was missing — immediately after
# `step ca init`. Nothing below ever ran, yet the container still booted, from the
# pristine `step ca init` config, which has NO db and NO crl block. Consequences:
#   * POST /revoke answered "501 NOT_IMPLEMENTED" (no persistence layer), so a
#     device certificate could never actually be revoked; and
#   * no CRL was ever generated, so the published crl.pem stayed the unparseable
#     16-byte text placeholder that the old revision of this script wrote.
# A pure-shell patch keeps the bootstrap dependency-free.
#
# `step ca init` already writes root/crt pointing at ${STEPPATH}/certs/*.crt —
# the very paths the regenerated hierarchy is copied to below — so strictly only
# the intermediate KEY path needs rewriting (init puts it under secrets/). All
# three are rewritten anyway, so the patch does not depend on init's layout.
#
# Intermediate CA id — first 16 hex chars of its SHA-256 fingerprint. Also forms
# the CRL Distribution Point path used here and by refresh-crl.sh.
INTERMEDIATE_ID="$(step certificate fingerprint "${STEPPATH}/certs/intermediate_ca.crt" | cut -c1-16)"
CRL_IDP_URL="${CRL_IDP_URL:-http://localhost:8088/ca/${INTERMEDIATE_ID}/crl.pem}"

# db  — REQUIRED for revocation. The `--no-db` flag above only suppresses the
#       block in the generated config; an authority with no database cannot
#       record a revoked serial, so /revoke fails and the CRL stays empty.
#       (badgerv2 + dataSource is exactly what `step ca init` emits itself.)
# crl — CRL generation/serving, disabled by default. Field names per
#       certificates v0.27.4 authority/config/config.go (CRLConfig): enabled,
#       generateOnRevoke, cacheDuration, renewPeriod, idpURL. There is NO
#       `generateOnRestart` field — an earlier revision wrote one, and step-ca
#       silently ignored it. cacheDuration 6h == the P1-22 revocation SLA.
awk -v root_crt="${STEPPATH}/certs/root_ca.crt" \
    -v int_crt="${STEPPATH}/certs/intermediate_ca.crt" \
    -v int_key="${STEPPATH}/certs/intermediate_ca_key.pem" \
    -v db_dir="${STEPPATH}/db" \
    -v idp_url="${CRL_IDP_URL}" '
  /^[[:space:]]*"root":[[:space:]]*"/ { sub(/"[^"]*"[[:space:]]*,?[[:space:]]*$/, "\"" root_crt "\",") }
  /^[[:space:]]*"crt":[[:space:]]*"/  { sub(/"[^"]*"[[:space:]]*,?[[:space:]]*$/, "\"" int_crt  "\",") }
  /^[[:space:]]*"key":[[:space:]]*"/  { sub(/"[^"]*"[[:space:]]*,?[[:space:]]*$/, "\"" int_key  "\",") }
  !inserted && /^[[:space:]]*"authority":[[:space:]]*\{/ {
    print "\t\"db\": {"
    print "\t\t\"type\": \"badgerv2\","
    print "\t\t\"dataSource\": \"" db_dir "\","
    print "\t\t\"badgerFileLoadingMode\": \"\""
    print "\t},"
    print "\t\"crl\": {"
    print "\t\t\"enabled\": true,"
    print "\t\t\"generateOnRevoke\": true,"
    print "\t\t\"cacheDuration\": \"6h\","
    print "\t\t\"renewPeriod\": \"4h\","
    print "\t\t\"idpURL\": \"" idp_url "\""
    print "\t},"
    inserted = 1
  }
  { print }
' "${CA_JSON}" > "${CA_JSON}.tmp"
mv "${CA_JSON}.tmp" "${CA_JSON}"

# --- structural sanity checks (the image has no JSON parser) ----------------
if [ "$(tr -cd '{' < "${CA_JSON}" | wc -c)" != "$(tr -cd '}' < "${CA_JSON}" | wc -c)" ]; then
    echo "FATAL: ${CA_JSON} is not brace-balanced after patching." >&2
    exit 1
fi
for needle in '"db"' '"crl"' '"badgerv2"' '"generateOnRevoke"'; do
    if ! grep -q "${needle}" "${CA_JSON}"; then
        echo "FATAL: ${needle} missing from ${CA_JSON} after patching." >&2
        exit 1
    fi
done

echo "== ca.json patched =="
grep -A5 '"db"' "${CA_JSON}"
grep -A6 '"crl"' "${CA_JSON}"

# -----------------------------------------------------------------------------
# 3. Build the CA bundle (root + intermediate) for EMQX + Spring Boot
# -----------------------------------------------------------------------------
CA_BUNDLE="/ca-certs-output/ca_bundle.pem"
INTERMEDIATE_OUT="/ca-certs-output/intermediate.crt"
ROOT_OUT="/ca-certs-output/root_ca.crt"

cat "${STEPPATH}/certs/root_ca.crt" "${STEPPATH}/certs/intermediate_ca.crt" > "${CA_BUNDLE}"
cp "${STEPPATH}/certs/intermediate_ca.crt" "${INTERMEDIATE_OUT}"
cp "${STEPPATH}/certs/root_ca.crt" "${ROOT_OUT}"
chmod 0644 "${CA_BUNDLE}" "${INTERMEDIATE_OUT}" "${ROOT_OUT}"

echo "== CA bundle written to ${CA_BUNDLE} =="

# -----------------------------------------------------------------------------
# 4. Issue the EMQX server cert + Spring Boot client cert (for mTLS)
#    Both signed by the intermediate. In production these are issued via the
#    step-ca /sign API; in dev we sign directly with the intermediate file.
# -----------------------------------------------------------------------------
SERVER_CRT="/ca-certs-output/server.crt"
SERVER_KEY="/ca-certs-output/server.key"
BACKEND_CRT="/ca-certs-output/she-backend.crt"
BACKEND_KEY="/ca-certs-output/she-backend.key"

echo "== Issuing EMQX server cert (CN=*.she.et, SAN=DNS:emqx-1,DNS:emqx-2,DNS:emqx-3,DNS:localhost,IP:127.0.0.1) =="
step certificate create "emqx.she.internal" \
  "${SERVER_CRT}" "${SERVER_KEY}" \
  --profile leaf \
  --kty RSA \
  --size 2048 \
  --not-after 8760h \
  --ca "${STEPPATH}/certs/intermediate_ca.crt" \
  --ca-key "${STEPPATH}/certs/intermediate_ca_key.pem" \
  --ca-password-file "${PASSWORD_FILE}" \
  --san "emqx-1" --san "emqx-2" --san "emqx-3" \
  --san "localhost" --san "127.0.0.1" \
  --san "she.et" --san "*.she.et" \
  --password-file "${PASSWORD_FILE}" \
  --force
chmod 0644 "${SERVER_CRT}"
chmod 0600 "${SERVER_KEY}"

echo "== Issuing Spring Boot backend client cert (CN=she-backend) =="
step certificate create "she-backend" \
  "${BACKEND_CRT}" "${BACKEND_KEY}" \
  --profile leaf \
  --kty EC \
  --curve P-256 \
  --not-after 8760h \
  --ca "${STEPPATH}/certs/intermediate_ca.crt" \
  --ca-key "${STEPPATH}/certs/intermediate_ca_key.pem" \
  --ca-password-file "${PASSWORD_FILE}" \
  --san "she-backend" \
  --password-file "${PASSWORD_FILE}" \
  --force
chmod 0644 "${BACKEND_CRT}"
chmod 0600 "${BACKEND_KEY}"

# -----------------------------------------------------------------------------
# 5. Generate the initial CRL file (served by the crl-server container)
# -----------------------------------------------------------------------------
# INTERMEDIATE_ID was resolved in §2c above (it also builds the CRL Distribution
# Point URL there).
CRL_DIR="/ca-certs-output/ca/${INTERMEDIATE_ID}"
mkdir -p "${CRL_DIR}"

echo "== CRL directory ready: ${CRL_DIR} =="
# Do NOT pre-seed a CRL file here. step-ca owns CRL generation (crl.enabled +
# generateOnRevoke) and its CRL numbering is the authoritative one; an
# openssl-generated file would start at a different number, and the previous
# text placeholder ("placeholder CRL") was not a parseable CRL at all — yet nginx
# serves whatever sits at this path as Content-Type: application/pkix-crl.
#
# Publication is done by infra/ca/refresh-crl.sh, which fetches step-ca's CRL
# (GET /crl) and writes it here. Run it once after the stack is up; cron keeps it
# fresh every 6 hours thereafter (P1-22).
if [ -f "${CRL_DIR}/crl.pem" ]; then
    echo "   removing stale crl.pem so nginx cannot serve a placeholder"
    rm -f "${CRL_DIR}/crl.pem"
fi
echo "   Next: run infra/ca/refresh-crl.sh (or wait for the 6-hourly cron)"

# -----------------------------------------------------------------------------
# 6. Print the root CA fingerprint for client bootstrap (STEP_CA_FINGERPRINT)
# -----------------------------------------------------------------------------
FINGERPRINT="$(step certificate fingerprint "${STEPPATH}/certs/root_ca.crt")"
echo ""
echo "================================================================"
echo "  SHE V3 step-ca bootstrap complete"
echo "================================================================"
echo "  Root CA fingerprint (set as STEP_CA_FINGERPRINT in .env):"
echo "    ${FINGERPRINT}"
echo "  Intermediate CA ID (used in CRL URL):"
echo "    ${INTERMEDIATE_ID}"
echo "  CA bundle:    ${CA_BUNDLE}"
echo "  Server cert:  ${SERVER_CRT}"
echo "  Backend cert: ${BACKEND_CRT}"
echo "  CRL URL:      http://localhost:8088/ca/${INTERMEDIATE_ID}/crl.pem"
echo "================================================================"
echo ""

# Persist fingerprint to a file so .env can be auto-populated
echo "${FINGERPRINT}" > /ca-certs-output/root_ca_fingerprint.txt
echo "${INTERMEDIATE_ID}" > /ca-certs-output/intermediate_id.txt
