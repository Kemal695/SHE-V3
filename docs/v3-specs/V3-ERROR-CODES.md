# V3 — Error Codes

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Backend Engineer

---

## 0. Scope

Every V3 API error returns a structured envelope. Error codes are stable, UPPER_SNAKE_CASE, never renamed (see §11 Stability policy). Approximately 100 codes covering auth, RBAC, resource not found, validation, conflict, rate limit, device/IoT, payment, and server errors.

```json
{
  "error": {
    "code": "DEVICE_OFFLINE",
    "message": "Device is offline; command queued in desired_state",
    "details": {
      "device_id": "8a3b1c2e-...",
      "queued_command_id": "9c4d2e3f-...",
      "last_seen_at": "2024-12-15T10:30:00Z"
    },
    "request_id": "req_abc123",
    "retryable": true,
    "retry_after_seconds": 30
  }
}
```

Every error includes `request_id` (propagated from `X-Request-Id` header or generated) for tracing in Loki + Spring Boot logs.

---

## 1. Auth errors (401/403/410)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `AUTH_INVALID_CREDENTIALS` | 401 | Invalid email or password | Yes (after delay) | Check password; rate-limited at 5 attempts per 5 min |
| `AUTH_ACCOUNT_DISABLED` | 403 | Account is disabled | No | Contact admin to re-enable |
| `AUTH_ACCOUNT_DELETED` | 410 | Account is deleted | No | User data anonymized; cannot recover |
| `AUTH_TOKEN_EXPIRED` | 401 | Access token expired | Yes (refresh) | Client should call `/api/v3/auth/refresh` |
| `AUTH_TOKEN_INVALID` | 401 | Invalid token | No | JWT signature failed or wrong issuer |
| `AUTH_TOKEN_REVOKED` | 401 | Token revoked | No | `jti` blacklisted in Redis (logout, password change, admin force-logout) |
| `AUTH_MFA_REQUIRED` | 401 | MFA code required | No | Client should re-call `/login` with `mfa_code` field |
| `AUTH_MFA_INVALID` | 401 | Invalid MFA code | Yes (limited) | 5 attempts before MFA lockout (15 min) |
| `AUTH_MFA_LOCKED` | 401 | MFA locked after 5 failed attempts | Yes (after 15 min) | User must wait 15 min or use backup code |
| `AUTH_OAUTH_STATE_MISMATCH` | 400 | OAuth state mismatch | No | Possible CSRF — restart OAuth flow |
| `AUTH_OAUTH_PROVIDER_ERROR` | 502 | OAuth provider error | Yes | GitHub/Google returned error — check provider status |
| `AUTH_ACCOUNT_LOCKED` | 403 | Account locked after 5 failed login attempts | Yes (after 15 min) | Wait 15 min or reset password |

---

## 2. RBAC errors (403/409)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `RBAC_FORBIDDEN` | 403 | You don't have permission to perform this action | No | Generic — see audit log for reason |
| `RBAC_INSUFFICIENT_ROLE` | 403 | Requires role {required}, you have {actual} | No | Promote user role or use different account |
| `RBAC_LAST_OWNER_CANNOT_LEAVE` | 409 | Cannot leave: you are the last OWNER of this home | No | Transfer ownership to another member first |
| `RBAC_TENANT_ADMIN_REQUIRED` | 403 | Tenant admin role required | No | Action needs TENANT_ADMIN role |
| `RBAC_SUPER_ADMIN_REQUIRED` | 403 | Super admin role required | No | Action needs SUPER_ADMIN role |
| `RBAC_IMPERSONATION_CHAIN` | 403 | Cannot impersonate while impersonating | No | End current impersonation before starting another |
| `RBAC_MFA_RECENT_REQUIRED` | 403 | Recent MFA verification required for this action | No | Re-verify MFA (within last 15 min) for sensitive operations |
| `TENANT_QUOTA_EXCEEDED` | 403 | Tenant quota exceeded: {current}/{limit} devices | No | Upgrade plan or remove unused devices |

---

## 3. Resource not found (404)

