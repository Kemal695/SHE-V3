package et.she.v3.security;

import jakarta.persistence.EntityManager;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.hibernate.Session;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.sql.Connection;
import java.sql.Statement;

/**
 * Sets Postgres session GUCs `app.tenant_id` + `app.is_platform_admin` per request
 * so the canonical RLS policy (P0-5) can enforce tenant isolation.
 *
 * P0-5 mechanism:
 *   SET LOCAL app.tenant_id = '<uuid>'              -- always set
 *   SET LOCAL app.is_platform_admin = 'on' | 'off'  -- 'on' only for PLATFORM_ADMIN / SUPER_ADMIN
 *
 * `SET LOCAL` (not `SET`) scopes the GUC to the current transaction — prevents
 * leakage across pooled HikariCP connections.
 *
 * This runs AFTER Spring Security has populated the AuthenticatedUser principal.
 *
 * Canonical references:
 *   - V3-SECURITY-MODEL.md §10.5 (RLS bypass mechanism)
 *   - V3-ARCHITECTURE.md §5.1 (canonical RLS policy text)
 *   - V3-DATABASE-DESIGN.md §10 (TenantContextInterceptor code)
 */
@Component
public class TenantContextInterceptor implements HandlerInterceptor {

    private final EntityManager entityManager;

    public TenantContextInterceptor(EntityManager entityManager) {
        this.entityManager = entityManager;
    }

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response, Object handler) {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication != null && authentication.getPrincipal() instanceof AuthenticatedUser auth) {
            setRlsGucs(auth.tenantId(), auth.isBypassCapable());
        }
        return true;
    }

    /**
     * Issue SET LOCAL statements inside the current Hibernate transaction.
     *
     * We use Session.doWork() to get a raw JDBC Connection — required because
     * `SET LOCAL` is a Postgres-specific command not exposed via JPA.
     */
    public void setRlsGucs(java.util.UUID tenantId, boolean isPlatformAdmin) {
        Session session = entityManager.unwrap(Session.class);
        session.doWork((Connection conn) -> {
            try (Statement stmt = conn.createStatement()) {
                // IMPORTANT: tenant_id must be a valid UUID string — never user input directly.
                // We use a PreparedStatement-style escape via string literal validation.
                String tenantIdLiteral = tenantId.toString();   // UUID.toString() is safe
                stmt.execute("SET LOCAL app.tenant_id = '" + tenantIdLiteral + "'");
                stmt.execute("SET LOCAL app.is_platform_admin = " + (isPlatformAdmin ? "'on'" : "'off'"));
            }
        });
    }

    /**
     * Used by bootstrap endpoints (registration of the first user) where there is
     * no authenticated user yet but RLS needs to be temporarily bypassed.
     *
     * This is safe ONLY because:
     *   1. It sets `app.is_platform_admin='on'` for the duration of a single transaction.
     *   2. The caller is responsible for only doing tenant-agnostic operations.
     *   3. In `prod` profile, this method is a no-op (guarded by SecurityConfig).
     */
    public void setRlsGucsForBootstrap(java.util.UUID tenantId) {
        setRlsGucs(tenantId, true);
    }
}
