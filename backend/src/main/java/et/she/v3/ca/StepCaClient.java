package et.she.v3.ca;

import et.she.v3.config.SheProperties;
import et.she.v3.errors.SheException;
import et.she.v3.security.JwtService;
import com.nimbusds.jose.JWEObject;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.crypto.PasswordBasedDecrypter;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;
import reactor.netty.http.client.HttpClient;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Date;
import java.util.Map;
import java.util.UUID;

/**
 * step-ca REST client.
 *
 * Calls the step-ca /sign API to sign device CSRs. Spring Boot NEVER holds
 * the CA private key — it always goes through step-ca (P0-2, P1-24).
 *
 * V3-CONFIGURATION §3 (step-ca setup), V3-SECURITY-MODEL §3.2 (cert lifecycle).
 *
 * step-ca API:
 *   POST /sign
 *     body: { csr: "<PEM>", ott: "<one-time token JWT>" }
 *     auth: the ott itself (signed by the provisioner key). Basic auth is NOT
 *           sufficient — step-ca answers 400 "missing ott".
 *     resp: 200 OK { crt: "<PEM>", ca: ["<root>", "<intermediate>"] }
 *           NOTE: no reliable `serial`/`fingerprint` fields — both are derived from
 *           the returned certificate (see signDeviceCsr).
 *
 *   POST /revoke
 *     body: { serial: "<hex>", reason: "key_compromise", ott: "<one-time token>" }
 *     resp: 200 OK { status: "ok" }
 *
 *   GET /crl/{cert-id}   (or /1/crl)
 *     resp: application/pkix-crl
 */
@Service
public class StepCaClient {

    private static final Logger log = LoggerFactory.getLogger(StepCaClient.class);

    private final SheProperties props;
    private WebClient webClient;
    private String provisionerPassword;

    /** Provisioner JWK, encrypted at rest (JWE, PBES2-HS256+A128KW / A256GCM). */
    private String provisionerEncryptedKey;
    /** `kid` of the provisioner key — must appear in the OTT header. */
    private String provisionerKid;

    public StepCaClient(SheProperties props) {
        this.props = props;
    }

    @PostConstruct
    void init() throws Exception {
        String url = props.ca().url();
        if (url == null || url.isBlank()) {
            throw new IllegalStateException("STEP_CA_CLIENT_URL is not set");
        }
        
        HttpClient httpClient = HttpClient.create();
        if (url.startsWith("https")) {
            io.netty.handler.ssl.SslContext sslContext = io.netty.handler.ssl.SslContextBuilder.forClient()
                    .trustManager(io.netty.handler.ssl.util.InsecureTrustManagerFactory.INSTANCE)
                    .build();
            httpClient = HttpClient.create().secure(t -> t.sslContext(sslContext));
        }

        this.webClient = WebClient.builder()
                .clientConnector(new org.springframework.http.client.reactive.ReactorClientHttpConnector(httpClient))
                .baseUrl(url)
                .build();
        // Read provisioner password from file (avoids env var leakage into process args)
        String passwordFile = props.ca().provisionerPasswordFile();
        if (passwordFile == null || passwordFile.isBlank()) {
            throw new IllegalStateException("STEP_CA_CLIENT_PROVISIONER_PASSWORD_FILE is not set");
        }
        this.provisionerPassword = Files.readString(Path.of(passwordFile)).trim();

        // Load the provisioner JWK (encrypted). step-ca's /sign endpoint requires a
        // one-time token (ott) signed by the provisioner key for JWK provisioners —
        // Basic auth alone is rejected with `missing ott`.
        String keyPath = props.ca().provisionerKeyPath();
        if (keyPath != null && !keyPath.isBlank() && Files.exists(Path.of(keyPath))) {
            Map<String, Object> keyJson = new ObjectMapper().readValue(
                    Files.readString(Path.of(keyPath)), Map.class);
            this.provisionerEncryptedKey = (String) keyJson.get("encryptedKey");
            this.provisionerKid = (String) keyJson.get("kid");
        } else {
            log.warn("STEP_CA_PROVISIONER_KEY_PATH not set or missing — device cert "
                    + "issuance will fail (step-ca requires a one-time token)");
        }

        log.info("step-ca client initialized — url={}, provisioner={}",
                url, props.ca().provisionerName());
    }

    // =========================================================================
    // ONE-TIME TOKEN (ott) — required by step-ca /sign for JWK provisioners
    // =========================================================================

    /**
     * Mint a step-ca one-time token (ott).
     *
     * step-ca authenticates /sign with a JWT signed by the provisioner's private
     * key. The key is stored encrypted (JWE: PBES2-HS256+A128KW / A256GCM) in the
     * CA config; we decrypt it in-process with the provisioner password.
     *
     * Claims mirror exactly what `step ca token` produces:
     *   aud=<ca-url>/1.0/<audiencePath>, iss=<provisioner>, sub=<subject>,
     *   sans=[<subject>], sha=<hex sha256(CSR DER)>, jti, iat, nbf, exp
     */
    private String mintProvisionerToken(String subject, byte[] csrDer, String audiencePath) {
        return mintToken(subject, csrDer, audiencePath, true);
    }

