package et.she.v3.security;

import et.she.v3.errors.SheException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.authentication.WebAuthenticationDetailsSource;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Parses `Authorization: Bearer <jwt>` header, verifies the JWT via {@link JwtService},
 * and populates the Spring Security context with an {@link AuthenticatedUser} principal.
 *
 * V3-SECURITY-MODEL §1.2 — JWT claims:
 *   sub            = user_id (UUID)
 *   email          = user email
 *   platform_role  = USER | PLATFORM_ADMIN | SUPER_ADMIN
 *   tenant_id      = UUID
 *   tenant_role    = TENANT_ADMIN | TENANT_INSTALLER | TENANT_VIEWER | null
 *   home_roles     = Map<home_id, role>  (cached snapshot, 5-min TTL)
 *   jti            = unique token ID for blacklist
 */
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtService jwtService;

    public JwtAuthenticationFilter(JwtService jwtService) {
        this.jwtService = jwtService;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String header = request.getHeader("Authorization");
        if (header == null || !header.startsWith("Bearer ")) {
            chain.doFilter(request, response);
            return;
        }
        String token = header.substring(7).trim();
        try {
            Map<String, Object> claims = jwtService.decode(token);

            AuthenticatedUser user = new AuthenticatedUser(
                    UUID.fromString((String) claims.get("sub")),
                    (String) claims.get("email"),
                    (String) claims.get("platform_role"),
                    claims.get("tenant_id") != null ? UUID.fromString((String) claims.get("tenant_id")) : null,
                    (String) claims.get("tenant_role"),
                    (Map<String, String>) claims.getOrDefault("home_roles", new HashMap<>()),
                    (String) claims.get("jti")
            );

            // Build Spring Security authorities from platform_role + tenant_role
            List<SimpleGrantedAuthority> authorities = new java.util.ArrayList<>();
            authorities.add(new SimpleGrantedAuthority("ROLE_" + user.platformRole()));
            if (user.tenantRole() != null) {
                authorities.add(new SimpleGrantedAuthority("ROLE_" + user.tenantRole()));
            }

            UsernamePasswordAuthenticationToken auth =
                    new UsernamePasswordAuthenticationToken(user, null, authorities);
            auth.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));
            SecurityContextHolder.getContext().setAuthentication(auth);

        } catch (SheException e) {
            // Let the GlobalExceptionHandler handle it via re-throw — but for filters,
            // we need to send the response directly since the exception won't propagate
            // through the filter chain to @ControllerAdvice.
            response.setStatus(e.getHttpStatus());
            response.setContentType("application/json");
            response.getWriter().write("""
                {"error":{"code":"%s","message":"%s","http_status":%d}}
                """.formatted(e.getCode(), e.getMessage(), e.getHttpStatus()));
            return;
        }

        chain.doFilter(request, response);
    }
}
