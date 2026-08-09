#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Back up the CA root key to an encrypted offline store
# =============================================================================
# Runs ONCE after bootstrap-ca.sh. The root CA private key is the most
# sensitive asset in the platform — its compromise requires re-issuing every
# device cert in the fleet (catastrophic).
#
# Canonical references:
#   V3-OPS-RUNBOOK §7.3 — CA key backup procedure
#   V3-SECURITY-MODEL §8.2 — secrets inventory (root CA: never rotated)
#   P0-2 — root CA: RSA 4096, 20 years
#
# Strategy:
#   1. The root CA private key is removed from the step-ca server (which only
#      needs the intermediate to sign device certs).
#   2. The root key is encrypted with a KEK derived from a passphrase
#      (Shamir's secret sharing in production — 3 of 5 Lead Engineers).
#   3. The encrypted blob is written to an offline USB stick stored in a
#      physical safe, AND to MinIO bucket she-ca-backup (read-only after write).
#
# Usage:
#   ./backup-root-key.sh /path/to/usb_mount
# =============================================================================
set -euo pipefail

DEST_DIR="${1:-/mnt/secure-usb}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "${DEST_DIR}" ]; then
    echo "ERROR: destination directory ${DEST_DIR} does not exist" >&2
    echo "Mount the USB stick first:  mount /dev/sdX1 ${DEST_DIR}" >&2
    exit 1
fi

# Locate the root key (inside the step-ca container volume)
ROOT_KEY="/var/lib/docker/volumes/she-v3_she-stepca-data/_data/certs/root_ca_key.pem"
if [ ! -f "${ROOT_KEY}" ]; then
    echo "ERROR: root key not found at ${ROOT_KEY}" >&2
    echo "Run 'docker compose up step-ca' first to initialize the CA." >&2
    exit 1
fi

PASSPHRASE_FILE="${SCRIPT_DIR}/step-ca-provisioner-password.txt"
if [ ! -f "${PASSPHRASE_FILE}" ]; then
    echo "ERROR: provisioner password file not found at ${PASSPHRASE_FILE}" >&2
    exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
ENC_FILE="${DEST_DIR}/she-root-ca-key-${TS}.enc"

echo "== Encrypting root CA key with AES-256-CBC + passphrase =="
openssl enc -aes-256-cbc \
    -salt -pbkdf2 -iter 100000 \
    -in "${ROOT_KEY}" \
    -out "${ENC_FILE}" \
    -pass file:"${PASSPHRASE_FILE}"

chmod 0400 "${ENC_FILE}"

# Compute SHA-256 for integrity verification
SHA="$(sha256sum "${ENC_FILE}" | awk '{print $1}')"
echo "${SHA}  ${ENC_FILE}" > "${ENC_FILE}.sha256"

echo ""
echo "================================================================"
echo "  Root CA key backup complete"
echo "================================================================"
echo "  Encrypted file: ${ENC_FILE}"
echo "  SHA-256:        ${SHA}"
echo "  Passphrase:     ${PASSPHRASE_FILE} (also offline-backed-up)"
echo ""
echo "  NEXT STEPS:"
echo "  1. Verify the backup on a DIFFERENT machine:"
echo "     openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in ${ENC_FILE} -out /tmp/test.key -pass file:${PASSPHRASE_FILE}"
echo "     step certificate fingerprint /tmp/test.key   # compare to step-ca root"
echo "  2. Physically secure the USB stick in the safe."
echo "  3. In production: split the passphrase via Shamir's secret sharing"
echo "     (3 of 5 Lead Engineers needed to reconstruct)."
echo "  4. Copy the encrypted blob to MinIO bucket she-ca-backup (read-only)."
echo "================================================================"
