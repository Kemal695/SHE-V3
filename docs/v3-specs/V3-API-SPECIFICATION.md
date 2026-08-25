# V3 — API Specification

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Backend Engineer

---

## 1. Conventions

| Aspect | Rule |
|---|---|
| Base path | `/api/v3/*` |
| Auth (REST) | `Authorization: Bearer <JWT>` on every endpoint except `POST /auth/login`, `POST /auth/register`, `GET /tenant/branding`, payment webhooks |
| Auth (WebSocket) | `Sec-WebSocket-Protocol: bearer.<jwt>` subprotocol header (see §12 — NOT `?token=` query param) |
| Success envelope | `{"data": ..., "meta": {...}}` |
| Error envelope | `{"error": {"code": "NODE_NOT_FOUND", "message": "...", "http_status": 404, "request_id": "uuid"}}` |
| Multi-tenancy | JWT carries `tenant_id`; Spring Boot sets `SET LOCAL app.tenant_id = '...'`; Postgres RLS enforces |
| Pagination | `?cursor=<base64>&limit=20` (max 100). Response: `{"data": [...], "meta": {"next_cursor": "...", "has_more": true}}` |
| Idempotency | `Idempotency-Key` header (UUID v4) on `POST` writes. **Two-tier:** Redis cache (24h TTL) for fast de-dup of non-payment writes; **Postgres `UNIQUE(idempotency_key, tenant_id)` constraint on `payments` table as source of truth** for payment idempotency (Redis is cache only — see V3-PAYMENTS.md §6.4) |
| Rate limit | 600 req/min per user (B2C), 6000 req/min per tenant (B2B). `429` with `Retry-After` |
| Timestamps | ISO-8601 UTC (`2024-12-01T14:23:45Z`) |
| Errors | Cross-reference `V3-ERROR-CODES.md` for the full code catalog |

The legacy `device` / `devices` path segments are **renamed to `node` / `nodes`** throughout V3 to mirror the RainMaker Node concept (V3-DEVICE-MODEL.md). Old `/api/v3/devices/...` paths return `308 Permanent Redirect` to `/api/v3/nodes/...` until V4 sunset.

---

## 2. Domain inventory (12 domains)

| § | Domain | Path prefix | Primary resource |
|---|---|---|---|
| 3 | Auth | `/auth/*` | User session, MFA, OAuth, data export |
| 4 | Tenant + branding | `/tenant/*` | White-label config, API keys |
| 5 | Home + room | `/homes/*` | Home, room, home_members |
| 6 | Node | `/nodes/*` + `/homes/{homeId}/nodes` | RainMaker Node + Device + Param |
| 7 | Automation | `/automations/*` | Trigger + action rules |
| 8 | Scene + node-group | `/scenes/*` + `/node-groups/*` | Grouped actions, broadcast groups |
| 9 | OTA | `/ota/*` | Self-hosted OTA batches + approvals |
| 10 | Energy | `/energy/*` | Per-node + per-tenant energy + ETB cost |
| 11 | Payment | `/payments/*` + `/subscription` | Chapa, invoices, webhook |
| 12 | Notification | `/notifications/*` | Preferences, FCM/APNs registration |
| 13 | Admin | `/api/admin/*` | Platform + tenant administration |
| 14 | WebSocket | `WSS /ws/v3` | Real-time push events |
| 15 | Internal | `/internal/*` | Server-to-server (EMQX, factory) |

---

## 3. Auth domain

| Method | Path | Body / Query | Response |
|---|---|---|---|
| POST | `/auth/register` | `{email, password, phone_number, language?}` | `201 {userId, requiresMfa}` |
| POST | `/auth/login` | `{email, password, mfa_code?}` | `200 {accessToken, refreshToken, expiresIn, tenantBranding}` |
| POST | `/auth/refresh` | `{refreshToken}` | `200 {accessToken, expiresIn}` |
| POST | `/auth/logout` | `{refreshToken}` | `204` (revokes refresh token) |
| POST | `/auth/oauth/{provider}` | `{code}` — provider ∈ `github`, `google` | `200 {accessToken, refreshToken}` |
| GET | `/auth/me` | — | `200 {user, tenant, branding}` |
| POST | `/auth/delete-me` | `{password}` | `202` — 7-day grace, then cascade-delete |
| GET | `/auth/data-export` | — | `200 {downloadUrl}` — signed MinIO URL, 1h TTL (PDPP right of access) |
| POST | `/auth/mfa/enable` | — | `200 {qrCodeUrl, backupCodes[]}` |
| POST | `/auth/mfa/disable` | `{mfa_code, password}` | `204` |
| POST | `/auth/mfa/verify` | `{mfa_code}` | `200 {accessToken}` (step-up token) |

