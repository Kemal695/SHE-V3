# SHE V3 — Release Checklist (V3-INTEGRATION-TEST-PLAN §8)

A release (tagged git commit) ships to production ONLY if ALL of these pass:

## Code Quality

- [ ] All unit tests pass (≥ 80% coverage on service/impl packages)
- [ ] All integration tests pass (including RLS isolation test)
- [ ] All API contract tests pass (happy + error paths)
- [ ] Flutter widget + integration tests pass on 3 Android + 2 iOS devices
- [ ] Firmware Unity tests pass
- [ ] Firmware 13-row smoke matrix passes on R4 + R8 + R16
- [ ] 7-day stability test passes on at least 1 SKU (no crashes, no leaks, no disconnects > 30s)

## Performance

- [ ] Load test: 10,000 devices, 1,000 telemetry/s for 30 min — all §2 targets met
- [ ] Command publish p95 < 500ms
- [ ] Telemetry ingest p95 < 200ms
- [ ] Energy ingest p95 < 100ms
- [ ] API throughput ≥ 500 req/s
- [ ] Postgres CPU < 60%, Redis CPU < 50%, Spring Boot CPU < 70%, EMQX CPU < 70%
- [ ] Memory growth < 5% over 1 hour (no leak)

## Chaos (nightly staging run, no SEV-1 alerts)

- [ ] Kill backend-1 → Nginx routes to backend-2 within 10s, 0 user-visible errors
- [ ] Kill emqx-2 → cluster rebalances, devices reconnect within 5 min
- [ ] Kill postgres → API returns 503, EMQX continues (cached ACL), recover on restart
- [ ] Kill redis → graceful degradation (JWT falls back to DB, rate limiting disabled)
- [ ] Disk full on Postgres → alert fires within 60s
- [ ] Cert expiry (simulate) → TLS handshake fails for new connections, alert fires

## Security

- [ ] OWASP ZAP scan: 0 high findings, ≤ 3 medium with remediation plan
- [ ] Snyk scan: 0 critical CVEs unfixed > 14 days, 0 high CVEs unfixed > 30 days
- [ ] Firmware pen test: no Secure Boot bypass, no Flash Encryption bypass, no OTA signature forgery
- [ ] mTLS + cert tests: cert chain validated, revoked cert blocked within 6h, expired cert rejected
- [ ] Rate limiting: 5 login attempts per 15 min → lockout enforced
- [ ] RLS: cross-tenant query returns 0 rows (automated test passes)
- [ ] Audit log hash chain: nightly verification passes

## Privacy (PDPP)

- [ ] Data export test: user can download JSON archive within 5 min
- [ ] Data erasure test: user data fully deleted within 14 days (7-day grace + 7-day processing)
- [ ] Audit log integrity: hash chain verification passes (no tampering detected)
- [ ] PII inventory matches database schema (no new PII columns without DPIA update)

## Certification

- [ ] CE pre-compliance: TÜV SÜD Shenzhen — EMC + safety (Week 41-42)
- [ ] FCC testing: Element Materials Technology — Part 15B/C (Week 43-44)
- [ ] ECA type approval: submitted to Ethiopian Communications Authority (Week 45-48)
- [ ] ECA submission acknowledged with letter of no-objection (OR full certification received)

## Infrastructure

- [ ] Production infrastructure running in Addis Ababa (Ethio Telecom Cloud)
- [ ] Cloudflare Business: DDoS + WAF + SSL termination + geo-block
- [ ] Monitoring: Prometheus + Grafana + Loki + PagerDuty all operational
- [ ] Backup: Postgres WAL archiving + nightly base backup tested (restore to staging passes)
- [ ] DR: runbook dry-run passed (simulate SEV-1, SEV-2, SEV-3 with on-call rotation)
- [ ] All V3 docs locked (no outstanding edits)

## Manufacturing

- [ ] 500 production devices manufactured at factory partner (ready to ship)
- [ ] Factory flashing workflow tested on pilot batch (cert issuance, QR print, QC)

## Sign-off

- [ ] Manual exploratory test: 2-hour session by non-author engineer
- [ ] Release manager signs off in RELEASE_NOTES.md
- [ ] CEO approval for GA launch

---

**Release manager:** ______________________ **Date:** ___________
**CEO:** ______________________ **Date:** ___________
