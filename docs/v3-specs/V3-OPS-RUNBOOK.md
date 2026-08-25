# V3 — Ops Runbook

**Status:** Locked
**Last updated:** 2025-Q1
**Owner:** Lead Engineer + Backend Engineer

---

## 0. Scope

Operational procedures for the SHE V3 self-hosted stack running on Ethio Telecom Cloud (Addis Ababa, ADR-008). This runbook covers deployment, monitoring, on-call diagnostics, incident response, CA rotation, backup, and data retention.

All commands assume:
- SSH access to production VPS hosts (jump host via Cloudflare Tunnel — no public SSH)
- Membership in the `she-ops` Linux group (for `docker` and `sudo` to specific commands)
- PagerDuty account + on-call rotation configured

---

## 1. Production infrastructure

| Service | Container / Process | Host | Port | Health check |
|---|---|---|---|---|
| Nginx | nginx (Docker) | edge-1 | 443 | `GET /` → 200 |
| Spring Boot 1 | backend-1 (Docker) | app-1 | 8080 | `GET /actuator/health` → UP |
| Spring Boot 2 | backend-2 (Docker) | app-2 | 8080 | `GET /actuator/health` → UP |
| PostgreSQL 16 | postgres (Docker, dedicated host) | db-1 | 5432 | `pg_isready` → "accepting connections" |
| TimescaleDB | (Postgres extension on db-1) | db-1 | 5432 | `SELECT extversion FROM pg_extension WHERE extname='timescaledb'` |
| Redis 7 | redis-1/2/3 (Docker, 3-node cluster) | cache-1 | 6379 | `redis-cli ping` → PONG |
| EMQX 5 | emqx-1/2/3 (Docker, 3-node cluster) | mqtt-1/2/3 | 8883 (mTLS), 18083 (dashboard) | `GET /status` → running |
| MinIO | minio (Docker) | storage-1 | 9000 | `GET /minio/health/live` → 200 |
| step-ca | step-ca (systemd, on db-1) | db-1 | 9000 | `step ca health` → OK |
| Prometheus | prometheus (Docker) | monitor-1 | 9090 | `GET /-/healthy` → 200 |
| Grafana | grafana (Docker) | monitor-1 | 3000 | `GET /api/health` → 200 |
| Loki | loki (Docker) | monitor-1 | 3100 | `GET /ready` → ready |

**Hosts:** 5 VPS on Ethio Telecom Cloud (edge-1, app-1, app-2, db-1, storage-1, monitor-1, mqtt-1/2/3 = 9 total). All in the same Addis Ababa data center (single region per ADR-008).

---

## 2. Deployment

### 2.1 Routine deploy (Spring Boot)

```bash
# SSH to app-1
ssh jump.she.et  # Cloudflare Tunnel jump host
ssh app-1

cd /opt/she
git pull origin main
cd infra
docker compose build backend-1
docker compose up -d backend-1 --no-deps

# Wait for healthy
until curl -sf http://localhost:8080/actuator/health | grep -q '"status":"UP"'; do
  echo "Waiting for backend-1..."; sleep 5
done

# Then deploy to app-2
ssh app-2
cd /opt/she && git pull origin main && cd infra
docker compose build backend-2
docker compose up -d backend-2 --no-deps
```

Roll both instances sequentially — never simultaneously — to avoid 100% API downtime. Nginx upstream health check removes the instance being deployed from the pool within 10 s.

### 2.2 EMQX rolling deploy

```bash
# One node at a time
ssh mqtt-1
cd /opt/she && git pull origin main && cd infra
docker compose build emqx-1
docker compose up -d emqx-1 --no-deps
# Wait for cluster rebalance + devices reconnecting
emqx_ctl cluster status  # wait for "running" on all 3

# Repeat for mqtt-2, then mqtt-3
```

### 2.3 Database migration (Flyway)

Flyway runs automatically on Spring Boot startup. First instance acquires an advisory lock; second instance waits (up to 5 min, then fails).

```bash
# Watch migration logs
docker compose logs backend-1 -f | grep -i flyway
# Expected: "Flyway Community Edition X.X.X by Redgate" → "Migrating schema V29" → "Successfully applied"
```

**Never manually run DDL in production.** Always via Flyway migration committed to the repo. If a migration fails:
1. Spring Boot will refuse to start (Flyway fail-fast)
2. Fix the migration in a new commit (forward-only — do not edit the failed migration)
3. Redeploy

### 2.4 Rollback

