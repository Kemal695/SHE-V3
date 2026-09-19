package et.she.v3.config;

import et.she.v3.errors.GlobalExceptionHandler;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.JwtAuthenticationFilter;
import et.she.v3.security.JwtService;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * Spring Security configuration.
 *
 * V3-SECURITY-MODEL §1.1 — JWT auth (EdDSA/Ed25519, P1-6).
 * V3-SECURITY-MODEL §2.5 — authorization chokepoint getAuthorizedHomeOrThrow (Phase 1+).
 * V3-API-SPECIFICATION §1 — public endpoints (auth/login, auth/register, tenant/branding, payment webhooks).
 *
 * Endpoint visibility:
 *   PUBLIC:    /actuator/health, /actuator/info, /api/v3/auth/login, /api/v3/auth/register,
 *              /api/v3/tenant/branding, /internal/mqtt/auth, /internal/mqtt/acl
 *   AUTHENTICATED: everything else under /api/v3/*
 *   INTERNAL:  /internal/* (not exposed via Cloudflare in prod; protected by network ACL)
 */
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    private final JwtService jwtService;

    public SecurityConfig(JwtService jwtService) {
        this.jwtService = jwtService;
    }

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())                    // stateless JWT — no CSRF
            .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                // Actuator health + info (no auth — needed for k8s probes + Cloudflare health checks)
                .requestMatchers("/actuator/health", "/actuator/info", "/actuator/prometheus").permitAll()
                // Auth endpoints — public
                .requestMatchers("/api/v3/auth/login", "/api/v3/auth/register").permitAll()
                .requestMatchers("/api/v3/auth/refresh").permitAll()
                .requestMatchers("/api/v3/tenant/branding").permitAll()
                // Chapa payment webhook — no session/JWT; authenticated by HMAC-SHA256 inside
                // PaymentService.verifySignature() (V3-PAYMENTS §3.2), not by Spring Security.
                .requestMatchers("/api/v3/payments/webhook").permitAll()
                // WebSocket handshake — auth is handled by WsAuthInterceptor via Sec-WebSocket-Protocol
                .requestMatchers("/ws/v3").permitAll()
                // Internal endpoints — protected by network ACL in prod (not exposed to Cloudflare)
                .requestMatchers("/internal/**").permitAll()
                // OTA firmware images — public by design. The device authenticates the
                // IMAGE, not the request: ota_handler verifies SHA-256 + Ed25519 via
                // TweetNaCl before flashing (V3-SECURITY-MODEL §5.5), so a forged or
                // tampered download is rejected on-device. Gating this behind a JWT
                // would break OTA outright — the ESP32 has no user token.
                .requestMatchers("/firmware/**").permitAll()
                // Swagger UI (local + staging only — disabled in prod via application-prod.yml)
                .requestMatchers("/swagger-ui/**", "/v3/api-docs/**").permitAll()
                // Everything else requires authentication
                .anyRequest().authenticated()
            )
            .addFilterBefore(new JwtAuthenticationFilter(jwtService), UsernamePasswordAuthenticationFilter.class)
            .exceptionHandling(eh -> eh
                .authenticationEntryPoint(GlobalExceptionHandler::unauthorized)
                .accessDeniedHandler(GlobalExceptionHandler::forbidden)
            );

        return http.build();
    }

    /**
     * BCrypt cost 12 per V3-DATABASE-DESIGN §4.2.
     */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }

    // NOTE: TenantContextInterceptor (HandlerInterceptor) was removed — it ran before
    // the @Transactional boundary, so SET LOCAL didn't apply to the correct transaction.
    // Replaced by TenantContextAspect (AOP @Around on @Transactional methods) which
    // runs INSIDE the transaction. See TenantContextAspect.java.
}
