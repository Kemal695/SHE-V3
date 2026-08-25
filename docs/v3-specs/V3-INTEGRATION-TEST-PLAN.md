# V3 — Integration Test Plan

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Backend Engineer + Lead Engineer

---

## 0. Scope

Defines the test pyramid, coverage targets, load/chaos scenarios, firmware smoke tests, security tests, and PDPP tests for SHE V3. Every PR must pass the CI gate; every release must pass the full plan.

---

## 1. Test pyramid

| Level | Tool | Coverage target | CI runtime |
|---|---|---|---|
| Unit | JUnit 5 + Mockito | 80% on service/impl packages (Spring Boot) | < 90 s |
| Integration | Testcontainers (Postgres 16 + Redis 7 + EMQX 5) | All repositories, all webhook handlers, all MQTT listeners | < 5 min |
| API contract | Spring Boot Test + MockMvc + RestAssured | All endpoints, happy + error paths | < 2 min |
| Flutter widget | `flutter test` | All screens, all user flows | < 3 min |
| Flutter integration | `flutter test integration_test/` + device farm | Critical paths on 3 Android + 2 iOS devices | < 10 min (parallel) |
| Firmware unit | Unity (ESP-IDF native) | All drivers (PCF8574, PZEM, Picovoice wrapper, OTA handler) | < 60 s |
| Firmware on-device smoke | Custom test jig + pogo pins | 13-row matrix (see §5) | < 90 s per device |
| E2E | Custom Python script + MQTT + REST | Critical paths: auth, command, telemetry, provisioning, OTA, payment | < 8 min |
| Load | k6 | 10,000 simulated devices, 1,000 telemetry/s, 100 commands/s | < 30 min |
| Chaos | Pumba (Docker) | Kill EMQX node, kill Postgres, network partition, disk full, cert expiry | < 20 min |
| Security | OWASP ZAP + Snyk + firmware pen test | OWASP Top 10 + dependency CVEs + Secure Boot bypass attempt | < 15 min (ZAP) + manual (pen test) |
| PDPP | Custom scripts | Data export, data erasure, audit log integrity | < 5 min |

**Total CI gate time (PR):** ~15 min (unit + integration + API contract + Flutter widget + firmware unit).
**Total release test time:** ~90 min (full pyramid + load + chaos + security + PDPP + on-device smoke on 5 devices).

---

## 2. Load tests (k6)

### 2.1 Targets

| Metric | Target |
|---|---|
| Concurrent simulated devices | 10,000 |
| Telemetry ingest rate | 1,000 msgs/s sustained for 30 min |
| Command rate | 100 msgs/s sustained for 30 min |
| API concurrent users | 1,000 (JWT-authenticated) |
| API throughput | 500 req/s sustained |
| Command publish p95 | < 500 ms |
| Telemetry ingest p95 | < 200 ms |
| Energy ingest p95 | < 100 ms |
| Automation execution p95 | < 2 s |
| Scene activation p95 | < 1 s |
| WS event delivery p95 | < 500 ms |
| Postgres CPU | < 60% |
| Redis CPU | < 50% |
| Spring Boot CPU (per instance) | < 70% |
| EMQX CPU (per node) | < 70% |
| Error rate | < 0.1% |
| Memory growth over 1 hour | < 5% (no leak) |

### 2.2 k6 script (excerpt)

```javascript
import { check, sleep } from 'k6';
import mqtt from 'k6/x/mqtt';

export const options = {
  scenarios: {
    telemetry: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 1000 },   // ramp to 1k devices
        { duration: '5m', target: 5000 },   // ramp to 5k
        { duration: '10m', target: 10000 }, // ramp to 10k
        { duration: '15m', target: 10000 }, // hold
        { duration: '2m', target: 0 },      // ramp down
      ],
    },
  },
};

export default function () {
  const publisher = new mqtt.Client(
    'tls://she.et:8883',
    `SHE-R8-loadtest-${__VU}-${__ITER}`,
    __ENV.DEVICE_CERT, __ENV.DEVICE_KEY, __ENV.CA_CERT
  );
  publisher.publish(
    `she/tenant-loadtest/home-1/room-1/SHE-R8-${__VU}/params/local`,
    JSON.stringify({ 'Relay 1': { Power: __ITER % 2 === 0 }, 'Diagnostics': { RSSI: -55 - (__ITER % 10) } }),
    0, false
  );
  sleep(5); // 5s telemetry interval → 200 VUs = 1000 msgs/s at 10k VUs
}
```

