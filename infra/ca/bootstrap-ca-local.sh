#!/usr/bin/env bash
# =============================================================================
# SHE V3 — step-ca bootstrap (runs INSIDE the step-ca container on first boot)
# =============================================================================
# Local dev version — no jq dependency, uses step-ca defaults (P-256)
# =============================================================================
set -euo pipefail

STEPPATH="${STEPPATH:-/home/step}"
PROVISIONER="${STEP_CA_PROVISIONER_NAME:-she-device-provisioner}"
PASSWORD_FILE="${STEP_CA_PROVISIONER_PASSWORD_FILE:-/provisioner-password.txt}"
CA_URL="https://localhost:9000"
DNS_NAME="step-ca.internal.she.et"

echo "== SHE V3 step-ca bootstrap (local dev) =="

# -----------------------------------------------------------------------------
# 1. Initialize the CA
# -----------------------------------------------------------------------------
step ca init \
  --name "Smart Home Ethiopia Local CA" \
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
# 2. Build the CA bundle
# -----------------------------------------------------------------------------
OUT="/home/step/ca-certs-output"
CA_BUNDLE="${OUT}/ca_bundle.pem"
INTERMEDIATE_OUT="${OUT}/intermediate.crt"
ROOT_OUT="${OUT}/root_ca.crt"

cat "${STEPPATH}/certs/root_ca.crt" "${STEPPATH}/certs/intermediate_ca.crt" > "${CA_BUNDLE}"
cp "${STEPPATH}/certs/intermediate_ca.crt" "${INTERMEDIATE_OUT}"
cp "${STEPPATH}/certs/root_ca.crt" "${ROOT_OUT}"
chmod 0644 "${CA_BUNDLE}" "${INTERMEDIATE_OUT}" "${ROOT_OUT}"

echo "== CA bundle written =="

# -----------------------------------------------------------------------------
# 3. Issue the EMQX server cert + Spring Boot client cert
# -----------------------------------------------------------------------------
SERVER_CRT="${OUT}/server.crt"
SERVER_KEY="${OUT}/server.key"
BACKEND_CRT="${OUT}/she-backend.crt"
BACKEND_KEY="${OUT}/she-backend.key"

echo "== Issuing EMQX server cert =="
step certificate create emqx.she.internal \
  "${SERVER_CRT}" "${SERVER_KEY}" \
  --profile leaf \
  --kty RSA \
  --size 2048 \
  --not-after 8760h \
  --ca "${STEPPATH}/certs/intermediate_ca.crt" \
  --ca-key "${STEPPATH}/secrets/intermediate_ca_key" \
  --ca-password-file "${PASSWORD_FILE}" \
  --san emqx-1 --san emqx-2 --san emqx-3 \
  --san localhost --san 127.0.0.1 \
  --password-file "${PASSWORD_FILE}" \
  --force
chmod 0644 "${SERVER_CRT}"
chmod 0600 "${SERVER_KEY}"

echo "== Issuing Spring Boot backend client cert =="
step certificate create she-backend \
  "${BACKEND_CRT}" "${BACKEND_KEY}" \
  --profile leaf \
  --kty EC \
  --curve P-256 \
  --not-after 8760h \
  --ca "${STEPPATH}/certs/intermediate_ca.crt" \
  --ca-key "${STEPPATH}/secrets/intermediate_ca_key" \
  --ca-password-file "${PASSWORD_FILE}" \
  --san she-backend \
  --password-file "${PASSWORD_FILE}" \
  --force
chmod 0644 "${BACKEND_CRT}"
chmod 0600 "${BACKEND_KEY}"

# -----------------------------------------------------------------------------
# 4. Generate initial CRL
# -----------------------------------------------------------------------------
INTERMEDIATE_ID="$(step certificate fingerprint "${STEPPATH}/certs/intermediate_ca.crt" | cut -c1-16)"
CRL_DIR="${OUT}/ca/${INTERMEDIATE_ID}"
mkdir -p "${CRL_DIR}"

echo "== Generating initial CRL =="
echo "placeholder CRL" > "${CRL_DIR}/crl.pem"

# -----------------------------------------------------------------------------
# 5. Print root CA fingerprint
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

echo "${FINGERPRINT}" > "${OUT}/root_ca_fingerprint.txt"
echo "${INTERMEDIATE_ID}" > "${OUT}/intermediate_id.txt"