```bash
# App rollback (Spring Boot)
cd /opt/she
git log --oneline -5  # find the previous good commit
git reset --hard <previous-commit>
cd infra
docker compose build backend-1 backend-2
docker compose up -d backend-1 backend-2 --no-deps

# Database rollback: NOT SUPPORTED (Flyway is forward-only)
# If a migration breaks production, write a new forward migration that reverses the change
# Example: if V29 added a column that breaks the app, V30 drops it
```

---

## 3. Monitoring

### 3.1 Stack

- **Prometheus** — scrapes metrics from Spring Boot (`/actuator/prometheus`), EMQX (`/metrics`), Postgres (`postgres_exporter`), Redis (`redis_exporter`), MinIO (`/minio/v2/metrics/cluster`), Nginx (`nginx_exporter`)
- **Grafana** — dashboards: Overview, Spring Boot, EMQX, Postgres, Redis, MinIO, OTA, Billing, Energy
- **Loki** — log aggregation. Spring Boot logs via Promtail; EMQX logs via Promtail; container stdout via Promtail
- **PagerDuty** — alert routing: SEV-1 → on-call + backup; SEV-2 → on-call only; SEV-3 → Slack only
- **UptimeRobot** — external pings to `https://she.et/actuator/health` every 60 s

### 3.2 EMQX dashboard

Available at `https://she.et:18083` (mTLS-protected, admin-only). Shows:
- Live connections (count, by tenant, by SKU)
- Subscriptions (count, topics)
- Message rate (publish/s, deliver/s)
- Retained messages (count, size)
- Cluster status (3 nodes, health)

### 3.3 Spring Boot Actuator

- `/actuator/health` — overall health (UP/DOWN)
- `/actuator/info` — build version, git commit
- `/actuator/metrics` — JVM, HTTP, DB pool, MQTT client metrics
- `/actuator/prometheus` — Prometheus scrape target
- `/actuator/loggers` — runtime log level changes (no restart)

### 3.4 Key alerts

| Alert | Threshold | Severity | Action |
|---|---|---|---|
| API 5xx error rate | > 1% sustained 5 min | SEV-2 | Check Spring Boot logs, recent deploy |
| API down (no healthy instance) | 0 healthy backends | SEV-1 | See §5.2 |
| MQTT broker down | Any EMQX node down 2 min | SEV-1 | See §5.3 |
| Postgres connection pool exhausted | Pool utilization > 90% sustained 5 min | SEV-2 | Check slow queries, scale up pool |
| Postgres replication lag | Lag > 60 s sustained 5 min | SEV-2 | Check replica disk IOPS, network |
| Cert expiry < 14 days | Any cert (TLS, mTLS, CA intermediate) | SEV-3 | Renew via step-ca |
| OTA failure rate | > 5% in a batch | SEV-2 | Pause batch, see §5.4 |
| Disk usage | > 80% on any host | SEV-3 | Clean up old logs, scale disk |
| Backup failure | Daily backup job failed | SEV-2 | See §7 |

---

## 4. On-call diagnostics

### 4.1 EMQX node down

```bash
ssh mqtt-1
docker compose ps emqx-1  # status?
docker compose logs emqx-1 --tail 200  # what's the error?

# Common causes:
# 1. Disk full (mnesia directory): df -h
# 2. Cert expired: openssl x509 -in /opt/she/infra/ca/mqtt.crt -noout -dates
# 3. OOM: dmesg | grep -i oom
# 4. mnesia corruption: emqx_ctl mnesia

# Restart
docker compose restart emqx-1

# If still down, remove from cluster and rejoin
ssh mqtt-2
emqx_ctL cluster leave emqx-1@mqtt-1  # force leave
# Then on mqtt-1: docker compose down emqx-1, wipe mnesia, docker compose up, rejoin cluster
```

### 4.2 Postgres replication lag

```bash
ssh db-1
psql -U she -d she_v3 -c "SELECT * FROM pg_stat_replication;"
# Check replay_lag, write_lag, flush_lag columns

# Common causes:
# 1. Replica disk IOPS saturated: iostat -x 1
# 2. Long-running query on replica blocking replay: SELECT * FROM pg_stat_activity WHERE state='active' AND query_start < NOW() - INTERVAL '5 min';
# 3. Network issue between primary and replica: ping, iperf3

# Fix: terminate blocking query on replica (rare) or scale disk IOPS
```

### 4.3 Cert expiry

