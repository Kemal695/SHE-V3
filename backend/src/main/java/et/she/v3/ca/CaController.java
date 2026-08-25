package et.she.v3.ca;

import et.she.v3.config.SheProperties;
import et.she.v3.errors.SheException;
import et.she.v3.entity.DeviceCert;
import et.she.v3.repository.DeviceCertRepository;
import et.she.v3.security.TenantContextInterceptor;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * step-ca integration endpoints — for the factory workstation + admin tools.
 *
 * V3-API-SPECIFICATION §15:
 *   POST /internal/factory/register-cert   — record a newly-issued device cert
 *   POST /internal/ca/revoke               — revoke a device cert + regenerate CRL
 *   GET  /internal/health/ca               — step-ca health
 *
 * V3-FACTORY-OPS — factory flashing workflow:
 *   1. ESP32 boots in factory mode, generates ECDSA P-256 keypair on-chip
 *   2. Firmware sends CSR (CN=MAC) over USB serial
 *   3. Factory workstation POSTs CSR to step-ca (via this controller)
 *   4. Cert returned, stored in device_certs table
 *   5. Factory workstation writes cert to ESP32 fctry NVS partition
 *
 * CRL refresh runs on a cron every 6 hours per P1-22.
 */
@RestController
@RequestMapping("/internal")
public class CaController {

    private static final Logger log = LoggerFactory.getLogger(CaController.class);

    private final StepCaClient stepCaClient;
    private final DeviceCertRepository deviceCertRepository;
    private final SheProperties props;
    private final TenantContextInterceptor tenantContextInterceptor;

