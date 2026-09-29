package et.she.v3.mqtt;

import et.she.v3.config.SheProperties;
import et.she.v3.entity.DeviceCert;
import et.she.v3.errors.SheException;
import et.she.v3.repository.DeviceCertRepository;
import et.she.v3.security.TenantContextInterceptor;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import jakarta.validation.Valid;
import java.util.Optional;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * EMQX HTTP auth/ACL backend endpoints (V3-SECURITY-MODEL §4.2 + §4.3).
 *
 * These endpoints are called by EMQX (NOT by external clients). They are not
 * exposed via Cloudflare in production — only reachable from the VPC private
 * subnet. They are protected by a shared `X-Internal-Token` header.
 *
 * Auth flow (V3-SECURITY-MODEL §4.2):
 *   1. Device connects to EMQX :8883 with mTLS
 *   2. EMQX extracts cert fingerprint (sha256 of DER)
 *   3. EMQX POST /internal/mqtt/auth { clientid, cn, fingerprint }
 *   4. Spring Boot SELECT FROM device_certs WHERE fingerprint = ? AND status = 'ACTIVE'
 *   5. Returns {result: "allow", is_superuser: false} or {result: "deny", reason: "..."}
 *
 * ACL flow (V3-SECURITY-MODEL §4.3):
 *   1. Device attempts to publish/subscribe to a topic
 *   2. EMQX POST /internal/mqtt/acl { clientid, topic, action }
 *   3. Spring Boot verifies the topic segments match the device's identity:
 *      - she/{tenant_id}/{home_id}/{room_id}/{node_mac}/{direction}
 *      - {node_mac} segment must equal clientid (device MAC)
 *   4. Returns {result: "allow"} or {result: "deny", reason: "mac_mismatch"}
 *
 * P1-11: EMQX caches auth responses for 300s — must be idempotent.
 * P1-10: is_superuser is ALWAYS false — no blanket ACL bypass.
 */
@RestController
@RequestMapping("/internal/mqtt")
public class MqttAuthController {

    private static final Logger log = LoggerFactory.getLogger(MqttAuthController.class);
    // The direction segment may itself contain slashes: "params/remote",
    // "params/local", "ota/url", "ota/status", "ota/progress". Capturing it with
    // [^/]+ truncated multi-segment directions to their first element ("params",
    // "ota"), which then failed isDirectionAllowed() and denied the subscribe for
    // every device — the firmware subscribes to she/.../params/remote at boot
    // (she_mqtt.c). Match the whole tail greedily instead.
    private static final Pattern TOPIC_PATTERN = Pattern.compile(
            "^she/(?<tenant>[^/]+)/(?<home>[^/]+)/(?<room>[^/]+)/(?<mac>[^/]+)/(?<direction>.+)$"
    );

    private final DeviceCertRepository deviceCertRepository;
    private final SheProperties props;
    private final TenantContextInterceptor tenantContextInterceptor;