```bash
# Check all certs
for cert in /opt/she/infra/ca/*.crt; do
  echo "=== $cert ==="
  openssl x509 -in "$cert" -noout -dates -subject
done

# Renew device certs (mTLS for MQTT)
step ca renew /opt/she/infra/ca/mqtt-server.crt /opt/she/infra/ca/mqtt-server.key
# Then restart EMQX to pick up new cert

# Renew Spring Boot TLS cert (via Cloudflare, automatic — check Next cert renewal date)
# Renew CA intermediate (yearly — see §6)
```

### 4.4 OTA failure

```bash
ssh app-1
psql -U she -d she_v3 -c "SELECT status, COUNT(*) FROM ota_approvals WHERE batch_id = '...' GROUP BY status;"
# FAILED count > 5% of total → pause batch

# Pause batch
psql -U she -d she_v3 -c "UPDATE ota_batches SET status = 'PAUSED' WHERE id = '...';"

# Inspect failing devices
psql -U she -d she_v3 -c "SELECT device_id, error_message, attempted_at FROM ota_approvals WHERE deployment_status = 'FAILED' ORDER BY attempted_at DESC LIMIT 20;"

# Common causes:
# 1. Firmware signature mismatch: verify OTA_SIGNING_KEY env var matches the key that signed the image
# 2. MinIO unreachable from device: check device MQTT → "ota_download_failed"
# 3. Anti-rollback eFuse: new firmware version is below the burned min version
# 4. Partition write error: device flash is failing (RMA the unit)
```

---

## 5. Incident response

### 5.1 Severity levels