    /**
     * Mint an ott for {@code /revoke}.
     *
     * <p>Same JWK-provisioner rule as {@code /sign}: Basic auth is NOT sufficient.
     * For revocation the token is bound to the certificate serial rather than a CSR,
     * so {@code sha = hex(sha256(serial))} and there are no SANs.
     */
    private String mintRevokeToken(String serial) {
        return mintToken(props.ca().provisionerName(),
                serial.getBytes(StandardCharsets.UTF_8), "revoke", false);
    }

    private String mintToken(String subject, byte[] shaInput, String audiencePath, boolean includeSans) {
        if (provisionerEncryptedKey == null || provisionerKid == null) {
            throw new SheException("CA_SERVICE_ERROR",
                    "Provisioner key not configured (STEP_CA_PROVISIONER_KEY_PATH)", 502);
        }
        try {
            JWEObject jwe = JWEObject.parse(provisionerEncryptedKey);
            jwe.decrypt(new PasswordBasedDecrypter(provisionerPassword));
            ECKey provisionerKey = ECKey.parse(jwe.getPayload().toString());

            String sha = toHex(MessageDigest.getInstance("SHA-256").digest(shaInput));
            Instant now = Instant.now();

            JWTClaimsSet.Builder claims = new JWTClaimsSet.Builder()
                    .audience(props.ca().url() + "/1.0/" + audiencePath)
                    .issuer(props.ca().provisionerName())
                    .subject(subject)
                    .claim("sha", sha)
                    .jwtID(UUID.randomUUID().toString().replace("-", ""))
                    .issueTime(Date.from(now))
                    .notBeforeTime(Date.from(now))
                    .expirationTime(Date.from(now.plusSeconds(300)));
            if (includeSans) {
                claims.claim("sans", java.util.List.of(subject));
            }

            SignedJWT jwt = new SignedJWT(
                    new JWSHeader.Builder(JWSAlgorithm.ES256).keyID(provisionerKid).build(),
                    claims.build());
            jwt.sign(new ECDSASigner(provisionerKey));
            return jwt.serialize();
        } catch (SheException e) {
            throw e;
        } catch (Exception e) {
            throw new SheException("CA_SERVICE_ERROR",
                    "Failed to mint step-ca one-time token: " + e.getMessage(), 502, e);
        }
    }

    /** PEM -> DER for a PKCS#10 CSR (the PEM body *is* the DER, base64-encoded). */
    private static byte[] csrPemToDer(String csrPem) {
        String body = csrPem
                .replace("-----BEGIN CERTIFICATE REQUEST-----", "")
                .replace("-----END CERTIFICATE REQUEST-----", "")
                .replaceAll("\\s+", "");
        return Base64.getDecoder().decode(body);
    }

    private static String toHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    // =========================================================================
    // SIGN device CSR
    // =========================================================================

    /**
     * Sign a PKCS#10 CSR via step-ca. Returns the signed cert PEM.
     *
     * V3-SECURITY-MODEL §3.2 cert lifecycle:
     *   1. ESP32 generates ECDSA P-256 keypair on-chip
     *   2. Firmware generates CSR with CN = {MAC_ADDRESS}
     *   3. Factory workstation reads CSR from ESP32 over USB serial
     *   4. Factory workstation sends CSR to step-ca (this method)
     *   5. step-ca signs with intermediate CA (RSA 4096 / 10yr)
     *   6. Cert returned — ECDSA P-256, 5-year validity
     */
    @SuppressWarnings("unchecked")
    public SignResult signDeviceCsr(String csrPem, String cn) {
        // step-ca authenticates /sign with a one-time token (ott) signed by the
        // provisioner key. Posting {csr, provisioner} with Basic auth — which this
        // method used to do — is rejected with HTTP 400 "missing ott".
        String ott = mintProvisionerToken(cn, csrPemToDer(csrPem), "sign");

        Map<String, Object> body = Map.of(
                "csr", csrPem,
                "ott", ott
        );
        Map<String, Object> resp = postToCa("/sign?format=pem", body);
        if (resp == null) {
            throw new SheException("CA_SERVICE_ERROR", "step-ca returned empty response", 502);
        }
        String crt = (String) resp.get("crt");
        if (crt == null) {
            throw new SheException("CA_SERVICE_ERROR", "step-ca response missing 'crt' field", 502);
        }
        // Derive serial + fingerprint from the issued certificate itself rather than
        // trusting the response body. step-ca's /sign does not reliably include them
        // (it returned neither, so every device_certs row got an EMPTY cert_serial —
        // which collides on the UNIQUE(cert_serial) constraint after the first device).
        // Deriving locally is CA-shape independent and is defense-in-depth: the value
        // we store is provably the one on the certificate handed to the device.
        X509Certificate x509 = parseCertPem(crt);
        String serial = x509.getSerialNumber().toString(16).toUpperCase();
        final String fingerprint;
        try {
            fingerprint = JwtService.sha256Hex(x509.getEncoded());
        } catch (Exception e) {
            throw new SheException("CA_SERVICE_ERROR",
                    "Cannot compute fingerprint of issued cert: " + e.getMessage(), 502);
        }
        return new SignResult(crt, serial, fingerprint);
    }

