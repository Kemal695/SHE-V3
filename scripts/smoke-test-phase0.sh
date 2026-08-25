#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Phase 0 End-to-End Smoke Test
# =============================================================================
# Run this AFTER `docker compose up -d` + `mvn spring-boot:run`.
# It exercises every Phase 0 exit criterion with real API traffic.
#
# Usage:  ./scripts/smoke-test-phase0.sh
# =============================================================================
set -uo pipefail

BACKEND="http://localhost:8080"
MQTT_HOST="localhost"
MQTT_PORT="8883"
STEP_CA_URL="http://localhost:9002"
CRL_BASE="http://localhost:8088/ca"
CA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/ca"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; FAILURES=$((FAILURES+1)); }
info() { echo -e "${BLUE}ℹ${NC} $1"; }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }
FAILURES=0

# Test user credentials (random email to avoid conflicts on re-runs)
TEST_EMAIL="phase0-test-$(date +%s)@example.et"
TEST_PASSWORD="Phase0Test!Pass123"

section "Criterion 3: Spring Boot /actuator/health"
HEALTH=$(curl -sf -m 5 "$BACKEND/actuator/health" || echo "{}")
STATUS=$(echo "$HEALTH" | jq -r '.status // "MISSING"')
if [ "$STATUS" = "UP" ]; then
    pass "/actuator/health = UP"
    DB_STATUS=$(echo "$HEALTH" | jq -r '.components.db.status // "MISSING"')
    REDIS_STATUS=$(echo "$HEALTH" | jq -r '.components.redis.status // "MISSING"')
    [ "$DB_STATUS" = "UP" ] && pass "  db component = UP" || fail "  db component = $DB_STATUS"
    [ "$REDIS_STATUS" = "UP" ] && pass "  redis component = UP" || fail "  redis component = $REDIS_STATUS"
else
    fail "/actuator/health = $STATUS (expected UP)"
    info "Response: $HEALTH"
fi

section "Criterion 3: Auth flow (register → login → me → users CRUD)"

# --- Register ---
info "POST /api/v3/auth/register  email=$TEST_EMAIL"
REGISTER_RESP=$(curl -sf -m 10 -X POST "$BACKEND/api/v3/auth/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"full_name\":\"Phase 0 Test\"}" \
    || echo "{}")
ACCESS_TOKEN=$(echo "$REGISTER_RESP" | jq -r '.data.access_token // empty')
if [ -n "$ACCESS_TOKEN" ]; then
    pass "register → access_token issued"
    EXPIRES_IN=$(echo "$REGISTER_RESP" | jq -r '.data.expires_in')
    [ "$EXPIRES_IN" = "900" ] && pass "  expires_in = 900 (15 min per V3-SECURITY-MODEL §1.1)" || fail "  expires_in = $EXPIRES_IN (expected 900)"
    TOKEN_TYPE=$(echo "$REGISTER_RESP" | jq -r '.data.token_type')
    [ "$TOKEN_TYPE" = "Bearer" ] && pass "  token_type = Bearer" || fail "  token_type = $TOKEN_TYPE"
else
    fail "register failed"
    info "Response: $REGISTER_RESP"
    exit 1
fi

# --- Login ---
info "POST /api/v3/auth/login"
LOGIN_RESP=$(curl -sf -m 10 -X POST "$BACKEND/api/v3/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}" \
    || echo "{}")
LOGIN_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.data.access_token // empty')
if [ -n "$LOGIN_TOKEN" ]; then
    pass "login → access_token issued"
else
    fail "login failed"
    info "Response: $LOGIN_RESP"
fi

# --- Me ---
info "GET /api/v3/auth/me"
ME_RESP=$(curl -sf -m 10 -X GET "$BACKEND/api/v3/auth/me" \
    -H "Authorization: Bearer $ACCESS_TOKEN" || echo "{}")