### 2.3 Run

```bash
k6 run --vus 10000 --duration 30m \
  --env DEVICE_CERT=loadtest.crt --env DEVICE_KEY=loadtest.key --env CA_CERT=root-ca.crt \
  load-tests/telemetry.js
```

---

## 3. Integration tests (Testcontainers)

### 3.1 Coverage

Every Spring Boot module has an integration test that spins up:
- Postgres 16 container (with RLS enabled, Flyway migrations run)
- Redis 7 container
- EMQX 5 container (with mTLS configured, test CA)
- MinIO container (for OTA image storage)

Tests cover:
- API → DB: every endpoint happy path + 4xx error paths
- API → EMQX: command publish triggers MQTT message on correct topic
- EMQX → Spring Boot: telemetry message on `params/local` triggers DB insert + WebSocket push
- Webhook handlers: Chapa payment webhook (signature verify, idempotency)
- RLS isolation: tenant A user querying tenant B's data returns 0 rows (cross-tenant test)

### 3.2 Example RLS isolation test

```java
@Test
void tenantA_cannotRead_tenantB_devices() {
    // Tenant A user logs in
    var tokenA = authApi.login("user-a@tenant-a.com", "password");
    var devicesA = deviceApi.list(tokenA);
    assertThat(devicesA).hasSize(5); // tenant A has 5 devices

    // Tenant B user logs in
    var tokenB = authApi.login("user-b@tenant-b.com", "password");
    var devicesB = deviceApi.list(tokenB);
    assertThat(devicesB).hasSize(3); // tenant B has 3 devices

    // Cross-tenant query attempt (simulated SQL injection / bug)
    var maliciousQuery = deviceApi.listWithTenantOverride(tokenA, "tenant-b-id");
    assertThat(maliciousQuery).isEmpty(); // RLS blocks

    // Verify in DB directly
    var crossTenantCount = jdbc.queryForObject(
        "SELECT COUNT(*) FROM nodes WHERE tenant_id = ? AND current_setting('app.tenant_id')::uuid = ?",
        Integer.class, tenantBId, tenantAId
    );
    assertThat(crossTenantCount).isZero();
}
```

---

## 4. Chaos tests (Pumba)

Run nightly on staging cluster:

| Scenario | Method | Expected |
|---|---|---|
| Kill backend-1 | `docker kill backend-1` | Nginx routes to backend-2 within 10 s; 0 user-visible errors |
| Kill both backends | `docker kill backend-1 backend-2` | Total outage; recover within 60 s of restart |
| Kill Postgres | `docker kill postgres` | API returns 503; EMQX continues accepting device connections (cached ACL); recover on restart |
| Kill Redis | `docker kill redis-1` | Graceful degradation — JWT validation falls back to DB; rate limiting disabled (allow-all); recover on restart |
| Kill 1 EMQX node | `docker kill emqx-2` | Cluster rebalances; devices on emqx-2 reconnect to emqx-1/3 within 5 min |
| Kill 2 EMQX nodes | `docker kill emqx-2 emqx-3` | Quorum lost; cluster unavailable; recover on restart of any 2 nodes |
| Network partition to Cloudflare | `iptables -A INPUT -s <CF IP> -j DROP` | External users can't reach API; devices still work via MQTT (Spring Boot → EMQX internal); local control still works |
| Disk full on Postgres | `fallocate -l 50G /var/lib/postgresql/fill` | Postgres stops writes; alert fires within 60 s; `df -h` shows 100% |
| Disk full on EMQX | `fallocate -l 50G /var/lib/emqx/fill` | EMQX stops accepting messages; alert fires; devices queue locally + retry |
| Cert expiry (simulate) | Replace `/opt/she/infra/ca/mqtt-server.crt` with expired cert, restart EMQX | TLS handshake fails for new connections; existing connections survive; alert fires |
| NTP clock skew (90 days) | `date -s "+90 days"` on EMQX node | mTLS handshake fails (cert not yet valid); alert fires; restores on NTP sync |
| Postgres replication lag | `pgbench` on primary to saturate WAL | Replica lag > 60 s alert fires; replication catches up when load stops |

