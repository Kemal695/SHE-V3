package et.she.v3.controller;

import et.she.v3.errors.SheException;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.service.SceneService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Scene endpoints.
 *
 * V3-API-SPECIFICATION §8.1. V3-DATABASE-DESIGN §4.7.
 *
 * The tables existed since V10 but no controller was ever written, which is
 * why the mobile app's scene row could only ever show a toast — there was no
 * API behind it.
 *
 * Tenant isolation is enforced by RLS on the scenes table; every handler runs
 * @Transactional so the app.tenant_id GUC is set for the connection.
 */
@RestController
@RequestMapping("/api/v3")
public class SceneController {

    private final SceneService sceneService;

    public SceneController(SceneService sceneService) {
        this.sceneService = sceneService;
    }

    /** GET /api/v3/homes/{homeId}/scenes */
    @GetMapping("/homes/{homeId}/scenes")
    public ResponseEntity<Map<String, Object>> list(@PathVariable UUID homeId) {
        List<SceneService.SceneOut> scenes = sceneService.list(homeId);
        return ResponseEntity.ok(Map.of("data", scenes));
    }

    /** POST /api/v3/homes/{homeId}/scenes — body {name, icon, actions[]} */
    @PostMapping("/homes/{homeId}/scenes")
    public ResponseEntity<Map<String, Object>> create(@PathVariable UUID homeId,
                                                     @RequestBody SceneService.CreateSceneRequest req) {
        return ResponseEntity.status(201).body(Map.of("data", sceneService.create(homeId, req)));
    }

    /** GET /api/v3/scenes/{id} */
    @GetMapping("/scenes/{id}")
    public ResponseEntity<Map<String, Object>> get(@PathVariable UUID id) {
        return ResponseEntity.ok(Map.of("data", sceneService.get(id)));
    }

    /** PATCH /api/v3/scenes/{id} — body {name?, icon?, actions?} */
    @PatchMapping("/scenes/{id}")
    public ResponseEntity<Map<String, Object>> update(@PathVariable UUID id,
                                                     @RequestBody SceneService.UpdateSceneRequest req) {
        return ResponseEntity.ok(Map.of("data", sceneService.update(id, req)));
    }

    /** DELETE /api/v3/scenes/{id} — 204, soft delete */
    @DeleteMapping("/scenes/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        // V3-API-SPECIFICATION §8.1 — DELETE is ADMIN+. Mobile MEMBERs can still
        // manage their own scenes via the API at create/update time; only deletion
        // is privileged. isBypassCapable() covers PLATFORM_ADMIN + SUPER_ADMIN.
        AuthenticatedUser u = currentUser();
        if (!u.isBypassCapable()) {
            throw new SheException("AUTH_FORBIDDEN",
                    "Only platform admins can delete scenes", 403);
        }
        sceneService.delete(id);
        return ResponseEntity.noContent().build();
    }

    /**
     * POST /api/v3/scenes/{id}/activate
     * Returns {executionId, acceptedCount, failed[]} — one failed device does
     * not abort the rest of the scene.
     */
    @PostMapping("/scenes/{id}/activate")
    public ResponseEntity<Map<String, Object>> activate(@PathVariable UUID id) {
        SceneService.ActivationResult result = sceneService.activate(id);
        return ResponseEntity.ok(Map.of("data", result));
    }

    private AuthenticatedUser currentUser() {
        Object principal = SecurityContextHolder.getContext().getAuthentication() != null
                ? SecurityContextHolder.getContext().getAuthentication().getPrincipal()
                : null;
        if (principal instanceof AuthenticatedUser u) return u;
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }
}
