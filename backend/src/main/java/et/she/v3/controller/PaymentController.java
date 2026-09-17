package et.she.v3.controller;

import et.she.v3.payment.PaymentService;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.UUID;

/**
 * Payment REST endpoints — Chapa/Telebirr integration.
 * V3-API-SPECIFICATION §11. V3-PAYMENTS §3.
 *
 *   POST /api/v3/payments/initiate   — initiate payment (auth required)
 *   POST /api/v3/payments/webhook    — Chapa webhook (public, HMAC verified)
 *   GET  /api/v3/payments/verify/{ref} — verify payment status (auth required)
 *   GET  /api/v3/subscriptions/current — current subscription (auth required)
 */
@RestController
@RequestMapping("/api/v3")
public class PaymentController {

    private final PaymentService paymentService;
    private final et.she.v3.payment.SubscriptionService subscriptionService;

    public PaymentController(PaymentService paymentService,
                             et.she.v3.payment.SubscriptionService subscriptionService) {
        this.paymentService = paymentService;
        this.subscriptionService = subscriptionService;
    }

    // ─── POST /api/v3/payments/initiate ────────────────────────────────────────
    public record InitiateRequest(
            @NotBlank String plan,                // B2C_PREMIUM | B2C_FAMILY | B2B_*
            UUID idempotency_key                  // optional
    ) {}

    @PostMapping("/payments/initiate")
    public ResponseEntity<Map<String, Object>> initiate(@Valid @RequestBody InitiateRequest req) {
        var resp = paymentService.initiatePayment(
                new PaymentService.InitiatePaymentRequest(req.plan(), req.idempotency_key() != null ?
                        req.idempotency_key().toString() : null));
        return ResponseEntity.ok(Map.of("data", resp));
    }

    // ─── POST /api/v3/payments/webhook ─────────────────────────────────────────
    // Public endpoint — no JWT auth. Protected by HMAC-SHA256 signature.
    @PostMapping("/payments/webhook")
    public ResponseEntity<Map<String, Object>> webhook(HttpServletRequest request) {
        try {
            // Read raw body for HMAC verification
            String body = request.getReader().lines()
                    .collect(java.util.stream.Collectors.joining("\n"));
            String signature = request.getHeader("X-Chapa-Signature");

            var resp = paymentService.processWebhook(body, signature);
            return ResponseEntity.ok(Map.of("data", resp));
        } catch (et.she.v3.errors.SheException e) {
            // Webhook errors return 401 for signature mismatch, 400 for invalid data
            return ResponseEntity.status(e.getHttpStatus())
                    .body(Map.of("error", Map.of(
                            "code", e.getCode(),
                            "message", e.getMessage(),
                            "http_status", e.getHttpStatus()
                    )));
        } catch (Exception e) {
            return ResponseEntity.status(500)
                    .body(Map.of("error", Map.of(
                            "code", "INTERNAL_ERROR",
                            "message", e.getMessage(),
                            "http_status", 500
                    )));
        }
    }

    // ─── GET /api/v3/payments/verify/{txRef} ────────────────────────────────────
    @GetMapping("/payments/verify/{txRef}")
    public ResponseEntity<Map<String, Object>> verify(@PathVariable String txRef) {
        var resp = paymentService.verifyPayment(txRef);
        return ResponseEntity.ok(Map.of("data", resp));
    }

    // ─── GET /api/v3/subscriptions/current ─────────────────────────────────────
    @GetMapping("/subscriptions/current")
    public ResponseEntity<Map<String, Object>> currentSubscription() {
        var resp = subscriptionService.getCurrentSubscription();
        return ResponseEntity.ok(Map.of("data", resp));
    }
}
