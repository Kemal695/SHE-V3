package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Audit log entry — tamper-evident hash-chained log.
 * V3-DATABASE-DESIGN §4.15. Migration V18. P1-19: TimescaleDB hypertable.
 *
 * Columns: sequence_number (monotonic per-tenant), prev_hash, hash.
 * hash = SHA-256(prev_hash || canonical_json(this_row)).
 *
 * Retention: 30 days raw + 2 years compressed + 7-year CSV archive.
 */
@Entity
@Table(name = "audit_log")
public class AuditLog {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id")
    private UUID tenantId;

    @Column(name = "actor_user_id")
    private UUID actorUserId;

    @Column(name = "actor_type", nullable = false, length = 20)
    private String actorType;     // USER | TENANT_ADMIN | PLATFORM_ADMIN | SYSTEM | DEVICE

    @Column(name = "action", nullable = false, length = 50)
    private String action;        // e.g. admin.tenant.created, payment.completed

    @Column(name = "target_type", length = 20)
    private String targetType;

    @Column(name = "target_id")
    private UUID targetId;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "details", columnDefinition = "jsonb")
    private Map<String, Object> details;

    // V18 declares this INET. Same reason as ApiKey#lastUsedIp.
    @JdbcTypeCode(SqlTypes.OTHER)
    @Column(name = "ip_address", columnDefinition = "inet")
    private String ipAddress;

    @Column(name = "user_agent")
    private String userAgent;

    @Column(name = "request_id")
    private UUID requestId;

    @Column(name = "sequence_number")
    private Long sequenceNumber;

    @Column(name = "prev_hash")
    private byte[] prevHash;

    @Column(name = "hash")
    private byte[] hash;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    // Getters/setters
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getActorUserId() { return actorUserId; }
    public void setActorUserId(UUID actorUserId) { this.actorUserId = actorUserId; }
    public String getActorType() { return actorType; }
    public void setActorType(String actorType) { this.actorType = actorType; }
    public String getAction() { return action; }
    public void setAction(String action) { this.action = action; }
    public String getTargetType() { return targetType; }
    public void setTargetType(String targetType) { this.targetType = targetType; }
    public UUID getTargetId() { return targetId; }
    public void setTargetId(UUID targetId) { this.targetId = targetId; }
    public Map<String, Object> getDetails() { return details; }
    public void setDetails(Map<String, Object> details) { this.details = details; }
    public String getIpAddress() { return ipAddress; }
    public void setIpAddress(String ipAddress) { this.ipAddress = ipAddress; }
    public String getUserAgent() { return userAgent; }
    public void setUserAgent(String userAgent) { this.userAgent = userAgent; }
    public UUID getRequestId() { return requestId; }
    public void setRequestId(UUID requestId) { this.requestId = requestId; }
    public Long getSequenceNumber() { return sequenceNumber; }
    public void setSequenceNumber(Long sequenceNumber) { this.sequenceNumber = sequenceNumber; }
    public byte[] getPrevHash() { return prevHash; }
    public void setPrevHash(byte[] prevHash) { this.prevHash = prevHash; }
    public byte[] getHash() { return hash; }
    public void setHash(byte[] hash) { this.hash = hash; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