| Code | HTTP | Message | Debugging hint |
|---|---|---|---|
| `USER_NOT_FOUND` | 404 | User not found | Check user_id; user may be deleted |
| `HOME_NOT_FOUND` | 404 | Home not found | Check home_id; RLS may be hiding it |
| `ROOM_NOT_FOUND` | 404 | Room not found | Check room_id |
| `DEVICE_NOT_FOUND` | 404 | Device not found | Check device_id; device may be unprovisioned |
| `NODE_NOT_FOUND` | 404 | Node not found | Check node_id (RainMaker hierarchy) |
| `NODE_DEVICE_NOT_FOUND` | 404 | Node device not found | Check device_name matches MQTT payload key |
| `DEVICE_TYPE_NOT_FOUND` | 404 | Device type not found | Use esp.device.* namespace |
| `AUTOMATION_NOT_FOUND` | 404 | Automation not found | Check automation_id |
| `SCENE_NOT_FOUND` | 404 | Scene not found | Check scene_id |
| `NODE_GROUP_NOT_FOUND` | 404 | Node group not found | Check node_group_id |
| `OTA_BATCH_NOT_FOUND` | 404 | OTA batch not found | Check batch_id |
| `OTA_APPROVAL_NOT_FOUND` | 404 | OTA approval not found | Check approval_id |
| `TENANT_NOT_FOUND` | 404 | Tenant not found | Check tenant_id |
| `PROVISIONING_TOKEN_NOT_FOUND` | 404 | Provisioning token not found | Token expired (10 min TTL) or already used |
| `INVOICE_NOT_FOUND` | 404 | Invoice not found | Check invoice_id |
| `API_KEY_NOT_FOUND` | 404 | API key not found | Check api_key; may be revoked |

---

## 4. Validation errors (400/422)

| Code | HTTP | Message | Debugging hint |
|---|---|---|---|
| `VALIDATION_FAILED` | 422 | Validation failed | Per-field details in `details.fields[]` |
| `VALIDATION_EMAIL_INVALID` | 422 | Invalid email format | RFC 5322 regex |
| `VALIDATION_PASSWORD_WEAK` | 422 | Password does not meet complexity requirements | Min 12 chars, 1 upper, 1 lower, 1 digit, 1 special |
| `VALIDATION_UUID_INVALID` | 422 | Invalid UUID | Must be UUIDv4 |
| `VALIDATION_FIELD_REQUIRED` | 422 | Required field missing | Field name in `details.field` |
| `VALIDATION_CRON_INVALID` | 422 | Invalid cron expression | 5-field Unix cron |
| `VALIDATION_TRIGGER_CONFIG_INVALID` | 422 | Invalid trigger configuration | See V3-API-SPECIFICATION.md §5 |
| `VALIDATION_PHONE_INVALID` | 422 | Invalid phone number | Ethiopian: `^(\+251\|0)?9\d{8}$` (V3-I18N.md §5.3) |
| `VALIDATION_COLOR_FORBIDDEN` | 422 | Color hue not allowed | Indigo/blue-purple hues rejected per V3-DESIGN-SYSTEM.md |
| `VALIDATION_AMHARIC_REQUIRED` | 422 | Amharic translation required for this field | B2C strings must be in both en + am ARB files |

---

## 5. Conflict errors (409)

| Code | HTTP | Message | Debugging hint |
|---|---|---|---|
| `CONFLICT_EMAIL_TAKEN` | 409 | Email already registered | Use login flow or password reset |
| `CONFLICT_DEVICE_MAC_TAKEN` | 409 | Device with this MAC already provisioned | Device already claimed by another user/tenant |
| `CONFLICT_DEVICE_QUARANTINED` | 409 | Device is quarantined | Admin must release quarantine |
| `CONFLICT_PROVISIONING_TOKEN_USED` | 409 | Provisioning token already used | Generate new token (10-min TTL) |
| `CONFLICT_OTA_BATCH_IN_PROGRESS` | 409 | OTA batch already in progress for this SKU | Wait for current batch to complete or abort it |
| `CONFLICT_TRANSFER_REQUIRES_ADMIN` | 409 | Home transfer requires admin approval | SUPER_ADMIN must approve tenant-bound home transfers |
| `CONFLICT_DEVICE_OFFLINE` | 409 | Device is offline; command queued | Command stored in `desired_state`, will apply on reconnect |
| `CONFLICT_SUBSCRIPTION_EXPIRED` | 409 | Subscription expired | Tenant/user must renew |
| `CONFLICT_TENANT_SUSPENDED` | 409 | Tenant is suspended (non-payment) | Billing must be resolved |

---

## 6. Rate limit (429)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `RATE_LIMIT_LOGIN` | 429 | Too many login attempts | Yes (after 5 min) | 5 attempts per email per 5 min |
| `RATE_LIMIT_API` | 429 | API rate limit exceeded | Yes (after 60 s) | 1000 req/min per user default |
| `RATE_LIMIT_NOTIFICATION` | 429 | Notification rate limit exceeded | Yes (after 60 s) | 10 notifications per user per minute |
| `RATE_LIMIT_ADMIN` | 429 | Admin API rate limit exceeded | Yes (after 60 s) | 100 req/min per admin user |
| `RATE_LIMIT_MQTT_PUBLISH` | 429 | MQTT publish rate limit exceeded | Yes (after 1 s) | Device-side: 10 msgs/sec sustained |
| `RATE_LIMIT_DEVICE_PROVISIONING` | 429 | Too many provisioning attempts | Yes (after 10 min) | 10 per hour per user |

