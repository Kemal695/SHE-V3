#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Revoke a device cert via step-ca + regenerate CRL
# =============================================================================
# Usage:
#   ./revoke-device-cert.sh <cert_file_or_serial>
#
# Revocation SLA: < 6 hours (P1-22). The CRL is regenerated immediately here,
# and a cron job runs refresh-crl.sh every 6 hours to keep the published CRL
# in sync (covers the case of multi-instance step-ca behind a load balancer).
#
# Reference: V3-SECURITY-MODEL §3.3, V3-CONFIGURATION §3.5, ADR-004
# =============================================================================
set -euo pipefail

CERT="${1:-}"
if [ -z "${CERT}" ]; then
    echo "Usage: $0 <cert_file_or_serial>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Revoking cert ${CERT} via step-ca =="
step ca revoke "${CERT}" \
  --provisioner "she-device-provisioner" \
  --provisioner-password-file "${SCRIPT_DIR}/step-ca-provisioner-password.txt" \
  --ca-url "${STEP_CA_URL:-http://localhost:9002}" \
  --root "${SCRIPT_DIR}/root_ca.crt" \
  --reason "key_compromise"

echo "== Regenerating CRL =="
"${SCRIPT_DIR}/refresh-crl.sh"

echo ""
echo "Revocation complete. EMQX will fetch the new CRL within 6 hours (P1-22)."
echo "For immediate effect, restart EMQX auth cache: docker compose restart emqx-1 emqx-2 emqx-3"
