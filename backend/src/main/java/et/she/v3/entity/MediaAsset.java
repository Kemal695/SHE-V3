package et.she.v3.entity;

import jakarta.persistence.*;

import java.time.Instant;
import java.util.UUID;

/**
 * An uploaded image. Migration V41.
 *
 * The bytes live on disk under `she.media.dir` (default ./data/media) in a file
 * named after {@link #id}; this row holds only the metadata. Keeping the name
 * and the id identical means the download endpoint can serve a file without a
 * second lookup, and an orphaned file is trivially identifiable.
 *
 * No RLS on this table — see V41 for why (public, unguessable-id reads).
 */
@Entity
@Table(name = "media")
public class MediaAsset {

    /**
     * Assigned by {@link et.she.v3.service.MediaService} BEFORE the bytes are
     * written, because the file is named after it and that name is what the
     * client stores in `scenes.icon` / `scenes.image`.
     *
     * Deliberately NOT @GeneratedValue: with a generator Hibernate ignores the
     * assigned value on save() and inserts a fresh UUID, so the row id and the
     * file name diverged and every stored URL 404'd.
     */
    @Id
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "owner_id")
    private UUID ownerId;

    @Column(name = "content_type", nullable = false, length = 100)
    private String contentType;

    @Column(name = "byte_size", nullable = false)
    private Integer byteSize;

    @Column(name = "storage_path", nullable = false, length = 300)
    private String storagePath;

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

    public UUID getOwnerId() { return ownerId; }
    public void setOwnerId(UUID ownerId) { this.ownerId = ownerId; }

    public String getContentType() { return contentType; }
    public void setContentType(String contentType) { this.contentType = contentType; }

    public Integer getByteSize() { return byteSize; }
    public void setByteSize(Integer byteSize) { this.byteSize = byteSize; }

    public String getStoragePath() { return storagePath; }
    public void setStoragePath(String storagePath) { this.storagePath = storagePath; }

    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
}
