# SHE V3 — Phase 1 Code Review Bug-Fix Report

**Review date:** 2025-08-11
**Reviewer:** 3 parallel code review agents (backend / firmware / mobile)
**Total bugs found:** ~130 (across all 3 layers)
**Critical bugs fixed:** 26 (all boot-blocking + major runtime)
**Remaining documented:** ~104 (HIGH/MEDIUM/LOW — tracked for Phase 2 hardening)

---

## 1. CRITICAL bugs FIXED (26)

### Backend (14 fixed)

| # | Bug | File | Fix |
|---|---|---|---|
| 1 | **Duplicate route `/internal/factory/register-cert`** — Spring won't boot | `CaController.java` | Renamed to `/internal/ca/sign-and-register` |
| 2 | **PemToKeyStore broken PEM stripping** — MQTT mTLS completely broken (BEGIN markers never stripped) | `PemToKeyStore.java` | Rewrote with regex-based PEM body extraction |
| 3 | **TenantContextInterceptor runs before @Transactional** — SET LOCAL doesn't apply to correct transaction, RLS unreliable | `TenantContextAspect.java` (new) | Created AOP @Around aspect that runs INSIDE @Transactional boundary |
| 4 | **MqttSubscriberService topic parsing** — multi-segment directions (`params/local`, `ota/status`) never match switch → all messages dropped | `MqttSubscriberService.java` | Reconstruct full direction: `parts[5] + "/" + parts[6]` |
| 5 | **NodeServiceImpl.writeParams multi-param overwrite** — only last param per device published to MQTT | `NodeServiceImpl.java` | Use `computeIfAbsent` to accumulate params per device |
| 6 | **JwtService NPE on missing exp** — `((Number) claims.get("exp")).longValue()` throws NPE | `JwtService.java` | Null-safe exp extraction + added iss/aud validation |
| 7 | **CaController.revoke wrong field** — `findActiveByCn(serial)` queries CN column with serial value → always empty | `CaController.java` | Changed to `findActiveByCertSerial(serial)` |
| 8 | **FactoryService wrong return** — returns `tenantId` as `node_db_id` | `FactoryService.java` | Returns `node.getId()` (looks up node by cert_fingerprint) |
| 9 | **FactoryService idempotency wrong field** — `findActiveByCn(serial)` → always empty → crashes | `FactoryService.java` | Changed to `findActiveByCertSerial(serial)` |
| 10 | **SecurityConfig broken interceptor** — `tenantContextInterceptorConfigurer` bean registers broken interceptor | `SecurityConfig.java` | Removed bean (replaced by TenantContextAspect) |
| 11 | **MqttAuthController.authenticate not @Transactional** — setRlsGucs runs without transaction | `MqttAuthController.java` | Added @Transactional |
| 12 | **MqttAuthController.authorize not @Transactional** | `MqttAuthController.java` | Added @Transactional |
| 13 | **CaController.registerCert not @Transactional** | `CaController.java` | Added @Transactional |
| 14 | **CaController.revoke not @Transactional** | `CaController.java` | Added @Transactional |
| 15 | **FactoryService.registerCert not @Transactional** — 3 DB writes with no atomicity | `FactoryService.java` | Added @Transactional |
| 16 | **DeviceCertRepository missing findActiveByCertSerial** | `DeviceCertRepository.java` | Added method |

### Firmware (7 fixed)

