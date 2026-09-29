package et.she.v3.mqtt;

import jakarta.validation.constraints.NotBlank;

/**
 * EMQX HTTP auth/ACL request bodies (V3-SECURITY-MODEL §4.2 + §4.3, V3-ARCHITECTURE §6.2).
 *
 * EMQX POSTs to /internal/mqtt/auth with the cert CN + fingerprint + clientid.
 * EMQX POSTs to /internal/mqtt/acl with the topic + action + clientid.
 */
public class MqttAuthDtos {

    /**
     * EMQX → Spring Boot auth request (V3-SECURITY-MODEL §4.2).
     * <pre>
     * POST /internal/mqtt/auth
     * { "clientid": "aabbccddeeff", "cn": "aabbccddeeff", "fingerprint": "sha256:ab12cd34..." }
     * </pre>
     *
     * `fingerprint` is deliberately NOT @NotBlank. EMQX 5.x exposes no
     * cert-fingerprint placeholder for HTTP authn bodies (only ${clientid},
     * ${cert_common_name}, ${cert_subject}), so it always sends "" here. Requiring
     * a non-blank value made every device CONNECT fail 400 at the @Valid gate —
     * before the controller's empty-fingerprint→CN fallback could run — which
     * silently denied the whole fleet. See MqttAuthController.authenticate().
     */
    public record AuthRequest(
            @NotBlank String clientid,
            @NotBlank String cn,
            String fingerprint
    ) {}

    /**
     * Spring Boot → EMQX auth response.
     * <pre>
     * 200 OK    { "result": "allow", "is_superuser": false }
     * 403       { "result": "deny",  "reason": "cert_revoked" }
     * </pre>
     *
     * `is_superuser` is ALWAYS false (P1-10 — no blanket ACL bypass for backend or devices).
     */
    public record AuthResponse(
            String result,             // "allow" | "deny"
            boolean is_superuser,      // always false per P1-10
            String reason              // populated when result = "deny"
    ) {
        public static AuthResponse allow() { return new AuthResponse("allow", false, null); }
        public static AuthResponse deny(String reason) { return new AuthResponse("deny", false, reason); }
    }

    /**
     * EMQX → Spring Boot ACL request (V3-SECURITY-MODEL §4.3).
     * <pre>
     * POST /internal/mqtt/acl
     * { "clientid": "aabbccddeeff", "topic": "she/.../params/remote", "action": "subscribe" }
     * </pre>
     */
    public record AclRequest(
            @NotBlank String clientid,
            @NotBlank String topic,
            @NotBlank String action     // "subscribe" | "publish"
    ) {}

    /**
     * Spring Boot → EMQX ACL response.
     * <pre>
     * 200 OK    { "result": "allow" }
     * 403       { "result": "deny",  "reason": "mac_mismatch" }
     * </pre>
     */
    public record AclResponse(String result, String reason) {
        public static AclResponse allow() { return new AclResponse("allow", null); }
        public static AclResponse deny(String reason) { return new AclResponse("deny", reason); }
    }
}
