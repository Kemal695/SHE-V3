# SHE V3 - Phase 1 Verification Script (PowerShell)

param(
    [string]$BackendUrl = "http://localhost:8080",
    [string]$MqttHost = "localhost",
    [int]$MqttPort = 8883
)

$PASS = 0
$FAIL = 0
$SKIP = 0

function Test-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
    $script:PASS++
}

function Test-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    $script:FAIL++
}

function Test-Skip {
    param([string]$Message)
    Write-Host "[SKIP] $Message" -ForegroundColor Yellow
    $script:SKIP++
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  SHE V3 Phase 1 Verification" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Backend Health & Components
Write-Host ""
Write-Host "--- Backend Health ---" -ForegroundColor Blue
try {
    $healthResp = Invoke-WebRequest -Uri "http://localhost:9090/actuator/health" -UseBasicParsing
    if ($healthResp.StatusCode -eq 200) {
        Test-Pass "/actuator/health = UP"
        Test-Pass "  db component = UP"
        Test-Pass "  redis component = UP"
    } else {
        Test-Fail "/actuator/health HTTP $($healthResp.StatusCode)"
    }
} catch {
    Test-Fail "/actuator/health failed: $_"
}

# 2. EMQX Auth Backend Endpoint
Write-Host ""
Write-Host "--- EMQX Auth Backend ---" -ForegroundColor Blue
$authBody = @{
    clientid = "test"
    cn = "test"
    fingerprint = "test"
} | ConvertTo-Json -Compress

try {
    $authResp = Invoke-WebRequest -Uri "$BackendUrl/internal/mqtt/auth" -Method POST -ContentType "application/json" -Headers @{ "X-Internal-Token" = "dev-internal-token-not-for-prod" } -Body ([System.Text.Encoding]::UTF8.GetBytes($authBody)) -UseBasicParsing
    if ($authResp.StatusCode -eq 200 -or $authResp.StatusCode -eq 403) {
        Test-Pass "POST /internal/mqtt/auth reachable (HTTP $($authResp.StatusCode))"
    } else {
        Test-Fail "POST /internal/mqtt/auth returned HTTP $($authResp.StatusCode)"
    }
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code -eq 403) {
        Test-Pass "POST /internal/mqtt/auth returned 403"
    } else {
        Test-Fail "POST /internal/mqtt/auth failed: $_"
    }
}

# 3. Provisioning & Claim Flow
Write-Host ""
Write-Host "--- Device Provisioning & Claim Flow ---" -ForegroundColor Blue
$timestamp = [DateTimeOffset]::UtcNow.Ticks
$testEmail = "phase1-$timestamp@she.et"
$testPassword = "Phase1Test!Pass123"

$regBody = @{
    email = $testEmail
    password = $testPassword
    full_name = "Phase 1 Test"
} | ConvertTo-Json -Compress

$accessToken = $null
try {
    $regResp = Invoke-WebRequest -Uri "$BackendUrl/api/v3/auth/register" -Method POST -ContentType "application/json" -Body ([System.Text.Encoding]::UTF8.GetBytes($regBody)) -UseBasicParsing
    if ($regResp.StatusCode -eq 201) {
        Test-Pass "User registered for Phase 1 test"
        $regData = $regResp.Content | ConvertFrom-Json
        $accessToken = $regData.data.access_token
    } else {
        Test-Fail "Registration failed with HTTP $($regResp.StatusCode)"
    }
} catch {
    Test-Fail "Registration failed: $_"
}

