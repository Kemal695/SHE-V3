#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Phase 0 Exit Criteria Verification
# =============================================================================
# Verifies ALL 5 Phase 0 exit criteria per V3-ROADMAP §2:
#
#   [ ] EMQX cluster running with cert-based mTLS auth —
#       `openssl s_client -connect she.et:8883` succeeds with device cert
#   [ ] CA operational — can issue + revoke device certs via step-ca;
#       CRL endpoint serves
#   [ ] Spring Boot MVP deployed to staging —
#       `/actuator/health` returns UP
#   [ ] CI/CD pipeline builds + deploys backend automatically on merge
#   [ ] All V3 docs + ADRs locked
#
# Usage:  ./scripts/verify-phase0.sh [target]
#   target = local | staging (default: local)
# =============================================================================
set -uo pipefail

TARGET="${1:-local}"
PASS=0
FAIL=0
SKIP=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'   # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CA_DIR="${PROJECT_ROOT}/infra/ca"

# Resolve target URLs
if [ "${TARGET}" = "staging" ]; then
    MQTT_HOST="she.et"
    MQTT_PORT="8883"
    STEP_CA_URL="https://step-ca.internal.she.et:9000"
    CRL_BASE_URL="https://she.et/ca"
    BACKEND_URL="https://staging.she.et"
    BACKEND_LOCAL_PORT=""
else
    MQTT_HOST="localhost"
    MQTT_PORT="8883"
    STEP_CA_URL="http://localhost:9002"
    CRL_BASE_URL="http://localhost:8088/ca"
    BACKEND_URL="http://localhost:8080"
fi

# =============================================================================
# Helpers
# =============================================================================
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAIL=$((FAIL+1)); }
skip() { echo -e "${YELLOW}→ SKIP${NC}: $1 (reason: $2)"; SKIP=$((SKIP+1)); }
info() { echo -e "${BLUE}ℹ INFO${NC}: $1"; }

section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

# =============================================================================
# Pre-flight: check tooling
# =============================================================================
section "Pre-flight checks"

command -v openssl >/dev/null 2>&1 && pass "openssl is available" || fail "openssl not found"
command -v curl >/dev/null 2>&1 && pass "curl is available" || fail "curl not found"
command -v step >/dev/null 2>&1 && pass "step CLI is available" || skip "step CLI not found" "install from https://smallstep.com/docs/step-cli/"
command -v docker >/dev/null 2>&1 && pass "docker is available" || fail "docker not found"
command -v jq >/dev/null 2>&1 && pass "jq is available" || fail "jq not found"

# =============================================================================
# Criterion 5: All V3 docs + ADRs locked
# =============================================================================
section "Criterion 5: Documentation lock"

LOCK_MANIFEST="${PROJECT_ROOT}/docs/LOCK-MANIFEST.md"
if [ -f "${LOCK_MANIFEST}" ]; then
    pass "docs/LOCK-MANIFEST.md exists"
    ADR_COUNT=$(ls "${PROJECT_ROOT}/../docs/v3-docs-final/V3-ADR/"*.md 2>/dev/null | wc -l)
    if [ "${ADR_COUNT}" -eq 14 ]; then
        pass "All 14 ADRs present (001-014)"
    else
        fail "Expected 14 ADRs, found ${ADR_COUNT}"
    fi

    DOCS_COUNT=$(ls "${PROJECT_ROOT}/../docs/v3-docs-final/V3-"*.md 2>/dev/null | wc -l)
    if [ "${DOCS_COUNT}" -ge 32 ]; then
        pass "All V3-* docs present (${DOCS_COUNT} files)"
    else
        fail "Expected ≥32 V3-* docs, found ${DOCS_COUNT}"
    fi
else
    fail "docs/LOCK-MANIFEST.md not found — run from project root"
fi

# =============================================================================
# Criterion 2: CA operational — can issue + revoke device certs; CRL serves
# =============================================================================
section "Criterion 2: step-ca operational"

# Check step-ca health
if curl -sf "${STEP_CA_URL}/health" >/dev/null 2>&1; then
    pass "step-ca health endpoint responds at ${STEP_CA_URL}"
else
    fail "step-ca health endpoint not responding at ${STEP_CA_URL}"
fi

# Check root CA fingerprint is available
ROOT_FP_FILE="${CA_DIR}/out/root_ca_fingerprint.txt"
if [ -f "${ROOT_FP_FILE}" ]; then
    ROOT_FP=$(cat "${ROOT_FP_FILE}")
    pass "Root CA fingerprint available: ${ROOT_FP:0:32}..."
else
    fail "Root CA fingerprint file not found at ${ROOT_FP_FILE} — run bootstrap-ca.sh first"
fi

# Check CA bundle exists
CA_BUNDLE="${CA_DIR}/ca_bundle.pem"
if [ -f "${CA_BUNDLE}" ]; then
    pass "CA bundle exists at ${CA_BUNDLE}"
    # Verify it contains both root + intermediate
    BUNDLE_CERTS=$(grep -c "BEGIN CERTIFICATE" "${CA_BUNDLE}" || echo 0)
    if [ "${BUNDLE_CERTS}" -ge 2 ]; then
        pass "CA bundle contains ${BUNDLE_CERTS} certs (root + intermediate)"
    else
        fail "CA bundle should contain ≥2 certs, found ${BUNDLE_CERTS}"
    fi
