package et.she.v3.payment;

import et.she.v3.entity.Payment;
import et.she.v3.entity.Subscription;
import et.she.v3.entity.User;
import et.she.v3.errors.SheException;
import et.she.v3.repository.PaymentRepository;
import et.she.v3.repository.SubscriptionRepository;
import et.she.v3.repository.UserRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import et.she.v3.websocket.WsEventBus;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.reactive.function.client.WebClientException;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.math.BigDecimal;
import java.security.MessageDigest;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/**
 * Payment service — Chapa integration + subscription management.
 *
 * V3-PAYMENTS §3-6. ADR-005: Chapa aggregator for Telebirr/CBE Birr.
 *
 * Idempotency (P2-4): Postgres UNIQUE(idempotency_key, tenant_id) is source of truth.
 * Redis cache (24h TTL) for fast de-dup of webhook calls.
 *
 * Subscription plans (V3-PAYMENTS §4):
 *   B2C_FREE (0 ETB), B2C_PREMIUM (150 ETB), B2C_FAMILY (300 ETB)
 *   B2B_100 ($100/mo), B2B_1000 ($800/mo), B2B_UNLIMITED ($2000+/mo)
 *
 * Webhook flow (V3-PAYMENTS §3.2):
 *   1. Verify HMAC-SHA256 (constant-time compare)
 *   2. Idempotency check (Redis + Postgres UNIQUE)
 *   3. Verify amount matches payment record
 *   4. UPDATE payments SET status='SUCCESS'
 *   5. INSERT or extend subscription (+30 days)
 *   6. WebSocket push: subscription_activated
 *   7. Audit log: payment.completed
 */
@Service
@Transactional
public class PaymentService {

    private static final Logger log = LoggerFactory.getLogger(PaymentService.class);

    private static final String REDIS_IDEMPOTENCY_PREFIX = "payment:idem:";
    private static final String REDIS_JTI_BLACKLIST_PREFIX = "jwt:jti:revoked:";

    private final ChapaClient chapaClient;
    private final PaymentRepository paymentRepository;
    private final SubscriptionRepository subscriptionRepository;
    private final UserRepository userRepository;
    private final StringRedisTemplate redis;
    private final TenantContextInterceptor tenantContextInterceptor;
    private final WsEventBus wsEventBus;

    @org.springframework.beans.factory.annotation.Value("${she.payment.chapa.webhook-secret:}")
    private String webhookSecret;

    @org.springframework.beans.factory.annotation.Value("${she.payment.chapa.callback-url:http://localhost:8080/api/v3/payments/webhook}")
    private String callbackUrl;

    @org.springframework.beans.factory.annotation.Value("${she.payment.chapa.return-url:she-app://payments/success}")
    private String returnUrl;

    // Plan prices in ETB (V3-PAYMENTS §4)
    private static final Map<String, BigDecimal> PLAN_PRICES_ETB = Map.of(
            "B2C_FREE", BigDecimal.ZERO,
            "B2C_PREMIUM", new BigDecimal("150.00"),
            "B2C_FAMILY", new BigDecimal("300.00"),
            "B2B_100", new BigDecimal("5500.00"),       // ~$100 at 55 ETB/$
            "B2B_1000", new BigDecimal("44000.00"),     // ~$800
            "B2B_UNLIMITED", new BigDecimal("110000.00") // ~$2000
    );

    public PaymentService(ChapaClient chapaClient,
                          PaymentRepository paymentRepository,
                          SubscriptionRepository subscriptionRepository,
                          UserRepository userRepository,
                          StringRedisTemplate redis,
                          TenantContextInterceptor tenantContextInterceptor,
                          WsEventBus wsEventBus) {
        this.chapaClient = chapaClient;
        this.paymentRepository = paymentRepository;
        this.subscriptionRepository = subscriptionRepository;
        this.userRepository = userRepository;
        this.redis = redis;
        this.tenantContextInterceptor = tenantContextInterceptor;
        this.wsEventBus = wsEventBus;
    }

    // =========================================================================
    // INITIATE — POST /api/v3/payments/initiate
    // =========================================================================

