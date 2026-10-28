package et.she.v3.controller;

import et.she.v3.entity.Node;
import et.she.v3.errors.SheException;
import et.she.v3.repository.NodeRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Admin device management endpoints.
 * V3-ADMIN-PLATFORM §4.3.
 *
 *   GET    /api/admin/devices              — list (RLS-scoped to tenant)
 *   GET    /api/admin/devices/{id}        — detail
 *   POST   /api/admin/devices/{id}/quarantine     — quarantine compromised device
 *   POST   /api/admin/devices/{id}/unquarantine  — unquarantine
 *   DELETE /api/admin/devices/{id}                — soft delete
 *   GET    /api/admin/devices/{id}/cert           — view cert info
 *   POST   /api/admin/devices/{id}/revoke-cert    — revoke device cert (calls step-ca)
 */
@RestController
@RequestMapping("/api/admin/devices")
public class AdminDeviceController {

    private final NodeRepository nodeRepository;
    private final TenantContextInterceptor tenantContextInterceptor;
    private final et.she.v3.ca.StepCaClient stepCaClient;
    private final et.she.v3.repository.DeviceCertRepository deviceCertRepository;

    public AdminDeviceController(NodeRepository nodeRepository,
                                  TenantContextInterceptor tenantContextInterceptor,
                                  et.she.v3.ca.StepCaClient stepCaClient,
                                  et.she.v3.repository.DeviceCertRepository deviceCertRepository) {
        this.nodeRepository = nodeRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
        this.stepCaClient = stepCaClient;
        this.deviceCertRepository = deviceCertRepository;
    }

    @GetMapping
    public ResponseEntity<Map<String, Object>> list() {
        // RLS is set by TenantContextAspect — findAll is auto-filtered
        // For platform admins (cross-tenant), need a separate query path
        // For now, use tenant-scoped query (TENANT_ADMIN sees own tenant devices)
        List<Node> nodes = nodeRepository.findAll();
        var data = nodes.stream()
                .filter(n -> n.getDeletedAt() == null)
                .map(this::toResponse)
                .toList();
        return ResponseEntity.ok(Map.of("data", data));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Map<String, Object>> getById(@PathVariable UUID id) {
        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Device not found", 404));
        return ResponseEntity.ok(Map.of("data", toResponse(node)));
    }

    @PostMapping("/{id}/quarantine")
    public ResponseEntity<Map<String, Object>> quarantine(@PathVariable UUID id,
                                                            @RequestBody(required = false) Map<String, String> body) {
        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Device not found", 404));
        // V3-SECURITY-MODEL §4.2 — set is_quarantined=true → EMQX auth backend denies future MQTT connections
        node.setQuarantined(true);
        nodeRepository.save(node);
        return ResponseEntity.ok(Map.of("data", Map.of(
                "id", id,
                "status", "quarantined",
                "reason", body != null ? body.getOrDefault("reason", "") : ""
        )));
    }

    @PostMapping("/{id}/unquarantine")
    public ResponseEntity<Map<String, Object>> unquarantine(@PathVariable UUID id) {
        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Device not found", 404));
        node.setQuarantined(false);
        nodeRepository.save(node);
        return ResponseEntity.ok(Map.of("data", Map.of(
                "id", id,
                "status", "active"
        )));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Device not found", 404));
        node.setDeletedAt(Instant.now());
        nodeRepository.save(node);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/cert")
    public ResponseEntity<Map<String, Object>> getCert(@PathVariable UUID id) {
        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Device not found", 404));
        if (node.getCertFingerprint() == null) {
            throw new SheException("CERT_NOT_FOUND", "Device has no cert fingerprint", 404);
        }
        // Set platform-admin GUC for cross-tenant cert lookup
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);
        var cert = deviceCertRepository.findActiveByFingerprint(node.getCertFingerprint())
                .orElseThrow(() -> new SheException("CERT_NOT_FOUND", "Cert not found", 404));
        // HashMap, not Map.of — revoked_at is null for active certs and Map.of rejects null values
        Map<String, Object> data = new java.util.HashMap<>();
        data.put("cn", cert.getCn());
        data.put("serial", cert.getCertSerial());
        data.put("fingerprint", cert.getFingerprint());
        data.put("status", cert.getStatus());
        data.put("issued_at", cert.getIssuedAt() != null ? cert.getIssuedAt().toString() : null);
        data.put("expires_at", cert.getExpiresAt() != null ? cert.getExpiresAt().toString() : null);
        data.put("revoked_at", cert.getRevokedAt() != null ? cert.getRevokedAt().toString() : null);
        return ResponseEntity.ok(Map.of("data", data));
    }

    @PostMapping("/{id}/revoke-cert")
    public ResponseEntity<Map<String, Object>> revokeCert(@PathVariable UUID id,
                                                            @RequestBody(required = false) Map<String, String> body) {
        Node node = nodeRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Device not found", 404));
        if (node.getCertSerial() == null) {
            throw new SheException("CERT_NOT_FOUND", "Device has no cert serial", 404);
        }

        // Revoke via step-ca
        String reason = body != null ? body.getOrDefault("reason", "key_compromise") : "key_compromise";
        stepCaClient.revokeCert(node.getCertSerial(), reason);

        // Update device_certs table
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);
        var cert = deviceCertRepository.findActiveByCertSerial(node.getCertSerial())
                .orElseThrow(() -> new SheException("CERT_NOT_FOUND", "Cert not found", 404));
        cert.setStatus("REVOKED");
        cert.setRevokedAt(Instant.now());
        cert.setRevokeReason(reason);
        deviceCertRepository.save(cert);

        // TODO: trigger CRL refresh + EMQX disconnect

        return ResponseEntity.ok(Map.of("data", Map.of(
                "id", id,
                "cert_serial", node.getCertSerial(),
                "status", "revoked",
                "reason", reason
        )));
    }

    private Map<String, Object> toResponse(Node n) {
        return Map.of(
                "id", n.getId(),
                "node_id", n.getNodeId(),
                "mac_address", n.getMacAddress(),
                "sku", n.getSku(),
                "name", n.getName(),
                "is_online", n.isOnline(),
                "firmware_version", n.getFirmwareVersion() != null ? n.getFirmwareVersion() : "",
                "last_seen_at", n.getLastSeenAt() != null ? n.getLastSeenAt().toString() : "",
                "provisioned_at", n.getProvisionedAt() != null ? n.getProvisionedAt().toString() : ""
        );
    }
}