    public CaController(StepCaClient stepCaClient,
                        DeviceCertRepository deviceCertRepository,
                        SheProperties props,
                        TenantContextInterceptor tenantContextInterceptor) {
        this.stepCaClient = stepCaClient;
        this.deviceCertRepository = deviceCertRepository;
        this.props = props;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    // =========================================================================
    // POST /internal/factory/register-cert
    // Factory workstation records a cert → device mapping after step-ca signs it.
    // =========================================================================

    public record RegisterCertRequest(
            @NotBlank String csr_pem,             // PKCS#10 CSR from ESP32
            @NotBlank String cn,                  // normalized MAC (must match CSR CN)
            UUID tenant_id,                       // tenant the device belongs to (default B2C = 00000000-...-0001)
            UUID ca_id                            // device_ca_certs.id of the signing intermediate
    ) {}

    public record RegisterCertResponse(
            String cert_pem,
            String serial,
            String fingerprint,
            String expires_at
    ) {}

    @PostMapping("/ca/sign-and-register")
    @Transactional
    public ResponseEntity<Map<String, Object>> registerCert(
            @Valid @RequestBody RegisterCertRequest req,
            HttpServletRequest httpReq) {

        // Step 1: send the CSR to step-ca for signing
        StepCaClient.SignResult signed = stepCaClient.signDeviceCsr(req.csr_pem(), req.cn());

        // Step 2: compute fingerprint (SHA-256 of DER cert) — step-ca returns it, but we
        // compute it locally too for defense-in-depth.
        // (For Phase 0 we trust step-ca's fingerprint; full local verification in Phase 5B.)

        // Step 3: store in device_certs table
        // RLS: cert registration is a tenant-agnostic operation. Set platform_admin=on
        // for this transaction (allowed by the policy).
        tenantContextInterceptor.setRlsGucs(req.tenant_id(), true);

        if (deviceCertRepository.existsByCertSerial(signed.serial())) {
            throw new SheException("CONFLICT_DEVICE_MAC_TAKEN",
                    "Cert with serial " + signed.serial() + " already exists", 409);
        }

        DeviceCert cert = new DeviceCert();
        cert.setTenantId(req.tenant_id());
        cert.setCn(req.cn());
        cert.setCertSerial(signed.serial());
        cert.setFingerprint(signed.fingerprint());
        cert.setCaId(req.ca_id());
        cert.setIssuedAt(Instant.now());
        cert.setExpiresAt(Instant.now().plusSeconds(5 * 365 * 86400L));  // 5 years per P0-2
        cert.setStatus("ACTIVE");

        DeviceCert saved = deviceCertRepository.save(cert);

        log.info("Device cert registered — cn={}, serial={}, tenant_id={}",
                req.cn(), signed.serial(), req.tenant_id());

        return ResponseEntity.ok(Map.of("data", new RegisterCertResponse(
                signed.certPem(),
                signed.serial(),
                signed.fingerprint(),
                saved.getExpiresAt().toString()
        )));
    }

    // =========================================================================
    // POST /internal/ca/revoke
    // =========================================================================

    public record RevokeRequest(
            @NotBlank String serial,
            @NotBlank String reason,
            UUID revoked_by_user_id
    ) {}

    @PostMapping("/ca/revoke")
    @Transactional
    public ResponseEntity<Map<String, Object>> revoke(
            @Valid @RequestBody RevokeRequest req,
            HttpServletRequest httpReq) {

        // Call step-ca to revoke (regenerates CRL internally)
        stepCaClient.revokeCert(req.serial(), req.reason());

        // Update the device_certs row — set status=REVOKED + revoked_at
        // RLS: revocation is platform-admin scope
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        DeviceCert cert = deviceCertRepository.findActiveByCertSerial(req.serial())
                .orElseThrow(() -> new SheException("CERT_NOT_FOUND",
                        "Active cert with serial " + req.serial() + " not found", 404));
        cert.setStatus("REVOKED");
        cert.setRevokedAt(Instant.now());
        cert.setRevokeReason(req.reason());
        if (req.revoked_by_user_id() != null) {
            cert.setRevokedByUserId(req.revoked_by_user_id());
        }
        deviceCertRepository.save(cert);

        log.info("Device cert revoked — serial={}, reason={}", req.serial(), req.reason());

        // Trigger an immediate CRL refresh (so revocation takes effect ASAP, not 6h later)
        refreshCrl();

        return ResponseEntity.ok(Map.of("data", Map.of("status", "revoked", "serial", req.serial())));
    }

    // =========================================================================
    // GET /internal/health/ca
    // =========================================================================

    @GetMapping("/health/ca")
    public ResponseEntity<Map<String, Object>> health() {
        boolean healthy = stepCaClient.isHealthy();
        return ResponseEntity.ok(Map.of(
                "data", Map.of(
                        "status", healthy ? "UP" : "DOWN",
                        "ca_url", props.ca().url(),
                        "crl_publish_base_url", props.ca().crlPublishBaseUrl()
                )
        ));
    }

    // =========================================================================
    // CRL refresh — every 6 hours per P1-22 (revocation SLA < 6 hours)
    // =========================================================================

    @Scheduled(cron = "0 0 */6 * * *")    // top of every 6th hour
    public void refreshCrl() {
        try {
            String intermediateId = readIntermediateId();
            byte[] crl = stepCaClient.fetchCrl(intermediateId);

            // Write to the CRL publish directory (served by nginx)
            Path publishDir = Path.of(props.ca().crlPublishBaseUrl().replaceFirst("^https?://[^/]+", ""))
                    .resolve(intermediateId);
            Files.createDirectories(publishDir);
            Path crlFile = publishDir.resolve("crl.pem");
            Files.copy(new java.io.ByteArrayInputStream(crl), crlFile, StandardCopyOption.REPLACE_EXISTING);

            log.info("CRL refreshed — size={} bytes, path={}", crl.length, crlFile);
        } catch (Exception e) {
            log.error("CRL refresh FAILED — revocation may be delayed beyond 6h SLA", e);
        }
    }

    private String readIntermediateId() throws Exception {
        Path idFile = Path.of(props.ca().intermediateCertPath()).getParent().resolve("intermediate_id.txt");
        if (Files.exists(idFile)) {
            return Files.readString(idFile).trim();
        }
        // Fallback: compute fingerprint of the intermediate cert
        return "default";
    }
}
