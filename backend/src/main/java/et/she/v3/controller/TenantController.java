package et.she.v3.controller;

import et.she.v3.tenant.TenantService;
import et.she.v3.entity.Tenant;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Tenant admin + branding endpoints.
 * V3-ADMIN-PLATFORM §4.1 (admin CRUD). V3-B2B-WHITELABEL §3 (public branding).
 *
 * Admin (SUPER_ADMIN only):
 *   GET    /api/admin/tenants
 *   POST   /api/admin/tenants
 *   GET    /api/admin/tenants/{id}
 *   PUT    /api/admin/tenants/{id}/branding
 *   PUT    /api/admin/tenants/{id}/status
 *
 * Public (no auth — Flutter app fetches on login):
 *   GET    /api/v3/tenant/branding?subdomain=xxx
 */
@RestController
public class TenantController {

    private final TenantService tenantService;
    private final et.she.v3.repository.AuditLogRepository auditLogRepository;

    public TenantController(TenantService tenantService,
                             et.she.v3.repository.AuditLogRepository auditLogRepository) {
        this.tenantService = tenantService;
        this.auditLogRepository = auditLogRepository;
    }

    // ─── Admin endpoints (SUPER_ADMIN only) ────────────────────────────────────

    @GetMapping("/api/admin/tenants")
    public ResponseEntity<Map<String, Object>> listTenants() {
        List<Tenant> tenants = tenantService.listTenants();
        return ResponseEntity.ok(Map.of("data", tenants));
    }

    @PostMapping("/api/admin/tenants")
    public ResponseEntity<Map<String, Object>> createTenant(@Valid @RequestBody TenantService.CreateTenantRequest req) {
        Tenant tenant = tenantService.createTenant(req);
        return ResponseEntity.status(201).body(Map.of("data", tenant));
    }

    @GetMapping("/api/admin/tenants/{id}")
    public ResponseEntity<Map<String, Object>> getTenant(@PathVariable UUID id) {
        Tenant tenant = tenantService.getTenant(id);
        return ResponseEntity.ok(Map.of("data", tenant));
    }

    @PutMapping("/api/admin/tenants/{id}/branding")
    public ResponseEntity<Map<String, Object>> updateBranding(@PathVariable UUID id,
                                                               @RequestBody Map<String, Object> branding) {
        Tenant tenant = tenantService.updateBranding(id, branding);
        return ResponseEntity.ok(Map.of("data", tenant));
    }

    @PutMapping("/api/admin/tenants/{id}/status")
    public ResponseEntity<Map<String, Object>> updateStatus(@PathVariable UUID id,
                                                              @RequestBody Map<String, String> body) {
        Tenant tenant = tenantService.updateStatus(id, body.get("status"));
        return ResponseEntity.ok(Map.of("data", tenant));
    }

    /**
     * GET /api/admin/tenants/{id}/audit-log
     * V3-ADMIN-PLATFORM §4.1 — audit log filtered by tenant.
     * Delegates to AdminAuditLogController with target_type=tenant filter.
     */
    @GetMapping("/api/admin/tenants/{id}/audit-log")
    public ResponseEntity<Map<String, Object>> getTenantAuditLog(
            @PathVariable UUID id,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        // Verify tenant exists
        tenantService.getTenant(id);
        // Delegate to audit log repository with tenant filter
        // For SUPER_ADMIN: cross-tenant; for TENANT_ADMIN: RLS enforces own tenant
        var logs = auditLogRepository.findFiltered(id, null, null,
                org.springframework.data.domain.PageRequest.of(page, Math.min(size, 100)));
        var data = logs.getContent().stream().toList();
        return ResponseEntity.ok(Map.of("data", data, "meta", Map.of(
                "total", logs.getTotalElements(),
                "page", page,
                "has_more", logs.hasNext()
        )));
    }

    // ─── Public branding endpoint ──────────────────────────────────────────────
    // V3-B2B-WHITELABEL §3 — Flutter app fetches on login to apply white-label branding.

    @GetMapping("/api/v3/tenant/branding")
    public ResponseEntity<Map<String, Object>> getBranding(@RequestParam(required = false) String subdomain) {
        Map<String, Object> branding = tenantService.getBrandingBySubdomain(subdomain);
        return ResponseEntity.ok(Map.of("data", branding));
    }
}