All 429 responses include `Retry-After` header (seconds) and `details.retry_after_seconds` field.

---

## 7. Device + IoT errors (409/422/503/504)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `DEVICE_OFFLINE` | 409 | Device is offline | Yes | LWT published; check EMQX dashboard |
| `DEVICE_COMMAND_TIMEOUT` | 504 | Command timed out waiting for device ack | Yes | Device may be busy or network unstable |
| `DEVICE_PARAM_UNKNOWN` | 422 | Unknown parameter for this device | No | Check node config payload for param_name |
| `DEVICE_CERT_REVOKED` | 403 | Device certificate revoked | No | Check step-ca CRL; RMA replacement |
| `DEVICE_TIMESERIES_UNAVAILABLE` | 409 | Time series data unavailable for this device | No | No PZEM sensor (SHE-R4) |
| `DEVICE_SYSTEM_SERVICE_UNAVAILABLE` | 409 | System service not supported on this device | No | SKU doesn't support this service |
| `DEVICE_PROVISIONING_FAILED` | 422 | Device provisioning failed | Yes | Check Wi-Fi credentials, BLE pairing, cloud reachability |
| `DEVICE_FIRMWARE_INCOMPATIBLE` | 422 | Firmware version incompatible with this command | No | Update firmware via OTA |
| `INVALID_CHANNEL` | 422 | Invalid relay channel for this SKU | No | R4 supports 0-3, R8 supports 0-7, R16 supports 0-15 |

---

## 8. OTA errors (400/422/409/502)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `OTA_INVALID_SIGNATURE` | 422 | OTA image signature verification failed | No | Ed25519 signature mismatch — verify `OTA_SIGNING_KEY` env var |
| `OTA_ROLLBACK_INITIATED` | 409 | OTA rollback initiated (health check failed) | No | Investigate firmware bug |
| `OTA_VERSION_DOWNGRADE_BLOCKED` | 422 | OTA version is below anti-rollback eFuse minimum | No | eFuse burned; cannot downgrade |
| `OTA_IMAGE_NOT_FOUND` | 404 | OTA image not found in MinIO | No | Check MinIO bucket |
| `OTA_DOWNLOAD_FAILED` | 502 | OTA image download failed | Yes | Device couldn't reach MinIO; check network |
| `OTA_BATCH_PAUSED` | 409 | OTA batch is paused | No | Admin must resume batch |
| `OTA_BATCH_ABORTED` | 409 | OTA batch is aborted | No | Admin must create new batch |
| `OTA_DISK_FULL` | 507 | Device flash partition full | No | RMA device (hardware fault) |

---

## 9. Payment errors (400/409/422/502)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `PAYMENT_INITIATION_FAILED` | 502 | Chapa API error during initiation | Yes | Check Chapa status; retry |
| `PAYMENT_WEBHOOK_INVALID_SIGNATURE` | 400 | Webhook signature verification failed | No | Do not process — possible fraud |
| `PAYMENT_ALREADY_PROCESSED` | 409 | Payment already processed | No | Idempotency check; do not re-activate |
| `PAYMENT_AMOUNT_INVALID` | 422 | Amount doesn't match plan price | No | Server-side validation failed; check plan config |
| `PAYMENT_PLAN_INVALID` | 422 | Invalid plan identifier | No | Use B2C_FREE / B2C_PREMIUM / B2C_FAMILY / B2B_100 / B2B_1000 / B2B_UNLIMITED |
| `PAYMENT_VERIFICATION_FAILED` | 502 | Chapa verify API returned failure | Yes | Webhook reported success but verify failed — investigate |
| `PAYMENT_REFUND_FAILED` | 502 | Chapa refund API error | Yes | Retry refund; if persists, manual refund via Chapa dashboard |

---

## 10. Server errors (500/502/503/504)

