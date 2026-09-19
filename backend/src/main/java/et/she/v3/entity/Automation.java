package et.she.v3.entity;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * Automation — a trigger plus an ordered list of actions.
 *
 * V3-DATABASE-DESIGN §4.6. Migration V9. V3-API-SPECIFICATION §7.
 * Trigger shapes (§7.1): SCHEDULE {cron}, NODE_STATE {node_id, device_name,
 * param_name, comparator, value}, MANUAL.
 * Actions live in {@link AutomationRule} (§7.2).
 *
 * trigger_config is JSONB — typed JsonNode (never Object) so Hibernate binds it
 * as jsonb rather than bytea.
 */
@Entity
@Table(name = "automations")
public class Automation {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "home_id", nullable = false)
    private UUID homeId;

    @Column(name = "name", nullable = false, length = 100)
    private String name;

    @Column(name = "description")
    private String description;

    @Column(name = "enabled", nullable = false)
    private Boolean enabled = true;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "trigger_config", nullable = false, columnDefinition = "jsonb")
    private JsonNode triggerConfig;

    @Column(name = "created_by_user_id")
    private UUID createdByUserId;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Column(name = "deleted_at")
    private Instant deletedAt;

    /**
     * When this SCHEDULE automation last fired (migration V35).
     *
     * Nullable: an automation that has never fired has no value. Used by
     * {@code AutomationService.runScheduled()} for bounded catch-up after
     * downtime, so a missed 06:00 run is not lost forever.
     */
    @Column(name = "last_fired_at")
    private Instant lastFiredAt;

    @PrePersist
    void onCreate() {
        Instant now = Instant.now();
        if (createdAt == null) createdAt = now;
        if (updatedAt == null) updatedAt = now;
        if (enabled == null) enabled = true;
    }

    @PreUpdate
    void onUpdate() {
        updatedAt = Instant.now();
    }

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }

    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }

    public UUID getHomeId() { return homeId; }
    public void setHomeId(UUID homeId) { this.homeId = homeId; }

    public String getName() { return name; }
    public void setName(String name) { this.name = name; }

    public String getDescription() { return description; }
    public void setDescription(String description) { this.description = description; }

    public Boolean getEnabled() { return enabled; }
    public void setEnabled(Boolean enabled) { this.enabled = enabled; }

    public JsonNode getTriggerConfig() { return triggerConfig; }
    public void setTriggerConfig(JsonNode triggerConfig) { this.triggerConfig = triggerConfig; }

    public UUID getCreatedByUserId() { return createdByUserId; }
    public void setCreatedByUserId(UUID createdByUserId) { this.createdByUserId = createdByUserId; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }

    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }

    public Instant getDeletedAt() { return deletedAt; }
    public void setDeletedAt(Instant deletedAt) { this.deletedAt = deletedAt; }

    public Instant getLastFiredAt() { return lastFiredAt; }
    public void setLastFiredAt(Instant lastFiredAt) { this.lastFiredAt = lastFiredAt; }
}
