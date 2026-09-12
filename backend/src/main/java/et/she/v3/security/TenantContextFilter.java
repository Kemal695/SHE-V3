package et.she.v3.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.UUID;

/**
 * Request-scoped filter that assigns and propagates the correlation ID
 * (`X-Request-Id` header + SLF4J MDC `reqId`) used by the error envelope
 * (V3-ERROR-CODES §1 — every error carries `request_id`).
 *
 * Canonical references:
 *   - V3-ERROR-CODES.md §1 (request_id in every error response)
 *
 * NOTE — RLS is NOT set here.
 *   Postgres session GUCs (`app.tenant_id` + `app.is_platform_admin`) are set by
 *   {@link TenantContextAspect}, which runs *inside* the {@code @Transactional}
 *   boundary. Setting them in a servlet filter would run outside the transaction
 *   and therefore not apply to the connection actually used by the query
 *   (P0-5 / bug-fix #3). A few call sites that need a GUC before/without a
 *   user context call {@link TenantContextInterceptor#setRlsGucs} directly.
 */
@Component
public class TenantContextFilter extends OncePerRequestFilter {

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