| Code | HTTP | Message | Retryable | Debugging hint |
|---|---|---|---|---|
| `INTERNAL_ERROR` | 500 | Internal server error | Yes (with backoff) | Check Spring Boot logs (Loki) |
| `DATABASE_ERROR` | 500 | Database error | Yes | Check Postgres logs; may be connection pool exhausted |
| `REDIS_ERROR` | 500 | Redis error | Yes | Check Redis cluster status |
| `MQTT_BROKER_UNREACHABLE` | 502 | MQTT broker unreachable | Yes | Check EMQX cluster health |
| `MQTT_PUBLISH_FAILED` | 502 | MQTT publish failed | Yes | EMQX rejected message; check ACL |
| `CA_SERVICE_ERROR` | 500 | Certificate authority service error | No | step-ca unreachable; check db-1 |
| `MINIO_UNREACHABLE` | 502 | MinIO (firmware storage) unreachable | Yes | Check storage-1 |
| `MAINTENANCE_MODE` | 503 | System in maintenance mode | Yes (after 5 min) | Check ops Slack for maintenance window |
| `BAD_GATEWAY` | 502 | Bad gateway | Yes | Nginx upstream failed; check Spring Boot health |
| `GATEWAY_TIMEOUT` | 504 | Gateway timeout | Yes | Nginx upstream timed out (30 s); check slow query log |
| `SERVICE_UNAVAILABLE` | 503 | Service temporarily unavailable | Yes (with backoff) | All Spring Boot instances down |

---

## 11. Retryability matrix

| Retryable | Codes |
|---|---|
| **Yes (with exponential backoff)** | `DEVICE_OFFLINE`, `DEVICE_COMMAND_TIMEOUT`, `MQTT_BROKER_UNREACHABLE`, `MQTT_PUBLISH_FAILED`, `INTERNAL_ERROR`, `DATABASE_ERROR`, `REDIS_ERROR`, `MINIO_UNREACHABLE`, `MAINTENANCE_MODE`, `BAD_GATEWAY`, `GATEWAY_TIMEOUT`, `SERVICE_UNAVAILABLE`, `PAYMENT_INITIATION_FAILED`, `PAYMENT_VERIFICATION_FAILED`, `PAYMENT_REFUND_FAILED`, `OTA_DOWNLOAD_FAILED`, `AUTH_OAUTH_PROVIDER_ERROR` |
| **Yes (after delay — see Retry-After)** | `RATE_LIMIT_*` (all), `AUTH_MFA_INVALID`, `AUTH_INVALID_CREDENTIALS`, `AUTH_MFA_LOCKED`, `AUTH_ACCOUNT_LOCKED` |
| **No** | All other 4xx (resource not found, validation, RBAC, conflict, cert revoked, OTA signature invalid, etc.) |

---

## 12. Stability policy

Error codes are part of the **public API contract**. Once shipped in a GA release, they cannot be renamed — only deprecated. This is critical because:

1. Mobile app versions in the field will reference codes by string
2. B2B API integrations may switch on codes programmatically
3. Documentation + SDKs reference codes

### 12.1 Adding a new code

1. Add row to this document (V3-ERROR-CODES.md) — code, HTTP, message, retryable, debugging hint
2. Add Java exception class in `backend/src/main/java/.../errors/`
3. Add handler in `GlobalExceptionHandler.java` (maps exception → HTTP response envelope)
4. Add unit test for the handler
5. Add integration test that triggers the error
6. Update V3-API-SPECIFICATION.md if endpoint-specific
7. PR with code review

### 12.2 Deprecating a code

Codes cannot be removed. To deprecate:

1. Mark the code as `(deprecated)` in this document with the date and superseding code
2. Continue returning the deprecated code for backwards compatibility (mobile apps may still switch on it)
3. Also return the new code in a `details.superseded_by` field
4. After 12 months (2 mobile app release cycles), the deprecated code may be removed only if telemetry shows < 1% of clients still reference it

### 12.3 Renaming a code

**Not allowed.** If a code is misnamed (e.g., typo), keep the misnamed code and add a correctly-named alias that returns both. Never break the public contract.

---

## 13. References

- V3-API-SPECIFICATION.md — endpoint specs that return these codes
- V3-SECURITY-MODEL.md §1 + §2 — auth + RBAC error causes
- V3-DEVICE-MODEL.md §5 — MQTT topic structure (relates to device errors)
- V3-PAYMENTS.md §11 — payment security (relates to PAYMENT_* codes)
- V3-I18N.md §5.3 — Ethiopian phone regex (VALIDATION_PHONE_INVALID)
- V3-DESIGN-SYSTEM.md §1.3 — color restrictions (VALIDATION_COLOR_FORBIDDEN)
- V3-B2B-WHITELABEL.md §4.3 — TENANT_QUOTA_EXCEEDED
- V3-FIRMWARE.md §6 — OTA rollback (OTA_ROLLBACK_INITIATED)
- V3-FACTORY-OPS.md §9 — cert revocation (DEVICE_CERT_REVOKED)
