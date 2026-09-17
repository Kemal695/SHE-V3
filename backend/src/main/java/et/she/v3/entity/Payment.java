package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

/**
 * Payment entity — Chapa/Telebirr transaction.
 * V3-DATABASE-DESIGN §4.12. Migration V15.
 * P2-4: UNIQUE(idempotency_key, tenant_id) is payment idempotency source of truth.
 */
@Entity
@Table(name = "payments")
public class Payment {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "user_id")
    private UUID userId;

    @Column(name = "idempotency_key", nullable = false)
    private UUID idempotencyKey;

    @Column(name = "amount_etb", nullable = false, precision = 10, scale = 2)
    private BigDecimal amountEtb;

    @Column(name = "plan", nullable = false, length = 20)
    private String plan;

    @Column(name = "status", nullable = false, length = 20)
    private String status = "PENDING";   // PENDING | PAID | FAILED | REFUNDED

    @Column(name = "chapa_ref", unique = true, length = 100)
    private String chapaRef;

    @Column(name = "checkout_url")
    private String checkoutUrl;

    @Column(name = "paid_at")
    private Instant paidAt;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    // Getters/setters
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getUserId() { return userId; }
    public void setUserId(UUID userId) { this.userId = userId; }
    public UUID getIdempotencyKey() { return idempotencyKey; }
    public void setIdempotencyKey(UUID idempotencyKey) { this.idempotencyKey = idempotencyKey; }
    public BigDecimal getAmountEtb() { return amountEtb; }
    public void setAmountEtb(BigDecimal amountEtb) { this.amountEtb = amountEtb; }
    public String getPlan() { return plan; }
    public void setPlan(String plan) { this.plan = plan; }
    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
    public String getChapaRef() { return chapaRef; }
    public void setChapaRef(String chapaRef) { this.chapaRef = chapaRef; }
    public String getCheckoutUrl() { return checkoutUrl; }
    public void setCheckoutUrl(String checkoutUrl) { this.checkoutUrl = checkoutUrl; }
    public Instant getPaidAt() { return paidAt; }
    public void setPaidAt(Instant paidAt) { this.paidAt = paidAt; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
}
