package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.Instant;
import java.util.UUID;

/**
 * OTA batch — self-hosted OTA via MinIO. Ed25519-signed firmware.
 * V3-DATABASE-DESIGN §4.11. Migration V14. V3-FIRMWARE §6.
 */
@Entity
@Table(name = "ota_batches")
public class OtaBatch {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "home_id", nullable = false)
    private UUID homeId;

    @Column(name = "firmware_version", nullable = false, length = 50)
    private String firmwareVersion;

    @Column(name = "firmware_url", nullable = false)
    private String firmwareUrl;

    @Column(name = "firmware_checksum", nullable = false, length = 64)
    private String firmwareChecksum;

    @Column(name = "signature_ed25519", nullable = false)
    private String signatureEd25519;

    @Column(name = "target_sku", nullable = false, length = 20)
    private String targetSku;

    @Column(name = "rollout_percent", nullable = false)
    private Short rolloutPercent = 100;

    @Column(name = "auto_approve", nullable = false)
    private boolean autoApprove = false;

    @Column(name = "status", nullable = false, length = 20)
    private String status = "DRAFT";

    @Column(name = "created_by_user_id")
    private UUID createdByUserId;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    // Getters/setters
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getHomeId() { return homeId; }
    public void setHomeId(UUID homeId) { this.homeId = homeId; }
    public String getFirmwareVersion() { return firmwareVersion; }
    public void setFirmwareVersion(String firmwareVersion) { this.firmwareVersion = firmwareVersion; }
    public String getFirmwareUrl() { return firmwareUrl; }
    public void setFirmwareUrl(String firmwareUrl) { this.firmwareUrl = firmwareUrl; }
    public String getFirmwareChecksum() { return firmwareChecksum; }
    public void setFirmwareChecksum(String firmwareChecksum) { this.firmwareChecksum = firmwareChecksum; }
    public String getSignatureEd25519() { return signatureEd25519; }
    public void setSignatureEd25519(String signatureEd25519) { this.signatureEd25519 = signatureEd25519; }
    public String getTargetSku() { return targetSku; }
    public void setTargetSku(String targetSku) { this.targetSku = targetSku; }
    public Short getRolloutPercent() { return rolloutPercent; }
    public void setRolloutPercent(Short rolloutPercent) { this.rolloutPercent = rolloutPercent; }
    public boolean isAutoApprove() { return autoApprove; }
    public void setAutoApprove(boolean autoApprove) { this.autoApprove = autoApprove; }
    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
    public UUID getCreatedByUserId() { return createdByUserId; }
    public void setCreatedByUserId(UUID createdByUserId) { this.createdByUserId = createdByUserId; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
}