---

## 4. Tenant + branding domain

| Method | Path | Min role | Notes |
|---|---|---|---|
| GET | `/tenant/branding?subdomain=xxx` | Public | Returns white-label config for the mobile app splash |
| GET | `/tenant` | TENANT_ADMIN | Current tenant detail |
| PUT | `/tenant/branding` | TENANT_ADMIN | `{logoUrl, primaryColor, accentColor, appName}` — palette must NOT use indigo/blue (V3-B2B-WHITELABEL.md §3) |
| POST | `/tenant/api-keys` | TENANT_ADMIN | `{name, scopes[]}` → `{id, key, createdAt}` — key shown once |
| GET | `/tenant/api-keys` | TENANT_ADMIN | List (without secret values) |
| DELETE | `/tenant/api-keys/{id}` | TENANT_ADMIN | Revoke |

---

## 5. Home + room domain

| Method | Path | Body / Query | Response |
|---|---|---|---|
| POST | `/homes` | `{name, address?}` | `201 {home}` |
| GET | `/homes` | `?cursor=&limit=` | `200 {data[], meta}` |
| GET | `/homes/{homeId}` | — | `200 {home}` |
| PATCH | `/homes/{homeId}` | `{name?, address?}` | `200 {home}` |
| DELETE | `/homes/{homeId}` | — | `204` — OWNER only, soft delete |
| POST | `/homes/{homeId}/rooms` | `{name, icon, sortOrder?}` | `201 {room}` |
| GET | `/homes/{homeId}/rooms` | — | `200 {rooms[]}` |
| PATCH | `/homes/{homeId}/rooms/{roomId}` | `{name?, icon?, sortOrder?}` | `200 {room}` |
| DELETE | `/homes/{homeId}/rooms/{roomId}` | — | `204` — ADMIN+ |
| GET | `/homes/{homeId}/members` | — | `200 {members[]}` |
| POST | `/homes/{homeId}/members` | `{email, role}` | `201 {member}` — OWNER only |
| PATCH | `/homes/{homeId}/members/{userId}` | `{role}` | `200 {member}` |
| DELETE | `/homes/{homeId}/members/{userId}` | — | `204` — OWNER or self |
| POST | `/homes/{homeId}/transfer-ownership` | `{toUserId}` | `200 {home}` — OWNER only |

---

## 6. Node domain (RainMaker hierarchy)

This is the core domain — every endpoint maps cleanly to the RainMaker Node / Device / Service / Parameter / Attribute hierarchy (V3-DEVICE-MODEL.md).

### 6.1 Node-level endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/homes/{homeId}/nodes` | List nodes in home (with `is_online`, `firmware_version`, device count) |
| GET | `/nodes/{nodeId}` | Full node config: `devices[]`, `services[]`, `attributes{}` — mirrors the MQTT `config` payload |
| PATCH | `/nodes/{nodeId}` | `{name?, roomId?}` |
| DELETE | `/nodes/{nodeId}` | Revokes cert + soft delete + EMQX disconnect |
| GET | `/nodes/{nodeId}/config` | Raw node self-description (cached from MQTT retained message) |
| GET | `/nodes/{nodeId}/params` | All param `last_value`s across all devices + services (fast UI cache read) |
| GET | `/nodes/{nodeId}/telemetry?from=&to=&param=&bucket=` | Time-series — queries TimescaleDB `device_telemetry` hypertable |
| GET | `/nodes/{nodeId}/presence` | `{isOnline, lastSeenAt, rssi, ip}` |
| POST | `/nodes/{nodeId}/system-service` | `{operation: "reboot" \| "wifi_reset" \| "factory_reset"}` |
| POST | `/nodes/{nodeId}/ota` | `{version}` — triggers OTA (see §9) |

### 6.2 Device-level endpoints (within a node)

| Method | Path | Notes |
|---|---|---|
| GET | `/nodes/{nodeId}/devices` | List devices + services on node |
| GET | `/nodes/{nodeId}/devices/{deviceId}` | Device detail (attributes, params with `last_value`) |
| PATCH | `/nodes/{nodeId}/devices/{deviceId}` | `{displayName?, attributes?}` |
| GET | `/nodes/{nodeId}/devices/{deviceId}/params` | Params for one device |
| PUT | `/nodes/{nodeId}/devices/{deviceId}/params` | Write parameter(s) — body: `{"Power": true}` or `{"Power": true, "Brightness": 75}` |