    public InitiatePaymentResponse initiatePayment(InitiatePaymentRequest req) {
        AuthenticatedUser user = currentUser();
        User userEntity = userRepository.findActiveById(user.userId())
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "User not found", 404));

        // Server-side amount validation (V3-PAYMENTS §11 — never trust client amount)
        BigDecimal expectedAmount = PLAN_PRICES_ETB.get(req.plan());
        if (expectedAmount == null) {
            throw new SheException("PAYMENT_PLAN_INVALID",
                    "Unknown plan: " + req.plan() + ". Valid: B2C_PREMIUM, B2C_FAMILY, B2B_*", 400);
        }
        if (expectedAmount.compareTo(BigDecimal.ZERO) == 0) {
            throw new SheException("PAYMENT_PLAN_INVALID", "Cannot initiate payment for FREE plan", 400);
        }

        // Generate idempotency key (UUID v4)
        UUID idempotencyKey = req.idempotency_key() != null ?
                UUID.fromString(req.idempotency_key()) : UUID.randomUUID();

        // Idempotency pre-check — if client retries with same key, return existing payment
        if (paymentRepository.existsByIdempotencyKeyAndTenantId(idempotencyKey, user.tenantId())) {
            // Find existing payment + return its checkout_url
            Payment existing = paymentRepository.findAllByTenantId(user.tenantId()).stream()
                    .filter(p -> idempotencyKey.equals(p.getIdempotencyKey()))
                    .findFirst()
                    .orElseThrow(() -> new SheException("INTERNAL_ERROR", "Idempotency check passed but lookup failed", 500));
            log.info("Idempotent retry: returning existing payment id={}", existing.getId());
            return new InitiatePaymentResponse(
                    existing.getId(),
                    existing.getCheckoutUrl(),
                    existing.getAmountEtb().toPlainString(),
                    "ETB",
                    existing.getPlan()
            );
        }

        // Create payment record (status=PENDING)
        Payment payment = new Payment();
        payment.setTenantId(user.tenantId());
        payment.setUserId(user.userId());
        payment.setIdempotencyKey(idempotencyKey);
        payment.setAmountEtb(expectedAmount);   // server-validated, not client-supplied
        payment.setPlan(req.plan());
        payment.setStatus("PENDING");
        payment = paymentRepository.save(payment);

        // Call Chapa to initialize
        ChapaClient.InitRequest chapaReq = new ChapaClient.InitRequest(
                expectedAmount.setScale(2).toPlainString(),
                "ETB",
                userEntity.getEmail(),
                userEntity.getFullName() != null ? userEntity.getFullName().split(" ")[0] : "User",
                userEntity.getFullName() != null && userEntity.getFullName().contains(" ") ?
                        userEntity.getFullName().split(" ", 2)[1] : "",
                payment.getId().toString(),      // tx_ref = payment.id
                callbackUrl,
                returnUrl,
                Map.of("title", "SHE " + req.plan(), "description", "Monthly subscription")
        );

        ChapaClient.InitResponse chapaResp;
        try {
            chapaResp = chapaClient.initialize(chapaReq);
        } catch (WebClientException e) {
            // Chapa unreachable / unconfigured (e.g. missing CHAPA_SECRET_KEY → 401).
            // Fail closed with 502 Bad Gateway rather than leaking a 500. Per
            // PHASE3-SIGNOFF §5 the local-dev path is "502 = Chapa not configured".
            throw new SheException("PAYMENT_PROVIDER_UNAVAILABLE",
                    "Chapa payment provider unreachable: " + e.getMessage(), 502, e);
        }

        // Store checkout_url for the Flutter app
        payment.setCheckoutUrl(chapaResp.checkout_url());
        paymentRepository.save(payment);

        log.info("Payment initiated: id={} plan={} amount={}ETB tx_ref={}",
                payment.getId(), req.plan(), expectedAmount, payment.getId());

        return new InitiatePaymentResponse(
                payment.getId(),
                chapaResp.checkout_url(),
                expectedAmount.toPlainString(),
                "ETB",
                req.plan()
        );
    }

    // =========================================================================
    // WEBHOOK — POST /api/v3/payments/webhook
    // =========================================================================

    /**
     * Process Chapa webhook.
     *
     * V3-PAYMENTS §3.2 — 7-step sequence:
     *   1. Verify HMAC-SHA256 (constant-time compare)
     *   2. Idempotency check (Redis + Postgres UNIQUE)
     *   3. Verify amount matches payment record
     *   4. UPDATE payments SET status='SUCCESS'
     *   5. INSERT or extend subscription (+30 days)
     *   6. WebSocket push: subscription_activated
     *   7. Audit log: payment.completed
     */
    public WebhookResponse processWebhook(String rawBody, String signatureHeader) {
        // Step 1: Verify HMAC-SHA256 signature (constant-time compare)
        if (webhookSecret == null || webhookSecret.isBlank()) {
            log.error("CHAPA_WEBHOOK_SECRET not set — cannot verify webhook");
            throw new SheException("INTERNAL_ERROR", "Webhook secret not configured", 500);
        }
        if (!verifySignature(rawBody, signatureHeader)) {
            log.warn("Webhook signature verification FAILED");
            throw new SheException("PAYMENT_WEBHOOK_INVALID_SIGNATURE",
                    "Invalid webhook signature", 401);
        }

        // Parse webhook body
        com.fasterxml.jackson.databind.ObjectMapper mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        com.fasterxml.jackson.databind.JsonNode body;
        try {
            body = mapper.readTree(rawBody);
        } catch (Exception e) {
            throw new SheException("VALIDATION_INVALID_JSON", "Malformed webhook body", 400);
        }

        String event = body.path("event").asText();
        String txRef = body.path("tx_ref").asText();
        String amount = body.path("amount").asText();
        String chapaRef = body.path("reference").asText();
        String status = body.path("status").asText();

        if (!"charge.success".equals(event)) {
            log.info("Ignoring webhook event: {}", event);
            return new WebhookResponse("ignored", "Event: " + event);
        }

        // Step 2: Idempotency check — Redis first (fast path)
        String idemKey = REDIS_IDEMPOTENCY_PREFIX + txRef;
        if (Boolean.TRUE.equals(redis.hasKey(idemKey))) {
            log.info("Webhook already processed (Redis cache hit): tx_ref={}", txRef);
            return new WebhookResponse("duplicate", "Payment already processed");
        }

        // Look up the payment record
        UUID paymentId;
        try {
            paymentId = UUID.fromString(txRef);
        } catch (IllegalArgumentException e) {
            throw new SheException("VALIDATION_FAILED", "Invalid tx_ref: " + txRef, 400);
        }

        // Set platform-admin GUC for cross-tenant lookup (payment could be any tenant)
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        Payment payment = paymentRepository.findById(paymentId)
                .orElseThrow(() -> new SheException("PAYMENT_NOT_FOUND",
                        "Payment " + txRef + " not found", 404));

        // Already processed?
        if ("PAID".equals(payment.getStatus())) {
            log.info("Webhook already processed (DB status=SUCCESS): tx_ref={}", txRef);
            // Set Redis cache for future webhooks
            redis.opsForValue().set(idemKey, payment.getId().toString(), 24, TimeUnit.HOURS);
            return new WebhookResponse("duplicate", "Payment already processed");
        }

        // Step 3: Verify amount matches
        BigDecimal expectedAmount = payment.getAmountEtb();
        BigDecimal receivedAmount = new BigDecimal(amount);
        if (receivedAmount.compareTo(expectedAmount) != 0) {
            log.error("Webhook amount mismatch: expected={} received={}", expectedAmount, receivedAmount);
            throw new SheException("PAYMENT_AMOUNT_INVALID",
                    "Amount mismatch: expected " + expectedAmount + " got " + receivedAmount, 400);
        }

        // Step 4: Update payment status
        payment.setStatus("PAID");
        payment.setChapaRef(chapaRef);
        payment.setPaidAt(Instant.now());
        paymentRepository.save(payment);

        // Step 5: Activate or extend subscription (+30 days)
        activateOrExtendSubscription(payment);

        // Step 6: WebSocket push
        wsEventBus.publishSubscriptionActivated(payment.getTenantId(), payment.getUserId(), payment.getPlan());

        // Step 7: Audit log (TODO: write to audit_log table)
        log.info("Payment completed: id={} plan={} amount={}ETB chapa_ref={}",
                payment.getId(), payment.getPlan(), expectedAmount, chapaRef);

        // Set Redis idempotency cache (24h TTL)
        redis.opsForValue().set(idemKey, payment.getId().toString(), 24, TimeUnit.HOURS);

        return new WebhookResponse("success", "Payment processed");
    }

    // =========================================================================
    // VERIFY — GET /api/v3/payments/verify/{txRef}
    // =========================================================================

    public VerifyPaymentResponse verifyPayment(String txRef) {
        ChapaClient.VerifyResponse chapaResp = chapaClient.verify(txRef);

        UUID paymentId = UUID.fromString(txRef);
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);
        Payment payment = paymentRepository.findById(paymentId).orElse(null);

        return new VerifyPaymentResponse(
                chapaResp.status(),
                chapaResp.amount(),
                chapaResp.currency(),
                payment != null ? payment.getPlan() : null,
                payment != null ? payment.getStatus() : null
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /**
     * Activate or extend a subscription by 30 days.
     */
    private void activateOrExtendSubscription(Payment payment) {
        var existing = subscriptionRepository.findByTenantIdAndStatus(payment.getTenantId(), "ACTIVE");

        Subscription sub;
        if (existing.isPresent()) {
            // Extend existing subscription
            sub = existing.get();
            Instant currentExpiry = sub.getExpiresAt() != null ? sub.getExpiresAt() : Instant.now();
            // If already expired, extend from now
            if (currentExpiry.isBefore(Instant.now())) {
                currentExpiry = Instant.now();
            }
            sub.setExpiresAt(currentExpiry.plus(30, ChronoUnit.DAYS));
            sub.setPaymentId(payment.getId());
            log.info("Subscription extended: tenant={} new_expiry={}", payment.getTenantId(), sub.getExpiresAt());
        } else {
            // Create new subscription
            sub = new Subscription();
            sub.setTenantId(payment.getTenantId());
            sub.setPlan(payment.getPlan());
            sub.setStatus("ACTIVE");
            sub.setStartedAt(Instant.now());
            sub.setExpiresAt(Instant.now().plus(30, ChronoUnit.DAYS));
            sub.setPaymentId(payment.getId());
            log.info("Subscription activated: tenant={} plan={} expires={}",
                    payment.getTenantId(), payment.getPlan(), sub.getExpiresAt());
        }
        subscriptionRepository.save(sub);
    }

    /**
     * Verify HMAC-SHA256 webhook signature (constant-time compare per V3-PAYMENTS §3.2).
     */
    private boolean verifySignature(String body, String signature) {
        if (signature == null || signature.isBlank()) return false;
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(webhookSecret.getBytes(), "HmacSHA256"));
            byte[] computed = mac.doFinal(body.getBytes());
            // Encode as hex
            StringBuilder sb = new StringBuilder();
            for (byte b : computed) sb.append(String.format("%02x", b));
            String computedHex = sb.toString();

            // Constant-time compare
            return MessageDigest.isEqual(computedHex.getBytes(), signature.trim().getBytes());
        } catch (Exception e) {
            log.error("Signature verification error: {}", e.getMessage());
            return false;
        }
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }

    // =========================================================================
    // DTOs
    // =========================================================================

    public record InitiatePaymentRequest(
            String plan,                // B2C_PREMIUM | B2C_FAMILY | B2B_*
            String idempotency_key      // optional UUID v4
    ) {}

    public record InitiatePaymentResponse(
            UUID payment_id,
            String checkout_url,
            String amount,
            String currency,
            String plan
    ) {}

    public record WebhookResponse(String status, String message) {}

    public record VerifyPaymentResponse(
            String chapa_status,
            String amount,
            String currency,
            String plan,
            String payment_status
    ) {}
}
