package et.she.v3.entity;

import jakarta.persistence.*;

import java.time.Instant;
import java.util.UUID;

/**
 * NodeGroup — a named broadcast group inside a home.
 *
 * V3-DATABASE-DESIGN §4.8. Migration V11 (device-level members added in V36).
 *
 * The custom groups the mobile app creates use {@code groupType = "CUSTOM"} and
 * their members live in {@link NodeGroupMember} (one row per device).
 *
 * RLS: node_groups has a FORCE'd tenant_isolation policy, so reads/writes must
 * run inside a transaction with app.tenant_id set (TenantContextAspect), which
 * is what happens under {@code @Transactional} on the service path.
 */
@Entity
@Table(name = "node_groups")
public class NodeGroup {

    public static final String TYPE_CUSTOM = "CUSTOM";

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "home_id", nullable = false)
    private UUID homeId;

    @Column(name = "name", nullable = false, length = 100)
    private String name;

    /** ROOM | CUSTOM | ALL_LIGHTS — see V11's CHECK constraint. */
    @Column(name = "group_type", nullable = false, length = 20)
    private String groupType = TYPE_CUSTOM;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Column(name = "deleted_at")
    private Instant deletedAt;

    @PrePersist
    void onCreate() {
        Instant now = Instant.now();
        if (createdAt == null) createdAt = now;
        if (updatedAt == null) updatedAt = now;
        if (groupType == null) groupType = TYPE_CUSTOM;
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

    public String getGroupType() { return groupType; }
    public void setGroupType(String groupType) { this.groupType = groupType; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }

    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }

    public Instant getDeletedAt() { return deletedAt; }
    public void setDeletedAt(Instant deletedAt) { this.deletedAt = deletedAt; }
}
