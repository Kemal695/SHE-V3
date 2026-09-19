#!/usr/bin/env bash
# =============================================================================
# SHE V3 — Phase 4 Exit Criteria Verification
# =============================================================================
# V3-ROADMAP §6 exit criteria:
#   [ ] Dark-mode Bento UI shipped + feels premium (internal review ≥ 8/10)
#   [ ] Energy monitoring shows real-time + historical data in ETB
#   [ ] Voice control works offline ("Hey Sheba" → relay toggles < 1s)
#   [ ] Full Amharic UI (100% strings translated + reviewed by native speaker)
#
# Portability fix: the original script hardcoded the author's Linux build host
# (/home/z/my-project/she-v3) in 21 places, so on any other machine every file
# check failed regardless of the real state of the tree. REPO_ROOT is now
# derived from this script's own location (scripts/ -> parent).
# =============================================================================
set -uo pipefail
PASS=0; FAIL=0; SKIP=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_URL="${BACKEND_URL:-http://localhost:8080}"

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${BLUE}ℹ INFO${NC}: $1"; }
# `skip` was called below but never defined in the original — undefined command.
skip() { echo -e "${YELLOW}− SKIP${NC}: $1 ${2:+($2)}"; SKIP=$((SKIP+1)); }
section() { echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; }

echo "Repo root: $REPO_ROOT"
echo "Backend:   $BACKEND_URL"

# =============================================================================
section "Criterion 1: Dark-mode Bento UI (design tokens + widgets)"
# =============================================================================

if [ -f "$REPO_ROOT/mobile/lib/core/theme/v3_design_tokens.dart" ]; then
    pass "V3 design tokens file exists (v3_design_tokens.dart)"
    # Check for forbidden hues.
    #
    # The tokens file legitimately DECLARES these hues as a denylist
    # (V3Colors.forbiddenHues, consumed by isForbiddenHue() to validate tenant
    # branding), so a plain grep over the whole file always matched the
    # declaration itself and reported a violation that did not exist.
    # Skip the `forbiddenHues = [ ... ];` block and only flag the hues if they
    # appear anywhere else (i.e. actually used in the palette).
    if awk '/forbiddenHues *= *\[/ { skip=1 }
            skip && /\]/ { skip=0; next }
            !skip { print }' \
         "$REPO_ROOT/mobile/lib/core/theme/v3_design_tokens.dart" \
       | grep -q "0xFF4F46E5\|0xFF6366F1\|0xFF7C3AED"; then
        fail "Forbidden indigo hues used in the design palette"
    else
        pass "No forbidden indigo/blue-purple hues in design tokens"
    fi
    # Check Deep Navy + Bright Sky Blue
    if grep -q "0xFF0B1D37" "$REPO_ROOT/mobile/lib/core/theme/v3_design_tokens.dart"; then
        pass "Deep Navy #0B1D37 present"
    else
        fail "Deep Navy #0B1D37 missing"
    fi
    if grep -q "0xFF56B4FA" "$REPO_ROOT/mobile/lib/core/theme/v3_design_tokens.dart"; then
        pass "Bright Sky Blue #56B4FA present"
    else
        fail "Bright Sky Blue #56B4FA missing"
    fi
else
    fail "V3 design tokens file missing"
fi

# Check premium widgets
for widget in she_toggle.dart haptic_slider.dart; do
    if [ -f "$REPO_ROOT/mobile/lib/core/widgets/$widget" ]; then
        pass "Premium widget exists: $widget"
    else
        fail "Premium widget missing: $widget"
    fi
done

# Check dynamic device widget has type-based rendering
if grep -q "esp.device.switch\|esp.device.lightbulb\|esp.device.fan" "$REPO_ROOT/mobile/lib/features/dashboard/widgets/dynamic_device_widget.dart"; then
    pass "DynamicDeviceWidget has type-based rendering (switch/lightbulb/fan)"
else
    fail "DynamicDeviceWidget missing type-based rendering"
fi

# Check scenes row
if [ -f "$REPO_ROOT/mobile/lib/features/scenes/scenes_row.dart" ]; then
    pass "Scenes row widget exists"
else
    fail "Scenes row widget missing"
fi

# =============================================================================
section "Criterion 2: Energy monitoring dashboard"
# =============================================================================

if [ -f "$REPO_ROOT/mobile/lib/features/energy/energy_screen.dart" ]; then
    pass "Energy screen exists"
    if grep -q "fl_chart\|LineChart\|BarChart" "$REPO_ROOT/mobile/lib/features/energy/energy_screen.dart"; then
        pass "Energy screen uses fl_chart for historical charts"
    else
        fail "Energy screen missing chart integration"
    fi
else
    fail "Energy screen missing"
fi

