package et.she.v3.controller;

import et.she.v3.errors.SheException;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.service.MediaService;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;

/**
 * Uploaded images. Migration V41.
 *
 * POST is authenticated (the uploader is recorded). GET is public — the file is
 * addressed by an unguessable UUID and a plain `Image.network` in the app cannot
 * reliably carry a JWT, so the read path is deliberately unauthenticated. See
 * V41 for the reasoning.
 */
@RestController
@RequestMapping("/api/v3/media")
public class MediaController {

    private final MediaService mediaService;

    public MediaController(MediaService mediaService) {
        this.mediaService = mediaService;
    }

    /**
     * POST /api/v3/media — multipart field `file` (jpeg/png/webp, ≤5 MB).
     * Returns `{data:{id,url,contentType,byteSize}}`; store `url` on a scene or
     * group.
     */
    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<Map<String, Object>> upload(@RequestPart("file") MultipartFile file) {
        AuthenticatedUser user = currentUser();
        MediaService.MediaOut out = mediaService.store(file, user.tenantId(), user.userId());
        return ResponseEntity.ok(Map.of("data", out));
    }

    /** GET /api/v3/media/{id} — the image bytes. */
    @GetMapping("/{id}")
    public ResponseEntity<byte[]> get(@PathVariable UUID id) {
        MediaService.MediaBytes media = mediaService.load(id);
        return ResponseEntity.ok()
                .contentType(MediaType.parseMediaType(media.contentType()))
                .cacheControl(CacheControl.maxAge(Duration.ofDays(30)).cachePublic())
                .header(HttpHeaders.CONTENT_DISPOSITION, "inline")
                .body(media.data());
    }

    private AuthenticatedUser currentUser() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthenticatedUser u) return u;
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }
}
