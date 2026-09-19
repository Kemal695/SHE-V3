package et.she.v3.controller;

import et.she.v3.service.AutomationService;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.errors.SheException;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Automation endpoints.
 *
 * V3-API-SPECIFICATION §7. V3-DATABASE-DESIGN §4.6. Migration V9.
 *
 * The tables existed since V9 with RLS (V32) but no controller was ever written.
 *
 * Tenant isolation comes from RLS on automations; automation_rules is protected by
 * an inherited-scope policy (V32) — visible iff its parent automation is.
 */
@RestController
@RequestMapping("/api/v3")
public class AutomationController {

    private final AutomationService automationService;

    public AutomationController(AutomationService automationService) {
        this.automationService = automationService;
    }

    /** GET /api/v3/homes/{homeId}/automations */
    @GetMapping("/homes/{homeId}/automations")
    public ResponseEntity<Map<String, Object>> list(@PathVariable UUID homeId) {
        List<AutomationService.AutomationOut> out = automationService.list(homeId);
        return ResponseEntity.ok(Map.of("data", out));
    }

    /** POST /api/v3/homes/{homeId}/automations */
    @PostMapping("/homes/{homeId}/automations")
    public ResponseEntity<Map<String, Object>> create(
            @PathVariable UUID homeId,
            @RequestBody AutomationService.CreateAutomationRequest req) {
        return ResponseEntity.status(201)
                .body(Map.of("data", automationService.create(homeId, req)));
    }

    /** GET /api/v3/automations/{id} */
    @GetMapping("/automations/{id}")
    public ResponseEntity<Map<String, Object>> get(@PathVariable UUID id) {
        return ResponseEntity.ok(Map.of("data", automationService.get(id)));
    }

    /** PUT /api/v3/automations/{id} — {name?, description?, enabled?} */
    @PutMapping("/automations/{id}")
    public ResponseEntity<Map<String, Object>> update(
            @PathVariable UUID id,
            @RequestBody AutomationService.UpdateAutomationRequest req) {
        return ResponseEntity.ok(Map.of("data", automationService.update(id, req)));
    }

    /** PATCH /api/v3/automations/{id}/enabled — {enabled: bool} */
    @PatchMapping("/automations/{id}/enabled")
    public ResponseEntity<Map<String, Object>> setEnabled(
            @PathVariable UUID id,
            @RequestBody AutomationService.SetEnabledRequest req) {
        return ResponseEntity.ok(Map.of("data", automationService.setEnabled(id, req)));
    }

    /** DELETE /api/v3/automations/{id} — 204, soft delete */
    @DeleteMapping("/automations/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        // V3-API-SPECIFICATION §7 — DELETE is ADMIN+. Mobile MEMBERs can still
        // create / update / enable / trigger their own automations; only deletion
        // is privileged. isBypassCapable() covers PLATFORM_ADMIN + SUPER_ADMIN.
        AuthenticatedUser u = currentUser();
        if (!u.isBypassCapable()) {
            throw new SheException("AUTH_FORBIDDEN",
                    "Only platform admins can delete automations", 403);
        }
        automationService.delete(id);
        return ResponseEntity.noContent().build();
    }

    /** POST /api/v3/automations/{id}/trigger — MANUAL trigger, executes actions now. */
    @PostMapping("/automations/{id}/trigger")
    public ResponseEntity<Map<String, Object>> trigger(@PathVariable UUID id) {
        return ResponseEntity.ok(Map.of("data", automationService.trigger(id)));
    }

    private AuthenticatedUser currentUser() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth != null && auth.getPrincipal() instanceof AuthenticatedUser u) return u;
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }
}