### 6.3 Example: write a parameter

```
PUT /api/v3/nodes/550e8400-e29b-41d4-a716-446655440000/devices/660e8400-.../params
Authorization: Bearer <jwt>
Idempotency-Key: 7a6b5c4d-3e2f-1a0b-9c8d-7e6f5a4b3c2d
Content-Type: application/json

{
  "Power": true
}
```

Response:

```json
{
  "data": {
    "nodeId": "550e8400-...",
    "deviceId": "660e8400-...",
    "params": {
      "Power": { "last_value": true, "last_reported_at": "2024-12-01T14:23:45Z" }
    },
    "accepted": true
  },
  "meta": { "mqtt_publish_id": "cmd-uuid-..." }
}
```

Spring Boot publishes the command to MQTT topic `she/{tenant_id}/{home_id}/{room_id}/{node_mac}/params/remote` (V3-MQTT-STANDARDS.md §3.4). The device ACKs via `params/local` within 2s; the new `last_value` is also pushed over WebSocket (`node.state` event, §14).

### 6.4 Internal node-claim endpoint (BLE provisioning)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/v3/nodes/claim` | Called by ESP32 during BLE provisioning — see `V3-FIRMWARE.md` §5 |

---

## 7. Automation domain

| Method | Path | Notes |
|---|---|---|
| GET | `/homes/{homeId}/automations` | List automations in home |
| POST | `/homes/{homeId}/automations` | `{name, description?, enabled?, trigger, actions[]}` |
| GET | `/automations/{id}` | Full automation with trigger + actions |
| PUT | `/automations/{id}` | `{name?, description?, enabled?}` |
| PATCH | `/automations/{id}/enabled` | `{enabled: true/false}` |
| DELETE | `/automations/{id}` | `204` — ADMIN+ |
| POST | `/automations/{id}/trigger` | MANUAL trigger — MEMBER+ |

### 7.1 Trigger config shapes

```json
// SCHEDULE
{ "type": "SCHEDULE", "cron": "0 6 * * *" }

// NODE_STATE — fires when a param crosses a threshold
{
  "type": "NODE_STATE",
  "node_id": "uuid",
  "device_name": "Relay 1",
  "param_name": "Power",
  "comparator": "==",
  "value": true
}

// MANUAL
{ "type": "MANUAL" }
```

### 7.2 Action config shapes

```json
[
  { "type": "WRITE_PARAM",
    "node_id": "uuid", "device_name": "Relay 1",
    "params": { "Power": true } },
  { "type": "ACTIVATE_SCENE", "scene_id": "uuid" },
  { "type": "NOTIFICATION", "category": "AUTOMATION",
    "title": "Living room light auto-on", "body": "Triggered by sunset" }
]
```

---

## 8. Scene + node-group domain

### 8.1 Scenes

| Method | Path | Notes |
|---|---|---|
| GET | `/homes/{homeId}/scenes` | List scenes |
| POST | `/homes/{homeId}/scenes` | `{name, icon, actions[]}` — actions are `WRITE_PARAM` shape |
| GET | `/scenes/{id}` | Scene detail |
| PATCH | `/scenes/{id}` | `{name?, icon?, actions?}` |
| DELETE | `/scenes/{id}` | `204` — ADMIN+ |
| POST | `/scenes/{id}/activate` | Returns `{executionId, acceptedCount, failedCount[]}` — fans out MQTT publishes in parallel |

### 8.2 Node groups (broadcast groups)

| Method | Path | Notes |
|---|---|---|
| GET | `/homes/{homeId}/node-groups` | List groups |
| POST | `/homes/{homeId}/node-groups` | `{name, groupType, nodeIds[]}` — groupType ∈ `ROOM`, `CUSTOM`, `ALL_LIGHTS` |
| POST | `/node-groups/{id}/command` | `{params: {"Power": false}}` — broadcasts to all member nodes |
| DELETE | `/node-groups/{id}` | `204` — ADMIN+ |

---

## 9. OTA domain

