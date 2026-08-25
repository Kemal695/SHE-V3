package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;

import java.time.Instant;
import java.util.UUID;

/**
 * Home member — multi-tenant RBAC per home.
 * V3-DATABASE-DESIGN §4.5. Migration V8.
 * Roles: OWNER (1 per home), ADMIN, MEMBER, GUEST.
 */
@Entity
@Table(name = "home_members")
public class HomeMember {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;
    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;
    @Column(name = "home_id", nullable = false)
    private UUID homeId;
    @Column(name = "user_id", nullable = false)
    private UUID userId;
    @Column(name = "role", nullable = false, length = 20)
    private String role;    // OWNER | ADMIN | MEMBER | GUEST
    @Column(name = "granted_by_user_id")
    private UUID grantedByUserId;
    @Column(name = "granted_at", nullable = false)
    private Instant grantedAt = Instant.now();
    @Column(name = "revoked_at")
    private Instant revokedAt;

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getHomeId() { return homeId; }
    public void setHomeId(UUID homeId) { this.homeId = homeId; }
    public UUID getUserId() { return userId; }
    public void setUserId(UUID userId) { this.userId = userId; }
    public String getRole() { return role; }
    public void setRole(String role) { this.role = role; }
    public UUID getGrantedByUserId() { return grantedByUserId; }
    public void setGrantedByUserId(UUID grantedByUserId) { this.grantedByUserId = grantedByUserId; }
    public Instant getGrantedAt() { return grantedAt; }
    public void setGrantedAt(Instant grantedAt) { this.grantedAt = grantedAt; }
    public Instant getRevokedAt() { return revokedAt; }
    public void setRevokedAt(Instant revokedAt) { this.revokedAt = revokedAt; }
}
