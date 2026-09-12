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
 * <p>Ordering is subtle and was originally inverted. Spring sorts advisors by
 * ascending {@code order} and the <em>lowest</em> value wraps <em>outermost</em>,
 * while the transaction interceptor defaults to {@link Ordered#LOWEST_PRECEDENCE}
 * (innermost). Pinning this aspect to {@code HIGHEST_PRECEDENCE} therefore put it
 * <em>outside</em> the transaction, so {@code SET LOCAL} ran before {@code BEGIN}
 * and Postgres discarded it with "SET LOCAL can only be used in transaction blocks".
 * {@link et.she.v3.config.TransactionConfig} now pins the transaction advisor to
 * {@code HIGHEST_PRECEDENCE} and this aspect sits at {@code HIGHEST_PRECEDENCE + 10},
 * which places it INSIDE the transaction while still wrapping everything else.</p>
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
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
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
    // `@annotation` alone is NOT enough. It only matches a @Transactional written
    // directly on the method, while most services declare @Transactional once at
    // class level. Those methods are still transactional (the transaction
    // interceptor reads the class-level annotation), but the aspect silently never
    // ran for them — so their RLS GUCs were never set and every tenant-scoped
    // query returned nothing (surfacing as 404s on write/OTA endpoints).
    // `@within` matches methods declared by an annotated type, covering both forms.
    @Around("@annotation(org.springframework.transaction.annotation.Transactional)"
          + " || @within(org.springframework.transaction.annotation.Transactional)")
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
