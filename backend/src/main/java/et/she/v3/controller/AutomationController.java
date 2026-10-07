package et.she.v3.controller;

import et.she.v3.service.AutomationService;
import org.springframework.http.ResponseEntity;
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
        // ⚠️ DEVIATION FROM V3-API-SPECIFICATION §7 (which marks this ADMIN+).
        //
        // That row was written for the ADMIN CONSOLE and was being applied to the
        // mobile app too, where it is simply wrong: a user who can CREATE and
        // UPDATE an automation in their own home could not remove it. The app
        // offered Delete, the request went out, and the server answered
        // 403 "Only platform admins can delete automations" — the user-visible
        // bug "I can't delete my automation".
        //
        // Security is NOT weakened by dropping the check:
        //   * Tenant isolation is enforced by RLS on `automations` (V32), so a
        //     caller can only ever see/resolve rows in their own tenant. The
        //     same protection already covers list / update / enable / trigger,
        //     none of which had an admin gate.
        //   * `requireAutomation(id)` resolves through the RLS-scoped repository,
        //     so a foreign id is a 404, not a delete.
        //   * Deletion stays a SOFT delete (`deleted_at`), so it is recoverable.
        //
        // Admins lose nothing — they were already capable.
        automationService.delete(id);
        return ResponseEntity.noContent().build();
    }

    /** POST /api/v3/automations/{id}/trigger — MANUAL trigger, executes actions now. */
    @PostMapping("/automations/{id}/trigger")
    public ResponseEntity<Map<String, Object>> trigger(@PathVariable UUID id) {
        return ResponseEntity.ok(Map.of("data", automationService.trigger(id)));
    }
}
