package et.she.v3.mqtt;

import et.she.v3.config.SheProperties;
import et.she.v3.entity.DeviceCert;
import et.she.v3.errors.SheException;
import et.she.v3.repository.DeviceCertRepository;
import et.she.v3.security.TenantContextInterceptor;
import jakarta.servlet.http.HttpServletRequest;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;

import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/**
 * Unit tests for {@link MqttAuthController}.
 *
 * V3-SECURITY-MODEL §4.2 (auth) + §4.3 (ACL).
 * P1-10: is_superuser always false. P1-11: cache TTL 300s (idempotent).
 */
class MqttAuthControllerTest {

    private DeviceCertRepository deviceCertRepository;
    private SheProperties props;
    private TenantContextInterceptor tenantContextInterceptor;
    private MqttAuthController controller;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        deviceCertRepository = mock(DeviceCertRepository.class);
        tenantContextInterceptor = mock(TenantContextInterceptor.class);
        props = mock(SheProperties.class);

        // Mock the properties chain
        SheProperties.Mqtt mqtt = new SheProperties.Mqtt(
                "ssl://localhost:8883",
                "/etc/she/certs/she-backend.crt",
                "/etc/she/certs/she-backend.key",
                "/etc/she/ca/ca_bundle.pem",
                "she-backend",
                "she-backend",
                "test-internal-token"
        );
        when(props.mqtt()).thenReturn(mqtt);

