package et.she.v3.security.filters;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Security headers filter — adds OWASP-recommended HTTP headers to every response.
 *
 * V3-SECURITY-MODEL §10 (OWASP A05 — Security Misconfiguration):
 *   - HSTS (max-age=2 years, includeSubDomains, preload)
 *   - X-Frame-Options: DENY (no clickjacking)
 *   - X-Content-Type-Options: nosniff (no MIME sniffing)
 *   - Referrer-Policy: strict-origin-when-cross-origin
 *   - Permissions-Policy: camera+microphone+geolocation disabled
 *   - Content-Security-Policy: restrict to she.et origin
 *
 * These complement (not replace) the Nginx-level headers.
 * Defense-in-depth: both Nginx + Spring Boot set the same headers.
 */
@Component
public class SecurityHeadersFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        // HSTS — 2 years, includeSubDomains, preload
        response.setHeader("Strict-Transport-Security",
                "max-age=63072000; includeSubDomains; preload");

        // No clickjacking
        response.setHeader("X-Frame-Options", "DENY");

        // No MIME sniffing
        response.setHeader("X-Content-Type-Options", "nosniff");

        // Referrer policy
        response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");

        // Permissions policy — disable camera, mic, geolocation
        response.setHeader("Permissions-Policy",
                "camera=(), microphone=(), geolocation=()");

        // CSP — restrict everything to 'self' (Nginx adds the full CSP with CDN)
        // This is a fallback if Nginx is bypassed
        if (response.getHeader("Content-Security-Policy") == null) {
            response.setHeader("Content-Security-Policy",
                    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
                    "img-src 'self' data: https:; connect-src 'self' wss://she.et; " +
                    "font-src 'self'; object-src 'none'; frame-ancestors 'none';");
        }

        chain.doFilter(request, response);
    }
}
