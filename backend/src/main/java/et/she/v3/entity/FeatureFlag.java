package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.annotations.UpdateTimestamp;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Per-tenant feature flag.
 * V3-DATABASE-DESIGN §4.17. Migration V22.
 * Used by AdminFeatureFlagController to toggle features per tenant.
 */
@Entity
@Table(name = "feature_flags")
public class FeatureFlag {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "flag_key", nullable = false, length = 50)
    private String flagKey;

    @Column(name = "enabled", nullable = false)
    private boolean enabled = false;

    @Column(name = "rollout_percent", nullable = false)
    private Short rolloutPercent = 0;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "config", columnDefinition = "jsonb")
    private Map<String, Object> config;

    @Column(name = "updated_by_user_id")
    private UUID updatedByUserId;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    // Getters/setters
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public String getFlagKey() { return flagKey; }
    public void setFlagKey(String flagKey) { this.flagKey = flagKey; }
    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public Short getRolloutPercent() { return rolloutPercent; }
    public void setRolloutPercent(Short rolloutPercent) { this.rolloutPercent = rolloutPercent; }
    public Map<String, Object> getConfig() { return config; }
    public void setConfig(Map<String, Object> config) { this.config = config; }
    public UUID getUpdatedByUserId() { return updatedByUserId; }
    public void setUpdatedByUserId(UUID updatedByUserId) { this.updatedByUserId = updatedByUserId; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
}