Pumba config (nightly cron on staging):
```yaml
# pumba-staging.yaml
- container: backend-1
  action: kill
  schedule: "0 2 * * *"
- container: emqx-2
  action: kill
  schedule: "30 2 * * *"
- container: postgres
  action: kill
  schedule: "0 3 * * *"  # Saturday only — more disruptive
  filters:
    daysOfWeek: "Saturday"
```

---

## 5. Firmware smoke tests (on-device, 13-row matrix)

Every firmware release must pass on 1 device of each SKU (R4, R8, R16) = 3 × 13 = 39 tests before shipping.

| # | Test | Description | Pass criteria |
|---|---|---|---|
| 1 | GPIO + relay toggle | Toggle each relay 10× via MQTT command | Relay clicks + feedback circuit confirms state |
| 2 | Feedback circuit (manual override) | Physically toggle relay (wall switch) while firmware commands OFF | Firmware detects override within 500 ms + syncs to cloud |
| 3 | Feedback circuit (relay weld) | Force relay stuck-on (simulated via debug flag) | Firmware detects weld + alerts cloud |
| 4 | Digital input (wall switch) | Trigger wall switch input GPIO | App reflects state change within 2 s |
| 5 | Analog input (ADS1115) | Apply 0-10 V signal to analog input | Reading within 1% of multimeter |
| 6 | MQTT connect + telemetry | Connect to broker, publish telemetry, subscribe to command topic | All messages delivered within 2 s |
| 7 | MQTT LWT (last will) | Disconnect Wi-Fi | EMQX publishes LWT within 60 s; app shows device offline |
| 8 | OTA update (happy path) | Push new firmware via admin API | Device updates + reboots within 5 min; health check passes; telemetry resumes |
| 9 | OTA rollback (bad firmware) | Push firmware that fails health check (forces watchdog reset 3×) | Device auto-rolls back to previous firmware within 10 min; reports `OTA_ROLLBACK` event |
| 10 | BLE provisioning | Provision via Flutter app (fresh device) | Device claims cert + connects to EMQX within 60 s |
| 11 | Energy monitoring (R8/R16 only) | Connect PZEM-004T, apply 220 V test load | Readings within 1% of calibrated meter; `cost_etb` calculated correctly per block tariff |
| 12 | Voice control (R16 only) | Say "Hey Sheba, turn on the living room light" in 60 dB ambient noise | Wake word detected in < 2 s; relay toggles within 1 s; intent logged in `esp.service.voice` params |
| 13 | Local control (LAN fallback) | Disconnect internet, control via mDNS + HTTPS to ESP32 LAN IP | Commands work over LAN within 500 ms |

### 5.1 7-day stability test

Before GA release, 1 device of each SKU runs a 7-day continuous operation test:
- 100 relay toggles per hour (automated via test jig)
- Telemetry every 5 s
- 1 OTA update mid-week
- 2 Wi-Fi disconnect/reconnect cycles per day (simulated)

**Pass criteria:** No crashes, no memory leaks (free heap stable ±5%), no Wi-Fi disconnects > 30 s, no MQTT reconnection storms, all 13 smoke tests pass at end of week.

---

## 6. Security tests

### 6.1 OWASP ZAP scan

- **Target:** `https://she.et` (staging environment)
- **Scan type:** Active scan + AJAX spider
- **Frequency:** Weekly (CI) + before every release
- **Pass criteria:** 0 high-severity findings, ≤ 3 medium with documented remediation plan
- **Alerts to ignore:** TLS configuration warnings handled by Cloudflare (not our app layer)

### 6.2 Dependency scanning

- **Tool:** Snyk (open-source) + GitHub Dependabot
- **Frequency:** Daily (CI on every PR + nightly on main)
- **Pass criteria:** 0 critical CVEs unfixed > 14 days; 0 high CVEs unfixed > 30 days

### 6.3 Firmware pen test

- **Scope:** Secure Boot v2 bypass attempt, Flash Encryption bypass, NVS encryption, JTAG/UART disable, OTA signature forgery, anti-rollback eFuse bypass
- **Tool:** Manual + Ghidra for binary analysis
- **Frequency:** Annual (before GA, then yearly)
- **Vendor:** External security firm (selected Phase 5 week 41)
- **Pass criteria:** No Secure Boot bypass achievable without destructive physical access (decapping); no OTA signature forgery (Ed25519); NVS encryption keys not extractable via JTAG (JTAG disabled in production eFuse)

### 6.4 mTLS + cert tests

