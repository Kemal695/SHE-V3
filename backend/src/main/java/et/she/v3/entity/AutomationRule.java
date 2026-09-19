package et.she.v3.entity;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * One action of an {@link Automation}, executed in sort_order.
 *
 * V3-DATABASE-DESIGN §4.6. Migration V9.
 * action_type (§7.2): WRITE_PARAM | ACTIVATE_SCENE | NOTIFICATION.
 *
 * NOTE: this table has NO tenant_id column. Tenant isolation is inherited: V32
 * gives automation_rules an RLS policy of
 * `automation_id IN (SELECT id FROM automations) OR is_platform_admin`, and
 * automations is itself RLS-protected. So an AutomationRule is visible iff its
 * parent automation is. Do NOT add a tenantId field here — the column doesn't
 * exist and RLS already covers it.
 */
@Entity
@Table(name = "automation_rules")
public class AutomationRule {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "automation_id", nullable = false)
    private UUID automationId;

    @Column(name = "action_type", nullable = false, length = 30)
    private String actionType;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "action_config", nullable = false, columnDefinition = "jsonb")
    private JsonNode actionConfig;

    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    void onCreate() {
        if (createdAt == null) createdAt = Instant.now();
        if (sortOrder == null) sortOrder = 0;
    }

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }

    public UUID getAutomationId() { return automationId; }
    public void setAutomationId(UUID automationId) { this.automationId = automationId; }

    public String getActionType() { return actionType; }
    public void setActionType(String actionType) { this.actionType = actionType; }

    public JsonNode getActionConfig() { return actionConfig; }
    public void setActionConfig(JsonNode actionConfig) { this.actionConfig = actionConfig; }

    public Integer getSortOrder() { return sortOrder; }
    public void setSortOrder(Integer sortOrder) { this.sortOrder = sortOrder; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
