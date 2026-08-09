package et.she.v3.dto;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

/**
 * GET /api/v3/auth/me response (V3-API-SPECIFICATION §3).
 */
public record MeResponse(
        UserView user,
        TenantView tenant,
        Map<String, Object> branding
) {
    public record UserView(
            UUID id,
            String email,
            String platform_role,
            String tenant_role,
            String phone_number,
            String preferred_language,
            String full_name,
            boolean mfa_enabled,
            Instant created_at
    ) {}

    public record TenantView(
            UUID id,
            String name,
            String subdomain,
            String plan,
            String status
    ) {}
}