        controller = new MqttAuthController(deviceCertRepository, props, tenantContextInterceptor);
    }

    // =========================================================================
    // /internal/mqtt/auth
    // =========================================================================

    @Test
    @DisplayName("Auth: valid fingerprint + matching clientid/cn → ALLOW, is_superuser=false")
    void authValidCert() {
        String fp = "ab12cd34" + "e".repeat(56);
        DeviceCert cert = new DeviceCert();
        cert.setTenantId(UUID.randomUUID());
        cert.setCn("aabbccddeeff");
        cert.setFingerprint(fp);
        cert.setStatus("ACTIVE");
        cert.setExpiresAt(Instant.now().plusSeconds(86400));

        when(deviceCertRepository.findActiveByFingerprint(fp)).thenReturn(Optional.of(cert));

        MqttAuthDtos.AuthRequest req = new MqttAuthDtos.AuthRequest(
                "aabbccddeeff", "aabbccddeeff", fp
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AuthResponse> resp = controller.authenticate(req, httpReq);

        assertEquals(200, resp.getStatusCode().value());
        assertEquals("allow", resp.getBody().result());
        assertFalse(resp.getBody().is_superuser(), "is_superuser must be false per P1-10");
    }

    @Test
    @DisplayName("Auth: clientid != cn → DENY (clientid_cn_mismatch)")
    void authClientidCnMismatch() {
        String fp = "ab12cd34" + "e".repeat(56);
        DeviceCert cert = new DeviceCert();
        cert.setCn("aabbccddeeff");
        cert.setFingerprint(fp);
        cert.setStatus("ACTIVE");
        cert.setExpiresAt(Instant.now().plusSeconds(86400));

        when(deviceCertRepository.findActiveByFingerprint(fp)).thenReturn(Optional.of(cert));

        MqttAuthDtos.AuthRequest req = new MqttAuthDtos.AuthRequest(
                "aabbccddeeff",     // clientid
                "112233445566",     // cn (different)
                fp
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AuthResponse> resp = controller.authenticate(req, httpReq);

        assertEquals(200, resp.getStatusCode().value());
        assertEquals("deny", resp.getBody().result());
        assertEquals("clientid_cn_mismatch", resp.getBody().reason());
    }

    @Test
    @DisplayName("Auth: cert not found → 403 CERT_NOT_FOUND")
    void authCertNotFound() {
        when(deviceCertRepository.findActiveByFingerprint(anyString())).thenReturn(Optional.empty());

        MqttAuthDtos.AuthRequest req = new MqttAuthDtos.AuthRequest(
                "aabbccddeeff", "aabbccddeeff", "nonexistent_fingerprint"
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        SheException ex = assertThrows(SheException.class, () -> controller.authenticate(req, httpReq));
        assertEquals("CERT_NOT_FOUND", ex.getCode());
        assertEquals(403, ex.getHttpStatus());
    }

    @Test
    @DisplayName("Auth: missing X-Internal-Token → 401 AUTH_TOKEN_INVALID")
    void authMissingInternalToken() {
        MqttAuthDtos.AuthRequest req = new MqttAuthDtos.AuthRequest(
                "aabbccddeeff", "aabbccddeeff", "any_fingerprint"
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn(null);

        SheException ex = assertThrows(SheException.class, () -> controller.authenticate(req, httpReq));
        assertEquals("AUTH_TOKEN_INVALID", ex.getCode());
        assertEquals(401, ex.getHttpStatus());
    }

    // =========================================================================
    // /internal/mqtt/acl
    // =========================================================================

    @Test
    @DisplayName("ACL: device publish to telemetry topic → ALLOW")
    void aclDevicePublishTelemetry() {
        MqttAuthDtos.AclRequest req = new MqttAuthDtos.AclRequest(
                "aabbccddeeff",
                "she/6f1c8a2b/9b2d4e7f/1c4e8a90/aabbccddeeff/telemetry",
                "publish"
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AclResponse> resp = controller.authorize(req, httpReq);

        assertEquals(200, resp.getStatusCode().value());
        assertEquals("allow", resp.getBody().result());
    }

    @Test
    @DisplayName("ACL: device subscribe to its own command topic → ALLOW")
    void aclDeviceSubscribeCommand() {
        MqttAuthDtos.AclRequest req = new MqttAuthDtos.AclRequest(
                "aabbccddeeff",
                "she/6f1c8a2b/9b2d4e7f/1c4e8a90/aabbccddeeff/command",
                "subscribe"
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AclResponse> resp = controller.authorize(req, httpReq);

        assertEquals("allow", resp.getBody().result());
    }

    @Test
    @DisplayName("ACL: device publish to another device's topic → DENY (mac_mismatch)")
    void aclDevicePublishToOtherDeviceTopic() {
        MqttAuthDtos.AclRequest req = new MqttAuthDtos.AclRequest(
                "aabbccddeeff",       // clientid (this device)
                "she/6f1c8a2b/9b2d4e7f/1c4e8a90/112233445566/telemetry",   // topic for OTHER device
                "publish"
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AclResponse> resp = controller.authorize(req, httpReq);

        assertEquals("deny", resp.getBody().result());
        assertEquals("mac_mismatch", resp.getBody().reason());
    }

    @Test
    @DisplayName("ACL: device subscribe to telemetry (publish-only direction) → DENY")
    void aclDeviceSubscribeToPublishOnlyDirection() {
        MqttAuthDtos.AclRequest req = new MqttAuthDtos.AclRequest(
                "aabbccddeeff",
                "she/6f1c8a2b/9b2d4e7f/1c4e8a90/aabbccddeeff/telemetry",
                "subscribe"     // telemetry is publish-only for devices
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AclResponse> resp = controller.authorize(req, httpReq);

        assertEquals("deny", resp.getBody().result());
        assertEquals("direction_not_allowed", resp.getBody().reason());
    }

    @Test
    @DisplayName("ACL: device publish to command (subscribe-only direction) → DENY")
    void aclDevicePublishToSubscribeOnlyDirection() {
        MqttAuthDtos.AclRequest req = new MqttAuthDtos.AclRequest(
                "aabbccddeeff",
                "she/6f1c8a2b/9b2d4e7f/1c4e8a90/aabbccddeeff/command",
                "publish"        // command is subscribe-only for devices
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AclResponse> resp = controller.authorize(req, httpReq);

        assertEquals("deny", resp.getBody().result());
        assertEquals("direction_not_allowed", resp.getBody().reason());
    }

    @Test
    @DisplayName("ACL: topic doesn't match namespace pattern → DENY")
    void aclInvalidTopicFormat() {
        MqttAuthDtos.AclRequest req = new MqttAuthDtos.AclRequest(
                "aabbccddeeff",
                "other/namespace/topic",
                "publish"
        );
        HttpServletRequest httpReq = mock(HttpServletRequest.class);
        when(httpReq.getHeader("X-Internal-Token")).thenReturn("test-internal-token");

        ResponseEntity<MqttAuthDtos.AclResponse> resp = controller.authorize(req, httpReq);

        assertEquals("deny", resp.getBody().result());
        assertEquals("invalid_topic_format", resp.getBody().reason());
    }
}
