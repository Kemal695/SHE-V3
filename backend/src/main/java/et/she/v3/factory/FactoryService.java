package et.she.v3.factory;

import et.she.v3.ca.StepCaClient;
import et.she.v3.entity.DeviceCert;
import et.she.v3.entity.Node;
import et.she.v3.errors.SheException;
import et.she.v3.repository.DeviceCertRepository;
import et.she.v3.repository.NodeRepository;
import et.she.v3.security.TenantContextInterceptor;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Factory service + endpoints.
 *
 * V3-FACTORY-OPS §3-5. V3-API-SPECIFICATION §15.
 *
 * POST /internal/factory/register-cert
 *   Called by factory workstation after step-ca signs a device cert.
 *   Records the cert in device_certs + creates a nodes row (pre-claim, tenant_id=NULL).
 *
 * V3-FACTORY-OPS §8 — all events also logged to factory_audit_log (V29).
 */
@RestController
@RequestMapping("/internal/factory")
public class FactoryService {

    private static final Logger log = LoggerFactory.getLogger(FactoryService.class);

    private final DeviceCertRepository deviceCertRepository;
    private final NodeRepository nodeRepository;
    private final JdbcTemplate jdbcTemplate;
    private final TenantContextInterceptor tenantContextInterceptor;

    public FactoryService(DeviceCertRepository deviceCertRepository,
                          NodeRepository nodeRepository,
                          JdbcTemplate jdbcTemplate,
                          TenantContextInterceptor tenantContextInterceptor) {
        this.deviceCertRepository = deviceCertRepository;
        this.nodeRepository = nodeRepository;
        this.jdbcTemplate = jdbcTemplate;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    public record RegisterCertRequest(
            @NotBlank String batch_id,
            @NotBlank String mac,                    // AA:BB:CC:DD:EE:FF (uppercase, colon-separated)
            @NotBlank String node_id,                // SHE-R8-AABBCC
            @NotBlank String sku,                    // SHE-R4 | SHE-R8 | SHE-R16
            @NotBlank String cert_pem,
            @NotBlank String cert_serial,
            @NotBlank String cert_fingerprint,       // SHA-256 of DER cert (lowercase hex)
            @NotBlank String cert_expires_at,        // ISO-8601
            @NotBlank String pop_hash,               // SHA-256 of the 9-digit PoP (P1-26)
            @NotBlank String hardware_revision,      // rev-a | rev-b | rev-c
            String operator_id,
            String workstation_id
    ) {}

    public record RegisterCertResponse(
            UUID node_db_id,
            String registered_at,
            String status
    ) {}

    @PostMapping("/register-cert")
    @org.springframework.transaction.annotation.Transactional
    public ResponseEntity<Map<String, Object>> registerCert(
            @Valid @RequestBody RegisterCertRequest req,
            HttpServletRequest httpReq) {

        // RLS: factory registration is cross-tenant (node is pre-claim) — set platform_admin=on
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        // Normalize MAC
        String normalizedMac = req.mac().toLowerCase().replaceAll("[:\\-]", "");
        if (!normalizedMac.matches("^[0-9a-f]{12}$")) {
            throw new SheException("VALIDATION_FAILED", "Invalid MAC format", 400);
        }

        // Idempotency: check if cert already registered — lookup by cert_serial (NOT cn)
        if (deviceCertRepository.existsByCertSerial(req.cert_serial())) {
            log.info("Cert already registered (idempotent skip): serial={}", req.cert_serial());
            DeviceCert existing = deviceCertRepository.findActiveByCertSerial(req.cert_serial())
                    .orElseThrow(() -> new SheException("INTERNAL_ERROR", "Cert exists but lookup failed", 500));
            // Look up the existing node by cert_fingerprint
            var nodeOpt = nodeRepository.findByCertFingerprint(existing.getFingerprint());
            UUID nodeId = nodeOpt.map(n -> n.getId()).orElse(existing.getTenantId());
            return ResponseEntity.ok(Map.of("data", new RegisterCertResponse(
                    nodeId,
                    Instant.now().toString(),
                    "ALREADY_REGISTERED"
            )));
        }

        // 1. INSERT into device_certs (tenant_id NULL for pre-claim; set on /nodes/claim)
        DeviceCert cert = new DeviceCert();
        // tenant_id is required NOT NULL in V3 — use a placeholder; /nodes/claim will update
        // For factory pre-registration, we use the default B2C tenant UUID
        cert.setTenantId(UUID.fromString("00000000-0000-0000-0000-000000000001"));
        cert.setCn(normalizedMac);
        cert.setCertSerial(req.cert_serial());
        cert.setFingerprint(req.cert_fingerprint());
        cert.setCaId(UUID.fromString("00000000-0000-0000-0000-000000000001"));   // placeholder
        cert.setIssuedAt(Instant.now());
        cert.setExpiresAt(Instant.parse(req.cert_expires_at()));
        cert.setStatus("ACTIVE");
        cert = deviceCertRepository.save(cert);

        // 2. INSERT into nodes (pre-claim: tenant_id = NULL)
        Node node = new Node();
        node.setNodeId(req.node_id());
        node.setMacAddress(req.mac().toUpperCase());
        node.setNormalizedMac(normalizedMac);
        node.setSku(req.sku());
        node.setName(req.node_id());
        node.setHardwareRevision(req.hardware_revision);
        node.setCertSerial(req.cert_serial());
        node.setCertFingerprint(req.cert_fingerprint());
        node = nodeRepository.save(node);

        // 3. INSERT into factory_audit_log (V29)
        jdbcTemplate.update(
                """
                INSERT INTO factory_audit_log
                  (event_type, batch_id, mac, node_id, sku, cert_serial, cert_fingerprint,
                   operator_id, workstation_id, hardware_revision, qc_status, details)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb)
                """,
                "CERT_REGISTERED", req.batch_id(), req.mac(), req.node_id(), req.sku(),
                req.cert_serial(), req.cert_fingerprint(),
                req.operator_id() != null ? req.operator_id() : "unknown",
                req.workstation_id() != null ? req.workstation_id() : "unknown",
                req.hardware_revision(),
                null,   // qc_status NULL until QC test
                "{\"pop_hash\":\"" + req.pop_hash() + "\"}"
        );

        log.info("Factory cert registered: node={} mac={} serial={}",
                req.node_id(), req.mac(), req.cert_serial());

        return ResponseEntity.ok(Map.of("data", new RegisterCertResponse(
                node.getId(),
                Instant.now().toString(),
                "PRE_PROVISIONED"
        )));
    }
}