ME_EMAIL=$(echo "$ME_RESP" | jq -r '.data.user.email // empty')
if [ "$ME_EMAIL" = "$TEST_EMAIL" ]; then
    pass "/auth/me returns authenticated user"
    PLATFORM_ROLE=$(echo "$ME_RESP" | jq -r '.data.user.platform_role')
    [ "$PLATFORM_ROLE" = "USER" ] && pass "  platform_role = USER (default B2C)" || fail "  platform_role = $PLATFORM_ROLE"
    TENANT_PLAN=$(echo "$ME_RESP" | jq -r '.data.tenant.plan')
    [ "$TENANT_PLAN" = "B2C-FREE" ] && pass "  tenant.plan = B2C-FREE (default tenant seeded)" || fail "  tenant.plan = $TENANT_PLAN"
    BRAND_COLOR=$(echo "$ME_RESP" | jq -r '.data.branding.primary_color')
    [ "$BRAND_COLOR" = "#0B1D37" ] && pass "  branding.primary_color = #0B1D37 (Deep Navy per V3-DESIGN-SYSTEM)" || fail "  branding.primary_color = $BRAND_COLOR"
else
    fail "/auth/me failed"
    info "Response: $ME_RESP"
fi

# --- JWT structure check (decode header + payload) ---
info "Decoding JWT header + payload to verify EdDSA + kid"
JWT_HEADER_B64=$(echo "$ACCESS_TOKEN" | cut -d. -f1)
JWT_HEADER=$(echo "$JWT_HEADER_B64" | base64 -d 2>/dev/null || echo "{}")
JWT_ALG=$(echo "$JWT_HEADER" | jq -r '.alg // empty')
JWT_KID=$(echo "$JWT_HEADER" | jq -r '.kid // empty')
[ "$JWT_ALG" = "EdDSA" ] && pass "JWT alg = EdDSA (P1-6)" || fail "JWT alg = $JWT_ALG (expected EdDSA)"
[ -n "$JWT_KID" ] && pass "JWT kid = $JWT_KID (multi-key rotation per P1-6)" || fail "JWT missing kid header"

JWT_PAYLOAD_B64=$(echo "$ACCESS_TOKEN" | cut -d. -f2)
JWT_PAYLOAD=$(echo "$JWT_PAYLOAD_B64" | base64 -d 2>/dev/null || echo "{}")
JWT_TYPE=$(echo "$JWT_PAYLOAD" | jq -r '.type')
JWT_ISS=$(echo "$JWT_PAYLOAD" | jq -r '.iss')
JWT_AUD=$(echo "$JWT_PAYLOAD" | jq -r '.aud')
[ "$JWT_TYPE" = "access" ] && pass "JWT type = access" || fail "JWT type = $JWT_TYPE"
[ "$JWT_ISS" = "she.et" ] && pass "JWT iss = she.et" || fail "JWT iss = $JWT_ISS"
[ "$JWT_AUD" = "she-api" ] && pass "JWT aud = she-api" || fail "JWT aud = $JWT_AUD"

# --- Refresh (rotating) ---
info "POST /api/v3/auth/refresh (rotating refresh — old jti blacklisted)"
REFRESH_TOKEN=$(echo "$REGISTER_RESP" | jq -r '.data.refresh_token')
REFRESH_RESP=$(curl -sf -m 10 -X POST "$BACKEND/api/v3/auth/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}" || echo "{}")
NEW_ACCESS=$(echo "$REFRESH_RESP" | jq -r '.data.access_token // empty')
if [ -n "$NEW_ACCESS" ] && [ "$NEW_ACCESS" != "$ACCESS_TOKEN" ]; then
    pass "refresh issued NEW access_token (rotating refresh per V3-SECURITY-MODEL §1.1)"
else
    fail "refresh did not issue a new token"
    info "Response: $REFRESH_RESP"
fi

# --- Old refresh token should now be revoked ---
info "Re-using old refresh token → expect 401 AUTH_TOKEN_REVOKED"
OLD_REFRESH_RESP=$(curl -s -m 10 -w "\n%{http_code}" -X POST "$BACKEND/api/v3/auth/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}")
OLD_REFRESH_CODE=$(echo "$OLD_REFRESH_RESP" | tail -1)
if [ "$OLD_REFRESH_CODE" = "401" ]; then
    pass "old refresh token rejected with 401 (jti blacklist works)"
