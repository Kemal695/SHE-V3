package et.she.v3.security;

import java.util.Map;
import java.util.UUID;

/**
 * Authenticated principal — populated from JWT claims (V3-SECURITY-MODEL §1.2).
 *
 * Claims (canonical):
 *   sub            = user_id (UUID)
 *   email          = user email
 *   platform_role  = USER | PLATFORM_ADMIN | SUPER_ADMIN
 *   tenant_id      = UUID (null for pure B2C — but our schema always has a tenant_id, default B2C tenant for them)
 *   tenant_role    = TENANT_ADMIN | TENANT_INSTALLER | TENANT_VIEWER | null
 *   home_roles     = Map<home_id, role> (cached snapshot, refreshed every 5 min from Redis)
 *   jti            = unique token ID for blacklist (Redis)
 */
public record AuthenticatedUser(
        UUID userId,
        String email,
        String platformRole,
        UUID tenantId,
        String tenantRole,
        Map<String, String> homeRoles,
        String jti
) {
    public boolean isPlatformAdmin() { return "PLATFORM_ADMIN".equals(platformRole); }
    public boolean isSuperAdmin()    { return "SUPER_ADMIN".equals(platformRole); }
    public boolean isBypassCapable() { return isPlatformAdmin() || isSuperAdmin(); }
}
