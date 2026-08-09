#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Refresh the published CRL file
# =============================================================================
# Runs in cron every 6 hours (P1-22).
# Fetches the latest CRL from step-ca and writes it to the nginx-served path.
#
# In production: copies the CRL to all nginx edge servers.
# In dev: writes to the shared volume consumed by the crl-server container.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_URL="${STEP_CA_URL:-http://localhost:9002}"
CA_CERTS_DIR="${SCRIPT_DIR}/../.ca-certs"   # local mirror

# Use the docker volume directly when running on the host
if [ -d "/var/lib/docker/volumes/she-v3_she-ca-certs/_data" ]; then
    PUBLISH_DIR="/var/lib/docker/volumes/she-v3_she-ca-certs/_data/ca"
else
    PUBLISH_DIR="${CA_CERTS_DIR}/ca"
fi
mkdir -p "${PUBLISH_DIR}"

# Read the intermediate ID from the file written by bootstrap-ca.sh
INTERMEDIATE_ID_FILE="${CA_CERTS_DIR}/intermediate_id.txt"
if [ ! -f "${INTERMEDIATE_ID_FILE}" ]; then
    echo "ERROR: intermediate_id.txt not found — run bootstrap-ca.sh first" >&2
    exit 1
fi
INTERMEDIATE_ID="$(cat "${INTERMEDIATE_ID_FILE}")"

CRL_FILE="${PUBLISH_DIR}/${INTERMEDIATE_ID}/crl.pem"
mkdir -p "$(dirname "${CRL_FILE}")"

echo "== Fetching CRL from step-ca =="
# step-ca exposes the CRL at GET /crl/{cert-id} (or /1/crl) depending on version.
# We try multiple paths; first one wins.
for path in "/crl/${INTERMEDIATE_ID}" "/1/crl" "/crl"; do
    if curl -sf -o "${CRL_FILE}.tmp" "${CA_URL}${path}"; then
        mv "${CRL_FILE}.tmp" "${CRL_FILE}"
        chmod 0644 "${CRL_FILE}"
        echo "== CRL written to ${CRL_FILE} =="
        echo "   Size: $(wc -c < "${CRL_FILE}") bytes"
        echo "   Next update window: within 6 hours (P1-22)"
        exit 0
    fi
done

echo "ERROR: could not fetch CRL from step-ca at ${CA_URL}" >&2
exit 1
