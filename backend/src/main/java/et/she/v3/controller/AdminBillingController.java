package et.she.v3.controller;

import et.she.v3.entity.Payment;
import et.she.v3.entity.Subscription;
import et.she.v3.errors.SheException;
import et.she.v3.repository.PaymentRepository;
import et.she.v3.repository.SubscriptionRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Admin billing endpoints.
 * V3-ADMIN-PLATFORM §4.6.
 *
 *   GET  /api/admin/billing/overview               — KPI cards (MRR, outstanding, next invoice)
 *   GET  /api/admin/billing/invoices                — invoice list (payments table)
 *   GET  /api/admin/billing/invoices/{id}           — invoice detail
 *   POST /api/admin/billing/invoices/{id}/mark-paid  — manual bank-transfer reconciliation (SUPER_ADMIN)
 *   GET  /api/admin/billing/invoices/{id}/pdf        — download invoice PDF (TODO: PDF generation)
 *
 * Auth: TENANT_ADMIN+ for own tenant, SUPER_ADMIN for any.
 */
@RestController
@RequestMapping("/api/admin/billing")
public class AdminBillingController {

    private final PaymentRepository paymentRepository;
    private final SubscriptionRepository subscriptionRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public AdminBillingController(PaymentRepository paymentRepository,
                                    SubscriptionRepository subscriptionRepository,
                                    TenantContextInterceptor tenantContextInterceptor) {
        this.paymentRepository = paymentRepository;
        this.subscriptionRepository = subscriptionRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    @GetMapping("/overview")
    public ResponseEntity<Map<String, Object>> overview() {
        AuthenticatedUser admin = currentUser();
        UUID tenantId = admin.tenantId();
        if (tenantId == null) {
            return ResponseEntity.ok(Map.of("data", Map.of("message", "B2C user — no billing overview")));
        }

        List<Payment> allPayments = paymentRepository.findAllByTenantId(tenantId);
        List<Subscription> subs = subscriptionRepository.findAllByTenantId(tenantId);

        // Calculate MRR (monthly recurring revenue)
        BigDecimal mrr = BigDecimal.ZERO;
        for (Subscription sub : subs) {
            if ("ACTIVE".equals(sub.getStatus())) {
                BigDecimal price = switch (sub.getPlan()) {
                    case "B2C_PREMIUM" -> new BigDecimal("150.00");
                    case "B2C_FAMILY" -> new BigDecimal("300.00");
                    case "B2B_100" -> new BigDecimal("5500.00");
                    case "B2B_1000" -> new BigDecimal("44000.00");
                    case "B2B_UNLIMITED" -> new BigDecimal("110000.00");
                    default -> BigDecimal.ZERO;
                };
                mrr = mrr.add(price);
            }
        }

        // Outstanding balance
        BigDecimal outstanding = allPayments.stream()
                .filter(p -> "PENDING".equals(p.getStatus()))
                .map(Payment::getAmountEtb)
                .reduce(BigDecimal.ZERO, BigDecimal::add);

        // Next invoice date (25th of next month — V3-PAYMENTS §5)
        Instant nextInvoice = Instant.now()
                .plusSeconds(30 * 86400L)
                .truncatedTo(java.time.temporal.ChronoUnit.DAYS);

        // NOTE: this must NOT be Map.of(...). `Map.of` rejects null values and
        // throws NullPointerException, and `active_subscription` is legitimately
        // null when the tenant has no active subscription — which turned the
        // whole endpoint into a 500 (the admin console's billing screen broke).
        // Use a HashMap, which permits nulls, matching the documented contract
        // (`active_subscription` is `{plan, expires_at} | null`).
        Map<String, Object> body = new java.util.HashMap<>();
        body.put("mrr_etb", mrr.toPlainString());
        body.put("outstanding_etb", outstanding.toPlainString());
        body.put("next_invoice_date", nextInvoice.toString());
        body.put("total_payments", allPayments.size());
        body.put("active_subscription", subs.stream()
                .filter(s -> "ACTIVE".equals(s.getStatus()))
                .findFirst()
                .map(s -> Map.of("plan", s.getPlan(), "expires_at",
                        s.getExpiresAt() != null ? s.getExpiresAt().toString() : ""))
                .orElse(null));

        return ResponseEntity.ok(Map.of("data", body));
    }

    @GetMapping("/invoices")
    public ResponseEntity<Map<String, Object>> listInvoices() {
        AuthenticatedUser admin = currentUser();
        List<Payment> payments = paymentRepository.findAllByTenantId(admin.tenantId());
        var data = payments.stream()
                .map(p -> Map.of(
                        "id", p.getId(),
                        "amount_etb", p.getAmountEtb().toPlainString(),
                        "plan", p.getPlan(),
                        "status", p.getStatus(),
                        "created_at", p.getCreatedAt().toString(),
                        "paid_at", p.getPaidAt() != null ? p.getPaidAt().toString() : "",
                        "chapa_ref", p.getChapaRef() != null ? p.getChapaRef() : ""
                ))
                .toList();
        return ResponseEntity.ok(Map.of("data", data));
    }

    @GetMapping("/invoices/{id}")
    public ResponseEntity<Map<String, Object>> getInvoice(@PathVariable UUID id) {
        Payment payment = paymentRepository.findById(id)
                .orElseThrow(() -> new SheException("INVOICE_NOT_FOUND", "Invoice not found", 404));
        AuthenticatedUser admin = currentUser();
        if (!admin.isSuperAdmin() && !payment.getTenantId().equals(admin.tenantId())) {
            throw new SheException("RBAC_FORBIDDEN", "Cannot view invoice from another tenant", 403);
        }
        return ResponseEntity.ok(Map.of("data", Map.of(
                "id", payment.getId(),
                "amount_etb", payment.getAmountEtb().toPlainString(),
                "plan", payment.getPlan(),
                "status", payment.getStatus(),
                "created_at", payment.getCreatedAt().toString(),
                "paid_at", payment.getPaidAt() != null ? payment.getPaidAt().toString() : "",
                "chapa_ref", payment.getChapaRef() != null ? payment.getChapaRef() : "",
                "checkout_url", payment.getCheckoutUrl() != null ? payment.getCheckoutUrl() : ""
        )));
    }

    public record MarkPaidRequest(String payment_method, String note) {}

    @PostMapping("/invoices/{id}/mark-paid")
    public ResponseEntity<Map<String, Object>> markPaid(@PathVariable UUID id,
                                                         @RequestBody MarkPaidRequest req) {
        AuthenticatedUser admin = currentUser();
        if (!admin.isSuperAdmin()) {
            throw new SheException("RBAC_SUPER_ADMIN_REQUIRED",
                    "Only SUPER_ADMIN can manually mark invoices as paid", 403);
        }

        Payment payment = paymentRepository.findById(id)
                .orElseThrow(() -> new SheException("INVOICE_NOT_FOUND", "Invoice not found", 404));
        payment.setStatus("PAID");
        payment.setPaidAt(Instant.now());
        if (req.payment_method() != null) {
            payment.setChapaRef("manual:" + req.payment_method());
        }
        paymentRepository.save(payment);

        return ResponseEntity.ok(Map.of("data", Map.of(
                "id", payment.getId(),
                "status", "SUCCESS",
                "paid_at", payment.getPaidAt().toString(),
                "marked_by", admin.email()
        )));
    }

    @GetMapping("/invoices/{id}/pdf")
    public ResponseEntity<Map<String, Object>> downloadPdf(@PathVariable UUID id) {
        // TODO: generate PDF via Apache PDFBox + return as application/pdf
        // For Phase 3: return placeholder
        throw new SheException("NOT_IMPLEMENTED",
                "PDF generation not yet implemented — use GET /api/admin/billing/invoices/{id} for JSON", 501);
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
