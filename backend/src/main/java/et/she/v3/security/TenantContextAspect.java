package et.she.v3.security;

import et.she.v3.config.SheProperties;
import jakarta.persistence.EntityManager;
import org.aspectj.lang.ProceedingJoinPoint;
import org.aspectj.lang.annotation.Around;
import org.aspectj.lang.annotation.Aspect;
import org.hibernate.Session;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;

import java.sql.Connection;
import java.sql.Statement;
import java.util.UUID;

/**
 * AOP aspect that sets Postgres RLS GUCs (app.tenant_id + app.is_platform_admin)
 * INSIDE the @Transactional boundary, so SET LOCAL applies to the correct
 * transaction's connection.
 *
 * <p>Replaces the broken {@link TenantContextInterceptor} which ran in
 * HandlerInterceptor.preHandle() BEFORE the transaction was opened — causing
 * SET LOCAL to either silently fail or leak to other pooled connections.</p>
 *
 * <p>This aspect runs at {@link Ordered#HIGHEST_PRECEDENCE} so it executes
 * INSIDE the @Transactional proxy (which defaults to LOWEST_PRECEDENCE).</p>
 *
 * <p>Canonical references:</p>
 * <ul>
 *   <li>V3-SECURITY-MODEL §10.5 — RLS bypass mechanism</li>
 *   <li>V3-ARCHITECTURE §5.1 — canonical RLS policy text</li>
 *   <li>P0-5 — she_app does NOT have BYPASSRLS; the policy itself checks the GUC</li>
 * </ul>
 */
@Aspect
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class TenantContextAspect {

    private static final Logger log = LoggerFactory.getLogger(TenantContextAspect.class);

    private final EntityManager entityManager;

    public TenantContextAspect(EntityManager entityManager) {
        this.entityManager = entityManager;
    }

    /**
     * Wrap all @Transactional methods — set RLS GUCs after the transaction
     * opens but before the method body executes.
     */
    @Around("@annotation(org.springframework.transaction.annotation.Transactional)")
    public Object setRlsGucs(ProceedingJoinPoint pjp) throws Throwable {
        setGucsForCurrentUser();
        return pjp.proceed();
    }

    /**
     * Set RLS GUCs for the authenticated user in the current SecurityContext.
     * If no user is authenticated (e.g., /actuator/health, /auth/login), skips.
     */
    private void setGucsForCurrentUser() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        if (auth == null || !auth.isAuthenticated()) return;

        Object principal = auth.getPrincipal();
        if (!(principal instanceof AuthenticatedUser user)) return;

        if (user.tenantId() == null) return;

        try {
            Session session = entityManager.unwrap(Session.class);
            session.doWork((Connection conn) -> {
                try (Statement stmt = conn.createStatement()) {
                    stmt.execute("SET LOCAL app.tenant_id = '" + user.tenantId().toString() + "'");
                    boolean isPlatformAdmin = user.isBypassCapable();
                    stmt.execute("SET LOCAL app.is_platform_admin = " + (isPlatformAdmin ? "'on'" : "'off'"));
                }
            });
        } catch (Exception e) {
            log.warn("Failed to set RLS GUCs: {}", e.getMessage());
        }
    }
}
