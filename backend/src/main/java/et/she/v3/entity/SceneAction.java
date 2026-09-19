package et.she.v3.entity;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.persistence.*;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * One (device, param) write within a {@link Scene}.
 *
 * V3-DATABASE-DESIGN §4.7. Migration V10.
 * `value` is a JSON scalar (boolean / number / string) — typed as JsonNode
 * rather than Object so Hibernate binds it as jsonb instead of bytea
 * (see the Hibernate+jsonb convention: entity JSON fields are JsonNode).
 */
@Entity
@Table(name = "scene_actions")
public class SceneAction {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "scene_id", nullable = false)
    private UUID sceneId;

    @Column(name = "node_id")
    private UUID nodeId;

    @Column(name = "node_device_id")
    private UUID nodeDeviceId;

    @Column(name = "param_name", nullable = false, length = 64)
    private String paramName;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "value", nullable = false, columnDefinition = "jsonb")
    private JsonNode value;

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

    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }

    public UUID getSceneId() { return sceneId; }
    public void setSceneId(UUID sceneId) { this.sceneId = sceneId; }

    public UUID getNodeId() { return nodeId; }
    public void setNodeId(UUID nodeId) { this.nodeId = nodeId; }

    public UUID getNodeDeviceId() { return nodeDeviceId; }
    public void setNodeDeviceId(UUID nodeDeviceId) { this.nodeDeviceId = nodeDeviceId; }

    public String getParamName() { return paramName; }
    public void setParamName(String paramName) { this.paramName = paramName; }

    public JsonNode getValue() { return value; }
    public void setValue(JsonNode value) { this.value = value; }

    public Integer getSortOrder() { return sortOrder; }
    public void setSortOrder(Integer sortOrder) { this.sortOrder = sortOrder; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
