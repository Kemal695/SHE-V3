package et.she.v3.billing;

import et.she.v3.entity.Payment;
import et.she.v3.entity.Subscription;
import et.she.v3.entity.Tenant;
import et.she.v3.repository.PaymentRepository;
import et.she.v3.repository.SubscriptionRepository;
import et.she.v3.repository.TenantRepository;
import et.she.v3.security.TenantContextInterceptor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Billing + invoice service.
 *
 * V3-PAYMENTS §5-9.
 *
 * Scheduled jobs:
 *   - B2B invoice generation: monthly on 25th at 09:00 Addis
 *   - Failed payment retry: daily at 09:00 Addis (Day 1, 3, 7 retry schedule)
 *   - Subscription suspension: daily at 09:00 Addis (7-day grace → SUSPENDED)
 *   - Daily reconciliation: 02:00 UTC (verify Chapa settlements)
 *   - Monthly reconciliation: 1st of month
 */
@Service
@Transactional
public class BillingService {

    private static final Logger log = LoggerFactory.getLogger(BillingService.class);
    private static final ZoneId ADDIS_ZONE = ZoneId.of("Africa/Addis_Ababa");

    // Plan prices in ETB (V3-PAYMENTS §4)
    private static final Map<String, BigDecimal> PLAN_PRICES_ETB = Map.of(
            "B2C_PREMIUM", new BigDecimal("150.00"),
            "B2C_FAMILY", new BigDecimal("300.00"),
            "B2B_100", new BigDecimal("5500.00"),
            "B2B_1000", new BigDecimal("44000.00"),
            "B2B_UNLIMITED", new BigDecimal("110000.00")
    );

