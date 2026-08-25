package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * RainMaker Parameter — controllable or measurable value.
 * V3-DATABASE-DESIGN §3.3. Migration V27. ADR-011.
 */
@Entity
@Table(name = "node_params")
public class NodeParam {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id")
    private UUID tenantId;

    @Column(name = "node_id", nullable = false)
    private UUID nodeId;

    @Column(name = "node_device_id", nullable = false)
    private UUID nodeDeviceId;

    @Column(name = "param_name", nullable = false, length = 64)
    private String paramName;           // "Power", "Brightness", "Temperature"

    @Column(name = "param_type", nullable = false, length = 64)
    private String paramType;           // esp.param.power | esp.param.brightness

    @Column(name = "data_type", nullable = false, length = 10)
    private String dataType;            // bool | int | float | string

    @Column(name = "ui_hint", length = 20)
    private String uiHint;              // toggle | slider | segmented | read_only

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "properties", nullable = false, columnDefinition = "jsonb")
    private List<String> properties;    // ["read","write","persist","time_series"]

    @Column(name = "min_value")
    private Double minValue;

    @Column(name = "max_value")
    private Double maxValue;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "last_value", columnDefinition = "jsonb")
    private Object lastValue;           // cached: true | 75 | "2024-12-01T..."

    @Column(name = "last_reported_at")
    private Instant lastReportedAt;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getNodeId() { return nodeId; }
    public void setNodeId(UUID nodeId) { this.nodeId = nodeId; }
    public UUID getNodeDeviceId() { return nodeDeviceId; }
    public void setNodeDeviceId(UUID nodeDeviceId) { this.nodeDeviceId = nodeDeviceId; }
    public String getParamName() { return paramName; }
    public void setParamName(String paramName) { this.paramName = paramName; }
    public String getParamType() { return paramType; }
    public void setParamType(String paramType) { this.paramType = paramType; }
    public String getDataType() { return dataType; }
    public void setDataType(String dataType) { this.dataType = dataType; }
    public String getUiHint() { return uiHint; }
    public void setUiHint(String uiHint) { this.uiHint = uiHint; }
    public List<String> getProperties() { return properties; }
    public void setProperties(List<String> properties) { this.properties = properties; }
    public Double getMinValue() { return minValue; }
    public void setMinValue(Double minValue) { this.minValue = minValue; }
    public Double getMaxValue() { return maxValue; }
    public void setMaxValue(Double maxValue) { this.maxValue = maxValue; }
    public Object getLastValue() { return lastValue; }
    public void setLastValue(Object lastValue) { this.lastValue = lastValue; }
    public Instant getLastReportedAt() { return lastReportedAt; }
    public void setLastReportedAt(Instant lastReportedAt) { this.lastReportedAt = lastReportedAt; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