| Method | Path | Min role | Notes |
|---|---|---|---|
| GET | `/homes/{homeId}/ota/batches` | MEMBER+ | List batches |
| POST | `/homes/{homeId}/ota/batches` | OWNER | `{firmwareVersion, firmwareUrl, firmwareChecksum, signatureEd25519, targetSku, rolloutPercent, autoApprove}` |
| GET | `/ota/batches/{id}` | MEMBER+ | With per-node approvals |
| POST | `/ota/batches/{id}/start` | ADMIN+ | Creates `PENDING` approvals for matching nodes |
| POST | `/ota/batches/{id}/abort` | OWNER | Cancels pending + in-progress deployments |
| POST | `/ota/approvals/{id}/approve` | ADMIN+ | Approves rollout for one node |
| POST | `/ota/approvals/{id}/decline` | ADMIN+ | Opts out one node |
| POST | `/nodes/{nodeId}/ota` | MEMBER+ | Trigger OTA on a single node — body `{version}` |

**OTA flow:** Spring Boot publishes to MQTT topic `she/.../{node_mac}/ota/url` (signed URL pointing to MinIO). Device downloads, verifies Ed25519 signature (V3-FIRMWARE.md §6), writes to alternate partition, reboots, runs 5-min health check, then either commits or auto-rolls back. Progress is reported via `ota/progress` topic and surfaced over WebSocket as `ota.progress` events.

---

## 10. Energy domain

| Method | Path | Notes |
|---|---|---|
| GET | `/homes/{homeId}/energy/summary` | Total energy + cost across all nodes (today / week / month) |
| GET | `/nodes/{nodeId}/energy?from=&to=&granularity=` | Per-node energy + cost — granularity ∈ `5m`, `1h`, `1d` |
| GET | `/tenant/energy/report?from=&to=&groupBy=` | TENANT_ADMIN — aggregate across all tenant nodes; `groupBy` ∈ `node`, `home`, `day` |
| GET | `/homes/{homeId}/energy/cost-breakdown` | EEU block-tariff breakdown (V3-ENERGY-MONITORING.md) |

Energy data is read from the `device_energy_readings` hypertable (or `energy_hourly` / `energy_daily` continuous aggregates for coarse queries — V3-DATABASE-DESIGN.md §5).

---

## 11. Payment domain

| Method | Path | Notes |
|---|---|---|
| POST | `/payments/initiate` | `{plan, amountEtb}` → `{paymentId, checkoutUrl}` — Chapa checkout |
| GET | `/payments/{id}/status` | Poll status (PENDING, PAID, FAILED, REFUNDED) |
| POST | `/payments/webhook` | Chapa webhook (HMAC-SHA256 verified, public path, no JWT) |
| GET | `/subscription` | Current subscription status |
| POST | `/subscription/cancel` | Cancels at end of billing period |
| GET | `/invoices?cursor=&limit=` | B2B: list invoices; B2C: list payment history |

---

## 12. Notification domain

| Method | Path | Notes |
|---|---|---|
| GET | `/notifications/preferences` | Per-category mutes |
| PUT | `/notifications/preferences` | Bulk update — `{AUTOMATION: {push: true, sms: false}, OTA: {...}, ...}` |
| GET | `/notifications/recent?limit=50` | Last 50 notifications |
| POST | `/notifications/register-device` | `{provider, token, platform, locale}` — provider ∈ `FCM`, `APNs` |
| DELETE | `/notifications/register-device/{token}` | Unregister |
| POST | `/notifications/test` | Sends a test push to verify FCM/APNs config |

---

## 13. Admin domain

All under `/api/admin/*`. Requires `PLATFORM_ADMIN`, `SUPER_ADMIN`, `TENANT_ADMIN`, or `TENANT_INSTALLER` depending on endpoint.

| Method | Path | Min role | Notes |
|---|---|---|---|
| GET | `/admin/tenants` | SUPER_ADMIN | List all tenants |
| POST | `/admin/tenants` | SUPER_ADMIN | Create tenant (white-label) |
| GET | `/admin/tenants/{id}` | SUPER_ADMIN | Tenant detail + branding |
| PUT | `/admin/tenants/{id}/branding` | SUPER_ADMIN | Update branding |
| POST | `/admin/tenants/{id}/suspend` | SUPER_ADMIN | Suspend tenant |
| GET | `/admin/users` | TENANT_ADMIN | List users (scoped to tenant via RLS) |
| PATCH | `/admin/users/{id}/role` | TENANT_ADMIN | Change tenant role |
| POST | `/admin/users/{id}/disable` | TENANT_ADMIN | Disable account |
| DELETE | `/admin/users/{id}` | TENANT_ADMIN | Delete + anonymize PII |
| POST | `/admin/impersonate/{userId}` | TENANT_ADMIN | 15-min impersonation JWT (audited) |
| GET | `/admin/audit-log?actor=&action=&from=&to=` | TENANT_ADMIN | Searchable audit log |
| GET | `/admin/audit-log/export` | TENANT_ADMIN | CSV export |
| GET | `/admin/nodes` | TENANT_ADMIN | All tenant nodes (replaces `/admin/devices`) |
| POST | `/admin/nodes/{id}/quarantine` | TENANT_ADMIN | Block MQTT commands + flag for review |
| GET | `/admin/feature-flags` | TENANT_ADMIN | List flags |
| PUT | `/admin/feature-flags/{flag}` | TENANT_ADMIN | Toggle flag |
| GET | `/admin/billing/overview` | TENANT_ADMIN | MRR, active subscriptions, invoices |

