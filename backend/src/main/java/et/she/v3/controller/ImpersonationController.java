package et.she.v3.controller;

import et.she.v3.admin.ImpersonationService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * Admin impersonation endpoints.
 * V3-ADMIN-PLATFORM §4.4.
 *
 *   POST   /api/admin/impersonate/{userId}  — start impersonation (15-min JWT)
 *   DELETE /api/admin/impersonate           — end impersonation
 *
 * Restrictions:
 * - Cannot impersonate while already impersonating → RBAC_IMPERSONATION_CHAIN
 * - SUPER_ADMIN can impersonate any user across any tenant
 * - TENANT_ADMIN can only impersonate users in their own tenant (RLS enforced)
 */
@RestController
@RequestMapping("/api/admin")
public class ImpersonationController {

    private final ImpersonationService impersonationService;

    public ImpersonationController(ImpersonationService impersonationService) {
        this.impersonationService = impersonationService;
    }

    @PostMapping("/impersonate/{userId}")
    public ResponseEntity<Map<String, Object>> impersonate(@PathVariable UUID userId) {
        var resp = impersonationService.impersonate(userId);
        return ResponseEntity.ok(Map.of("data", resp));
    }

    @DeleteMapping("/impersonate")
    public ResponseEntity<Void> endImpersonation() {
        impersonationService.endImpersonation();
        return ResponseEntity.noContent().build();
    }
}