else
    fail "old refresh token was NOT rejected (expected 401, got $OLD_REFRESH_CODE)"
fi

# --- Error envelope format ---
info "GET /api/v3/auth/me with malformed JWT → expect 401 AUTH_TOKEN_INVALID"
ERR_RESP=$(curl -s -m 5 -w "\n%{http_code}" -X GET "$BACKEND/api/v3/auth/me" \
    -H "Authorization: Bearer not-a-real-jwt")
ERR_CODE=$(echo "$ERR_RESP" | head -1 | jq -r '.error.code // empty')
ERR_HTTP=$(echo "$ERR_RESP" | head -1 | jq -r '.error.http_status // empty')
ERR_REQID=$(echo "$ERR_RESP" | head -1 | jq -r '.error.request_id // empty')
[ "$ERR_CODE" = "AUTH_TOKEN_INVALID" ] && pass "error.code = AUTH_TOKEN_INVALID" || fail "error.code = $ERR_CODE"
[ "$ERR_HTTP" = "401" ] && pass "error.http_status = 401" || fail "error.http_status = $ERR_HTTP"
[ -n "$ERR_REQID" ] && pass "error.request_id present (V3-ERROR-CODES §1)" || fail "error.request_id missing"

# --- Validation envelope ---
info "POST /api/v3/auth/register with weak password → expect 400 VALIDATION_FAILED"
VAL_RESP=$(curl -s -m 5 -w "\n%{http_code}" -X POST "$BACKEND/api/v3/auth/register" \
    -H "Content-Type: application/json" \
    -d '{"email":"bad@example.et","password":"short"}')
VAL_CODE=$(echo "$VAL_RESP" | head -1 | jq -r '.error.code // empty')
[ "$VAL_CODE" = "VALIDATION_FAILED" ] && pass "weak password → VALIDATION_FAILED" || fail "expected VALIDATION_FAILED, got $VAL_CODE"

section "Criterion 2: step-ca operational"

# Check step-ca health
CA_HEALTH=$(curl -sf -m 5 "$STEP_CA_URL/health" || echo "FAIL")
if [ "$CA_HEALTH" != "FAIL" ]; then
    pass "step-ca /health responds"
else
    fail "step-ca /health not responding at $STEP_CA_URL"
fi

# Check root CA fingerprint file exists
if [ -f "$CA_DIR/out/root_ca_fingerprint.txt" ]; then
    ROOT_FP=$(cat "$CA_DIR/out/root_ca_fingerprint.txt")
    pass "Root CA fingerprint available: ${ROOT_FP:0:32}..."
else
    fail "Root CA fingerprint file missing — run bootstrap-ca.sh"
fi

# Check CA bundle exists + has both root + intermediate
if [ -f "$CA_DIR/ca_bundle.pem" ]; then
    BUNDLE_COUNT=$(grep -c "BEGIN CERTIFICATE" "$CA_DIR/ca_bundle.pem" || echo 0)
    [ "$BUNDLE_COUNT" -ge 2 ] && pass "CA bundle has $BUNDLE_COUNT certs (root + intermediate)" || fail "CA bundle has only $BUNDLE_COUNT certs"
else
    fail "CA bundle missing at $CA_DIR/ca_bundle.pem"
fi

# Verify root CA cert details (RSA 4096, 20yr)
if [ -f "$CA_DIR/out/root_ca.crt" ]; then
    ROOT_KEY_SIZE=$(openssl x509 -in "$CA_DIR/out/root_ca.crt" -noout -text 2>/dev/null | grep -A1 "Public-Key" | head -1 | grep -oE '[0-9]+' || echo "?")
    [ "$ROOT_KEY_SIZE" = "4096" ] && pass "Root CA key size = 4096-bit (P0-2, P1-23)" || fail "Root CA key size = $ROOT_KEY_SIZE (expected 4096)"
    ROOT_DAYS=$(openssl x509 -in "$CA_DIR/out/root_ca.crt" -noout -dates 2>/dev/null)
    pass "Root CA validity: $ROOT_DAYS"
else
    fail "Root CA cert missing at $CA_DIR/out/root_ca.crt"
