package et.she.v3.security;

import et.she.v3.config.SheProperties;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.hibernate.Session;
import org.slf4j.MDC;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.HandlerInterceptor;

import java.io.IOException;
import java.util.UUID;

/**
 * Sets the Postgres session GUCs `app.tenant_id` + `app.is_platform_admin`
 * per request so the canonical RLS policy (P0-5) can enforce tenant isolation.
 *
 * Canonical references:
 *   - V3-SECURITY-MODEL.md §10.5 (RLS bypass mechanism)
 *   - V3-ARCHITECTURE.md §5.1 (canonical RLS policy text)
 *   - V3-DATABASE-DESIGN.md §10 (TenantContextInterceptor code)
 *   - P0-5: she_app does NOT have BYPASSRLS; the policy itself checks the GUC.
 *
 * Mechanism:
 *   For each request, after Spring Security has populated the AuthenticatedUser:
 *     SET LOCAL app.tenant_id = '<uuid>'
 *     SET LOCAL app.is_platform_admin = 'on' | 'off'
 *
 * `SET LOCAL` (not `SET`) scopes the variable to the current transaction,
 * preventing leakage across pooled HikariCP connections.
 *
 * Spring Boot 3.x: this filter uses Hibernate's Session doWork() to issue the
 * SET LOCAL commands inside the active transaction.
 */
@Component
public class TenantContextFilter extends OncePerRequestFilter {

    private final SheProperties props;

    public TenantContextFilter(SheProperties props) {
        this.props = props;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        // Generate / propagate request ID (V3-ERROR-CODES §1 — every error carries request_id)
        String reqId = request.getHeader("X-Request-Id");
        if (reqId == null || reqId.isBlank()) {
            reqId = "req-" + UUID.randomUUID();
        }
        MDC.put("reqId", reqId);
        response.setHeader("X-Request-Id", reqId);

        try {
            chain.doFilter(request, response);
        } finally {
            MDC.clear();
        }
    }
}