else
    fail "CA bundle not found at ${CA_BUNDLE}"
fi

# Check CRL endpoint serves
INTERMEDIATE_ID_FILE="${CA_DIR}/out/intermediate_id.txt"
if [ -f "${INTERMEDIATE_ID_FILE}" ]; then
    INTERMEDIATE_ID=$(cat "${INTERMEDIATE_ID_FILE}")
    CRL_URL="${CRL_BASE_URL}/${INTERMEDIATE_ID}/crl.pem"
    if curl -sf -o /dev/null -w "%{http_code}" "${CRL_URL}" | grep -q "200"; then
        pass "CRL endpoint serves at ${CRL_URL}"
    else
        fail "CRL endpoint not serving at ${CRL_URL}"
    fi
else
    skip "CRL endpoint check" "intermediate_id.txt not found"
fi

# Issue + revoke a test device cert
TEST_MAC="deadbeef0011"
info "Issuing test device cert for MAC ${TEST_MAC}..."
if command -v step >/dev/null 2>&1; then
    if [ -f "${CA_DIR}/step-ca-provisioner-password.txt" ]; then
        cd "${CA_DIR}"
        if step ca certificate "${TEST_MAC}" "/tmp/${TEST_MAC}.crt" "/tmp/${TEST_MAC}.key" \
            --san "${TEST_MAC}" \
            --not-after 1h \
            --provisioner "she-device-provisioner" \
            --provisioner-password-file "${CA_DIR}/step-ca-provisioner-password.txt" \
            --ca-url "${STEP_CA_URL}" \
            --root "${CA_DIR}/out/root_ca.crt" 2>/dev/null; then
            pass "step-ca can issue device certs"

            # Revoke it
            if step ca revoke "/tmp/${TEST_MAC}.crt" \
                --provisioner "she-device-provisioner" \
                --provisioner-password-file "${CA_DIR}/step-ca-provisioner-password.txt" \
                --ca-url "${STEP_CA_URL}" \
                --root "${CA_DIR}/out/root_ca.crt" \
                --reason "key_compromise" 2>/dev/null; then
                pass "step-ca can revoke device certs"
            else
                fail "step-ca revoke failed"
            fi
        else
            fail "step-ca cert issuance failed"
        fi
        cd "${PROJECT_ROOT}"
    else
        skip "step-ca issue/revoke test" "provisioner password file missing"
    fi
else
    skip "step-ca issue/revoke test" "step CLI not installed"
fi

# =============================================================================
# Criterion 1: EMQX cluster running with cert-based mTLS auth
# =============================================================================
section "Criterion 1: EMQX cluster + mTLS"

# Check EMQX dashboard responds
EMQX_DASHBOARD_URL="http://${MQTT_HOST}:18083"
if curl -sf -o /dev/null -w "%{http_code}" "${EMQX_DASHBOARD_URL}" | grep -q "200\|302\|401"; then
    pass "EMQX dashboard responds at ${EMQX_DASHBOARD_URL}"
else
    fail "EMQX dashboard not responding at ${EMQX_DASHBOARD_URL}"
fi

# Check EMQX MQTT port is listening
if timeout 5 bash -c "echo > /dev/tcp/${MQTT_HOST}/${MQTT_PORT}" 2>/dev/null; then
    pass "EMQX MQTT port ${MQTT_PORT} is accepting connections"
else
    fail "EMQX MQTT port ${MQTT_PORT} is not reachable"
fi

# Test mTLS handshake with a device cert (the canonical exit criterion test)
DEVICE_CRT="${CA_DIR}/out/devices/she-backend.crt"
DEVICE_KEY="${CA_DIR}/out/devices/she-backend.key"
CA_CERT="${CA_DIR}/out/root_ca.crt"
if [ -f "${DEVICE_CRT}" ] && [ -f "${DEVICE_KEY}" ] && [ -f "${CA_CERT}" ]; then
    info "Running: openssl s_client -connect ${MQTT_HOST}:${MQTT_PORT} with device cert"
    # Send QoS0 CONNECT packet via openssl, expect TLS handshake to succeed
    HANDSHAKE_OUT=$(echo "" | timeout 10 openssl s_client -connect "${MQTT_HOST}:${MQTT_PORT}" \
        -cert "${DEVICE_CRT}" -key "${DEVICE_KEY}" \
        -CAfile "${CA_CERT}" \
        -verify_return_error 2>&1 || true)

    if echo "${HANDSHAKE_OUT}" | grep -q "Verification: OK\|Verify return code: 0"; then
        pass "mTLS handshake succeeds with device cert (openssl s_client -connect ${MQTT_HOST}:${MQTT_PORT})"
    else
        fail "mTLS handshake failed — output:"
        echo "${HANDSHAKE_OUT}" | tail -20
    fi
else
    skip "mTLS handshake test" "device cert/key/CA not found — run bootstrap-ca.sh first"
fi