---

## 14. WebSocket

```
WSS /ws/v3
```

### 14.1 Authentication — `Sec-WebSocket-Protocol` header

**The original V3 docs used `?token=` query param — this was a security smell** (URLs are logged by proxies/load balancers, leaking JWTs). V3 corrects this by using the standard `Sec-WebSocket-Protocol` subprotocol mechanism:

```
GET /ws/v3 HTTP/1.1
Host: api.she.et
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
Sec-WebSocket-Protocol: bearer.eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

Spring Boot's WebSocket handshake interceptor:

```java
@Component
public class WsAuthInterceptor implements HandshakeInterceptor {
    @Override
    public boolean beforeHandshake(ServerHttpRequest req, ServerHttpResponse resp,
                                   WsConfig attrs, Map<String, Object> map) {
        List<String> subprotocols = req.getHeaders().get("Sec-WebSocket-Protocol");
        if (subprotocols == null || subprotocols.isEmpty()) {
            resp.setStatusCode(HttpStatus_UNAUTHORIZED);
            return false;
        }
        String token = subprotocols.stream()
            .filter(s -> s.startsWith("bearer."))
            .map(s -> s.substring("bearer.".length()))
            .findFirst()
            .orElse(null);
        if (token == null || !jwtVerifier.verify(token)) {
            resp.setStatusCode(HttpStatus_UNAUTHORIZED);
            return false;
        }
        AuthenticatedUser user = jwtVerifier.parse(token);
        map.put("user", user);
        // Echo back the selected subprotocol so the client accepts
        resp.getHeaders().set("Sec-WebSocket-Protocol", "bearer." + token);
        return true;
    }
}
```

The Flutter client passes the subprotocol via `WebSocket.connect(url, protocols: ['bearer.$jwt'])`.

### 14.2 Client → Server

```json
{ "action": "subscribe", "scope": "home", "home_id": "uuid" }
{ "action": "subscribe", "scope": "node", "node_id": "uuid" }
{ "action": "unsubscribe", "scope": "node", "node_id": "uuid" }
{ "action": "ping" }
```

### 14.3 Server → Client (event types)

| Event | Payload | Trigger |
|---|---|---|
| `node.state` | `{nodeId, deviceId, paramName, value, timestamp}` | MQTT `params/local` message — per-param update |
| `node.telemetry` | `{nodeId, voltage, current, powerW, energyWh, costEtb, timestamp}` | Energy ingest (every 5s from PZEM) |
| `node.presence` | `{nodeId, isOnline, lastSeenAt}` | MQTT LWT (online/offline) |
| `automation.triggered` | `{automationId, name, triggerType}` | Automation executor |
| `automation.completed` | `{automationId, success, durationMs, failedActions[]}` | |
| `scene.activated` | `{sceneId, executionId, acceptedCount, failedCount}` | |
| `scene.completed` | `{sceneId, executionId, status}` | |
| `energy.update` | `{nodeId, powerW, costTodayEtb, costMonthEtb}` | Energy ingest — also pushes to `node.telemetry` for raw |
| `ota.progress` | `{nodeId, batchId, status, progress, version}` | OTA service param changes |
| `notification.received` | `{category, title, body, timestamp}` | Notification service |

### 14.4 Example frame

```json
{
  "event": "node.state",
  "data": {
    "nodeId": "550e8400-e29b-41d4-a716-446655440000",
    "deviceId": "660e8400-...",
    "deviceName": "Relay 1",
    "paramName": "Power",
    "value": true,
    "timestamp": "2024-12-01T14:23:45.123Z"
  },
  "meta": { "request_id": "mqtt-msg-uuid-..." }
}
```

---

## 15. Internal endpoints (server-to-server)

Not exposed via Cloudflare — only reachable from the VPC private subnet.

| Method | Path | Notes |
|---|---|---|
| POST | `/internal/mqtt/auth` | EMQX HTTP auth backend — verifies cert fingerprint → tenant + node |
| POST | `/internal/mqtt/acl` | EMQX HTTP ACL backend — per-node topic authorization (V3-SECURITY-MODEL.md §6) |
| POST | `/api/v3/nodes/claim` | ESP32 BLE provisioning — issues cert, creates `nodes` row (V3-FIRMWARE.md §5) |
| POST | `/internal/factory/register-cert` | Factory workstation — records cert → node_id mapping (V3-FACTORY-OPS.md §3) |
| GET | `/internal/health/mqtt` | EMQX connection health |
| GET | `/internal/health/redis` | Redis health |
| GET | `/internal/health/db` | Postgres health |
| GET | `/internal/health/ca` | step-ca CA health |
| POST | `/internal/energy/ingest` | MQTT bridge — bulk-inserts PZEM readings into `device_energy_readings` |

---

## 16. Error response format

All errors follow the same envelope. The `code` field is one of the catalog entries in `V3-ERROR-CODES.md`:

```json
{
  "error": {
    "code": "NODE_NOT_FOUND",
    "message": "Node 550e8400-... does not exist or is not accessible by this tenant.",
    "http_status": 404,
    "request_id": "req-uuid-...",
    "details": {
      "node_id": "550e8400-e29b-41d4-a716-446655440000"
    }
  }
}
```

| HTTP status | Code prefix | Examples |
|---|---|---|
| 400 | `VALIDATION_*` | `VALIDATION_FAILED`, `VALIDATION_INVALID_JSON` |
| 401 | `AUTH_*` | `AUTH_TOKEN_EXPIRED`, `AUTH_TOKEN_INVALID`, `AUTH_MFA_REQUIRED` |
| 403 | `FORBIDDEN_*` | `FORBIDDEN_ROLE`, `FORBIDDEN_QUARANTINED` |
| 404 | `*_NOT_FOUND` | `NODE_NOT_FOUND`, `HOME_NOT_FOUND`, `USER_NOT_FOUND` |
| 409 | `*_CONFLICT` | `NODE_ALREADY_CLAIMED`, `SUBSCRIPTION_ACTIVE` |
| 422 | `*_UNPROCESSABLE` | `NODE_OFFLINE`, `OTA_VERSION_DOWNGRADE_BLOCKED` |
| 429 | `RATE_LIMITED` | Per-user / per-tenant rate limit |
| 500 | `INTERNAL_*` | `INTERNAL_DB`, `INTERNAL_MQTT` (logged with stack trace) |
| 503 | `*_UNAVAILABLE` | `OTA_SERVICE_UNAVAILABLE`, `PAYMENT_PROVIDER_UNAVAILABLE` |

**Cross-reference:** Full code catalog (60+ codes), HTTP status mapping, and user-facing Amharic/English message templates — see `V3-ERROR-CODES.md`.

---

## 17. Versioning + deprecation

| Version | Status | Notes |
|---|---|---|
| `/api/v3/*` | **Locked (current)** | This document |
| `/api/v2/*` | Sunset (2024-Q1) | Returned `410 Gone` after 6-month deprecation |
| `/api/v4/*` | Planned (2025-Q4) | Matter-over-Wi-Fi endpoints, solar inverter integration |

Breaking changes within V3 are forbidden. Additive changes (new endpoints, new optional fields) do not require a new major version. Deprecation of any V3 endpoint requires: 6-month `Deprecation` header on response + `Sunset` header announcement + migration guide in `V3-CHANGELOG.md`.

---

## 18. References

- `V3-DEVICE-MODEL.md` — RainMaker hierarchy that this API surfaces
- `V3-DATABASE-DESIGN.md` — schema behind every endpoint
- `V3-MQTT-STANDARDS.md` — topic structure that drives async responses
- `V3-SECURITY-MODEL.md` §6 — EMQX auth/ACL backends
- `V3-ERROR-CODES.md` — full error code catalog
- `V3-FIRMWARE.md` §5 — BLE provisioning → `/api/v3/nodes/claim` flow
- `V3-FACTORY-OPS.md` §3 — `/internal/factory/register-cert` flow
- `V3-OPS-RUNBOOK.md` — rate-limit tuning, idempotency-key purge, WebSocket connection limits
- RainMaker REST reference: https://swaggerapis.rainmaker.espressif.com/ (used as inspiration only — SHE V3 cloud is fully self-hosted)
