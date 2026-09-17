package et.she.v3.controller;

import et.she.v3.entity.User;
import et.she.v3.errors.SheException;
import et.she.v3.repository.UserRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * Admin user management endpoints.
 * V3-ADMIN-PLATFORM §4.2.
 *
 *   GET    /api/admin/users                  — list (paginated, RLS-scoped)
 *   GET    /api/admin/users/{id}             — detail
 *   PATCH  /api/admin/users/{id}/role        — change role
 *   POST   /api/admin/users/{id}/disable      — disable (set deleted_at)
 *   POST   /api/admin/users/{id}/enable       — re-enable
 *   DELETE /api/admin/users/{id}              — hard delete
 *
 * Auth: TENANT_ADMIN+ for own tenant, SUPER_ADMIN for any tenant.
 */
@RestController
@RequestMapping("/api/admin/users")
public class AdminUserController {

    private final UserRepository userRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public AdminUserController(UserRepository userRepository,
                                 TenantContextInterceptor tenantContextInterceptor) {
        this.userRepository = userRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    @GetMapping
    public ResponseEntity<Map<String, Object>> list(
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size) {
        AuthenticatedUser admin = currentUser();
        if (size > 100) size = 100;
        // RLS is already set by TenantContextAspect — JPA query auto-filters by tenant
        Page<User> result = userRepository.findAll(PageRequest.of(page, size));
        var data = result.getContent().stream()
                .filter(u -> u.getDeletedAt() == null)
                .map(this::toResponse)
                .toList();
        return ResponseEntity.ok(Map.of("data", data, "meta", Map.of(
                "total", result.getTotalElements(),
                "page", page,
                "size", size
        )));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Map<String, Object>> getById(@PathVariable UUID id) {
        User user = userRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "User not found", 404));
        return ResponseEntity.ok(Map.of("data", toResponse(user)));
    }

    public record UpdateRoleRequest(@NotBlank String platform_role, String tenant_role) {}

    @PatchMapping("/{id}/role")
    public ResponseEntity<Map<String, Object>> updateRole(@PathVariable UUID id,
                                                           @Valid @RequestBody UpdateRoleRequest req) {
        User user = userRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "User not found", 404));

        if (!req.platform_role().matches("^(USER|PLATFORM_ADMIN|SUPER_ADMIN)$")) {
            throw new SheException("VALIDATION_FAILED", "platform_role must be USER|PLATFORM_ADMIN|SUPER_ADMIN", 400);
        }
        user.setPlatformRole(req.platform_role());
        if (req.tenant_role() != null && !req.tenant_role().isBlank()) {
            if (!req.tenant_role().matches("^(TENANT_ADMIN|TENANT_INSTALLER|TENANT_VIEWER)$")) {
                throw new SheException("VALIDATION_FAILED", "tenant_role must be TENANT_ADMIN|TENANT_INSTALLER|TENANT_VIEWER", 400);
            }
            user.setTenantRole(req.tenant_role());
        }
        userRepository.save(user);
        return ResponseEntity.ok(Map.of("data", toResponse(user)));
    }

    @PostMapping("/{id}/disable")
    public ResponseEntity<Map<String, Object>> disable(@PathVariable UUID id,
                                                        @RequestBody(required = false) Map<String, String> body) {
        User user = userRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "User not found", 404));
        user.setDeletedAt(Instant.now());
        userRepository.save(user);
        return ResponseEntity.ok(Map.of("data", Map.of("id", id, "status", "disabled")));
    }

    @PostMapping("/{id}/enable")
    public ResponseEntity<Map<String, Object>> enable(@PathVariable UUID id) {
        User user = userRepository.findById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "User not found", 404));
        user.setDeletedAt(null);
        userRepository.save(user);
        return ResponseEntity.ok(Map.of("data", Map.of("id", id, "status", "enabled")));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable UUID id) {
        AuthenticatedUser admin = currentUser();
        if (id.equals(admin.userId())) {
            throw new SheException("VALIDATION_FAILED", "Cannot delete your own account", 400);
        }
        userRepository.deleteById(id);
        return ResponseEntity.noContent().build();
    }

    /**
     * POST /api/admin/users/{id}/reset-mfa
     * V3-ADMIN-PLATFORM §4.2 — SUPER_ADMIN only.
     * Clears MFA secret + recovery codes so user can re-enroll.
     */
    @PostMapping("/{id}/reset-mfa")
    public ResponseEntity<Map<String, Object>> resetMfa(@PathVariable UUID id) {
        AuthenticatedUser admin = currentUser();
        if (!admin.isSuperAdmin()) {
            throw new SheException("RBAC_SUPER_ADMIN_REQUIRED",
                    "Only SUPER_ADMIN can reset MFA", 403);
        }
        User user = userRepository.findActiveById(id)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "User not found", 404));
        user.setMfaEnabled(false);
        user.setTotpSecretEncrypted(null);
        user.setTotpRecoveryCodes(null);
        user.setMfaFailedAttempts(0);
        user.setMfaLockedUntil(null);
        userRepository.save(user);
        return ResponseEntity.ok(Map.of("data", Map.of(
                "id", id,
                "mfa_enabled", false,
                "message", "MFA reset — user must re-enroll on next login"
        )));
    }

    private Map<String, Object> toResponse(User u) {
        return Map.of(
                "id", u.getId(),
                "email", u.getEmail(),
                "platform_role", u.getPlatformRole(),
                "tenant_role", u.getTenantRole() != null ? u.getTenantRole() : "",
                "full_name", u.getFullName() != null ? u.getFullName() : "",
                "phone_number", u.getPhoneNumber() != null ? u.getPhoneNumber() : "",
                "mfa_enabled", u.isMfaEnabled(),
                "created_at", u.getCreatedAt() != null ? u.getCreatedAt().toString() : "",
                "last_login_at", u.getLastLoginAt() != null ? u.getLastLoginAt().toString() : ""
        );
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
