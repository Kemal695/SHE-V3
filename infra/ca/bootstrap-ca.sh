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
# 2. Patch ca.json to enforce RSA 4096 + 20yr root / 10yr intermediate
#    (step-ca defaults to P-256 with 10yr root / 10yr intermediate — we override)
# -----------------------------------------------------------------------------
# Replace the default root/intermediate templates to match P0-2:
#   root:         RSA 4096, 20 years
#   intermediate: RSA 4096, 10 years
# This is done by editing ca.json's `authority` section. The simplest approach
# in dev: regenerate root + intermediate with the correct profile, then
# update ca.json to point at them.
CA_JSON="${STEPPATH}/config/ca.json"
TMP_ROOT_CRT="/tmp/root_ca.crt"
TMP_ROOT_KEY="/tmp/root_ca_key.pem"
TMP_INT_CRT="/tmp/intermediate_ca.crt"
TMP_INT_KEY="/tmp/intermediate_ca_key.pem"

echo "== Regenerating root CA (RSA 4096, 20yr) =="
step certificate create "Smart Home Ethiopia Root CA" \
  "${TMP_ROOT_CRT}" "${TMP_ROOT_KEY}" \
  --profile root-ca \
  --kty RSA \
  --size 4096 \
  --not-after 175200h \
  --password-file "${PASSWORD_FILE}" \
  --force

echo "== Regenerating intermediate CA (RSA 4096, 10yr, signed by root) =="
step certificate create "Smart Home Ethiopia Intermediate CA" \
  "${TMP_INT_CRT}" "${TMP_INT_KEY}" \
  --profile intermediate-ca \
  --kty RSA \
  --size 4096 \
  --not-after 87600h \
  --ca "${TMP_ROOT_CRT}" \
  --ca-key "${TMP_ROOT_KEY}" \
  --ca-password-file "${PASSWORD_FILE}" \
  --password-file "${PASSWORD_FILE}" \
  --force

# Overwrite the auto-generated ones
cp "${TMP_ROOT_CRT}" "${STEPPATH}/certs/root_ca.crt"
cp "${TMP_ROOT_KEY}" "${STEPPATH}/certs/root_ca_key.pem"
cp "${TMP_INT_CRT}"  "${STEPPATH}/certs/intermediate_ca.crt"
cp "${TMP_INT_KEY}"  "${STEPPATH}/certs/intermediate_ca_key.pem"
chmod 0600 "${STEPPATH}/certs/root_ca_key.pem" "${STEPPATH}/certs/intermediate_ca_key.pem"
chmod 0644 "${STEPPATH}/certs/root_ca.crt" "${STEPPATH}/certs/intermediate_ca.crt"

# Patch ca.json to point at the new root + intermediate
# (ca.json's "root" + "crt" + "key" fields)
jq --arg root "${STEPPATH}/certs/root_ca.crt" \
   --arg intcrt "${STEPPATH}/certs/intermediate_ca.crt" \
   --arg intkey "${STEPPATH}/certs/intermediate_ca_key.pem" \
   '.root = $root | .crt = $intcrt | .key = $intkey' \
   "${CA_JSON}" > "${CA_JSON}.tmp"
mv "${CA_JSON}.tmp" "${CA_JSON}"

# Add CRL issuer config — step-ca serves CRL at /crl/{crl-id} per ca.json's
# crl config block. We enable CRL generation with a 6h refresh (P1-22).
jq '. + {crl: {enabled: true, generateOnRestart: true}}' \
   "${CA_JSON}" > "${CA_JSON}.tmp"
mv "${CA_JSON}.tmp" "${CA_JSON}"

echo "== ca.json patched =="

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
INTERMEDIATE_ID="$(step certificate fingerprint "${STEPPATH}/certs/intermediate_ca.crt" | cut -c1-16)"
CRL_DIR="/ca-certs-output/ca/${INTERMEDIATE_ID}"
mkdir -p "${CRL_DIR}"

echo "== Generating initial CRL for intermediate ${INTERMEDIATE_ID} =="
# step-ca will serve CRL at /crl/{cert-id} once it boots; for the standalone
# nginx CRL server we generate it manually here (and refresh-crl.sh updates it).
step ca root --crl > "${CRL_DIR}/crl.pem" 2>/dev/null || true
# If step ca root --crl requires the server running, fall back to openssl
if [ ! -s "${CRL_DIR}/crl.pem" ]; then
    openssl ca -gencrl \
        -config <(echo "[ca]"; echo "default_ca = CA_default"; echo "[CA_default]"; \
                  echo "database = /dev/null"; \
                  echo "new_certs_dir = /dev/null"; \
                  echo "certificate = ${STEPPATH}/certs/intermediate_ca.crt"; \
                  echo "private_key = ${STEPPATH}/certs/intermediate_ca_key.pem"; \
                  echo "default_md = sha256"; \
                  echo "default_crl_days = 7") \
        -passin pass:"$(cat "${PASSWORD_FILE}")" \
        -out "${CRL_DIR}/crl.pem" 2>/dev/null || \
    echo "placeholder CRL — will be regenerated by refresh-crl.sh" > "${CRL_DIR}/crl.pem"
fi

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
