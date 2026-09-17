package et.she.v3.controller;

import et.she.v3.entity.AuditLog;
import et.she.v3.repository.AuditLogRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.io.PrintWriter;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Admin audit log endpoints.
 * V3-ADMIN-PLATFORM §4.5.
 *
 *   GET /api/admin/audit-log          — paginated, filterable audit log
 *   GET /api/admin/audit-log/export   — CSV export (max 100k rows)
 *
 * Retention: 2 years (V3-ADMIN-PLATFORM §5.2).
 * Integrity: hash-chained — tamper-evident (P1-19).
 */
@RestController
@RequestMapping("/api/admin/audit-log")
public class AdminAuditLogController {

    private final AuditLogRepository auditLogRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public AdminAuditLogController(AuditLogRepository auditLogRepository,
                                    TenantContextInterceptor tenantContextInterceptor) {
        this.auditLogRepository = auditLogRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    @GetMapping
    public ResponseEntity<Map<String, Object>> list(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actor_type,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {

        AuthenticatedUser admin = currentUser();
        if (size > 100) size = 100;

        // SUPER_ADMIN sees all tenants; TENANT_ADMIN sees only own tenant (RLS)
        UUID tenantFilter = admin.isSuperAdmin() ? null : admin.tenantId();
        Page<AuditLog> result = auditLogRepository.findFiltered(
                tenantFilter, action, actor_type, PageRequest.of(page, size));

        var data = result.getContent().stream()
                .map(this::toResponse)
                .toList();

        return ResponseEntity.ok(Map.of("data", data, "meta", Map.of(
                "total", result.getTotalElements(),
                "page", page,
                "size", size,
                "has_more", result.hasNext()
        )));
    }

    @GetMapping("/export")
    public void exportCsv(
            @RequestParam(required = false) String from,
            @RequestParam(required = false) String to,
            HttpServletResponse response) throws Exception {

        AuthenticatedUser admin = currentUser();
        UUID tenantFilter = admin.isSuperAdmin() ? null : admin.tenantId();

        Instant fromInstant = from != null ? Instant.parse(from) : Instant.now().minusSeconds(86400);
        Instant toInstant = to != null ? Instant.parse(to) : Instant.now();

        var logs = auditLogRepository.findForExport(tenantFilter, fromInstant, toInstant);

        response.setContentType("text/csv");
        response.setHeader("Content-Disposition",
                "attachment; filename=\"audit_log_" + Instant.now().toEpochMilli() + ".csv\"");

        PrintWriter writer = response.getWriter();
        writer.println("created_at,tenant_id,actor_type,action,target_type,target_id,details,ip_address");

        for (AuditLog log : logs) {
            writer.printf("%s,%s,%s,%s,%s,%s,%s,%s%n",
                    log.getCreatedAt(),
                    log.getTenantId(),
                    log.getActorType(),
                    log.getAction(),
                    log.getTargetType() != null ? log.getTargetType() : "",
                    log.getTargetId() != null ? log.getTargetId() : "",
                    log.getDetails() != null ? log.getDetails().toString().replace(",", ";").replace("\n", " ") : "",
                    log.getIpAddress() != null ? log.getIpAddress() : ""
            );
        }
        writer.flush();
    }

    private Map<String, Object> toResponse(AuditLog a) {
        return Map.of(
                "id", a.getId(),
                "created_at", a.getCreatedAt().toString(),
                "tenant_id", a.getTenantId() != null ? a.getTenantId() : "",
                "actor_type", a.getActorType(),
                "action", a.getAction(),
                "target_type", a.getTargetType() != null ? a.getTargetType() : "",
                "target_id", a.getTargetId() != null ? a.getTargetId() : "",
                "details", a.getDetails() != null ? a.getDetails() : Map.of(),
                "ip_address", a.getIpAddress() != null ? a.getIpAddress() : ""
        );
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