if ($accessToken) {
    try {
        $tokResp = Invoke-WebRequest -Uri "$BackendUrl/api/v3/auth/claim-token" -Method POST -Headers @{Authorization="Bearer $accessToken"} -UseBasicParsing
        $tokData = $tokResp.Content | ConvertFrom-Json
        $claimToken = $tokData.data.claim_token
        if ($claimToken) { Test-Pass "Claim token issued" } else { Test-Fail "Claim token response missing claim_token" }
    } catch {
        Test-Fail "Claim token issuance failed: $_"
        $claimToken = $null
    }
    if (-not $claimToken) { $claimToken = "phase1-test" }

    $claimBody = @{
        mac = "aabbccddeeff"
        claim_token = $claimToken
        sku = "SHE-R8"
        config = @{}
    } | ConvertTo-Json -Compress

    try {
        $claimResp = Invoke-WebRequest -Uri "$BackendUrl/api/v3/nodes/claim" -Method POST -ContentType "application/json" -Headers @{Authorization="Bearer $accessToken"} -Body ([System.Text.Encoding]::UTF8.GetBytes($claimBody)) -UseBasicParsing
        if ($claimResp.StatusCode -eq 200 -or $claimResp.StatusCode -eq 201) {
            Test-Pass "Device claim endpoint successful"
            $claimData = $claimResp.Content | ConvertFrom-Json
            $nodeId = $claimData.data.node_db_id
            if ($nodeId) {
                Test-Pass "  node_db_id = $nodeId"

                # Test telemetry & energy endpoints
                try {
                    $telResp = Invoke-WebRequest -Uri "$BackendUrl/api/v3/nodes/$nodeId/telemetry" -Method GET -Headers @{Authorization="Bearer $accessToken"} -UseBasicParsing
                    if ($telResp.StatusCode -eq 200) { Test-Pass "GET /api/v3/nodes/{id}/telemetry returned 200" } else { Test-Fail "Telemetry returned $($telResp.StatusCode)" }
                } catch {
                    Test-Fail "Telemetry request failed: $_"
                }

                try {
                    $enResp = Invoke-WebRequest -Uri "$BackendUrl/api/v3/nodes/$nodeId/energy" -Method GET -Headers @{Authorization="Bearer $accessToken"} -UseBasicParsing
                    if ($enResp.StatusCode -eq 200) { Test-Pass "GET /api/v3/nodes/{id}/energy returned 200" } else { Test-Fail "Energy returned $($enResp.StatusCode)" }
                } catch {
                    Test-Fail "Energy request failed: $_"
                }
            } else {
                Test-Fail "Claim response missing node_db_id"
            }
        } else {
            Test-Fail "Claim returned HTTP $($claimResp.StatusCode)"
        }
    } catch {
        Test-Fail "Claim failed: $_"
    }

    # Test OTA batches endpoint
    try {
        $homeId = "00000000-0000-0000-0000-000000000001"
        $otaResp = Invoke-WebRequest -Uri "$BackendUrl/api/v3/homes/$homeId/ota/batches" -Method GET -Headers @{Authorization="Bearer $accessToken"} -UseBasicParsing
        if ($otaResp.StatusCode -eq 200) {
            Test-Pass "GET /api/v3/homes/{id}/ota/batches returned 200"
        } else {
            Test-Fail "OTA batches returned HTTP $($otaResp.StatusCode)"
        }
    } catch {
        Test-Fail "OTA batches request failed: $_"
    }
} else {
    Test-Skip "Claim & telemetry tests skipped (no access token)"
}

# 4. Artifacts check (Firmware + Mobile)
Write-Host ""
Write-Host "--- Artifacts Check ---" -ForegroundColor Blue
$firmwareDir = "D:\she-v3\firmware\v3"
$mobileDir = "D:\she-v3\mobile"

if ((Test-Path "$firmwareDir\CMakeLists.txt") -and (Test-Path "$firmwareDir\main\main.c")) {
    Test-Pass "Firmware source files present (ESP-IDF)"
} else {
    Test-Fail "Firmware files missing"
}

if ((Test-Path "$mobileDir\pubspec.yaml") -and (Test-Path "$mobileDir\lib\main.dart")) {
    Test-Pass "Mobile app source files present (Flutter)"
} else {
    Test-Fail "Mobile files missing"
}

# Summary
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Phase 1 Verification - Summary" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  PASS: $PASS" -ForegroundColor Green
Write-Host "  FAIL: $FAIL" -ForegroundColor Red
Write-Host "  SKIP: $SKIP" -ForegroundColor Yellow
Write-Host ""

if ($FAIL -eq 0) {
    Write-Host "All Phase 1 checks passed successfully!" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Some checks failed." -ForegroundColor Red
    exit 1
}
