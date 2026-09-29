package et.she.v3.entity;

import jakarta.persistence.*;

import java.time.Instant;
import java.util.UUID;

/**
 * One membership row of a {@link NodeGroup}.
 *
 * V3-DATABASE-DESIGN §4.8. Migration V11; {@code deviceId} added in V36.
 *
 * A row is either NODE-level ({@code nodeId} set, {@code deviceId} null) or
 * DEVICE-level (both set) — the custom groups the app creates are device-level,
 * so one group can contain several relays of the same board.
 */
@Entity
@Table(name = "node_group_members")
public class NodeGroupMember {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "group_id", nullable = false)
    private UUID groupId;

    @Column(name = "node_id")
    private UUID nodeId;

    /** Device-level membership (V36). NULL = node-level membership. */
    @Column(name = "device_id")
    private UUID deviceId;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    void onCreate() {
        if (createdAt == null) createdAt = Instant.now();
    }

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }

    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }

    public UUID getGroupId() { return groupId; }
    public void setGroupId(UUID groupId) { this.groupId = groupId; }

    public UUID getNodeId() { return nodeId; }
    public void setNodeId(UUID nodeId) { this.nodeId = nodeId; }

    public UUID getDeviceId() { return deviceId; }
    public void setDeviceId(UUID deviceId) { this.deviceId = deviceId; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