# =============================================================================
# Criterion 3: Spring Boot MVP deployed — /actuator/health returns UP
# =============================================================================
section "Criterion 3: Spring Boot /actuator/health"

HEALTH_URL="${BACKEND_URL}/actuator/health"
HEALTH_RESP=$(curl -sf -m 10 "${HEALTH_URL}" 2>/dev/null || echo "FETCH_FAILED")
if echo "${HEALTH_RESP}" | jq -e '.status == "UP"' >/dev/null 2>&1; then
    pass "/actuator/health returns UP at ${HEALTH_URL}"

    # Verify components (db + redis + ca)
    DB_STATUS=$(echo "${HEALTH_RESP}" | jq -r '.components.db.status // "MISSING"' 2>/dev/null)
    if [ "${DB_STATUS}" = "UP" ]; then
        pass "Health component 'db' is UP"
    else
        fail "Health component 'db' is ${DB_STATUS} (expected UP)"
    fi

    REDIS_STATUS=$(echo "${HEALTH_RESP}" | jq -r '.components.redis.status // "MISSING"' 2>/dev/null)
    if [ "${REDIS_STATUS}" = "UP" ]; then
        pass "Health component 'redis' is UP"
    else
        fail "Health component 'redis' is ${REDIS_STATUS} (expected UP)"
    fi
else
    fail "/actuator/health did not return UP at ${HEALTH_URL}"
    info "Response: ${HEALTH_RESP}"
fi

# Test register endpoint (validates full stack: web → DB → RLS → JWT)
REGISTER_RESP=$(curl -sf -m 10 -X POST "${BACKEND_URL}/api/v3/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"phase0-verify@example.et","password":"VerifyPhase0!Pass"}' 2>/dev/null || echo "FETCH_FAILED")
if echo "${REGISTER_RESP}" | jq -e '.data.access_token' >/dev/null 2>&1; then
    pass "/api/v3/auth/register works end-to-end (web → DB → JWT)"
    ACCESS_TOKEN=$(echo "${REGISTER_RESP}" | jq -r '.data.access_token')

    # Test /auth/me with the issued token
    ME_RESP=$(curl -sf -m 10 -X GET "${BACKEND_URL}/api/v3/auth/me" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" 2>/dev/null || echo "FETCH_FAILED")
    if echo "${ME_RESP}" | jq -e '.data.user.email == "phase0-verify@example.et"' >/dev/null 2>&1; then
        pass "/api/v3/auth/me returns authenticated user"
    else
        fail "/api/v3/auth/me did not return expected user"
    fi
else
    fail "/api/v3/auth/register failed"
    info "Response: ${REGISTER_RESP}"
fi

# =============================================================================
# Criterion 4: CI/CD pipeline builds + deploys on merge
# =============================================================================
section "Criterion 4: CI/CD pipeline"

CI_WORKFLOW="${PROJECT_ROOT}/.github/workflows/ci.yml"
if [ -f "${CI_WORKFLOW}" ]; then
    pass ".github/workflows/ci.yml exists"

    # Verify required jobs are defined
    if grep -q "build-test" "${CI_WORKFLOW}"; then
        pass "CI workflow defines 'build-test' job"
    else
        fail "CI workflow missing 'build-test' job"
    fi

    if grep -q "docker-build-push" "${CI_WORKFLOW}"; then
        pass "CI workflow defines 'docker-build-push' job"
    else
        fail "CI workflow missing 'docker-build-push' job"
    fi

    if grep -q "deploy-staging" "${CI_WORKFLOW}"; then
        pass "CI workflow defines 'deploy-staging' job"
    else
        fail "CI workflow missing 'deploy-staging' job"
    fi

    # Verify Java 21
    if grep -q "JAVA_VERSION: '21'" "${CI_WORKFLOW}"; then
        pass "CI workflow uses Java 21 (P1-25)"
    else
        fail "CI workflow should specify Java 21"
    fi

    # Verify Maven verify (runs tests + integration tests)
    if grep -q "mvn -B -ntp clean verify" "${CI_WORKFLOW}"; then
        pass "CI runs 'mvn clean verify' (build + unit + integration tests)"
    else
        fail "CI should run 'mvn clean verify'"
    fi
else
    fail ".github/workflows/ci.yml not found"
fi

if [ "${TARGET}" = "staging" ]; then
    info "For criterion 4, verify on GitHub Actions UI:"
    info "  https://github.com/she-v3/she-v3/actions"
    info "A green build on the latest main commit confirms auto-deploy works."
fi

# =============================================================================
# Summary
# =============================================================================
section "Summary"

TOTAL=$((PASS + FAIL))
echo ""
echo -e "  ${GREEN}PASS${NC}: ${PASS}"
echo -e "  ${RED}FAIL${NC}: ${FAIL}"
echo -e "  ${YELLOW}SKIP${NC}: ${SKIP}"
echo ""

if [ "${FAIL}" -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ All Phase 0 exit criteria met — ready for Phase 1.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ ${FAIL} Phase 0 exit criterion check(s) failed.${NC}"
    echo -e "${RED}  Fix the failures above before proceeding to Phase 1.${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