    private final TenantRepository tenantRepository;
    private final PaymentRepository paymentRepository;
    private final SubscriptionRepository subscriptionRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public BillingService(TenantRepository tenantRepository,
                         PaymentRepository paymentRepository,
                         SubscriptionRepository subscriptionRepository,
                         TenantContextInterceptor tenantContextInterceptor) {
        this.tenantRepository = tenantRepository;
        this.paymentRepository = paymentRepository;
        this.subscriptionRepository = subscriptionRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    // =========================================================================
    // B2B invoice generation — monthly on 25th at 09:00 Addis
    // V3-PAYMENTS §5: "monthly, auto-invoiced on the 25th of each month"
    // =========================================================================

    @Scheduled(cron = "0 0 9 25 * *", zone = "Africa/Addis_Ababa")
    public void generateB2BInvoices() {
        log.info("=== B2B invoice generation started ===");

        // Set platform-admin GUC for cross-tenant query
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        // Find all ACTIVE B2B tenants
        List<Tenant> b2bTenants = tenantRepository.findAll().stream()
                .filter(t -> "ACTIVE".equals(t.getStatus()))
                .filter(t -> t.getPlan() != null && t.getPlan().startsWith("B2B"))
                .toList();

        int generated = 0;
        for (Tenant tenant : b2bTenants) {
            try {
                generateInvoiceForTenant(tenant);
                generated++;
            } catch (Exception e) {
                log.error("Invoice generation failed for tenant {}: {}", tenant.getId(), e.getMessage());
            }
        }

        log.info("=== B2B invoice generation complete: {}/{} invoices generated ===", generated, b2bTenants.size());
    }

    private void generateInvoiceForTenant(Tenant tenant) {
        BigDecimal amount = PLAN_PRICES_ETB.get(tenant.getPlan());
        if (amount == null) {
            log.warn("Unknown plan {} for tenant {} — skipping", tenant.getPlan(), tenant.getId());
            return;
        }

        // Check if invoice already generated this month (idempotency)
        Instant monthStart = ZonedDateTime.now(ADDIS_ZONE).withDayOfMonth(1).withHour(0).withMinute(0).withSecond(0).toInstant();
        boolean alreadyInvoiced = paymentRepository.findAllByTenantId(tenant.getId()).stream()
                .anyMatch(p -> p.getCreatedAt().isAfter(monthStart) && "B2B".equals(p.getPlan().substring(0, 3)));

        if (alreadyInvoiced) {
            log.debug("Tenant {} already invoiced this month — skipping", tenant.getId());
            return;
        }

        // Create payment record (status=PENDING)
        Payment payment = new Payment();
        payment.setTenantId(tenant.getId());
        payment.setUserId(null);   // B2B = tenant-level payment, no user
        payment.setIdempotencyKey(UUID.randomUUID());
        payment.setAmountEtb(amount);
        payment.setPlan(tenant.getPlan());
        payment.setStatus("PENDING");
        paymentRepository.save(payment);

        log.info("Invoice generated: tenant={} plan={} amount={}ETB payment_id={}",
                tenant.getId(), tenant.getPlan(), amount, payment.getId());

        // TODO: generate PDF invoice + email to tenant admin
        // TODO: upload PDF to MinIO s3://she-invoices/{tenant_id}/{invoice_id}.pdf
    }

    // =========================================================================
    // Failed payment retry + subscription suspension — daily at 09:00 Addis
    // V3-PAYMENTS §5: 3 retries over 7 days (Day 1, 3, 7), then SUSPENDED
    // =========================================================================

    @Scheduled(cron = "0 0 9 * * *", zone = "Africa/Addis_Ababa")
    public void processFailedPayments() {
        log.info("=== Failed payment processing started ===");

        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        Instant now = Instant.now();
        Instant day1 = now.minusSeconds(1 * 86400L);
        Instant day3 = now.minusSeconds(3 * 86400L);
        Instant day7 = now.minusSeconds(7 * 86400L);
        Instant day30 = now.minusSeconds(30 * 86400L);

        // Day 1: send reminder email (TODO: email service)
        List<Payment> day1Payments = paymentRepository.findPendingBefore("PENDING", day1);
        day1Payments.stream().filter(p -> p.getCreatedAt().isAfter(day3))
                .forEach(p -> log.info("Day 1 reminder: payment={}", p.getId()));

        // Day 3: send reminder + re-initiate payment (TODO)
        List<Payment> day3Payments = paymentRepository.findPendingBefore("PENDING", day3);
        day3Payments.stream().filter(p -> p.getCreatedAt().isAfter(day7))
                .forEach(p -> log.info("Day 3 reminder: payment={}", p.getId()));

        // Day 7: suspend subscription (devices still work, users can't login)
        List<Payment> day7Payments = paymentRepository.findPendingBefore("PENDING", day7);
        for (Payment payment : day7Payments) {
            log.warn("Day 7 SUSPENSION: payment={} tenant={}", payment.getId(), payment.getTenantId());
            suspendSubscription(payment.getTenantId());
        }

        // Day 30: expire/terminate
        List<Payment> day30Payments = paymentRepository.findPendingBefore("PENDING", day30);
        for (Payment payment : day30Payments) {
            log.warn("Day 30 EXPIRATION: payment={} tenant={}", payment.getId(), payment.getTenantId());
            expireSubscription(payment.getTenantId());
        }

        log.info("=== Failed payment processing complete ===");
    }

    private void suspendSubscription(UUID tenantId) {
        subscriptionRepository.findByTenantIdAndStatus(tenantId, "ACTIVE")
                .ifPresent(sub -> {
                    sub.setStatus("SUSPENDED");
                    subscriptionRepository.save(sub);
                    log.info("Subscription suspended: tenant={}", tenantId);
                    // V3-PAYMENTS §5: devices STILL WORK (safety — do not turn off lights)
                    // V3-B2B-WHITELABEL §2.8: users cannot login (frontend blocks)
                });
    }

    private void expireSubscription(UUID tenantId) {
        subscriptionRepository.findByTenantIdAndStatus(tenantId, "SUSPENDED")
                .ifPresent(sub -> {
                    sub.setStatus("EXPIRED");
                    subscriptionRepository.save(sub);
                    log.info("Subscription expired: tenant={}", tenantId);
                });
        // Also set tenant status to TERMINATED (B2B) — V3-B2B-WHITELABEL §2.8
        tenantRepository.findById(tenantId).ifPresent(tenant -> {
            tenant.setStatus("TERMINATED");
            tenantRepository.save(tenant);
        });
    }

    // =========================================================================
    // Daily reconciliation — 02:00 UTC
    // V3-PAYMENTS §9: verify all SUCCESS payments against Chapa
    // =========================================================================

    @Scheduled(cron = "0 0 2 * * *", zone = "UTC")
    public void dailyReconciliation() {
        log.info("=== Daily reconciliation started ===");

        // TODO: for each payment with status=SUCCESS and paid_at in last 24h:
        //   1. Call chapaClient.verify(payment.id)
        //   2. If verify status != "success" → log SEV-2 alert + audit_log
        //   3. Generate daily report → email to SUPER_ADMIN

        log.info("=== Daily reconciliation complete (stub — TODO in Phase 5B) ===");
    }
}
