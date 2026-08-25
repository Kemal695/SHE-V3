package et.she.v3.ca;

import et.she.v3.config.SheProperties;
import et.she.v3.errors.SheException;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.netty.http.client.HttpClient;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Map;

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
 *     body: { csr: "<PEM>", provisioner: "she-device-provisioner" }
 *     auth: Basic <provisioner-name>:<provisioner-password>
 *     resp: 200 OK { crt: "<PEM>", ca: ["<root>", "<intermediate>"], serial: "..." }
 *
 *   POST /revoke
 *     body: { serial: "<hex>", reason: "key_compromise", provisioner: "..." }
 *     auth: Basic
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
        log.info("step-ca client initialized — url={}, provisioner={}",
                url, props.ca().provisionerName());
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
        Map<String, Object> body = Map.of(
                "csr", csrPem,
                "provisioner", props.ca().provisionerName()
        );
        Map<String, Object> resp = webClient.post()
                .uri("/sign?format=pem")
                .headers(h -> h.setBasicAuth(props.ca().provisionerName(), provisionerPassword))
                .bodyValue(body)
                .retrieve()
                .bodyToMono(Map.class)
                .timeout(Duration.ofSeconds(10))
                .block();
        if (resp == null) {
            throw new SheException("CA_SERVICE_ERROR", "step-ca returned empty response", 502);
        }
        String crt = (String) resp.get("crt");
        if (crt == null) {
            throw new SheException("CA_SERVICE_ERROR", "step-ca response missing 'crt' field", 502);
        }
        return new SignResult(
                crt,
                (String) resp.getOrDefault("serial", ""),
                (String) resp.getOrDefault("fingerprint", "")
        );
    }

    public record SignResult(String certPem, String serial, String fingerprint) {}

    // =========================================================================
    // REVOKE device cert
    // =========================================================================

    public void revokeCert(String serial, String reason) {
        Map<String, Object> body = Map.of(
                "serial", serial,
                "reason", reason,
                "provisioner", props.ca().provisionerName()
        );
        webClient.post()
                .uri("/revoke")
                .headers(h -> h.setBasicAuth(props.ca().provisionerName(), provisionerPassword))
                .bodyValue(body)
                .retrieve()
                .bodyToMono(Map.class)
                .timeout(Duration.ofSeconds(10))
                .block();
        log.info("Cert revoked — serial={}, reason={}", serial, reason);
    }

    // =========================================================================
    // FETCH CRL
    // =========================================================================

    /**
     * Fetch the latest CRL from step-ca. Used by the scheduled refresh job
     * (every 6 hours per P1-22) to update the nginx-served CRL file.
     */
    public byte[] fetchCrl(String intermediateId) {
        // step-ca serves CRL at /crl/{cert-id} — try common paths
        for (String path : new String[]{"/crl/" + intermediateId, "/1/crl", "/crl"}) {
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