- **Cert chain validation:** Device cert → intermediate → root chain verified at EMQX handshake
- **Revoked cert blocked:** Revoke a cert via step-ca CRL → EMQX blocks new connection within 6 h (CRL refresh interval); existing connection survives until next reconnect
- **Cert expiry:** Device with expired cert cannot connect; correct error in EMQX log

---

## 7. PDPP tests

### 7.1 Data export

```python
def test_data_export():
    user = create_user_with_devices_and_history()
    request_id = api.request_data_export(user.jwt)
    wait_for_status(request_id, "COMPLETED", timeout=30*24*60*60)  # 30 days PDPP limit
    export_url = api.get_export_url(request_id)
    export = download_json(export_url)
    
    assert export["user"]["email"] == user.email
    assert len(export["homes"]) == 2
    assert len(export["devices"]) == 5
    assert len(export["telemetry"]) > 0
    assert len(export["audit_log"]) > 0
    assert "no_third_party_data_leaked" in export  # DPIA requirement
```

### 7.2 Data erasure

```python
def test_data_erasure():
    user = create_user_with_data()
    api.request_data_erasure(user.jwt)
    wait_for_status(request_id, "COMPLETED", timeout=30*24*60*60)
    
    # Verify user cannot login
    with pytest.raises(AuthError):
        api.login(user.email, user.password)
    
    # Verify data removed from all tables
    assert db.count("users", where=f"id = '{user.id}'") == 0
    assert db.count("homes", where=f"owner_id = '{user.id}'") == 0
    assert db.count("nodes", where=f"owner_id = '{user.id}'") == 0
    assert db.count("device_telemetry", where=f"user_id = '{user.id}'") == 0
    assert db.count("audit_log", where=f"actor_user_id = '{user.id}'") == 0  # anonymized
    
    # Verify cert revoked
    cert = db.query("SELECT status FROM device_certs WHERE user_id = ?", user.id)
    assert cert == "REVOKED"
```

### 7.3 Audit log integrity

```python
def test_audit_log_integrity():
    # Hash-chain verification: each row's `prev_hash` = SHA256(prev_row.hash + prev_row.payload)
    rows = db.query("SELECT * FROM audit_log ORDER BY created_at DESC LIMIT 1000")
    
    for i in range(1, len(rows)):
        expected_prev_hash = sha256(rows[i].hash + rows[i].payload)
        assert rows[i-1].prev_hash == expected_prev_hash, \
            f"Audit log tampering detected at row {i}"
    
    # Verify no gaps
    for i in range(1, len(rows)):
        assert rows[i].sequence_number == rows[i-1].sequence_number + 1, \
            f"Sequence gap at row {i}"
```

---

## 8. Release gate

A release (tagged git commit) can ship to production only if:

- [ ] All unit tests pass (≥ 80% coverage)
- [ ] All integration tests pass (including RLS isolation)
- [ ] All API contract tests pass
- [ ] Flutter widget + integration tests pass on 3 Android + 2 iOS devices
- [ ] Firmware Unity tests pass
- [ ] Firmware 13-row smoke matrix passes on R4 + R8 + R16
- [ ] 7-day stability test passes on at least 1 SKU
- [ ] Load test meets all §2 targets
- [ ] Chaos tests pass (nightly staging run, no SEV-1 alerts)
- [ ] OWASP ZAP scan: 0 high findings
- [ ] Snyk scan: 0 critical CVEs unfixed > 14 days
- [ ] PDPP tests pass (data export, erasure, audit log integrity)
- [ ] Manual exploratory test: 2-hour session by non-author engineer
- [ ] All V3 docs updated for any new features

Release manager signs off in `RELEASE_NOTES.md`.

---

## 9. References

- V3-SUCCESS-METRICS.md §2 — performance targets (must match §2.1 here)
- V3-SECURITY-MODEL.md §5 — firmware security (drives §6.3 pen test)
- V3-PRIVACY-COMPLIANCE.md — PDPP requirements (drives §7)
- V3-DATABASE-DESIGN.md §1 — RLS policies (drives §3.2 isolation test)
- V3-FIRMWARE.md §6 — OTA rollback (drives §5 row 9)
- V3-ENERGY-MONITORING.md §3 — ETB tariff (drives §5 row 11)
- V3-VOICE-MATTER.md §1.6 — voice latency budget (drives §5 row 12)
- V3-FACTORY-OPS.md — factory test jig (§5 tests run on factory jig)
