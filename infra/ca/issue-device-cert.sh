#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Issue a device cert via step-ca
# =============================================================================
# Usage:
#   ./issue-device-cert.sh <normalized_mac> [not_after_hours]
#
# Default validity: 5 years (43800h) per P0-2.
#
# The CSR is generated locally (ECDSA P-256), then signed by step-ca.
# In the canonical factory flow (P0-1), the ESP32 generates the keypair
# on-chip via mbedTLS and the factory workstation reads the CSR over USB
# serial. This script emulates that flow on a host machine for testing.
#
# Reference: V3-SECURITY-MODEL §3.2, V3-FACTORY-OPS, ADR-014
# =============================================================================
set -euo pipefail

MAC="${1:-}"
NOT_AFTER="${2:-43800h}"   # 5 years per P0-2

if [ -z "${MAC}" ]; then
    echo "Usage: $0 <normalized_mac> [not_after_hours]" >&2
    echo "Example: $0 aabbccddeeff" >&2
    exit 1
fi

# Validate MAC format (lowercase, 12 hex chars, no colons)
if ! echo "${MAC}" | grep -qE '^[0-9a-f]{12}$'; then
    echo "ERROR: MAC must be 12 lowercase hex chars (e.g. aabbccddeeff)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/out/devices"
mkdir -p "${OUT_DIR}"

CSR_FILE="${OUT_DIR}/${MAC}.csr"
KEY_FILE="${OUT_DIR}/${MAC}.key"
CRT_FILE="${OUT_DIR}/${MAC}.crt"

echo "== Generating ECDSA P-256 keypair + CSR for device ${MAC} =="
step certificate create "${MAC}" \
  "${CRT_FILE}" "${KEY_FILE}" \
  --csr \
  --kty EC \
  --curve P-256 \
  --no-password \
  --insecure \
  --force

echo "== Signing CSR via step-ca (provisioner: she-device-provisioner) =="
step ca sign "${CSR_FILE}" "${CRT_FILE}" \
  --san "${MAC}" \
  --not-after "${NOT_AFTER}" \
  --provisioner "she-device-provisioner" \
  --provisioner-password-file "${SCRIPT_DIR}/step-ca-provisioner-password.txt" \
  --ca-url "${STEP_CA_URL:-http://localhost:9002}" \
  --root "${SCRIPT_DIR}/root_ca.crt"

FINGERPRINT="$(step certificate fingerprint "${CRT_FILE}")"

echo ""
echo "================================================================"
echo "  Device cert issued for ${MAC}"
echo "================================================================"
echo "  Cert:        ${CRT_FILE}"
echo "  Key:         ${KEY_FILE}"
echo "  Fingerprint: ${FINGERPRINT}"
echo "  Validity:    ${NOT_AFTER}"
echo "================================================================"