fi

# Issue + revoke a test device cert (if step CLI is available)
if command -v step >/dev/null 2>&1; then
    TEST_MAC="deadbeefcafe"
    info "Issuing test device cert for MAC $TEST_MAC (ECDSA P-256, 5yr per P0-2)..."
    cd "$CA_DIR"
    if step ca certificate "$TEST_MAC" "/tmp/${TEST_MAC}.crt" "/tmp/${TEST_MAC}.key" \
        --san "$TEST_MAC" --not-after 43800h \
        --provisioner "she-device-provisioner" \
        --provisioner-password-file "$CA_DIR/step-ca-provisioner-password.txt" \
        --ca-url "$STEP_CA_URL" --root "$CA_DIR/out/root_ca.crt" 2>/dev/null; then
        pass "step-ca can issue device certs"

        # Verify the issued cert is ECDSA P-256
        CERT_KEY_TYPE=$(openssl x509 -in "/tmp/${TEST_MAC}.crt" -noout -text 2>/dev/null | grep -A1 "Public Key Algorithm" | tail -1 | grep -oE 'P-256|P-384|RSA' | head -1)
        [ "$CERT_KEY_TYPE" = "P-256" ] && pass "Device cert key = ECDSA P-256 (P0-2)" || fail "Device cert key = $CERT_KEY_TYPE (expected P-256)"

        # Revoke
        if step ca revoke "/tmp/${TEST_MAC}.crt" \
            --provisioner "she-device-provisioner" \
            --provisioner-password-file "$CA_DIR/step-ca-provisioner-password.txt" \
            --ca-url "$STEP_CA_URL" --root "$CA_DIR/out/root_ca.crt" \
            --reason "key_compromise" 2>/dev/null; then
            pass "step-ca can revoke device certs"
        else
            fail "step-ca revoke failed"
        fi
    else
        fail "step-ca cert issuance failed"
    fi
    cd - >/dev/null
else
    info "step CLI not installed — skipping issue/revoke test"
    info "Install from https://smallstep.com/docs/step-cli/ to run this check"
fi

# Check CRL endpoint serves
if [ -f "$CA_DIR/out/intermediate_id.txt" ]; then
    INT_ID=$(cat "$CA_DIR/out/intermediate_id.txt")
    CRL_URL="$CRL_BASE/$INT_ID/crl.pem"
    CRL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$CRL_URL")
    [ "$CRL_CODE" = "200" ] && pass "CRL endpoint serves at $CRL_URL" || fail "CRL endpoint returned $CRL_CODE at $CRL_URL"
fi

section "Criterion 1: EMQX mTLS handshake"

# EMQX dashboard
EMQX_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://localhost:18083" || echo "FAIL")
[[ "$EMQX_CODE" =~ ^(200|302|401)$ ]] && pass "EMQX dashboard responds ($EMQX_CODE)" || fail "EMQX dashboard not responding ($EMQX_CODE)"

# Port 8883 open
if timeout 5 bash -c "echo > /dev/tcp/$MQTT_HOST/$MQTT_PORT" 2>/dev/null; then
    pass "MQTT port $MQTT_PORT is accepting connections"
else
    fail "MQTT port $MQTT_PORT not reachable"
fi

# mTLS handshake (the canonical exit criterion test)
if [ -f "$CA_DIR/out/devices/she-backend.crt" ] && [ -f "$CA_DIR/out/devices/she-backend.key" ] && [ -f "$CA_DIR/out/root_ca.crt" ]; then
    info "openssl s_client -connect $MQTT_HOST:$MQTT_PORT (with backend client cert)"
    HANDSHAKE=$(echo "Q" | timeout 8 openssl s_client -connect "$MQTT_HOST:$MQTT_PORT" \
        -cert "$CA_DIR/out/devices/she-backend.crt" \
        -key "$CA_DIR/out/devices/she-backend.key" \
        -CAfile "$CA_DIR/out/root_ca.crt" \
        -verify_return_error 2>&1 || true)
    if echo "$HANDSHAKE" | grep -q "Verification: OK\|Verify return code: 0"; then
        pass "mTLS handshake succeeds — openssl s_client -connect $MQTT_HOST:$MQTT_PORT (criterion 1 PASS)"
    else
        fail "mTLS handshake failed"
        echo "$HANDSHAKE" | tail -15 | sed 's/^/    /'
    fi
