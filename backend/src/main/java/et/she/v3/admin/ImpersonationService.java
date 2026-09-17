package et.she.v3.admin;

import et.she.v3.entity.User;
import et.she.v3.errors.SheException;
import et.she.v3.repository.UserRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.JwtService;
import et.she.v3.security.TenantContextInterceptor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Impersonation service — allows admins to act as another user for support.
 *
 * V3-ADMIN-PLATFORM §4.4.
 * - SUPER_ADMIN can impersonate any user across any tenant
 * - TENANT_ADMIN can only impersonate users in their own tenant (RLS enforced)
 * - Impersonation JWT TTL: 15 min
 * - Cannot impersonate while already impersonating (no chains)
 * - JWT carries `impersonated_by` claim (admin's user_id)
 * - All actions audit-logged with BOTH admin + target user IDs
 */
@Service
@Transactional
public class ImpersonationService {

    private static final Logger log = LoggerFactory.getLogger(ImpersonationService.class);
    private static final Duration IMPERSONATION_TTL = Duration.ofMinutes(15);

    private final UserRepository userRepository;
    private final JwtService jwtService;
    private final TenantContextInterceptor tenantContextInterceptor;

    public ImpersonationService(UserRepository userRepository,
                                JwtService jwtService,
                                TenantContextInterceptor tenantContextInterceptor) {
        this.userRepository = userRepository;
        this.jwtService = jwtService;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    /**
     * POST /api/admin/impersonate/{userId}
     * Returns a 15-min impersonation JWT.
     */
    public ImpersonationResponse impersonate(UUID targetUserId) {
        AuthenticatedUser admin = currentUser();

        // Check for chain (can't impersonate while already impersonating)
        if (admin.jti() != null && admin.jti().startsWith("imp:")) {
            throw new SheException("RBAC_IMPERSONATION_CHAIN",
                    "Cannot impersonate while already impersonating — end current session first", 403);
        }

        // Set RLS context — TENANT_ADMIN can only impersonate within own tenant
        if (admin.isSuperAdmin()) {
            // SUPER_ADMIN: cross-tenant allowed — set platform-admin GUC
            tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);
        } else {
            // TENANT_ADMIN: RLS-enforced to own tenant
            tenantContextInterceptor.setRlsGucs(admin.tenantId(), admin.isBypassCapable());
        }

        User target = userRepository.findActiveById(targetUserId)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND",
                        "User " + targetUserId + " not found", 404));

        // TENANT_ADMIN can only impersonate users in their own tenant
        if (!admin.isSuperAdmin() && !target.getTenantId().equals(admin.tenantId())) {
            throw new SheException("RBAC_FORBIDDEN",
                    "Cannot impersonate user from another tenant", 403);
        }

        // Build impersonation JWT (15-min TTL, impersonated_by claim)
        Instant now = Instant.now();
        Instant expiry = now.plus(IMPERSONATION_TTL);

        Map<String, Object> claims = new LinkedHashMap<>();
        claims.put("sub", target.getId().toString());
        claims.put("email", target.getEmail());
        claims.put("platform_role", target.getPlatformRole());
        claims.put("tenant_id", target.getTenantId().toString());
        claims.put("tenant_role", target.getTenantRole());
        claims.put("home_roles", new HashMap<>());
        claims.put("jti", "imp:" + UUID.randomUUID());
        claims.put("iat", now.getEpochSecond());
        claims.put("exp", expiry.getEpochSecond());
        claims.put("iss", "she.et");
        claims.put("aud", "she-api");
        claims.put("type", "access");
        claims.put("impersonated_by", admin.userId().toString());

        String token = jwtService.encode(claims);

        log.info("Impersonation started: admin={} → target={} (expires in {}min)",
                admin.email(), target.getEmail(), IMPERSONATION_TTL.toMinutes());

        // TODO: write audit_log event admin.impersonate.started

        return new ImpersonationResponse(token, target.getEmail(), expiry.toString(), admin.email());
    }

    /**
     * DELETE /api/admin/impersonate — end impersonation (return to admin JWT).
     * The caller must use their original admin JWT (not the impersonation JWT).
     */
    public void endImpersonation() {
        AuthenticatedUser admin = currentUser();
        log.info("Impersonation ended by admin={}", admin.email());
        // TODO: write audit_log event admin.impersonate.ended
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }

    public record ImpersonationResponse(
            String access_token,
            String impersonated_email,
            String expires_at,
            String impersonated_by
    ) {}
}
