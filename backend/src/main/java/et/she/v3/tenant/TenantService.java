package et.she.v3.tenant;

import et.she.v3.entity.Tenant;
import et.she.v3.errors.SheException;
import et.she.v3.repository.TenantRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * Tenant management service — CRUD for B2B tenants.
 *
 * V3-B2B-WHITELABEL §1-3. V3-ADMIN-PLATFORM §4.1.
 *
 * Tenant lifecycle (V3-B2B-WHITELABEL §2.8):
 *   TRIAL → ACTIVE → SUSPENDED → TERMINATED
 *
 * Branding (V3-B2B-WHITELABEL §3):
 *   branding_config JSONB: {app_name, logo_url, primary_color, login_bg_url,
 *   domain, support_email, support_phone, primary_language}
 *   Forbidden hues: #4F46E5, #6366F1, #7C3AED, #8B5CF6 (indigo/blue-purple)
 */
@Service
@Transactional
public class TenantService {

    private static final Pattern FORBIDDEN_HUES = Pattern.compile(
            "^#(4F46E5|6366F1|7C3AED|8B5CF6|5B21B6|6D28D9|7E22CE|9333EA)",
            Pattern.CASE_INSENSITIVE
    );

    private final TenantRepository tenantRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public TenantService(TenantRepository tenantRepository,
                         TenantContextInterceptor tenantContextInterceptor) {
        this.tenantRepository = tenantRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    // =========================================================================
    // Admin CRUD (SUPER_ADMIN only)
    // =========================================================================

    public Tenant createTenant(CreateTenantRequest req) {
        requireSuperAdmin();

        // Validate subdomain format
        if (!req.subdomain().matches("^[a-z0-9-]{3,60}$")) {
            throw new SheException("VALIDATION_FAILED",
                    "Subdomain must be 3-60 chars, lowercase alphanumeric + hyphens", 400);
        }
        if (tenantRepository.findBySubdomain(req.subdomain()).isPresent()) {
            throw new SheException("CONFLICT_EMAIL_TAKEN",
                    "Subdomain " + req.subdomain() + " already taken", 409);
        }

        // Validate branding primary_color (no indigo/blue-purple)
        if (req.branding_config() != null) {
            String color = (String) req.branding_config().get("primary_color");
            if (color != null && FORBIDDEN_HUES.matcher(color).find()) {
                throw new SheException("VALIDATION_COLOR_FORBIDDEN",
                        "This hue is reserved for the SHE platform. Please choose a different brand color.", 400);
            }
        }

        // Set platform-admin GUC for tenant creation (cross-tenant)
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        Tenant tenant = new Tenant();
        tenant.setName(req.name());
        tenant.setSubdomain(req.subdomain());
        tenant.setPlan(req.plan());
        tenant.setStatus("TRIAL");
        tenant.setBrandingConfig(req.branding_config());
        tenant = tenantRepository.save(tenant);

        return tenant;
    }

    public List<Tenant> listTenants() {
        requireSuperAdmin();
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);
        return tenantRepository.findAll();
    }

    public Tenant getTenant(UUID id) {
        requirePlatformAdmin();
        return tenantRepository.findById(id)
                .orElseThrow(() -> new SheException("TENANT_NOT_FOUND", "Tenant " + id + " not found", 404));
    }

    public Tenant updateBranding(UUID id, Map<String, Object> branding) {
        requireSuperAdmin();
        Tenant tenant = getTenant(id);

        // Validate primary_color
        String color = (String) branding.get("primary_color");
        if (color != null && FORBIDDEN_HUES.matcher(color).find()) {
            throw new SheException("VALIDATION_COLOR_FORBIDDEN",
                    "This hue is reserved for the SHE platform. Please choose a different brand color.", 400);
        }

        tenant.setBrandingConfig(branding);
        return tenantRepository.save(tenant);
    }

    public Tenant updateStatus(UUID id, String status) {
        requireSuperAdmin();
        Tenant tenant = getTenant(id);

        if (!status.matches("^(TRIAL|ACTIVE|SUSPENDED|TERMINATED)$")) {
            throw new SheException("VALIDATION_FAILED",
                    "Status must be TRIAL, ACTIVE, SUSPENDED, or TERMINATED", 400);
        }

        tenant.setStatus(status);
        if ("TERMINATED".equals(status)) {
            // V3-B2B-WHITELABEL §2.8 — on TERMINATED: revoke certs, factory-reset devices
            // TODO: trigger cert revocation + device factory_reset via MQTT
        }
        return tenantRepository.save(tenant);
    }

    // =========================================================================
    // Branding (public — no auth, resolves by subdomain)
    // =========================================================================

    /**
     * GET /api/v3/tenant/branding?subdomain=xxx
     * Public endpoint — Flutter app fetches on login to apply white-label branding.
     */
    public Map<String, Object> getBrandingBySubdomain(String subdomain) {
        if (subdomain == null || subdomain.isBlank()) {
            // Return default B2C branding
            return defaultB2CBranding();
        }
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);
        return tenantRepository.findBySubdomain(subdomain)
                .map(tenant -> {
                    Map<String, Object> result = new java.util.HashMap<>();
                    if (tenant.getBrandingConfig() != null) {
                        result.putAll(tenant.getBrandingConfig());
                    }
                    result.put("tenant_id", tenant.getId());
                    result.put("tenant_name", tenant.getName());
                    result.put("subdomain", tenant.getSubdomain());
                    result.put("plan", tenant.getPlan());
                    return result;
                })
                .orElse(defaultB2CBranding());
    }

    private Map<String, Object> defaultB2CBranding() {
        return Map.of(
                "app_name", "Smart Home Ethiopia",
                "primary_color", "#0B1D37",
                "accent_color", "#56B4FA",
                "primary_language", "am",
                "is_default", true
        );
    }

    // =========================================================================
    // RBAC
    // =========================================================================

    private void requireSuperAdmin() {
        AuthenticatedUser user = currentUser();
        if (!user.isSuperAdmin()) {
            throw new SheException("RBAC_SUPER_ADMIN_REQUIRED",
                    "SUPER_ADMIN role required", 403);
        }
    }

    private void requirePlatformAdmin() {
        AuthenticatedUser user = currentUser();
        if (!user.isBypassCapable()) {
            throw new SheException("RBAC_FORBIDDEN",
                    "PLATFORM_ADMIN or SUPER_ADMIN role required", 403);
        }
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }

    // =========================================================================
    // DTOs
    // =========================================================================

    public record CreateTenantRequest(
            String name,
            String subdomain,
            String plan,                 // B2B_100 | B2B_1000 | B2B_UNLIMITED
            Map<String, Object> branding_config
    ) {}
}