else
    fail "Device cert/key/CA bundle missing — run infra/ca/bootstrap-ca.sh"
fi

# EMQX auth backend (POST /internal/mqtt/auth with the backend cert fingerprint)
if [ -f "$CA_DIR/out/devices/she-backend.crt" ]; then
    info "POST /internal/mqtt/auth with backend cert fingerprint (testing EMQX → Spring Boot path)"
    BACKEND_FP=$(openssl x509 -in "$CA_DIR/out/devices/she-backend.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
    AUTH_RESP=$(curl -s -m 5 -w "\n%{http_code}" -X POST "$BACKEND/internal/mqtt/auth" \
        -H "Content-Type: application/json" \
        -H "X-Internal-Token: dev-internal-token-not-for-prod" \
        -d "{\"clientid\":\"she-backend\",\"cn\":\"she-backend\",\"fingerprint\":\"$BACKEND_FP\"}")
    AUTH_CODE=$(echo "$AUTH_RESP" | tail -1)
    # We expect either 200 (allow) or 403 (deny — because she-backend isn't a device cert in device_certs table)
    if [[ "$AUTH_CODE" =~ ^(200|403)$ ]]; then
        pass "EMQX auth backend reachable (HTTP $AUTH_CODE — expected 403 since she-backend isn't a registered device cert)"
    else
        fail "EMQX auth backend returned $AUTH_CODE (expected 200 or 403)"
        info "Response: $(echo "$AUTH_RESP" | head -1)"
    fi
fi

section "Criterion 4: CI/CD pipeline"
CI_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows/ci.yml"
if [ -f "$CI_FILE" ]; then
    pass ".github/workflows/ci.yml exists"
    grep -q "build-test" "$CI_FILE" && pass "  build-test job defined" || fail "  build-test job missing"
    grep -q "docker-build-push" "$CI_FILE" && pass "  docker-build-push job defined" || fail "  docker-build-push job missing"
    grep -q "deploy-staging" "$CI_FILE" && pass "  deploy-staging job defined" || fail "  deploy-staging job missing"
    grep -q "JAVA_VERSION: '21'" "$CI_FILE" && pass "  Java 21 (P1-25)" || fail "  Java version not pinned"
    grep -q "mvn -B -ntp clean verify" "$CI_FILE" && pass "  runs 'mvn clean verify' (build + tests)" || fail "  missing 'mvn clean verify'"
    grep -q "branches: \[main\]" "$CI_FILE" && pass "  auto-trigger on merge to main" || fail "  no main-branch trigger"
else
    fail ".github/workflows/ci.yml not found"
fi

section "Criterion 5: Documentation lock"
LOCK_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/LOCK-MANIFEST.md"
if [ -f "$LOCK_FILE" ]; then
    pass "docs/LOCK-MANIFEST.md exists"
    ADR_COUNT=$(find "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../docs/v3-docs-final/V3-ADR" -name '*.md' 2>/dev/null | wc -l)
    [ "$ADR_COUNT" -eq 14 ] && pass "  $ADR_COUNT/14 ADRs present" || fail "  $ADR_COUNT/14 ADRs present"
    DOCS_COUNT=$(find "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../docs/v3-docs-final" -maxdepth 1 -name 'V3-*.md' 2>/dev/null | wc -l)
    [ "$DOCS_COUNT" -ge 32 ] && pass "  $DOCS_COUNT V3-* docs present" || fail "  $DOCS_COUNT V3-* docs present (expected ≥32)"
else
    fail "docs/LOCK-MANIFEST.md not found"
fi

section "Summary"
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✓ ALL PHASE 0 EXIT CRITERIA VERIFIED WITH LIVE API TRAFFIC${NC}"
    echo -e "${GREEN}  ✓ Phase 0 is COMPLETE — ready to proceed to Phase 1${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ✗ $FAILURES check(s) failed${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
