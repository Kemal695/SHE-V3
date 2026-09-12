package et.she.v3.security;

import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.springframework.stereotype.Component;

import java.sql.Connection;
import java.sql.Statement;

/**
 * Helper that issues the Postgres RLS session GUCs
 * `app.tenant_id` + `app.is_platform_admin` so the canonical RLS policy (P0-5)
 * can enforce tenant isolation.
 *
 * P0-5 mechanism:
 *   SET LOCAL app.tenant_id = '<uuid>'              -- always set
 *   SET LOCAL app.is_platform_admin = 'on' | 'off'  -- 'on' only for PLATFORM_ADMIN / SUPER_ADMIN
 *
 * `SET LOCAL` (not `SET`) scopes the GUC to the current transaction — prevents
 * leakage across pooled HikariCP connections.
 *
 * IMPORTANT — this is NOT a servlet filter / MVC interceptor.
 *   It deliberately does not implement {@code HandlerInterceptor} any more.
 *   A filter/interceptor runs BEFORE the {@code @Transactional} boundary, so its
 *   {@code SET LOCAL} would bind to a different connection than the one the query
 *   later uses, leaving RLS unreliable (bug-fix #3). Per-request GUCs are instead
 *   applied by {@link TenantContextAspect} (AOP {@code @Around}, inside the
 *   transaction). This class survives as an explicitly-invoked utility for the
 *   few call sites that must set a GUC outside the normal authenticated-request
 *   path (CA registration, factory registration, MQTT auth, bootstrap flows).
 *
 * Canonical references:
 *   - V3-SECURITY-MODEL.md §10.5 (RLS bypass mechanism)
 *   - V3-ARCHITECTURE.md §5.1 (canonical RLS policy text)
 *   - V3-DATABASE-DESIGN.md §10
 *   - P0-5: she_app does NOT have BYPASSRLS; the policy itself checks the GUC.
 */
@Component
public class TenantContextInterceptor {

    private final EntityManager entityManager;

    public TenantContextInterceptor(EntityManager entityManager) {
        this.entityManager = entityManager;
    }

    /**
     * Issue SET LOCAL statements inside the current Hibernate transaction.
     *
     * We use Session.doWork() to get a raw JDBC Connection — required because
     * `SET LOCAL` is a Postgres-specific command not exposed via JPA.
     *
     * Must be called from inside an active transaction, otherwise `SET LOCAL`
     * is discarded at statement end.
     */
    public void setRlsGucs(java.util.UUID tenantId, boolean isPlatformAdmin) {
        Session session = entityManager.unwrap(Session.class);
        session.doWork((Connection conn) -> {
            try (Statement stmt = conn.createStatement()) {
                // tenantId is a java.util.UUID — UUID.toString() emits only [0-9a-f-],
                // so it cannot carry an injection payload. Never pass raw user input here.
                String tenantIdLiteral = tenantId.toString();
                stmt.execute("SET LOCAL app.tenant_id = '" + tenantIdLiteral + "'");
                stmt.execute("SET LOCAL app.is_platform_admin = " + (isPlatformAdmin ? "'on'" : "'off'"));
            }
        });
    }

    /**
     * Pre-tenant-resolution bootstrap.
     *
     * <p>Registration and login must read the {@code tenants} table to discover
     * which tenant they are operating on — but the RLS policy on {@code tenants}
     * is keyed on {@code app.tenant_id}, which cannot be set until that lookup has
     * already returned. The lookup therefore sees zero rows and every
     * unauthenticated auth call fails with "Default B2C tenant not seeded".
     *
     * <p>This opens a platform-admin window for that single lookup. Only
     * {@code app.is_platform_admin} is set; {@code app.tenant_id} is deliberately
     * left unset, and the real tenant context is applied immediately afterwards by
     * {@link #setRlsGucsForBootstrap(java.util.UUID)}.</p>
     *
     * <p>Must be called from inside an active transaction — {@code SET LOCAL} is
     * discarded otherwise.</p>
     */
    public void setRlsGucsForTenantLookup() {
        Session session = entityManager.unwrap(Session.class);
        session.doWork((Connection conn) -> {
            try (Statement stmt = conn.createStatement()) {
                stmt.execute("SET LOCAL app.is_platform_admin = 'on'");
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