| # | Bug | File | Fix |
|---|---|---|---|
| 17 | **Missing Kconfig.projbuild** — all CONFIG_SHE_* undefined → nothing compiles | `main/Kconfig.projbuild` (new) | Created with all SHE_R4/R8/R16/HAS_PZEM/HAS_VOICE/FIRMWARE_VERSION/SECURE_VERSION declarations |
| 18 | **CMakeLists.txt wrong certs path** — `"certs/ca.pem"` resolves to `main/certs/ca.pem` (doesn't exist) | `main/CMakeLists.txt` | Changed to `"../certs/ca.pem"` |
| 19 | **energy_monitor.c PZEM byte order** — 32-bit values parsed in wrong byte order (little-endian instead of big-endian) → garbage readings | `energy_monitor.c` | Fixed to `(resp[5]<<24)\|(resp[6]<<16)\|(resp[7]<<8)\|resp[8]` with uint32_t casts |
| 20 | **ota_handler.c nonexistent header** — `#include "mbedtls/ed25519.h"` doesn't exist in mbedTLS | `ota_handler.c` | Removed include |
| 21 | **ota_handler.c NULL deref** — `verify_ed25519_signature(NULL, ...)` → `mbedtls_sha256(NULL, ...)` crashes | `ota_handler.c` | Commented out stub call (Phase 1 stub — full impl in Phase 2B) |
| 22 | **ble_provisioning.c type error** — `wifi_prov_scheme_ble_set_service_uuid(0xFFFF)` passes int where uint8_t* required | `ble_provisioning.c` | Pass proper `uint8_t service_uuid[16]` buffer |
| 23 | **relay_driver.c relay_set_all(0) no-op** — when bitmask=0, chips never written → relays stuck ON | `relay_driver.c` | Write both chips unconditionally after loop |

### Mobile (5 fixed)

| # | Bug | File | Fix |
|---|---|---|---|
| 24 | **dynamic_device_widget undefined icons** — `Icons.power_outlet` / `Icons.dashboard_outlet` don't exist → compile error | `dynamic_device_widget.dart` | Replaced with `Icons.power` / `Icons.dashboard` |
| 25 | **dio_client concurrent refresh race** — multiple concurrent 401s each call _refreshToken() → first succeeds, rest use stale token → mass logout | `dio_client.dart` | Added Completer-based mutex — only one refresh at a time, all 401s wait for same result |
| 26 | **device_detail setState-after-dispose** — _loadParams doesn't check mounted → crash on navigation back | `device_detail_screen.dart` | Added `if (mounted)` guards before all setState calls |
| 27 | **Invisible spinners** — CircularProgressIndicator defaults to primary color (brightSkyBlue) on brightSkyBlue button background | login/register/provisioning screens | Added `color: Colors.white` |
| 28 | **Amharic typo** — `አማርክ` (wrong: "kə") instead of `አማርኛ` (correct: "ñə") | `settings_screen.dart` | Fixed to `አማርኛ` |

---

## 2. Remaining bugs DOCUMENTED for Phase 2 hardening (~104)

### Backend — HIGH (not fixed, tracked for Phase 2)

| # | Bug | File | Impact |
|---|---|---|---|
| H1 | HomeServiceImpl: no RBAC on ANY home/room/member operation | `HomeServiceImpl.java` | Any USER can read/modify any home, add/remove members, grant OWNER role |
| H2 | OtaService: no RBAC on createBatch/startBatch/abort/approve/decline | `OtaService.java` | Any USER can push firmware to all devices |
| H3 | NodeServiceImpl IDOR: device write doesn't verify device belongs to node | `NodeServiceImpl.java` | Cross-device write within same tenant |
| H4 | WsEventBus.publishOtaProgress broadcasts to ALL tenants | `WsEventBus.java` | Cross-tenant OTA progress disclosure |
| H5 | WsEventBus null tenantId NPE | `WsEventBus.java` | B2C user with null tenant_id crashes ConcurrentHashMap |
| H6 | ScheduledJobs hash-chain verification is no-op (RLS blocks all rows) | `ScheduledJobs.java` | Audit log tamper-evidence not verified |
| H7 | EnergyService timezone bug | `EnergyService.java` | Month boundary computed in wrong zone → cost calc wrong |
| H8 | EnergyService.detectAnomalies no RLS GUCs | `EnergyService.java` | Anomaly detection silently never runs |
| H9 | MqttPublishService connection leak | `MqttPublishService.java` | Old client never closed on reconnect |
| H10 | MqttSubscriberService never sets RLS GUCs for MQTT handlers | `MqttSubscriberService.java` | MQTT ingestion queries see 0 rows (RLS blocks) |
| H11 | JwtAuthenticationFilter unchecked exceptions → 500 | `JwtAuthenticationFilter.java` | UUID.fromString / cast failures not caught |
| H12 | GlobalExceptionHandler malformed JSON in static writer | `GlobalExceptionHandler.java` | String.formatted with user input breaks JSON |
| H13 | WsAuthInterceptor echoes JWT in response header | `WsAuthInterceptor.java` | Token leakage in response headers |
| H14 | NodeServiceImpl.getTelemetry ignores bucket parameter | `NodeServiceImpl.java` | API advertises 5m/1h/1d but returns raw points |
| H15 | NodeServiceImpl seq uses System.currentTimeMillis() | `NodeServiceImpl.java` | Not monotonic, not per-device, clock skew breaks replay protection |

### Firmware — HIGH/MEDIUM (not fixed, tracked for Phase 2B)

| # | Bug | File | Impact |
|---|---|---|---|
| F1 | local_ctrl.c plain HTTP on port 443 (mDNS says HTTPS) | `local_ctrl.c` | TLS handshake fails — local control broken |
| F2 | ble_provisioning.c prov_recv_handler is dead code (endpoint never registered) | `ble_provisioning.c` | BLE provisioning payload never processed |
| F3 | ble_provisioning.c FREE_BTDM wrong for C3 | `ble_provisioning.c` | R4 build may fail |
| F4 | feedback_monitor.c hardcoded S3 pins break on C3 | `feedback_monitor.c` | R4 GPIO conflict with flash |
| F5 | device_profiles.c profile_free frees static arrays | `device_profiles.c` | UB if called |
| F6 | main.c OTA health check is a stub (marks valid immediately) | `main.c` | Bad OTA not rolled back |
| F7 | main.c MQTT start failure has no retry | `main.c` | Device runs without cloud |
| F8 | idf_component.yml references nonexistent espressif/provisioning | `idf_component.yml` | Build fails on dependency resolution |
| F9 | CMakeLists.txt picovoice component referenced but not declared | `main/CMakeLists.txt` | R16 build fails |
| F10 | button_task.c no debouncing | `button_task.c` | Glitch triggers relay cycle |
| F11 | app_wifi.c no exponential backoff (despite header claim) | `app_wifi.c` | Fixed 5 retries, no backoff |
| F12 | system_service.c missing FreeRTOS includes | `system_service.c` | May not compile on all IDF versions |

### Mobile — HIGH/MEDIUM (not fixed, tracked for Phase 2)

| # | Bug | File | Impact |
|---|---|---|---|
| M1 | i18n completely non-functional — no screen calls AppLocalizations | all screens | 100% English despite Amharic locale |
| M2 | dashboard hardcoded fake homeId | `dashboard_screen.dart` | Real users see empty state forever |
| M3 | WS events only printed, no provider dispatch | `ws_client.dart` | Real-time updates never reach UI |
| M4 | GoRouter.redirect not reactive to auth state | `app_router.dart` | No auto-redirect to /login on token expiry |
| M5 | _ParamRow toggle has no optimistic UI + no refresh | `device_detail_screen.dart` | Switch snaps back after toggle |
| M6 | provisioning_screen SSID/password collected but never sent | `provisioning_screen.dart` | Wi-Fi creds silently dropped |
| M7 | energy_screen chart uses hardcoded placeholder data | `energy_screen.dart` | Chart doesn't consume API response |
| M8 | node_service.writeParams body shape contradicts spec | `node_service.dart` | Sends `{"params":{...}}` but spec says flat `{"Power":true}` |
| M9 | auth_service unsafe dynamic casts on refresh response | `auth_service.dart` | Runtime type errors on non-string fields |
| M10 | dashboard RefreshIndicator not scrollable in error/empty states | `dashboard_screen.dart` | Pull-to-refresh silently fails |
| M11 | provisioning PoP not validated as 9-digit numeric | `provisioning_screen.dart` | User can submit non-numeric PoP |
| M12 | WS lifecycle: _isConnected set before handshake, no dispose guard | `ws_client.dart` | Zombie reconnects + socket leak |

---

## 3. Summary

| Layer | Critical (fixed) | High (documented) | Medium (documented) | Low (documented) | Total |
|-------|-----------------|-------------------|---------------------|-------------------|-------|
| **Backend** | 16 | 15 | ~10 | ~5 | ~46 |
| **Firmware** | 7 | 12 | ~8 | ~5 | ~32 |
| **Mobile** | 5 | 12 | ~13 | ~8 | ~38 |
| **Total** | **28** | **39** | **~31** | **~18** | **~116** |

**Phase 1 is functional** with the 26 critical fixes applied. The remaining HIGH bugs are primarily:
- **RBAC enforcement** (HomeServiceImpl, OtaService) — needs `getAuthorizedHomeOrThrow` implementation
- **MQTT handler RLS GUCs** — needs @Transactional on handler methods or manual GUC setting
- **i18n wiring** — needs AppLocalizations.of(context) calls on all screens
- **BLE provisioning handler registration** — needs `wifi_prov_mgr_endpoint_register` call
- **Local control HTTPS** — needs `httpd_ssl_start` instead of `httpd_start`

These are tracked for Phase 2 hardening (weeks 13-24) alongside the custom hardware work.

---

## 4. Phase 2 hardening pass — verification status (2026-09-12)

The 39 HIGH-severity bugs listed in §2 have now been implemented and verified against the
working tree. Verification method: clean `mvn -o test` (26 tests, all green), `flutter analyze`
(0 errors), and per-bug source inspection.

### 4.1 Backend — 15/15 resolved

| # | Bug | Status | Where it is fixed |
|---|---|---|---|
| H1 | No RBAC on home/room/member ops | ✅ | `HomeServiceImpl.getAuthorizedHomeOrThrow()` — tenant check + role hierarchy (OWNER>ADMIN>MEMBER>GUEST), applied on all 11 entry points |
| H2 | No RBAC on OTA ops | ✅ | `OtaService` — `currentUser()` + `RBAC_INSUFFICIENT_ROLE` ("Tenant admin role required for OTA operations") |
| H3 | IDOR on device param write | ✅ | `NodeServiceImpl.writeParams()` → `getAuthorizedNodeOrThrow(nodeId,"MEMBER")` + `device.getNodeId().equals(nodeId)` check |
| H4 | OTA progress broadcast to all tenants | ✅ | `WsEventBus.sessionsByTenant` + `broadcast(tenantId, …)` |
| H5 | Null tenantId NPE | ✅ | `WsEventBus` — `user.tenantId() == null` guarded before registration |
| H6 | Hash-chain verification was a no-op | ✅ | `ScheduledJobs.verifyAuditLogHashChain()` — `@Transactional` + platform-admin GUC + per-tenant iteration |
| H7 | Energy timezone bug | ✅ | `EnergyService` — all month/day boundaries use `ZoneId.of("Africa/Addis_Ababa")` |
| H8 | `detectAnomalies` never ran (no GUCs) | ✅ | `EnergyService.detectAnomalies()` — `@Transactional` + `SET LOCAL app.is_platform_admin='true'` |
| H9 | MQTT publish connection leak | ✅ | `MqttPublishService` — stale client closed before reconnect |
| H10 | MQTT handlers never set RLS GUCs | ✅ | `MqttSubscriberService.processMessageWithRls()` — `@Transactional` wrapper + platform-admin GUC around the whole dispatch |
| H11 | JWT filter unchecked exceptions → 500 | ✅ | `JwtAuthenticationFilter` — `catch (SheException)` + `catch (Exception)` |
| H12 | Malformed JSON in error writer | ✅ | `GlobalExceptionHandler` — writes the envelope via `objectMapper.writeValue()`, no string interpolation |
| H13 | JWT echoed in WS response header | ✅ | `WsAuthInterceptor` — responds `Sec-WebSocket-Protocol: bearer` (subprotocol only, never the token) |
| H14 | `getTelemetry` ignored `bucket` | ✅ | `NodeServiceImpl.getTelemetry()` — TimescaleDB `time_bucket()` with 5m/1h/1d intervals |
| H15 | `seq` from `System.currentTimeMillis()` | ✅ | `NodeServiceImpl` — per-node `AtomicLong` seeded from wall-clock, strictly increasing |

### 4.2 Firmware — 12/12 resolved

F1 (`httpd_ssl_start`), F2 (dead custom provisioning endpoint removed — standard app-claims flow),
F3 (`FREE_BLE` on C3, not `FREE_BTDM`), F4 (target-conditional feedback pins),
F5 (`profile_free` no longer frees static arrays), F6 (real 300 s OTA health check + rollback),
F7 (bounded MQTT start retry), F8 (bogus `espressif/provisioning` dep removed),
F9 (picovoice reference made conditional / stubbed), F10 (50 ms button debounce),
F11 (real exponential backoff, 500 ms→10 s), F12 (FreeRTOS includes added).

Also: `mqtt_client.c/.h` was replaced by `she_mqtt.c/.h`; `main/CMakeLists.txt` lists the new
source and no file references the deleted API — the swap is complete, not a dangling deletion.

### 4.3 Mobile — 12/12 resolved

M1 (`AppLocalizations` wired on all screens, incl. device detail), M2 (real home id from
`homesProvider`), M3 (WS events dispatched via `ref.invalidate`), M4 (`refreshListenable` reactive
redirect), M5 (optimistic toggle with revert), M6 (SSID/password actually sent),
M7 (chart uses real `energy_wh` data), M8 (flat request body — see §5), M9 (type-checked refresh
response), M10 (scrollable empty/error states), M11 (9-digit numeric PoP validation),
M12 (`await channel.ready` before marking connected + generation/dispose guards).

---

## 5. Defects found and fixed during this pass (not in the original §2 list)

These were discovered while verifying the hardening work; all three were blocking CI or
violating the canonical spec.

| # | Defect | File | Fix |
|---|---|---|---|
| A | **`JwtServiceTest` hung the build forever.** `@BeforeAll` spawned `openssl` with `inheritIO()`, which steals Maven Surefire's stdin fork-communication channel → the forked VM never reports back ("terminated without properly saying goodbye", `Tests run: 0`), so the suite hung until killed. | `JwtServiceTest.java` | Replaced the subprocess with in-process JDK `KeyPairGenerator("Ed25519")` + PEM encoding. Test went from hanging to **5 tests in ~1 s**, and no longer depends on `openssl` being on `PATH`. |
| B | **`AuthControllerWebTest`: all 6 tests errored** — the `@WebMvcTest` slice could not build `tenantContextFilter` (needed `SheProperties`) and `tenantContextInterceptor` (needed `EntityManager`), neither of which exists in a web slice. | `TenantContextFilter.java`, `TenantContextInterceptor.java` | Both dependencies were **dead**: the filter never used `SheProperties`, and the interceptor is no longer registered as a `HandlerInterceptor` (replaced by `TenantContextAspect`). Removed the unused dependency and the vestigial `implements HandlerInterceptor` / `preHandle`. Stale javadoc corrected. |
| C | **M8 — param-write body contradicted the canonical spec.** `V3-API-SPECIFICATION.md` documents a FLAT body `{"Power": true}`; the backend DTO wrapped it as `{"params": {…}}` and the mobile client sent the wrapped form while its own comment said flat. | `NodeDtos.java`, `NodeController.java`, `node_service.dart` | Backend now binds the documented flat body via `WriteParamsRequest.of()` and still unwraps the legacy `{"params": {…}}` form, so no existing caller breaks. Mobile client switched to the flat body. Covered by 5 new unit tests. |

### 5.1 Known remaining cruft (non-blocking)

- `MqttSubscriberService.tenantContextInterceptor` is injected but unused (H10 is handled via
  `jdbcTemplate` in `processMessageWithRls`). Harmless dead dependency.
- `TenantContextInterceptor` is now a misnomer — it is an RLS-GUC helper, not an interceptor.
  A rename would touch 8 call sites; deferred to avoid churn.
- `mobile`: 19 remaining `flutter analyze` issues, all pre-existing lint info/warnings
  (`avoid_print`, `withOpacity` deprecation, `prefer_const_constructors`, unused test imports).

---

## 6. Verification commands

```bash
# Backend: clean build + tests (26 tests, expect BUILD SUCCESS)
cd backend && mvn -o test

# Mobile: static analysis (expect 0 errors)
cd mobile && flutter analyze
```

> Note: on this machine `mvn` fails from Git Bash (`ClassNotFoundException:
> org.codehaus.plexus.classworlds.launcher.Launcher`) because the shell wrapper passes POSIX
> paths to a Windows JVM, and `JAVA_HOME` is unset. Run Maven from PowerShell, or set
> `JAVA_HOME=C:\Program Files\Zulu\zulu-21` and invoke `mvn.cmd`.

---

## 7. Track-1 end-to-end testing (2026-09-12)

A device simulator (`scripts/she_e2e_track1.py`) drives the **real** stack — real step-ca,
real EMQX mTLS + ACL, real Spring Boot, real TimescaleDB — and exercises the five Phase-1
flows (BLE provisioning, telemetry + energy, param write, OTA, local control).

Result: **27/27 hardware-independent checks pass** (Test 5.4, the LAN toggle latency
measurement, needs a physical board).

Running it surfaced **seven additional production defects**, all now fixed. Six of them were
invisible to the unit tests and would have blocked Phase 1 exit criteria on real hardware.

| # | Defect | Impact | File(s) | Fix |
|---|---|---|---|---|
| D | **MQTT ingestion subscription used a regex alternation.** The backend subscribed to `$share/she-backend/she/+/+/+/+/(telemetry\|status\|params/local\|energy\|ota/status\|ota/progress)`. MQTT topic filters support only `+`/`#` — `(`, `\|`, `)` are literal characters, so the filter was an 8-level topic that matched nothing. EMQX also **denied the SUBSCRIBE** (`AUTHZ … authorization_permission_denied … action: SUBSCRIBE(Q1)`). | **Severe.** No telemetry, energy, `status`, `params/local` or OTA progress was ever ingested from any device. Only `config` arrived (it uses a plain filter), which masked the failure — `is_online` still flipped true because the `config` handler also sets presence. | `MqttSubscriberService.java`, `infra/emqx-acl/acl.conf` | Subscribe once per direction with plain `+` wildcards (both in `connect()` and `connectComplete()`); ACL now lists every direction explicitly in both the plain and `$share/<group>/` forms. |
| E | **`node_params.last_value` bound as SQL `boolean` against a `jsonb` column.** `NodeParamRepository.updateLastValue` was an HQL bulk update with `@Param("value") Object`. Hibernate resolves an HQL parameter's bind type from the *runtime* value class — a `Boolean` — and the entity's `@JdbcTypeCode(SqlTypes.JSON)` does **not** propagate to query parameters. | `PUT /nodes/{id}/devices/{did}/params` returned **HTTP 500** for every param write (`column "last_value" is of type jsonb but expression is of type boolean`). | `NodeParamRepository.java` | Native query with an explicit `CAST(:value AS jsonb)`, fed by a `default` method that serializes the value with Jackson. |
| F | **`NodeParam.lastValue` was typed `Object` with `@JdbcTypeCode(SqlTypes.JSON)`.** Hibernate cannot resolve a concrete `JavaType` for `Object`, so its JSON mapper casts the value to `String`. | **Severe.** Any device whose `config` reports an initial param value (`"value": true` — which `V3-MQTT-STANDARDS §8.1` shows as the normal case) threw `ClassCastException: BooleanNode cannot be cast to String`, rolling back the whole self-description transaction. **No devices, params or services were ever registered** from a real device's `config`. | `NodeParam.java` | Field retyped to `JsonNode`, which Jackson's format mapper handles natively. |
| G | **OTA authorization required `TENANT_ADMIN`.** `OtaService.requireTenantAdmin()` accepted only `TENANT_ADMIN` or a bypass-capable principal — but `V3-API-SPECIFICATION §9` specifies **home-level** roles (`POST batches` = OWNER, `start`/`approve` = ADMIN+, `abort` = OWNER). Registration sets `tenant_role = null` and only an admin can promote, so **no normally-registered user could ever create an OTA batch**. | OTA completely unusable (HTTP 403). | `OtaService.java`, `HomeService.java`, `HomeServiceImpl.java` | Added `HomeService.requireHomeAccess(homeId, minRole)` (delegating to the existing, already-correct `getAuthorizedHomeOrThrow`) and applied the spec's per-endpoint minimum roles. |
| H | **`OtaBatch.createdAt` was null when the response was built.** `@CreationTimestamp` is applied when the INSERT executes; with `GenerationType.UUID` the id is generated in memory, so `save()` merely registers the entity and defers the INSERT to commit. | `POST /ota/batches` threw `NullPointerException` in `toBatchResponse` → **HTTP 500**. | `OtaService.java` | `saveAndFlush(...)` so generated columns are populated before the response is mapped. |
| I | **step-ca serial/fingerprint were read from the `/sign` response, which does not return them.** `signDeviceCsr` used `resp.getOrDefault("serial", "")`, so every `device_certs` row got an **empty `cert_serial`**. | The second device ever provisioned failed with `409 CONFLICT_DEVICE_MAC_TAKEN: "Cert with serial  already exists"` — `cert_serial` has a UNIQUE constraint. Only one device could ever be provisioned. | `StepCaClient.java` | Derive serial and fingerprint from the issued certificate itself (`getSerialNumber()` / SHA-256 of the DER) — CA-shape independent and defense-in-depth. |
| J | **step-ca `/revoke` authenticated with Basic auth.** Same root cause as the `/sign` bug fixed earlier in this pass: the JWK provisioner requires a one-time token. | `POST /internal/ca/revoke` → step-ca `400 Bad Request`. **Certificate revocation never reached the CA**, so the CRL stayed empty and a retired or compromised device cert kept validating. | `StepCaClient.java` | Mint an ott bound to the serial (`sha = hex(sha256(serial))`, `aud = …/1.0/revoke`, no SANs), send the serial in the `0x`-prefixed form step-ca requires, and post `{serial, reason, ott}`. Also added a `postToCa` helper that surfaces step-ca's error body — the previous opaque `400 Bad Request` is what made this hard to diagnose. |

### 7.2 Revocation — RESOLVED (the root cause was not what this section first assumed)

Defect **J** was fixed on the backend side, yet revocation still failed with:

```
501 NOT_IMPLEMENTED: The requested method is not implemented by the certificate authority.
```

That message is actively misleading, and untangling it produced three further defects (K, L, M),
all now fixed.

#### Defect K — step-ca 0.27.x implements **passive revocation only**; `passive: true` is mandatory

`api/revoke.go` rejects every request that does not set the flag:

```go
func (r *RevokeRequest) Validate() (err error) {
	...
	if !r.Passive {
		return errs.NotImplemented("non-passive revocation not implemented")
	}
```

The backend never sent `passive`, so **every** revocation was rejected before the ott or the
serial were even examined. Verified directly against the CA:

| request body | result |
|---|---|
| `{serial, reason, ott}` — what the backend sent | **501** |
| `{serial, reason, passive:false, ott}` | **501** |
| `{serial, reason, passive:true, ott:"bogus"}` | **401** — `Validate()` passed, so it reached auth |

**Why the message was useless.** `errs.Errorf` unconditionally appends the *NotImplemented*
default message for **every** status code, overwriting the specific reason
(`certificates v0.27.4`, `errs/error.go:288-294`):

```go
func Errorf(code int, format string, args ...interface{}) error {
	as, opts := splitOptionArgs(args)
	opts = append(opts, withDefaultMessage(NotImplementedDefaultMsg))   // <- always
```

So `NotImplemented("non-passive revocation not implemented")` reaches the client as the generic
501 text. Diagnosing this required reading the step-ca source — the response alone is not
actionable.

**Fix:** `StepCaClient.revokeCert` now sends `"passive": true`.

#### Defect L — the CA had no `db` and no `crl` block, because the bootstrap's `jq` patches never ran

The live `ca.json` contained neither block. Root cause: `bootstrap-ca.sh` patched the config with
`jq`, but **`jq` is not in the `smallstep/step-ca` image** (Alpine 3.20.3) and the container runs
as uid 1000, so it cannot `apk add` one either. Under `set -e` the script aborted the instant
`jq` was missing — immediately after `step ca init` — and the container then booted from the
pristine `step ca init` config. (Corroborated by `"key"` still pointing at
`secrets/intermediate_ca_key` instead of the `certs/` path the script would have patched it to.)

Two more defects hid in that dead code path:

- it wrote `generateOnRestart`, a field that **does not exist** in step-ca — the real name is
  `generateOnRevoke` (`authority/config/config.go`, `CRLConfig`);
- the "initial CRL" step fell through to `echo "placeholder CRL" > crl.pem`, so nginx served a
  16-byte text file as `Content-Type: application/pkix-crl`.

**Fixes:**

- `bootstrap-ca.sh` no longer uses `jq` at all — a pure-shell `awk` patch rewrites
  `root`/`crt`/`key` and inserts correct `db` and `crl` blocks, guarded by structural sanity
  checks. Validated by running the script in a throwaway container and **booting step-ca with the
  result** (Badger store opens, `Serving HTTPS on :9000`).
- The misleading placeholder-CRL generation was removed; publication is `refresh-crl.sh`'s job.
- The **live** CA was reconfigured (backup retained at `/home/step/config/ca.json.bak-<ts>`):

  ```json
  "db":  { "type": "badgerv2", "dataSource": "/home/step/db", "badgerFileLoadingMode": "" },
  "crl": { "enabled": true, "generateOnRevoke": true, "cacheDuration": "6h",
           "renewPeriod": "4h", "idpURL": "http://localhost:8088/ca/<id>/crl.pem" }
  ```

  Safe to restart: the named volume `she-stepca-data` keeps the same key material, so existing
  device certs stay valid — verified by comparing the intermediate key's public key against
  `certs/intermediate_ca.crt` (match) and `openssl verify` of the root→intermediate chain (OK).

#### Defect M — `refresh-crl.sh` could not publish anything

- It read `intermediate_id.txt` from `infra/.ca-certs/`, which **does not exist** — the file is
  written to the `she-ca-certs` volume, so the script aborted at its own preflight.
- It wrote to `/var/lib/docker/volumes/she-v3_she-ca-certs/_data`, unreachable from Docker
  Desktop on Windows/macOS.
- Its endpoint list was wrong: step-ca serves the CRL at **`GET /crl`** (and `/1.0/crl`);
  `/crl/{id}` and `/1/crl` both return 404.

**Fix:** it now resolves the intermediate id from the volume and publishes by fetching *inside*
the step-ca container (`docker exec -u 0 …` — the volume's `ca/` directory is root-owned while
the image user is uid 1000), with a host-volume fallback for bare-metal Linux.

#### Verification — `scripts/she_e2e_revocation.py`, 13/13

| check | result |
|---|---|
| `POST /internal/ca/sign-and-register` | HTTP 200, serial issued |
| `POST /internal/ca/revoke` | **HTTP 200** `{"status":"revoked"}` |
| `device_certs` row | `REVOKED` + `revoked_at` + `revoke_reason` |
| step-ca CRL number | `0 → 1 → 2` |
| revoked serial listed | yes — in step-ca's CRL **and** the nginx-published one |
| published CRL number == CA's | yes |
| CRL validity window | 6 h, matching `cacheDuration` |

**Phase-1 exit criterion 2 is met**: the CA issues, revokes, and both CRL endpoints serve.

> Note: EMQX does **not** consume a CRL — its TLS listener is configured with `verify_peer` +
> `ca_bundle.pem` (chain validation only), and there is no CRL/OCSP setting anywhere in
> `infra/`. Revocation is enforced by the HTTP auth callback
> (`/internal/mqtt/auth` → `{"result":"deny","reason":"cert_revoked"}`), with a 300 s cache TTL.
> The CRL is therefore a publication/compliance artifact, not the enforcement path.

### 7.3 Test-harness defect (not a product bug)

The simulator computed the firmware checksum with `sha256sum`. On Git Bash for Windows GNU
coreutils prefixes the output line with a backslash when the filename contains backslashes,
so `sha256sum "C:\…"` yielded a 65-character `\<hash>` that failed the backend's
`@Size(max = 64)` on `firmware_checksum` — producing a spurious HTTP 400. Replaced with
Python `hashlib.sha256`.

### 7.4 Known remaining gap (needs physical hardware)

- **ESP32-WROOM-32D not detectable.** The CH340 bridge enumerates on COM4 but esptool fails
  in every reset mode and a raw serial read returns **0 bytes**, so the board is either not
  powered, not in the right mode, or the cable is charge-only. Firmware-in-the-loop
  validation (Test 1 BLE provisioning, Test 5.4 LAN toggle + <500 ms latency) is blocked
  until it responds.
- `infra/ca/step-ca-provisioner-password.txt` is **committed to git** (pre-existing). It
  should be moved to a secret store and rotated.

### 7.5 Row-Level Security was entirely inert — RESOLVED (2026-09-12)

This section originally recorded a single defect, **N**: `she_app` is a superuser, so every RLS
policy is bypassed. Pulling that thread uncovered **four** independent defects, each on its own
sufficient to disable tenant isolation. All four are fixed, and isolation is now proven by a new
test (`scripts/she_e2e_rls_isolation.py`, 10/10).

| # | Defect | Evidence | Fix |
|---|---|---|---|
| **N1** | **`she_app` was the bootstrap superuser.** `infra/docker-compose.yml` set `POSTGRES_USER: ${POSTGRES_USER:-she_app}`, and the official image creates `POSTGRES_USER` as a superuser (OID 10). Superusers skip RLS unconditionally, so "not granting BYPASSRLS" in the init script changed nothing. Postgres additionally **refuses to demote** that role: `ERROR: The bootstrap user must have the SUPERUSER attribute.` | `SELECT oid, rolname, rolsuper FROM pg_roles` → `10 \| she_app \| t`; `ALTER ROLE she_app NOSUPERUSER` → permission denied. | Split the roles. OID 10 was renamed to `she_superuser` (bootstrap/ops) and `she_app` recreated as `NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE` with explicit grants (only `flyway_schema_history` was ever missing one, and Flyway connects as `she_migrate`). `docker-compose.yml` now defaults `POSTGRES_USER` to `she_superuser`, and `01-bootstrap-roles.sql` creates `she_app` itself and **aborts the bootstrap** if it is OID 10 or still privileged. |
| **N2** | **`TenantContextAspect` ran OUTSIDE the transaction.** It was pinned `@Order(HIGHEST_PRECEDENCE)`; Spring's transaction interceptor defaults to `LOWEST_PRECEDENCE`, and a *lower* order value wraps *outermost*. Its `SET LOCAL` therefore ran before `BEGIN` — Postgres logged `WARNING: SET LOCAL can only be used in transaction blocks` and discarded it. The class comment asserting this placed it "INSIDE the @Transactional proxy" had the ordering backwards. | With `log_statement=all`: `SET LOCAL app.tenant_id` → `WARNING` → `SET LOCAL app.is_platform_admin` → `WARNING` → **then** `BEGIN READ ONLY`. | `config/TransactionConfig` pins the transaction advisor to `HIGHEST_PRECEDENCE`; the aspect moved to `HIGHEST_PRECEDENCE + 10`, i.e. inside it. Re-measured: `BEGIN READ ONLY` → `SET LOCAL` (no warning) → `COMMIT`. |
| **N3** | **The pointcut missed class-level `@Transactional`.** `@annotation(Transactional)` matches only an annotation written *on the method*, but most services declare it once per class. Those methods were still transactional, yet the aspect never ran for them, so their GUCs were never set. | After N2 was fixed, `PUT /nodes/{id}/devices/{id}/params` and `POST /ota/batches/{id}/start` still returned 404 (row invisible → "not found"), while methods carrying a *direct* `@Transactional` worked. | Pointcut is now `@annotation(…) \|\| @within(…)`. |
| **N4** | **Policy text was not NULL-safe.** `current_setting('app.tenant_id', true)::uuid` returns `NULL` before the GUC is ever touched, but the **empty string** once it has been — and the placeholder then persists for the life of a pooled connection. `''::uuid` is a hard error, not a deny. | Fresh session: `current_setting('app.tenant_id', true)` → `NULL`. Same session after any `SET LOCAL` + `COMMIT` → `''` (length 0). Then `SELECT … FROM device_certs` → `ERROR: invalid input syntax for type uuid: ""` (22P02). | Migration **V30** rebuilds all 25 policies as `NULLIF(current_setting('app.tenant_id', true), '')::uuid OR COALESCE(NULLIF(current_setting('app.is_platform_admin', true), '')::boolean, false)`, preserving each table's `OR tenant_id IS NULL` allowance and the USING/WITH CHECK asymmetry on `nodes` / `node_devices` / `node_params`. |

**Fallout fixed while switching enforcement on** — each was a latent production bug that the
superuser bypass had concealed:

- `AuthServiceImpl.register()` / `login()` read `tenants` *before* setting `app.tenant_id`, a
  chicken-and-egg that made the lookup return zero rows ("Default B2C tenant not seeded"). Added
  `TenantContextInterceptor#setRlsGucsForTenantLookup()` to open a platform-admin window for
  that single read.
- `MqttSubscriberService.processMessageWithRls()` was annotated `@Transactional` but called from
  `messageArrived` **in the same class** — self-invocation bypasses the Spring proxy, so no
  transaction existed and the GUC was discarded. Now driven by an explicit `TransactionTemplate`.
  This was silently dropping **all** device telemetry and energy data (log filled with
  "telemetry from unknown MAC").
- `EnergyService` had no `@Transactional` at all, and `EnergyController` reads `nodeRepository`
  directly (outside any transaction). Both now run inside one.

**Verification** — every suite re-run with `she_app` as a non-superuser:

| Suite | Result |
|---|---|
| `scripts/she_e2e_track1.py` | **27/27** |
| `scripts/she_e2e_revocation.py` | **13/13** |
| `scripts/she_e2e_rls_isolation.py` (new) | **10/10** |

The isolation test proves both directions: as `she_app` with a tenant GUC, tenant B's rows are
invisible (0); with the platform-admin GUC they are visible (1); and a warmed session no longer
raises 22P02.

> **Note:** both e2e harnesses previously verified their own DB assertions as `she_app`. Now that
> the role is RLS-restricted they verify as `she_superuser` (a privileged observer) — otherwise
> the harness would report 0 rows for data the application had written correctly.

### 7.6 Fallout from N1 — the nightly retention job — RESOLVED (2026-09-12)

Auditing every `@Scheduled` method against the now-enforced RLS turned up a defect that N1 had
been masking.

**Defect R — `ScheduledJobs.enforceRetention()` could not drop chunks, and never needed to.**

It called `drop_chunks()` directly on `device_telemetry`, `device_energy_readings` and `audit_log`.
Once `she_app` stopped being a superuser this failed immediately, because `drop_chunks()` requires
hypertable **ownership** and all three hypertables are owned by `she_migrate`:

```
SELECT drop_chunks('device_telemetry', INTERVAL '36500 days');
ERROR:  must be owner of hypertable "device_telemetry"
```

The `catch (Exception e)` around it swallowed the failure, so retention silently did nothing while
the log looked busy — the same false-success shape as defect O. Granting `she_app` ownership would
have been the wrong fix (the owner is exempt from policies unless `relforcerowsecurity` is on, and
it would hand the app role DDL rights over the hypertables).

**Retention was already fully handled elsewhere.** Migrations V18, V23 and V24 each call
`add_retention_policy`, and all three TimescaleDB background jobs are present and scheduled:

| job | hypertable | `drop_after` | owner |
|---|---|---|---|
| 1000 | `audit_log` | 730 days | `she_migrate` |
| 1001 | `device_telemetry` | 30 days | `she_migrate` |
| 1002 | `device_energy_readings` | 365 days | `she_migrate` |

Those run inside the TimescaleDB background worker as the owner, which is exactly the role that is
allowed to drop chunks. The application job was a redundant duplicate.

**Fix — `enforceRetention()` is now an assertion, not a duplicate worker.** It no longer needs
ownership or a GUC (it reads `timescaledb_information.jobs`, an unprotected view). It verifies a
retention policy exists *and* is scheduled *and* carries the expected window for each table, and
logs `ERROR` if any is missing — so a dropped retention policy is now a loud alarm instead of
silent unbounded growth.

**The other two scheduled jobs were already correct** and were left alone:
`verifyAuditLogHashChain()` and `EnergyService.detectAnomalies()` both carry `@Transactional` plus
an explicit `SET LOCAL app.is_platform_admin = 'true'`. `logCompressionStats()` reads
`timescaledb_information.chunks`, which is not RLS-protected. Confirmed that no
`SecurityContextHolder` strategy is overridden (default `MODE_THREADLOCAL`), so scheduler threads
cannot inherit a request's tenant context.

**Cleanup:** the diagnostic role `she_rls_probe` (login role, SELECT on `tenants`/`nodes`/`users`/
`device_certs`, created while proving N1) was dropped from the local database.

### 7.7 Defect O — `CaController.refreshCrl()` false success — RESOLVED (2026-09-12)

The job *published* the CRL by stripping the scheme+host off `ca.crl-publish-base-url` and treating
the remainder as a filesystem directory — conflating a URL with a path. With the default
`http://localhost:8088/ca` it created `\ca\default\crl.pem` and logged `INFO CRL refreshed`. Note
`default` rather than the real intermediate id: `readIntermediateId()` looked for
`<intermediateCertPath>/../intermediate_id.txt`, missed, and returned the literal `"default"`. No
topology mounts the ca-certs volume into the backend, so the write target was unreachable
everywhere — a silent false success, plus litter on the host filesystem.

**Key discovery — the intermediate id is derivable, so no new config is needed.** step-ca names the
intermediate directory after the **first 16 hex chars of the SHA-256 of the DER-encoded intermediate
certificate**. Verified against the live CA:

```
sha256(/home/step/certs/intermediate_ca.crt, DER) = 4746eb60a64abb7e7a66c68d390a58e…
published path                                    = /ca-certs-output/ca/4746eb60a64abb7e/crl.pem
```

**Fix.** `refreshCrl()` no longer writes anywhere. Publication stays with `refresh-crl.sh`/cron —
the documented mechanism and the only component that can write the root-owned volume. The job now
**verifies**: it fetches step-ca's current CRL and the published copy at
`<crl-publish-base-url>/<intermediate-id>/crl.pem`, and logs `INFO` on a byte-for-byte match or
`WARN … CRL publication is STALE` when they diverge, so a stalled publisher is an alarm instead of
silence. `readIntermediateId()` prefers `intermediate_id.txt`, then derives the fingerprint from the
certificate, and now **throws** instead of returning `"default"` when neither is available.

**Verified** before recompiling: `https://localhost:9002/crl` and
`http://localhost:8088/ca/4746eb60a64abb7e/crl.pem` are byte-identical (491 bytes, both
`sha256:84e950c4…`), so the new code path reaches the real published CRL.

### 7.8 Defect P — fresh CA bootstrap could not write the volume — RESOLVED (2026-09-12)

Docker creates a named volume's root as `root:root 0755`, but the step-ca image runs as uid 1000
(`User=step`). The bootstrap's **first** write is `cat > /ca-certs-output/ca_bundle.pem`
(`bootstrap-ca.sh:255`), so on a brand-new volume it died immediately and EMQX and the backend came
up with no `ca_bundle.pem` / `server.crt`. This was masked locally only because the volume was
first populated on 2026-08-09.

**Fix — a one-shot init service** (`ca-certs-init` in `infra/docker-compose.yml`) that runs as
`user: "0:0"` purely to `chown -R 1000:1000 /ca-certs-output`, then exits. `step-ca` now
`depends_on` it with `condition: service_completed_successfully`. Running the CA as root was the
alternative and was rejected.

**Deliberately no `chmod`.** `server.key` lives in this volume at `0600`, so a recursive `a+rX`
would have published the EMQX private key to nginx. Ownership alone is sufficient because the files
that must be world-readable already are (`0644`) — verified after the change: `server.key` is still
`-rw-------` while `step` can now write.

Verified: `touch /ca-certs-output/.write-probe` as `step` went from **Permission denied** to
**WRITABLE**; `docker compose config` clean; all three suites still green.

### 7.9 Four tenant-scoped tables had no RLS at all — RESOLVED (migration V31)

V30 could only rebuild policies on tables that already had RLS switched on. A catalogue sweep of
every `public` table with a `tenant_id` column found four that did not:

| table | `tenant_id` | rows | used by app code |
|---|---|---|---|
| `device_energy_readings` | NOT NULL | 43 | yes — raw SQL in `EnergyService` |
| `blacklisted_tokens` | nullable | 0 | no |
| `node_group_members` | NOT NULL | 0 | no |
| `scene_actions` | NOT NULL | 0 | no |

`device_energy_readings` is the material one: a hypertable of per-device energy/cost telemetry with
**no JPA entity**, so RLS is the only thing that can constrain it. Every current query does remember
`WHERE tenant_id = ?`, so this was **not an active leak** — but it was one forgotten predicate away
from one, while the other 26 tenant tables were all protected. The other three are unused today and
were included so a future repository cannot be written against an unprotected table.

Migration **V31** enables + forces RLS on all four and creates the same NULL-safe `tenant_isolation`
policy V30 uses. `blacklisted_tokens` keeps `OR tenant_id IS NULL` on the USING side (a global
blacklist entry must be visible to everyone) but **not** on WITH CHECK, so minting a global entry
requires the platform-admin GUC.

Verified: as `she_app`, `device_energy_readings` returns **0** rows under a non-owner tenant GUC and
**43** under the platform-admin GUC. Both continuous aggregates (`energy_hourly`, `energy_daily`)
still refresh over the now-protected hypertable, and all three suites stayed green.

**Residual, documented not fixed:** the continuous aggregates themselves
(`energy_hourly`, `energy_daily`) carry `tenant_id`/`node_id` but are **not** RLS-protected —
Postgres has no RLS on views, and enabling it on TimescaleDB's internal materialization hypertable
is unsupported. They are not queried by application code today (`EnergyService` reads the raw
hypertable, because the aggregate lags ~1h), so the exposure is latent rather than live. The
stale javadoc claiming otherwise was corrected.

### 7.10 `automation_rules` — inherited-scope RLS — RESOLVED (migration V32)

The one tenant-scoped table left after V31 had no `tenant_id` of its own: it hangs off
`automation_id → automations(id)`, and `automations` is already protected. V32 gives it an
**inherited-scope** policy — a rule is visible iff its parent automation is:

```sql
automation_id IN (SELECT id FROM public.automations)
OR COALESCE(NULLIF(current_setting('app.is_platform_admin', true), '')::boolean, false)
```

The subquery runs against `automations`, whose own `tenant_isolation` policy applies to it, so the
two compose rather than duplicating the predicate: with no GUC the subquery matches nothing; with a
tenant GUC only that tenant's rules; with platform-admin the `OR` branch passes. No recursion risk
— the policy references `automations`, never itself.

The table is unused by application code, so this is defence in depth, as with `node_group_members`
and `scene_actions`.

**Coverage sweep is now clean:**

```sql
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity = false
  AND EXISTS (SELECT 1 FROM information_schema.columns i
              WHERE i.table_schema = 'public' AND i.table_name = c.relname
                AND i.column_name = 'tenant_id');
-- 0 rows
```

### 7.11 Test-harness robustness

`scripts/she_e2e_revocation.py` produced one **11/13** run (R5.2 + R6.3) immediately after the
volume work, then 13/13 on the next five runs. step-ca's `/crl` response is cached
(`crl.cacheDuration`) and CRL generation on revoke is asynchronous, so a single read right after
revoking can legitimately return the previous CRL. The harness now **polls for up to 20 s** for the
serial to appear instead of racing it, so a real regression cannot be masked by a timing flake.

### 7.12 The audit trail did not exist — RESOLVED (P1-19)

P1-19 is a locked canonical decision: `audit_log` must be "a tamper-evident hash chain via
`hash`/`prev_hash`/`sequence_number`". PHASE1-SIGNOFF recorded it as delivered —
`V18__audit_log.sql` plus `ScheduledJobs.verifyAuditLogHashChain()`.

**Two independent defects meant none of it was real.**

**(a) Nothing ever wrote to `audit_log`.** There is no `Audit` entity, repository or service
anywhere in the codebase; the only reference outside the verifier was a
`// TODO: insert audit_log row …` in `EnergyService`. The table was permanently empty, so the
nightly job reported `verified: 0 tenants, 0 mismatches` — a compliance control that silently
recorded nothing while reporting success.

**(b) The verifier could not detect tampering anyway.** V3-DATABASE-DESIGN §5.10 defines
`hash = SHA-256(prev_hash || canonical JSON of this row)`. The job only compared each row's
`prev_hash` with the previous row's `hash` **linkage**, and never recomputed `hash` from the row's
content. So anyone with DB write access could edit a row's `action`, `details` or `target_id` in
place and the chain would still "verify". That is not tamper-*evident*.

**Fix.**

- New `audit/AuditService` appends hash-chained rows in their **own transaction** (`REQUIRES_NEW`)
  under the platform-admin GUC, so an entry survives a failed business operation and is not filtered
  by the caller's tenant context. It derives `sequence_number` per tenant and computes
  `hash = SHA-256(prev_hash || canonical JSON)`.
- The **canonical form is defined once and shared** with the verifier: a JSON object with a fixed
  key order, nulls rendered as `""`, `details` re-serialised with recursively sorted keys (so JSONB's
  key order cannot change the digest), and `created_at` excluded (its text form varies by driver and
  timezone, which would make the hash irreproducible).
- `verifyAuditLogHashChain()` now recomputes each row's `hash` from that same canonical form **in
  addition to** the linkage check, and reports `hash does not match row content; the row was
  modified in place`.
- Wired to the privileged actions the specs call out: `auth.register`, `auth.login.success`,
  `auth.login.failed`, `ca.cert.revoked`, `ota.batch.started`, `node.param.write`. Each records the
  target and the parameters actually applied (not just that an action happened) — e.g.
  `node.param.write` stores the device name → param → value map that was pushed to the device.

**Verified end to end** (with a temporary fast cron, then reverted):

| step | result |
|---|---|
| 3 real registrations through `POST /api/v3/auth/register` | rows at `sequence_number` 1,2,3 with `prev_hash` correctly equal to the previous row's `hash` |
| nightly job on that data | `Audit log hash chain verified: 1 tenants, 0 mismatches` |
| `UPDATE audit_log SET details = … ` on one row, chain columns untouched | `AUDIT LOG HASH CHAIN MISMATCH … hash does not match row content; the row was modified in place (SECURITY_ALERT)` — **1** mismatch, exactly the tampered row |
| the same tamper before this change | undetected (linkage was intact) |

The canonical form was additionally reproduced independently in Python and matches the stored digest
byte-for-byte, confirming the writer is self-consistent.

Two bugs were found and fixed while proving this: `queryForMap()` throws
`EmptyResultDataAccessException` on a tenant's *first* entry (now `queryForList`), and the verifier's
per-row query selected only `id, sequence_number, prev_hash, hash, details`, so every other canonical
field was silently `""` and every row looked tampered.

**Coverage after wiring.** Running the e2e harnesses end to end produced a real, correctly linked
chain spanning all wired event types:

```
 sequence_number |      action       | link
-----------------+-------------------+------
               1 | auth.register     | ok
               2 | node.param.write  | ok
               3 | node.param.write  | ok
               4 | ota.batch.started | ok
               5 | ca.cert.revoked   | ok
```

**Still to do:** home/member management, scene and automation changes, billing and platform-admin
actions are not yet audited. The chain is sound and the writer is proven; extending it is now a
one-line `auditService.record(...)` per action.

### 7.13 Status

All defects found during this pass are now resolved, and every tenant-scoped table in `public` has
row-level security enforced (V30 rebuilt the policies, V31 covered the four tables that had none,
V32 covers `automation_rules` by inherited scope).

**Verification snapshot** — all with `she_app` as a genuine non-superuser:

| Suite | Result |
|---|---|
| `scripts/she_e2e_track1.py` | **27/27** |
| `scripts/she_e2e_revocation.py` | **13/13** |
| `scripts/she_e2e_rls_isolation.py` | **10/10** |
| backend unit/integration tests (`mvn test`) | **26/26**, BUILD SUCCESS |
| `flutter analyze` | **0 errors** (3 warnings, 16 infos) |

**Remaining work, outside the scope of this report:**

- **Extend audit coverage.** `auth.*`, `ca.cert.revoked`, `ota.batch.started` and
  `node.param.write` are wired (§7.12). Home/member management, scenes, automations, billing and
  platform-admin operations still need `record(...)` calls.
- Rotate the CA provisioner password — it is still in git history from the initial commit and must
  be rotated before any real deployment.
- Flash the ESP32-WROOM-32D. Not dead: it is a CH340 on COM4 and it emits the ROM banner at 115200
  baud once EN is pulsed correctly. esptool cannot complete a sync at any baud, so the PC→board
  direction looks broken — try a known-good data cable. Before flashing, check `esptool flash_id`:
  `build-esp32d` is laid out for 8 MB, but a WROOM-32D is often 4 MB. See §5b of the
  local-verification skill.
- The continuous aggregates `energy_hourly` / `energy_daily` carry `tenant_id` but cannot carry RLS
  (§7.9). Latent only — nothing queries them today.