    public MqttAuthController(DeviceCertRepository deviceCertRepository,
                              SheProperties props,
                              TenantContextInterceptor tenantContextInterceptor) {
        this.deviceCertRepository = deviceCertRepository;
        this.props = props;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    // =========================================================================
    // /internal/mqtt/auth — cert fingerprint verification
    // =========================================================================

    @PostMapping("/auth")
    @org.springframework.transaction.annotation.Transactional
    public ResponseEntity<MqttAuthDtos.AuthResponse> authenticate(
            @Valid @RequestBody MqttAuthDtos.AuthRequest req,
            HttpServletRequest httpReq) {

        verifyInternalToken(httpReq);

        // Strip "sha256:" prefix if EMQX sends it
        String fingerprint = req.fingerprint();
        if (fingerprint != null && fingerprint.startsWith("sha256:")) {
            fingerprint = fingerprint.substring("sha256:".length());
        }

        // Look up the device cert.
        // EMQX 5.x has NO cert-fingerprint placeholder for HTTP authn bodies — only
        // ${clientid} / ${cert_common_name} / ${cert_subject}. So when EMQX can't supply a
        // fingerprint it sends an empty one and we fall back to the CN (normalized MAC)
        // lookup. The mTLS chain is still verified by EMQX itself (verify_peer), so the CN
        // comes from the verified client cert. When a fingerprint IS provided it stays the
        // primary key (defense-in-depth).
        //
        // RLS chicken-and-egg: we don't yet know the tenant_id (we're trying to find it
        // via the cert). The RLS policy allows reads when `app.is_platform_admin='on'`,
        // which is safe here because:
        //   1. The query is a tenant-agnostic lookup (returns 0 or 1 row)
        //   2. The result is only used to decide ALLOW/DENY — no tenant data is leaked
        //   3. The endpoint is internal (not exposed via Cloudflare) and protected by
        //      X-Internal-Token verification
        // We use a sentinel UUID for tenant_id (the policy checks `id = tenant_id OR is_platform_admin`,
        // so the sentinel won't match any real tenant — only the platform_admin branch allows the read).
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        Optional<DeviceCert> certOpt = (fingerprint != null && !fingerprint.isBlank())
                ? deviceCertRepository.findActiveByFingerprint(fingerprint)
                : deviceCertRepository.findActiveByCn(req.cn());
        DeviceCert cert = certOpt.orElseThrow(() -> {
            log.debug("MQTT auth DENY: cert not found or inactive — cn={}", req.cn());
            return new SheException("CERT_NOT_FOUND",
                    "Device cert not found", 403);
        });

        // Verify clientid == CN == normalized MAC (defense-in-depth)
        if (!req.clientid().equals(req.cn())) {
            log.warn("MQTT auth DENY: clientid != cn — clientid={}, cn={}", req.clientid(), req.cn());
            return ResponseEntity.ok(MqttAuthDtos.AuthResponse.deny("clientid_cn_mismatch"));
        }
        if (!req.cn().equalsIgnoreCase(cert.getCn())) {
            log.warn("MQTT auth DENY: cn mismatch — expected={}, got={}", cert.getCn(), req.cn());
            return ResponseEntity.ok(MqttAuthDtos.AuthResponse.deny("cn_mismatch"));
        }

        log.debug("MQTT auth ALLOW: cn={}, tenant_id={}", cert.getCn(), cert.getTenantId());
        return ResponseEntity.ok(MqttAuthDtos.AuthResponse.allow());
    }

    // =========================================================================
    // /internal/mqtt/acl — per-device topic authorization
    // =========================================================================

    @PostMapping("/acl")
    @org.springframework.transaction.annotation.Transactional
    public ResponseEntity<MqttAuthDtos.AclResponse> authorize(
            @Valid @RequestBody MqttAuthDtos.AclRequest req,
            HttpServletRequest httpReq) {

        verifyInternalToken(httpReq);

        Matcher m = TOPIC_PATTERN.matcher(req.topic());
        if (!m.matches()) {
            log.warn("MQTT acl DENY: topic doesn't match namespace — topic={}", req.topic());
            return ResponseEntity.ok(MqttAuthDtos.AclResponse.deny("invalid_topic_format"));
        }

        String topicMac = m.group("mac");
        String direction = m.group("direction");

        // Verify the {node_mac} segment in the topic matches the clientid (device MAC)
        // V3-SECURITY-MODEL §4.3 — all 4 checks must pass:
        //   1. {node_mac} == clientid
        //   2. {tenant_id} matches device's actual tenant_id
        //   3. {home_id} matches device's actual home_id
        //   4. {direction} is in the device's allowed list
        if (!topicMac.equalsIgnoreCase(req.clientid())) {
            log.warn("MQTT acl DENY: mac_mismatch — topic_mac={}, clientid={}", topicMac, req.clientid());
            return ResponseEntity.ok(MqttAuthDtos.AclResponse.deny("mac_mismatch"));
        }

        // Verify the direction is in the allowed list for the requested action
        boolean isPublish = "publish".equals(req.action());
        if (!isDirectionAllowed(direction, isPublish)) {
            log.warn("MQTT acl DENY: direction not allowed — direction={}, action={}", direction, req.action());
            return ResponseEntity.ok(MqttAuthDtos.AclResponse.deny("direction_not_allowed"));
        }

        // NOTE: In Phase 0 we do NOT yet have the `nodes` table (that comes in V26).
        // So we cannot verify the {tenant_id}/{home_id} segments against the device's
        // actual tenant/home. We rely on:
        //   - EMQX's file-based ACL (which restricts the topic pattern to she/+/+/+/${clientid}/...)
        //   - The device cert being ACTIVE (verified in /auth above)
        //   - The MAC match (verified here)
        // Phase 1 will add the full tenant/home check via the nodes table.

        log.debug("MQTT acl ALLOW: clientid={}, topic={}, action={}", req.clientid(), req.topic(), req.action());
        return ResponseEntity.ok(MqttAuthDtos.AclResponse.allow());
    }

    /**
     * V3-SECURITY-MODEL §4.3 — direction × action matrix for devices.
     *
     * (The backend service cert CN="she-backend" has its own ACL rules in EMQX's
     * file-based source — those are NOT checked here, only device ACLs.)
     */
    private boolean isDirectionAllowed(String direction, boolean isPublish) {
        return switch (direction) {
            // Device PUBLISH directions
            case "config", "params/local", "telemetry", "status", "energy",
                 "ota/status", "ota/progress" -> isPublish;
            // Device SUBSCRIBE directions
            case "command", "params/remote", "ota/url" -> !isPublish;
            // Unknown direction — deny
            default -> false;
        };
    }

    /**
     * Verify the X-Internal-Token header — proves the call comes from EMQX
     * (which knows the shared secret), not from an external client that
     * somehow reached the /internal/* endpoint.
     *
     * In production, /internal/* is also protected by network ACL (not exposed
     * to Cloudflare). This header check is defense-in-depth.
     */
    private void verifyInternalToken(HttpServletRequest req) {
        String token = req.getHeader("X-Internal-Token");
        String expected = props.mqtt().internalToken();
        if (expected == null || expected.isBlank()) {
            // Misconfiguration — fail-closed
            log.error("INTERNAL_MQTT_TOKEN env var not set — refusing /internal/mqtt/* call");
            throw new SheException("INTERNAL_ERROR", "Internal token not configured", 500);
        }
        if (token == null || !token.equals(expected)) {
            log.warn("/internal/mqtt/* call with invalid or missing X-Internal-Token");
            throw new SheException("AUTH_TOKEN_INVALID", "Invalid internal token", 401);
        }
    }
}
