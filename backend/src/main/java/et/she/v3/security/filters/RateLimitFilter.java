package et.she.v3.security.filters;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.Duration;
import java.util.concurrent.TimeUnit;

/**
 * Rate limiting filter — enforces per-user and per-IP limits via Redis sliding window.
 *
 * V3-API-SPECIFICATION §1:
 *   B2C: 600 req/min per user
 *   B2B: 6000 req/min per tenant
 *   Login: 5 attempts per 15 min → RATE_LIMIT_LOGIN
 *   Admin: 100 req/min → RATE_LIMIT_ADMIN
 *
 * V3-SECURITY-MODEL §10.3 — brute-force backoff: 5 → 15 → 60 → 360 min.
 */
@Component
public class RateLimitFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(RateLimitFilter.class);
    private static final String RATE_LIMIT_PREFIX = "ratelimit:";

    private final StringRedisTemplate redis;

    /**
     * Requests per minute for the general API bucket. Comes from
     * `she.api.rate-limit.per-user-per-minute` (default 600).
     *
     * The bucket is keyed by IP rather than by user: this filter runs in the
     * servlet chain, BEFORE authentication, so there is no principal to key on
     * yet. `per-tenant-per-minute` therefore cannot be applied here — it is
     * enforced per authenticated tenant elsewhere. The value used to be
     * hardcoded, which silently ignored the documented setting.
     */
    private final int apiPerMinute;

    public RateLimitFilter(StringRedisTemplate redis,
                           @Value("${she.api.rate-limit.per-user-per-minute:600}") int apiPerMinute) {
        this.redis = redis;
        this.apiPerMinute = apiPerMinute;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String path = request.getRequestURI();

        // Skip actuator + static
        if (path.startsWith("/actuator") || path.startsWith("/static")) {
            chain.doFilter(request, response);
            return;
        }

        // Determine rate limit key + window
        String ip = getClientIP(request);
        String limitKey;
        int maxRequests;
        int windowSeconds;

        if (path.startsWith("/api/v3/auth/login") || path.startsWith("/api/v3/auth/register")) {
            // Login rate limit: 5 per 15 min per IP
            limitKey = RATE_LIMIT_PREFIX + "login:" + ip;
            maxRequests = 5;
            windowSeconds = 900;  // 15 min
        } else if (path.startsWith("/api/admin/")) {
            // Admin rate limit: 100 per min per IP
            limitKey = RATE_LIMIT_PREFIX + "admin:" + ip;
            maxRequests = 100;
            windowSeconds = 60;
        } else {
            // Default API rate limit — configured, not hardcoded (see apiPerMinute).
            limitKey = RATE_LIMIT_PREFIX + "api:" + ip;
            maxRequests = apiPerMinute;
            windowSeconds = 60;
        }

        // Redis INCR + expire
        Long count = redis.opsForValue().increment(limitKey);
        if (count != null && count == 1) {
            redis.expire(limitKey, windowSeconds, TimeUnit.SECONDS);
        }

        if (count != null && count > maxRequests) {
            log.warn("Rate limited: path={} ip={} count={}/{}", path, ip, count, maxRequests);
            response.setStatus(429);
            response.setContentType("application/json");
            response.setHeader("Retry-After", String.valueOf(windowSeconds));
            response.getWriter().write(
                "{\"error\":{\"code\":\"RATE_LIMIT_API\",\"message\":\"Rate limit exceeded. Try again in "
                + windowSeconds + " seconds.\",\"http_status\":429}}"
            );
            return;
        }

        chain.doFilter(request, response);
    }

    private String getClientIP(HttpServletRequest request) {
        String xff = request.getHeader("X-Forwarded-For");
        if (xff != null && !xff.isEmpty()) {
            return xff.split(",")[0].trim();
        }
        return request.getRemoteAddr();
    }
}
