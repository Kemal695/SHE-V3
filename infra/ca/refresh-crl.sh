#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Refresh the published CRL file
# =============================================================================
# Runs in cron every 6 hours (P1-22). Revocation SLA < 6 hours.
#
# step-ca serves its CRL over HTTP at GET /crl (verified on 0.27.4 — /crl/{id}
# and /1/crl are both 404). It never writes a CRL file itself, and the nginx
# crl-server mounts the ca-certs volume READ-ONLY, so something holding WRITE
# access to that volume has to fetch and store the CRL.
#
# That something is the step-ca container: it reaches the CA over TLS and it owns
# /ca-certs-output. Publishing from inside it works on every host — including
# Docker Desktop on Windows/macOS, where the named volume is not on the host
# filesystem at all. (The previous host-path strategy silently wrote nowhere on
# those hosts, so the published crl.pem stayed the 16-byte text placeholder that
# bootstrap-ca.sh writes — not even a parseable CRL.)
#
# Strategy order:
#   1. docker exec into the step-ca container  (default; portable)
#   2. host-side write to the docker volume    (bare-metal Linux cron)
#
# Canonical references: V3-SECURITY-MODEL §3.3, V3-CONFIGURATION §3.5, P1-22.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STEP_CA_CONTAINER="${STEP_CA_CONTAINER:-she-step-ca}"
# URL step-ca uses to reach itself, from inside its own container.
CA_URL_IN_CONTAINER="${STEP_CA_URL_IN_CONTAINER:-https://localhost:9000}"
# Host-reachable CA URL — fallback path only.
CA_URL="${STEP_CA_URL:-http://localhost:9002}"
CA_CERTS_VOLUME="${CA_CERTS_VOLUME:-she-v3_she-ca-certs}"
VOLUME_MOUNT="${CA_CERTS_VOLUME_MOUNT:-/var/lib/docker/volumes/${CA_CERTS_VOLUME}/_data}"

# -----------------------------------------------------------------------------
# 1. Resolve the intermediate CA id — it forms the public CRL path.
#    Authoritative source is the file bootstrap-ca.sh writes into the volume.
# -----------------------------------------------------------------------------
INTERMEDIATE_ID="$(docker exec "${STEP_CA_CONTAINER}" \
    cat /ca-certs-output/intermediate_id.txt 2>/dev/null | tr -d '\r\n' || true)"

if [ -z "${INTERMEDIATE_ID}" ] && [ -f "${SCRIPT_DIR}/../.ca-certs/intermediate_id.txt" ]; then
    INTERMEDIATE_ID="$(tr -d '\r\n' < "${SCRIPT_DIR}/../.ca-certs/intermediate_id.txt")"
fi

if [ -z "${INTERMEDIATE_ID}" ]; then
    echo "ERROR: could not determine the intermediate CA id." >&2
    echo "       Run bootstrap-ca.sh first — it writes /ca-certs-output/intermediate_id.txt" >&2
    echo "       into the ${CA_CERTS_VOLUME} volume." >&2
    exit 1
fi

CRL_PATH="/ca-certs-output/ca/${INTERMEDIATE_ID}/crl.pem"
echo "== Refreshing published CRL (intermediate ${INTERMEDIATE_ID}) =="

# -----------------------------------------------------------------------------
# 2a. Publish from inside the step-ca container.
#     -u 0 because Docker creates the ca-certs volume (and its ca/ subdirectory)
#     root-owned, while the image's default user is uid 1000 (step).
# -----------------------------------------------------------------------------
if docker exec -u 0 "${STEP_CA_CONTAINER}" sh -c \
        "wget -q -O '${CRL_PATH}.tmp' --no-check-certificate '${CA_URL_IN_CONTAINER}/crl' &&
         mv '${CRL_PATH}.tmp' '${CRL_PATH}'" 2>/dev/null; then
    SIZE="$(docker exec "${STEP_CA_CONTAINER}" sh -c "wc -c < '${CRL_PATH}'" | tr -d ' \r\n')"
    echo "== CRL published to the ca-certs volume =="
    echo "   ${CRL_PATH} (${SIZE} bytes)"
    echo "   Public URL: http://localhost:8088/ca/${INTERMEDIATE_ID}/crl.pem"
    echo "   Next update window: within 6 hours (P1-22)"
    exit 0
fi

# -----------------------------------------------------------------------------
# 2b. Fallback — bare-metal Linux where the docker volume is directly writable.
# -----------------------------------------------------------------------------
PUBLISH_DIR="${VOLUME_MOUNT}/ca/${INTERMEDIATE_ID}"
if [ -d "${VOLUME_MOUNT}" ]; then
    mkdir -p "${PUBLISH_DIR}"
    for path in "/crl" "/1.0/crl"; do
        if curl -sf -k -o "${PUBLISH_DIR}/crl.pem.tmp" "${CA_URL}${path}"; then
            mv "${PUBLISH_DIR}/crl.pem.tmp" "${PUBLISH_DIR}/crl.pem"
            chmod 0644 "${PUBLISH_DIR}/crl.pem"
            echo "== CRL published via host volume path =="
            echo "   ${PUBLISH_DIR}/crl.pem ($(wc -c < "${PUBLISH_DIR}/crl.pem") bytes)"
            echo "   Next update window: within 6 hours (P1-22)"
            exit 0
        fi
    done
fi

echo "ERROR: could not publish the CRL." >&2
echo "       Tried: docker exec ${STEP_CA_CONTAINER}  (${CA_URL_IN_CONTAINER}/crl)" >&2
echo "              host volume path              (${VOLUME_MOUNT})" >&2
exit 1