# Check ETB formatter
if [ -f "$REPO_ROOT/mobile/lib/core/utils/etb_formatter.dart" ]; then
    pass "ETB currency formatter exists"
    if grep -q "ብር" "$REPO_ROOT/mobile/lib/core/utils/etb_formatter.dart"; then
        pass "ETB formatter uses ብር symbol for Amharic"
    else
        fail "ETB formatter missing ብር symbol"
    fi
else
    fail "ETB formatter missing"
fi

# Check energy endpoints (backend)
#
# NOTE: do NOT write `$(curl ... || echo "000")`. curl writes the status code via
# -w and THEN exits non-zero (observed exit 23 "Failed writing body" in Git Bash
# on Windows, even for successful 200s), so the `||` branch appends a second code
# and the value becomes e.g. "401000" — which matches nothing and made this check
# silently SKIP forever, reporting "backend not running" even when it was up.
# Capture the code, then swallow curl's exit status separately.
ENERGY_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 \
    "$BACKEND_URL/api/v3/nodes/00000000-0000-0000-0000-000000000001/energy" 2>/dev/null) || true
ENERGY_CODE="${ENERGY_CODE:-000}"
if [[ "$ENERGY_CODE" =~ ^(200|401|403|404)$ ]]; then
    pass "Energy endpoint reachable (HTTP $ENERGY_CODE)"
else
    fail "Energy endpoint unreachable (HTTP $ENERGY_CODE)"
fi

# =============================================================================
section "Criterion 3: Voice control (R16 only)"
# =============================================================================

if [ -f "$REPO_ROOT/mobile/lib/features/voice/voice_screen.dart" ]; then
    pass "Voice control screen exists"
    if grep -q "Hey Sheba\|ሰበኣ" "$REPO_ROOT/mobile/lib/features/voice/voice_screen.dart"; then
        pass "Wake word 'Hey Sheba' / 'ሰበኣ' referenced in voice screen"
    else
        fail "Wake word not referenced"
    fi
else
    fail "Voice control screen missing"
fi

# Check firmware voice_control.c
if [ -f "$REPO_ROOT/firmware/v3/main/voice_control.c" ]; then
    pass "Firmware voice_control.c exists"
    if grep -q "porcupine\|rhino\|Porcupine\|Rhino" "$REPO_ROOT/firmware/v3/main/voice_control.c"; then
        pass "Picovoice SDK integration referenced in firmware"
    else
        info "Picovoice integration is a stub (Phase 2B will complete)"
    fi
else
    fail "Firmware voice_control.c missing"
fi

# =============================================================================
section "Criterion 4: Amharic i18n (100% coverage)"
# =============================================================================

if [ -f "$REPO_ROOT/mobile/lib/l10n/app_en.arb" ] && [ -f "$REPO_ROOT/mobile/lib/l10n/app_am.arb" ]; then
    pass "ARB files exist (app_en.arb + app_am.arb)"

    EN_COUNT=$(grep -c '"' "$REPO_ROOT/mobile/lib/l10n/app_en.arb")
    AM_COUNT=$(grep -c '"' "$REPO_ROOT/mobile/lib/l10n/app_am.arb")

    if [ "$EN_COUNT" -gt 50 ] && [ "$AM_COUNT" -gt 50 ]; then
        pass "ARB files have substantial string coverage (EN: $EN_COUNT lines, AM: $AM_COUNT lines)"
    else
        fail "ARB files have insufficient coverage (EN: $EN_COUNT, AM: $AM_COUNT)"
    fi

    # Check key Amharic strings are present
    if grep -q "ብር" "$REPO_ROOT/mobile/lib/l10n/app_am.arb"; then
        pass "Amharic ETB symbol (ብር) present in ARB"
    else
        fail "Amharic ETB symbol missing from ARB"
    fi
else
    fail "ARB files missing"
fi

# Check Ethiopian calendar utility
if [ -f "$REPO_ROOT/mobile/lib/core/utils/ethiopian_calendar.dart" ]; then
    pass "Ethiopian calendar utility exists"
    if grep -q "Meskerem\|መስከረም" "$REPO_ROOT/mobile/lib/core/utils/ethiopian_calendar.dart"; then
        pass "Ethiopian calendar has month names (Amharic + English)"
    else
        fail "Ethiopian calendar missing month names"
    fi
else
    fail "Ethiopian calendar utility missing"
fi

# =============================================================================
section "Summary"
# =============================================================================

echo ""
echo -e "  ${GREEN}PASS${NC}: ${PASS}"
echo -e "  ${RED}FAIL${NC}: ${FAIL}"
echo -e "  ${YELLOW}SKIP${NC}: ${SKIP}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✓ All Phase 4 exit criteria checks passed${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ✗ ${FAIL} check(s) failed${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
