package et.she.v3.entity;

import jakarta.persistence.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.annotations.UpdateTimestamp;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * RainMaker Node — one physical ESP32 board.
 * V3-DATABASE-DESIGN §3.1. Migration V27. ADR-011.
 */
@Entity
@Table(name = "nodes")
public class Node {
    @Id @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(name = "tenant_id")
    private UUID tenantId;              // NULL until BLE provisioning claim

    @Column(name = "home_id")
    private UUID homeId;

    @Column(name = "room_id")
    private UUID roomId;

    @Column(name = "node_id", nullable = false, unique = true, length = 64)
    private String nodeId;              // SHE-R8-AABBCC

    @Column(name = "mac_address", nullable = false, unique = true, length = 17)
    private String macAddress;          // 24:6F:28:AA:BB:CC (uppercase, colon-separated)

    @Column(name = "normalized_mac", nullable = false, unique = true, length = 12)
    private String normalizedMac;       // 246f28aabbcc (lowercase, no colons) — MQTT clientid

    @Column(name = "sku", nullable = false, length = 20)
    private String sku;                 // SHE-R4 | SHE-R8 | SHE-R16

    @Column(name = "name", nullable = false, length = 100)
    private String name;

    @Column(name = "firmware_version", length = 50)
    private String firmwareVersion;

    @Column(name = "hardware_revision", length = 20)
    private String hardwareRevision;

    @Column(name = "cert_serial", length = 64)
    private String certSerial;

    @Column(name = "cert_fingerprint", length = 64)
    private String certFingerprint;

    @Column(name = "is_online", nullable = false)
    private boolean isOnline = false;

    @Column(name = "last_seen_at")
    private Instant lastSeenAt;

    @Column(name = "provisioned_at")
    private Instant provisionedAt;

    @CreationTimestamp @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Column(name = "deleted_at")
    private Instant deletedAt;

    // Getters/setters
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public UUID getHomeId() { return homeId; }
    public void setHomeId(UUID homeId) { this.homeId = homeId; }
    public UUID getRoomId() { return roomId; }
    public void setRoomId(UUID roomId) { this.roomId = roomId; }
    public String getNodeId() { return nodeId; }
    public void setNodeId(String nodeId) { this.nodeId = nodeId; }
    public String getMacAddress() { return macAddress; }
    public void setMacAddress(String macAddress) { this.macAddress = macAddress; }
    public String getNormalizedMac() { return normalizedMac; }
    public void setNormalizedMac(String normalizedMac) { this.normalizedMac = normalizedMac; }
    public String getSku() { return sku; }
    public void setSku(String sku) { this.sku = sku; }
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public String getFirmwareVersion() { return firmwareVersion; }
    public void setFirmwareVersion(String firmwareVersion) { this.firmwareVersion = firmwareVersion; }
    public String getHardwareRevision() { return hardwareRevision; }
    public void setHardwareRevision(String hardwareRevision) { this.hardwareRevision = hardwareRevision; }
    public String getCertSerial() { return certSerial; }
    public void setCertSerial(String certSerial) { this.certSerial = certSerial; }
    public String getCertFingerprint() { return certFingerprint; }
    public void setCertFingerprint(String certFingerprint) { this.certFingerprint = certFingerprint; }
    public boolean isOnline() { return isOnline; }
    public void setOnline(boolean online) { isOnline = online; }
    public Instant getLastSeenAt() { return lastSeenAt; }
    public void setLastSeenAt(Instant lastSeenAt) { this.lastSeenAt = lastSeenAt; }
    public Instant getProvisionedAt() { return provisionedAt; }
    public void setProvisionedAt(Instant provisionedAt) { this.provisionedAt = provisionedAt; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
    public Instant getDeletedAt() { return deletedAt; }
    public void setDeletedAt(Instant deletedAt) { this.deletedAt = deletedAt; }
}
