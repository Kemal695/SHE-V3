package et.she.v3.service;

import et.she.v3.entity.MediaAsset;
import et.she.v3.errors.SheException;
import et.she.v3.repository.MediaAssetRepository;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.UUID;

/**
 * Uploaded images (scene/group covers, custom icons). Migration V41.
 *
 * Bytes are stored on disk, one file per row, named after the row id. The type
 * is decided from the file's MAGIC BYTES, never from the client's
 * `Content-Type` — a caller can claim `image/png` and send anything.
 *
 * This is deliberately local-disk storage: the dev box and a single-node
 * deployment need no object store. Swapping in S3 later means replacing the two
 * file operations in {@link #store} / {@link #load}; the API stays the same.
 */
@Service
public class MediaService {

    /** 5 MB — a phone photo of a room, not a RAW file. */
    private static final long MAX_BYTES = 5L * 1024 * 1024;

    /** What `GET /api/v3/media/{id}` is mounted at; also what we store in scenes/groups. */
    public static final String URL_PREFIX = "/api/v3/media/";

    private final MediaAssetRepository repository;
    private final Path root;

    public MediaService(MediaAssetRepository repository,
                        @Value("${she.media.dir:./data/media}") String dir) {
        this.repository = repository;
        this.root = Paths.get(dir).toAbsolutePath().normalize();
    }

    /** Result of an upload: the row id plus the URL to store on a scene/group. */
    public record MediaOut(UUID id, String url, String contentType, int byteSize) {}

    /** Bytes + type for the download endpoint. */
    public record MediaBytes(byte[] data, String contentType) {}

    @Transactional
    public MediaOut store(MultipartFile file, UUID tenantId, UUID ownerId) {
        if (file == null || file.isEmpty()) {
            throw new SheException("VALIDATION_ERROR", "No file uploaded", 422);
        }
        if (file.getSize() > MAX_BYTES) {
            throw new SheException("VALIDATION_ERROR", "Image must be 5 MB or smaller", 422);
        }

        byte[] bytes;
        try {
            bytes = file.getBytes();
        } catch (IOException e) {
            throw new SheException("UPLOAD_FAILED", "Could not read the upload", 500);
        }

        String contentType = detectType(bytes);
        if (contentType == null) {
            throw new SheException("VALIDATION_ERROR",
                    "Only JPEG, PNG or WebP images are supported", 422);
        }

        UUID id = UUID.randomUUID();
        Path target = root.resolve(id.toString());
        try {
            Files.createDirectories(root);
            Files.write(target, bytes);
        } catch (IOException e) {
            throw new SheException("UPLOAD_FAILED", "Could not save the image", 500);
        }

        try {
            MediaAsset asset = new MediaAsset();
            asset.setId(id);
            asset.setTenantId(tenantId);
            asset.setOwnerId(ownerId);
            asset.setContentType(contentType);
            asset.setByteSize(bytes.length);
            asset.setStoragePath(target.toString());
            repository.save(asset);
        } catch (RuntimeException e) {
            // Don't leave an orphaned file behind if the row could not be written.
            try { Files.deleteIfExists(target); } catch (IOException ignored) { }
            throw e;
        }

        return new MediaOut(id, URL_PREFIX + id, contentType, bytes.length);
    }

    /** Read one image by id. Throws 404 when the row or its file is missing. */
    @Transactional(readOnly = true)
    public MediaBytes load(UUID id) {
        MediaAsset asset = repository.findById(id)
                .orElseThrow(() -> new SheException("NOT_FOUND", "Image not found", 404));
        try {
            byte[] data = Files.readAllBytes(Paths.get(asset.getStoragePath()));
            return new MediaBytes(data, asset.getContentType());
        } catch (IOException e) {
            throw new SheException("NOT_FOUND", "Image file missing", 404);
        }
    }

    /**
     * Content type from the magic bytes. Returns null for anything that is not
     * a JPEG, PNG or WebP.
     */
    private static String detectType(byte[] b) {
        if (b.length >= 3
                && (b[0] & 0xFF) == 0xFF && (b[1] & 0xFF) == 0xD8 && (b[2] & 0xFF) == 0xFF) {
            return "image/jpeg";
        }
        if (b.length >= 8
                && (b[0] & 0xFF) == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') {
            return "image/png";
        }
        if (b.length >= 12
                && b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F'
                && b[8] == 'W' && b[9] == 'E' && b[10] == 'B' && b[11] == 'P') {
            return "image/webp";
        }
        return null;
    }
}
