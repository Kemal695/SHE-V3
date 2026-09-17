package et.she.v3.payment;

import et.she.v3.errors.SheException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
import java.util.Map;

/**
 * Chapa payment aggregator client — Telebirr + CBE Birr + cards.
 *
 * V3-PAYMENTS §3. ADR-005: Chapa aggregator for Telebirr/CBE Birr.
 *
 * Chapa API:
 *   POST https://api.chapa.co/v1/transaction/initialize
 *   GET  https://api.chapa.co/v1/transaction/verify/{tx_ref}
 *   POST https://api.chapa.co/v1/transaction/refund/{tx_ref}
 *
 * Auth: Bearer CHAPA_SECRET_KEY (env var, never committed).
 */
@Service
public class ChapaClient {

    private static final Logger log = LoggerFactory.getLogger(ChapaClient.class);

    @Value("${she.payment.chapa.api-base-url:https://api.chapa.co/v1}")
    private String apiBaseUrl;

    @Value("${she.payment.chapa.secret-key:}")
    private String secretKey;

    private final ObjectMapper objectMapper;
    private WebClient webClient;

    public ChapaClient(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    @PostConstruct
    void init() {
        if (secretKey == null || secretKey.isBlank()) {
            log.warn("CHAPA_SECRET_KEY not set — payment integration will fail. Set she.payment.chapa.secret-key env var.");
        }
        this.webClient = WebClient.builder()
                .baseUrl(apiBaseUrl)
                .defaultHeader("Authorization", "Bearer " + secretKey)
                .defaultHeader("Content-Type", "application/json")
                .build();
        log.info("ChapaClient initialized — baseUrl={}", apiBaseUrl);
    }

    // =========================================================================
    // INITIALIZE — POST /v1/transaction/initialize
    // =========================================================================

    public record InitRequest(
            String amount,
            String currency,
            String email,
            String first_name,
            String last_name,
            String tx_ref,
            String callback_url,
            String return_url,
            Map<String, String> customization
    ) {}

    public record InitResponse(
            String checkout_url,
            String tx_ref,
            String status
    ) {}

    public InitResponse initialize(InitRequest req) {
        Map<String, Object> body = Map.of(
                "amount", req.amount(),
                "currency", req.currency(),
                "email", req.email(),
                "first_name", req.first_name(),
                "last_name", req.last_name(),
                "tx_ref", req.tx_ref(),
                "callback_url", req.callback_url(),
                "return_url", req.return_url(),
                "customization", req.customization()
        );

        JsonNode resp = webClient.post()
                .uri("/transaction/initialize")
                .bodyValue(body)
                .retrieve()
                .bodyToMono(JsonNode.class)
                .timeout(Duration.ofSeconds(15))
                .block();

        if (resp == null) {
            throw new SheException("PAYMENT_PROVIDER_UNAVAILABLE", "Chapa returned empty response", 502);
        }

        String status = resp.path("status").asText();
        if (!"success".equals(status)) {
            log.error("Chapa initialize failed: status={} message={}", status, resp.path("message").asText());
            throw new SheException("PAYMENT_INITIATION_FAILED",
                    "Chapa initialization failed: " + resp.path("message").asText(), 502);
        }

        JsonNode data = resp.path("data");
        return new InitResponse(
                data.path("checkout_url").asText(),
                data.path("tx_ref").asText(),
                data.path("status").asText()
        );
    }

    // =========================================================================
    // VERIFY — GET /v1/transaction/verify/{tx_ref}
    // =========================================================================

    public record VerifyResponse(
            String status,
            String amount,
            String currency,
            String reference
    ) {}

    public VerifyResponse verify(String txRef) {
        JsonNode resp = webClient.get()
                .uri("/transaction/verify/{txRef}", txRef)
                .retrieve()
                .bodyToMono(JsonNode.class)
                .timeout(Duration.ofSeconds(10))
                .block();

        if (resp == null) {
            throw new SheException("PAYMENT_PROVIDER_UNAVAILABLE", "Chapa verify returned empty", 502);
        }

        JsonNode data = resp.path("data");
        return new VerifyResponse(
                data.path("status").asText(),
                data.path("amount").asText(),
                data.path("currency").asText(),
                data.path("reference").asText()
        );
    }

    // =========================================================================
    // REFUND — POST /v1/transaction/refund/{tx_ref}
    // =========================================================================

    public VerifyResponse refund(String txRef) {
        JsonNode resp = webClient.post()
                .uri("/transaction/refund/{txRef}", txRef)
                .retrieve()
                .bodyToMono(JsonNode.class)
                .timeout(Duration.ofSeconds(15))
                .block();

        if (resp == null) {
            throw new SheException("PAYMENT_REFUND_FAILED", "Chapa refund returned empty", 502);
        }

        JsonNode data = resp.path("data");
        return new VerifyResponse(
                data.path("status").asText(),
                data.path("amount").asText(),
                data.path("currency").asText(),
                data.path("reference").asText()
        );
    }

    public boolean isHealthy() {
        try {
            webClient.get().uri("/health").retrieve().bodyToMono(String.class)
                    .timeout(Duration.ofSeconds(3)).block();
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
