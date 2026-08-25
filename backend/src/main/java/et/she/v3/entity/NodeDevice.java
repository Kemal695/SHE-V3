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
 * RainMaker Device — logical entity per node (e.g. "Relay 1", "OTA service").
 * V3-DATABASE-DESIGN §3.2. Migration V27. ADR-011.
 */
@Entity
@Table(name = "node_devices")
public class NodeDevice {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id")
    private UUID tenantId;

    @Column(name = "node_id", nullable = false)
    private UUID nodeId;

    @Column(name = "device_name", nullable = false, length = 64)
    private String deviceName;          // "Relay 1" — matches MQTT payload key

    @Column(name = "device_type", nullable = false, length = 64)
    private String deviceType;          // esp.device.switch | esp.service.ota | esp.service.diag

    @Column(name = "display_name", length = 100)
    private String displayName;         // user-assigned: "Kitchen Light"

    @Column(name = "channel_index")
    private Short channelIndex;         // 0-15, maps to GPIO via PCF8574

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "attributes", columnDefinition = "jsonb")
    private Map<String, Object> attributes;  // {"Label":"Kitchen Light","Channel":"0"}

    @Column(name = "is_service", nullable = false)
    private boolean isService = false;  // auto-set by trigger

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getNodeId() { return nodeId; }
    public void setNodeId(UUID nodeId) { this.nodeId = nodeId; }
    public String getDeviceName() { return deviceName; }
    public void setDeviceName(String deviceName) { this.deviceName = deviceName; }
    public String getDeviceType() { return deviceType; }
    public void setDeviceType(String deviceType) { this.deviceType = deviceType; }
    public String getDisplayName() { return displayName; }
    public void setDisplayName(String displayName) { this.displayName = displayName; }
    public Short getChannelIndex() { return channelIndex; }
    public void setChannelIndex(Short channelIndex) { this.channelIndex = channelIndex; }
    public Map<String, Object> getAttributes() { return attributes; }
    public void setAttributes(Map<String, Object> attributes) { this.attributes = attributes; }
    public boolean isService() { return isService; }
    public void setService(boolean service) { isService = service; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
}
