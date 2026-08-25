package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.Instant;
import java.util.UUID;

/**
 * Per-node OTA deployment tracking.
 * V3-DATABASE-DESIGN §4.11. Migration V14.
 */
@Entity
@Table(name = "ota_approvals")
public class OtaApproval {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "batch_id", nullable = false)
    private UUID batchId;

    @Column(name = "node_id")
    private UUID nodeId;

    @Column(name = "status", nullable = false, length = 20)
    private String status = "PENDING";   // PENDING | APPROVED | DECLINED | IN_PROGRESS | COMPLETED | ROLLED_BACK | FAILED

    @Column(name = "approved_by_user_id")
    private UUID approvedByUserId;

    @Column(name = "approved_at")
    private Instant approvedAt;

    @Column(name = "deployment_status", length = 20)
    private String deploymentStatus;     // DOWNLOADING | VERIFYING | WRITING | REBOOTING | HEALTH_CHECK | COMMITTED

    @Column(name = "progress", nullable = false)
    private Integer progress = 0;

    @Column(name = "last_error")
    private String lastError;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getBatchId() { return batchId; }
    public void setBatchId(UUID batchId) { this.batchId = batchId; }
    public UUID getNodeId() { return nodeId; }
    public void setNodeId(UUID nodeId) { this.nodeId = nodeId; }
    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
    public UUID getApprovedByUserId() { return approvedByUserId; }
    public void setApprovedByUserId(UUID approvedByUserId) { this.approvedByUserId = approvedByUserId; }
    public Instant getApprovedAt() { return approvedAt; }
    public void setApprovedAt(Instant approvedAt) { this.approvedAt = approvedAt; }
    public String getDeploymentStatus() { return deploymentStatus; }
    public void setDeploymentStatus(String deploymentStatus) { this.deploymentStatus = deploymentStatus; }
    public Integer getProgress() { return progress; }
    public void setProgress(Integer progress) { this.progress = progress; }
    public String getLastError() { return lastError; }
    public void setLastError(String lastError) { this.lastError = lastError; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
}
