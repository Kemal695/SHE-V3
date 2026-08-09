package et.she.v3.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.Instant;
import java.util.UUID;

/**
 * Per-device X.509 certificate record.
 *
 * Schema: V3-DATABASE-DESIGN §4.6
 * Migration: V3__device_certs.sql
 *
 * EMQX auth backend (V3-SECURITY-MODEL §4.2) flow:
 *   1. Device connects to EMQX :8883 with mTLS
 *   2. EMQX POST /internal/mqtt/auth { clientid, cn, fingerprint }
 *   3. Spring Boot SELECT FROM device_certs WHERE fingerprint = ? AND status = 'ACTIVE'
 *   4. Return {result: "allow"} or {result: "deny"}
 *
 * P1-22: CRL refreshes every 6h; revoked certs also blocked at DB layer (defense-in-depth).
 */
@Entity
@Table(name = "device_certs")
public class DeviceCert {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    /** Cert CN = normalized MAC (lowercase, no colons). Must match clientid. */
    @Column(name = "cn", nullable = false, length = 64)
    private String cn;

    /** X.509 cert serial (hex). */
    @Column(name = "cert_serial", nullable = false, unique = true, length = 64)
    private String certSerial;

    /** SHA-256 of DER cert (lowercase hex, no colons). EMQX auth lookup key. */
    @Column(name = "fingerprint", nullable = false, unique = true, length = 64)
    private String fingerprint;

    @Column(name = "ca_id", nullable = false)
    private UUID caId;

    @Column(name = "issued_at", nullable = false)
    private Instant issuedAt;

    @Column(name = "expires_at", nullable = false)
    private Instant expiresAt;

    @Column(name = "status", nullable = false, length = 20)
    private String status = "ACTIVE";

    @Column(name = "revoked_at")
    private Instant revokedAt;

    @Column(name = "revoke_reason", length = 50)
    private String revokeReason;

    @Column(name = "revoked_by_user_id")
    private UUID revokedByUserId;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp
    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    // ---- Getters / Setters ----
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public String getCn() { return cn; }
    public void setCn(String cn) { this.cn = cn; }
    public String getCertSerial() { return certSerial; }
    public void setCertSerial(String certSerial) { this.certSerial = certSerial; }
    public String getFingerprint() { return fingerprint; }
    public void setFingerprint(String fingerprint) { this.fingerprint = fingerprint; }
    public UUID getCaId() { return caId; }
    public void setCaId(UUID caId) { this.caId = caId; }
    public Instant getIssuedAt() { return issuedAt; }
    public void setIssuedAt(Instant issuedAt) { this.issuedAt = issuedAt; }
    public Instant getExpiresAt() { return expiresAt; }
    public void setExpiresAt(Instant expiresAt) { this.expiresAt = expiresAt; }
    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
    public Instant getRevokedAt() { return revokedAt; }
    public void setRevokedAt(Instant revokedAt) { this.revokedAt = revokedAt; }
    public String getRevokeReason() { return revokeReason; }
    public void setRevokeReason(String revokeReason) { this.revokeReason = revokeReason; }
    public UUID getRevokedByUserId() { return revokedByUserId; }
    public void setRevokedByUserId(UUID revokedByUserId) { this.revokedByUserId = revokedByUserId; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }

    public boolean isActive() { return "ACTIVE".equals(status); }
}
