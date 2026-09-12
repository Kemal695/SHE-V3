package et.she.v3.ca;

import et.she.v3.audit.AuditService;
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
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Base64;
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
    private final AuditService auditService;

    public CaController(StepCaClient stepCaClient,
                        DeviceCertRepository deviceCertRepository,
                        SheProperties props,
                        TenantContextInterceptor tenantContextInterceptor,
                        AuditService auditService) {
        this.stepCaClient = stepCaClient;
        this.deviceCertRepository = deviceCertRepository;
        this.props = props;
        this.tenantContextInterceptor = tenantContextInterceptor;
        this.auditService = auditService;
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

        // P1-19: revoking a device credential is a privileged action — hash-chained
        // audit entry. Runs in its own transaction, so it is recorded even if the
        // surrounding request later fails.
        auditService.record(cert.getTenantId(), "PLATFORM_ADMIN", req.revoked_by_user_id(),
                "ca.cert.revoked", "device_cert", cert.getId(),
                Map.of("serial", req.serial(), "reason", String.valueOf(req.reason())),
                clientIp(httpReq), httpReq.getHeader("User-Agent"), null);

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

    /**
     * Verify that the published CRL still matches the CA's current one.
     *
     * This used to *publish* the CRL by stripping the scheme+host off
     * {@code ca.crl-publish-base-url} and treating the remainder as a filesystem
     * directory — conflating a URL with a path. With the default
     * {@code http://localhost:8088/ca} it wrote to {@code \ca\default\crl.pem}
     * and logged {@code INFO CRL refreshed}, a false success: no topology mounts
     * the ca-certs volume into the backend, so the target is unreachable
     * everywhere. ({@code default} came from {@link #readIntermediateId()} falling
     * back to that literal.)
     *
     * Publication is owned by {@code refresh-crl.sh}/cron, the only component that
     * can write the root-owned volume. This job now verifies instead, so a stalled
     * publisher is an alarm rather than a silent revocation-SLA breach.
     */
    @Scheduled(cron = "${she.ca.crl-verify-cron:0 0 */6 * * *}")    // top of every 6th hour
    public void refreshCrl() {
        try {
            String intermediateId = readIntermediateId();
            byte[] crl = stepCaClient.fetchCrl(intermediateId);

            String base = props.ca().crlPublishBaseUrl();
            if (base == null || base.isBlank()) {
                log.warn("CRL publish base URL is not configured — cannot verify publication");
                return;
            }
            String publishedUrl = base.replaceAll("/+$", "") + "/" + intermediateId + "/crl.pem";
            byte[] published;
            try (java.io.InputStream in = java.net.URI.create(publishedUrl).toURL().openStream()) {
                published = in.readAllBytes();
            }

            if (java.util.Arrays.equals(crl, published)) {
                log.info("CRL verified — published copy matches step-ca ({} bytes, url={})",
                        crl.length, publishedUrl);
            } else {
                log.warn("CRL publication is STALE — step-ca has {} bytes, {} has {} bytes. "
                        + "Run refresh-crl.sh; revocation may be delayed beyond the 6h SLA.",
                        crl.length, publishedUrl, published.length);
            }
        } catch (Exception e) {
            log.error("CRL verification FAILED — revocation may be delayed beyond 6h SLA", e);
        }
    }


    /** Best-effort client IP for audit rows (honours X-Forwarded-For behind nginx). */
    private static String clientIp(HttpServletRequest req) {
        if (req == null) return null;
        String xff = req.getHeader("X-Forwarded-For");
        if (xff != null && !xff.isBlank()) {
            return xff.split(",")[0].trim();
        }
        return req.getRemoteAddr();
    }

    private String readIntermediateId() throws Exception {
        Path idFile = Path.of(props.ca().intermediateCertPath()).getParent().resolve("intermediate_id.txt");
        if (Files.exists(idFile)) {
            String id = Files.readString(idFile).trim();
            if (!id.isBlank()) {
                return id;
            }
        }
        // Derive it from the certificate. step-ca names the intermediate directory
        // after the first 16 hex chars of the SHA-256 fingerprint of the DER-encoded
        // intermediate cert (verified against the live CA: 4746eb60a64abb7e).
        // The previous fallback was the literal "default", which produced bogus
        // paths and made every CRL refresh look successful.
        Path cert = Path.of(props.ca().intermediateCertPath());
        if (!Files.exists(cert)) {
            throw new IllegalStateException("Cannot determine intermediate id — no intermediate_id.txt "
                    + "and no intermediate certificate at " + cert);
        }
        return fingerprintPrefix(Files.readAllBytes(cert));
    }

    /** First 16 hex chars of the SHA-256 of the DER-encoded certificate. */
    private static String fingerprintPrefix(byte[] pem) throws Exception {
        String base64 = new String(pem, java.nio.charset.StandardCharsets.US_ASCII)
                .replaceAll("-----[A-Z ]+-----", "")
                .replaceAll("\\s", "");
        byte[] der = Base64.getDecoder().decode(base64);
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(der);
        StringBuilder sb = new StringBuilder(16);
        for (int i = 0; i < 8; i++) {
            sb.append(String.format("%02x", digest[i]));
        }
        return sb.toString();
    }
}