| Severity | Definition | Response time | Escalation |
|---|---|---|---|
| SEV-1 | Total outage or data loss (API down, MQTT down, data breach) | 5 min | PagerDuty → on-call + backup + Lead Engineer; Slack `#incidents` |
| SEV-2 | Major feature broken (OTA failing, payments broken, RLS violation) | 15 min | PagerDuty → on-call |
| SEV-3 | Minor feature broken (one tenant's billing dashboard broken, slow query) | 1 hour (business hours) | Slack `#engineering-help` |
| SEV-4 | Cosmetic (typo in admin web, dark mode toggle off-by-one) | Next business day | Slack `#engineering-help` |

### 5.2 Playbook: API down (SEV-1)

1. Acknowledge in PagerDuty (5 min SLA)
2. SSH to jump host → app-1
3. `docker compose ps` — what's unhealthy?
4. `docker compose logs backend-1 backend-2 --tail 200`
5. If DB unreachable:
   - `docker compose logs postgres` on db-1
   - Check disk: `df -h`
   - Check connections: `psql -U she -d she_v3 -c "SELECT COUNT(*) FROM pg_stat_activity;"`
   - If disk full: clean WAL archive (`pg_archivecleanup`) or scale disk
6. If Redis unreachable:
   - `docker compose logs redis-1 redis-2 redis-3`
   - Check memory: `docker stats redis-1`
   - Restart: `docker compose restart redis-1 redis-2 redis-3`
7. If EMQX unreachable: see §4.1
8. If app error (Spring Boot exception): roll back to previous commit (§2.4)
9. Confirm recovery: `curl https://she.et/actuator/health` → UP
10. Post to `#incidents`: "Resolved — root cause: X, duration: Y min, follow-up: Z"

### 5.3 Playbook: MQTT broker down (SEV-1)

1. Check EMQX dashboard: `https://she.et:18083`
2. `docker compose logs emqx-1 emqx-2 emqx-3 --tail 200` on each mqtt host
3. Check cert expiry: `openssl s_client -connect she.et:8883 -showcerts`
4. If EMQX crashed: `docker compose restart emqx-1 emqx-2 emqx-3` (all 3 simultaneously if cluster quorum lost)
5. Devices reconnect automatically within 5 min (LWT + reconnect backoff)
6. Confirm: check `mqtt.connected` metric in Prometheus returns to baseline

### 5.4 Playbook: OTA failure rate > 5% (SEV-2)

1. Pause batch: `UPDATE ota_batches SET status = 'PAUSED' WHERE id = '...'`
2. Inspect failing devices (see §4.4)
3. If firmware bug: do not auto-rollback; prepare fixed firmware
4. If signing key mismatch: verify `OTA_SIGNING_KEY` env var
5. Resume batch only after fix deployed + 10-device canary passes

### 5.5 Postmortem template

After every SEV-1 and SEV-2, write a postmortem within 48 hours:

```markdown
## Incident: <short title>
- Date: <YYYY-MM-DD>
- Duration: <X min>
- Severity: SEV-N
- Impact: <users/tenants affected, feature broken>

## Timeline
- T+0: Alert fired (<alert name>)
- T+2: On-call acknowledged
- T+5: Investigation began (<what was checked>)
- T+15: Root cause identified (<what was the cause>)
- T+25: Fix applied (<what was done>)
- T+30: Confirmed resolved (<how confirmed>)

## Root cause
<2-3 sentences — the actual technical cause, not "human error">

## Contributing factors
- <monitoring gap, deploy process issue, etc.>

## What went well
- <fast detection, good runbook, etc.>

## What went poorly
- <slow response, missing alert, etc.>

## Action items
- [ ] <action> — owner: <name> — due: <date>
- [ ] <action> — owner: <name> — due: <date>
```

Postmortems are stored in `docs/postmortems/` and reviewed in the weekly engineering meeting.

---

## 6. CA rotation procedure

### 6.1 Yearly intermediate CA rotation

The intermediate CA signs all device certs. Per security best practice, rotate yearly (key compromise window is bounded).

**Pre-conditions:**
- Root CA offline (air-gapped, in physical safe)
- step-ca running on db-1 (signs intermediates with root key via offline signing workflow)
- All device certs signed by current intermediate have `not_after` > rotation date + 90 days (so they keep working during cutover)

**Procedure:**

```bash
# On db-1 (step-ca host)
ssh db-1
cd /opt/she/infra/ca

# 1. Generate new intermediate key + CSR
step certificate create "SHE Intermediate CA 2025" \
  intermediate-2025.csr intermediate-2025.key \
  --profile intermediate-ca \
  --csr

# 2. Sign the new intermediate with the ROOT CA (offline, air-gapped machine)
# Transfer intermediate-2025.csr to the air-gapped machine via USB stick (verified by SHA-256)
# On air-gapped machine:
step certificate sign intermediate-2025.csr root-ca.crt root-ca.key \
  --profile intermediate-ca \
  --not-after "2026-12-31T23:59:59Z" \
  > intermediate-2025.crt

# Transfer intermediate-2025.crt back to db-1 (SHA-256 verify)

# 3. Load new intermediate into step-ca
cp intermediate-2025.crt /opt/she/infra/ca/intermediate-2025.crt
cp intermediate-2025.key /opt/she/infra/ca/intermediate-2025.key
sudo systemctl restart step-ca

# 4. Verify new intermediate issues certs
step ca certificate test-device.csr test-device.crt test-device.key \
  --san SHE-R8-TEST \
  --ca intermediate-2025.crt

# 5. Update EMQX to trust BOTH old + new intermediates during cutover (90-day overlap)
# Edit /opt/she/infra/emqx/emqx.conf:
#   listener.ssl.external.cacertfile = /etc/emqx/certs/ca-bundle.crt
# Where ca-bundle.crt = root-ca.crt + intermediate-2024.crt + intermediate-2025.crt (concatenated)
docker compose restart emqx-1 emqx-2 emqx-3

# 6. New device certs are now signed by intermediate-2025
# Existing device certs (signed by intermediate-2024) keep working until their own expiry

# 7. After 90 days, remove intermediate-2024 from ca-bundle.crt
# (Only if no device certs signed by intermediate-2024 remain active — check via:
#   SELECT COUNT(*) FROM device_certs WHERE ca_serial = '<intermediate-2024 serial>' AND status='ACTIVE';)
```

### 6.2 Root CA rotation (every 10 years)

Much rarer. Documented in V3-CONFIGURATION.md §4. Requires re-issuing every device cert + every server cert. Not in scope for V3 GA.

### 6.3 CRL generation

```bash
# Generate CRL (certificate revocation list) — published daily + on-demand
step ca root --crl
# CRL served at: https://she.et/ca.crl (HTTP, not HTTPS — devices fetch via HTTP to avoid cert-chicken-egg)

# EMQX fetches CRL every 6 hours and blocks revoked certs at TLS handshake
```

---

## 7. Backup

### 7.1 Postgres

- **WAL archiving** enabled (`archive_mode = on`, `archive_command = 'aws s3 cp ... s3://she-backups/wal/%f'` — uses MinIO-compatible S3 endpoint at secondary DC)
- **Base backup** daily at 02:00 UTC via `pg_basebackup` → compressed tar → MinIO
- **PITR** (point-in-time recovery) possible to any second within 14-day retention
- **Restore test**: quarterly — restore to staging, run smoke tests, document time-to-restore

```bash
# Manual base backup
ssh db-1
pg_basebackup -D - -Ft -z -P -U she | \
  aws s3 cp - s3://she-backups/base/$(date +%Y-%m-%d).tar.gz \
  --endpoint-url https://minio-backup.she.et
```

### 7.2 MinIO (firmware images)

- **Versioning** enabled — every firmware image upload creates a new version; old versions retained indefinitely
- **Cross-region replication** to secondary MinIO at backup DC (async, ~5 min lag)
- Firmware images are immutable (cannot be overwritten — only new versions added)

### 7.3 CA keys

- **Root CA**: offline, air-gapped machine in physical safe. Backup: encrypted USB stick in safe, plus Shamir's secret sharing across 3 of 5 Lead Engineers (any 3 needed to reconstruct)
- **Intermediate CA**: encrypted at rest on db-1, backed up to MinIO (encrypted with KEK)
- **KEK** (Key Encryption Key): 3 fragments across 3 Lead Engineers (any 2 needed to reconstruct)

### 7.4 Redis

- **AOF** (append-only file) every second — warm-restart only (cache is reproducible, no disaster recovery needed)
- **RDB snapshot** every 6 hours (for faster restart)
- No offsite backup — Redis is a cache, not a source of truth

### 7.5 Retention

| Backup | Retention | Storage |
|---|---|---|
| Postgres WAL | 14 days | MinIO at backup DC |
| Postgres base backup | 30 daily + 12 monthly | MinIO at backup DC |
| MinIO firmware images | Indefinite (versioned) | Primary + backup DC |
| CA intermediate key | Indefinite (encrypted) | MinIO at backup DC |
| Redis AOF | 7 days | Local only |

---

## 8. Data retention enforcement

TimescaleDB `drop_chunks` runs nightly at 02:00 UTC via Spring Boot `@Scheduled` task:

| Table | Retention | Mechanism |
|---|---|---|
| `device_telemetry` | 30 days | `SELECT drop_chunks('device_telemetry', INTERVAL '30 days');` |
| `device_energy_readings` | 365 days | `SELECT drop_chunks('device_energy_readings', INTERVAL '365 days');` |
| `notification_log` | 30 days | `DELETE FROM notification_log WHERE created_at < NOW() - INTERVAL '30 days';` |
| `audit_log` | 2 years | `DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL '2 years';` (per V3-PRIVACY-COMPLIANCE.md) |
| `payments` | 7 years (Ethiopian tax law) | Never deleted; archived to cold storage after 2 years |

Verify retention job runs: check Grafana "Retention" panel or Loki logs for `Retention policy executed` daily.

---

## 9. On-call checklist

### 9.1 Daily (5 min)
- Open Grafana "Overview" dashboard — any red?
- Check `#incidents` Slack — any open incidents?
- Verify UptimeRobot all green
- Check cert expiry dashboard — any cert < 14 days?
- Check disk usage dashboard — any host > 80%?

### 9.2 Weekly (30 min, Monday morning)
- Review error log trends (Loki: `level=ERROR` count over 7 days — should be flat or decreasing)
- Review slow queries (`pg_stat_statements` top 10 — mean_exec_time > 500 ms)
- Verify all backup jobs succeeded (check MinIO at backup DC for last 7 daily base backups)
- Test restore from latest backup on staging (run smoke tests, document time-to-restore)
- Review PagerDuty — count of incidents last week, MTTR, postmortems filed

### 9.3 Monthly (2 hours, first Monday)
- Review audit log for SUPER_ADMIN actions (spot check)
- Review feature flags — any stale flags that should be removed?
- Review tenant lifecycle — any SUSPENDED tenants past 30-day mark → TERMINATED?
- Update this runbook if any procedure changed
- Patch host OS + Docker (security patches)
- Rotate any quarterly secrets (DB password, JWT signing key, MQTT superuser password)

---

## 10. References

- V3-ARCHITECTURE.md §3 — production topology
- V3-CONFIGURATION.md §4 — step-ca CA setup, CRL endpoint
- V3-SECURITY-MODEL.md §1.4 — JWT rotation policy
- V3-PRIVACY-COMPLIANCE.md — data retention rules, breach response
- V3-FACTORY-OPS.md §9 — cert revocation on RMA
- V3-SUPPORT-RMA.md — incident escalation for tenant support
- ADR-004 — cert-based MQTT auth (drives CRL + rotation procedures)
- ADR-008 — Ethio Telecom Cloud hosting decision