    /** Parse a PEM-encoded X.509 certificate. */
    private static X509Certificate parseCertPem(String pem) {
        try {
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            return (X509Certificate) cf.generateCertificate(
                    new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            throw new SheException("CA_SERVICE_ERROR",
                    "step-ca returned an unparseable certificate: " + e.getMessage(), 502);
        }
    }

    public record SignResult(String certPem, String serial, String fingerprint) {}

    // =========================================================================
    // REVOKE device cert
    // =========================================================================

    public void revokeCert(String serial, String reason) {
        // step-ca's /revoke needs an ott exactly like /sign — the JWK provisioner does
        // not accept Basic auth, so the previous body ({serial, reason, provisioner} +
        // Basic auth) was rejected with HTTP 400. Revocation therefore never reached
        // the CA and the CRL stayed empty (a retired/compromised cert kept validating).
        //
        // step-ca also rejects a bare hex serial: it wants base 10, or base 16 with an
        // explicit "0x" prefix ("'EFCB…' is not a valid serial number"). Normalise once
        // and bind the ott to the exact string we send.
        String normalized = serial.startsWith("0x") || serial.startsWith("0X")
                ? serial
                : "0x" + serial;
        String ott = mintRevokeToken(normalized);
        // `passive: true` is MANDATORY. step-ca 0.27.x implements passive revocation
        // only: api/revoke.go's Validate() returns
        //     errs.NotImplemented("non-passive revocation not implemented")
        // whenever Passive is false, so omitting the flag fails every request.
        //
        // Worse, the failure is undiagnosable from the response: errs.Errorf()
        // unconditionally appends withDefaultMessage(NotImplementedDefaultMsg) for
        // EVERY status code, overwriting the specific reason with
        // "The requested method is not implemented by the certificate authority."
        // (verified against certificates v0.27.4 errs/error.go:288-294).
        //
        // Passive revocation records the serial in the CA database; because ca.json
        // also sets crl.enabled + crl.generateOnRevoke, the CA then republishes its
        // CRL with that serial listed — which is what actually blocks the device.
        Map<String, Object> body = Map.of(
                "serial", normalized,
                "reason", reason,
                "passive", true,
                "ott", ott
        );
        postToCa("/revoke", body);
        log.info("Cert revoked — serial={}, reason={}", normalized, reason);
    }

    /**
     * POST a JSON body to step-ca and return the parsed response.
     *
     * <p>Surfaces step-ca's own error body on failure: without it a 400 gives no clue
     * which of the token / body / serial-format rules was violated.
     */
    @SuppressWarnings("unchecked")
    private Map<String, Object> postToCa(String path, Object body) {
        try {
            return webClient.post()
                    .uri(path)
                    .bodyValue(body)
                    .retrieve()
                    .bodyToMono(Map.class)
                    .timeout(Duration.ofSeconds(10))
                    .block();
        } catch (WebClientResponseException e) {
            throw new SheException("CA_SERVICE_ERROR",
                    "step-ca POST " + path + " -> " + e.getStatusCode() + ": "
                            + e.getResponseBodyAsString(), 502, e);
        }
    }

    // =========================================================================
    // FETCH CRL
    // =========================================================================

    /**
     * Fetch the latest CRL from step-ca. Used by the scheduled verification job
     * (every 6 hours per P1-22) to compare the CA's CRL against the published one.
     */
    public byte[] fetchCrl(String intermediateId) {
        // step-ca serves the CRL at GET /crl. /crl/{id} and /1/crl were guessed and
        // are 404 on every version we have run (verified on 0.27.4) — kept only as
        // legacy fallbacks, after the path that actually works, so the common case
        // costs one request instead of three.
        for (String path : new String[]{"/crl", "/crl/" + intermediateId, "/1/crl"}) {
            try {
                byte[] crl = webClient.get()
                        .uri(path)
                        .retrieve()
                        .bodyToMono(byte[].class)
                        .timeout(Duration.ofSeconds(10))
                        .block();
                if (crl != null && crl.length > 0) return crl;
            } catch (Exception e) {
                log.debug("CRL fetch failed at {}: {}", path, e.getMessage());
            }
        }
        throw new SheException("CA_SERVICE_ERROR",
                "step-ca did not serve CRL at any known path", 502);
    }

    // =========================================================================
    // HEALTH CHECK
    // =========================================================================

    public boolean isHealthy() {
        try {
            webClient.get()
                    .uri("/health")
                    .retrieve()
                    .bodyToMono(String.class)
                    .timeout(Duration.ofSeconds(3))
                    .block();
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
