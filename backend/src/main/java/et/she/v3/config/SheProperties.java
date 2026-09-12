package et.she.v3.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;
import java.util.Map;

/**
 * SHE-specific configuration properties bound to {@code she.*} in application.yml.
 *
 * Canonical references:
 *   - V3-CONFIGURATION.md §2.1 (env var catalog)
 *   - V3-SECURITY-MODEL.md §1.1 (JWT spec), §6 (MFA)
 *   - V3-ARCHITECTURE.md §5.4 (Redis cache TTLs)
 *   - P1-6: EdDSA / Ed25519 with kid multi-key rotation
 *   - P0-5: RLS bypass via app.is_platform_admin GUC
 */
@ConfigurationProperties(prefix = "she")
public record SheProperties(
        Jwt jwt,
        Security security,
        Mqtt mqtt,
        Ca ca,
        Api api
) {

    /**
     * JWT configuration (EdDSA / Ed25519 per P1-6).
     *
     * @param signingPrivateKeyPath     path to Ed25519 private key (PEM, PKCS#8)
     * @param signingKeyId              kid JWT header value (e.g. "2025q1")
     * @param signingPublicKeysJson     JSON array of {kid, public_key_pem} entries — all accepted during rotation
     * @param accessTokenTtlSeconds     15 min (900s) for ALL roles per V3-SECURITY-MODEL §1.1
     * @param refreshTokenTtlSeconds    per-role refresh TTLs (USER=30d, TENANT/PLATFORM_ADMIN=8h, SUPER_ADMIN=4h)
     * @param issuer                    JWT iss claim
     * @param audience                  JWT aud claim
     */
    public record Jwt(
            String signingPrivateKeyPath,
            String signingKeyId,
            String signingPublicKeysJson,
            long accessTokenTtlSeconds,
            Map<String, Long> refreshTokenTtlSeconds,
            String issuer,
            String audience
    ) {
        public Duration accessTokenTtl() { return Duration.ofSeconds(accessTokenTtlSeconds); }
        public Duration refreshTokenTtl(String platformRole) {
            return Duration.ofSeconds(refreshTokenTtlSeconds.getOrDefault(platformRole, 3600L));
        }
    }

    /**
     * Security configuration.
     */
    public record Security(
            int bcryptCost,                 // 12 per V3-DATABASE-DESIGN §4.2
            String kek,                     // AES-256-GCM master key (base64)
            String mfaIssuer,
            LoginRateLimit loginRateLimit,
            boolean devModeRlsBypass
    ) {
        public record LoginRateLimit(int maxAttempts, int windowMinutes, int lockoutMinutes) {}
    }

    /**
     * MQTT client configuration (Paho + mTLS per V3-SECURITY-MODEL §4.4).
     * P1-10: backend uses client cert + explicit ACL — NO superuser, NO blanket bypass.
     */
    public record Mqtt(
            String brokerUrl,
            String backendCertPath,
            String backendKeyPath,
            String caBundlePath,
            String sharedSubscriptionGroup,
            String clientIdPrefix,
            String internalToken
    ) {}

    /**
     * step-ca client configuration (V3-CONFIGURATION §3, V3-SECURITY-MODEL §3.1).
     * Spring Boot NEVER holds the CA private key — it calls step-ca REST API to sign CSRs.
     */
    public record Ca(
            String url,
            String provisionerName,
            String provisionerPasswordFile,
            String provisionerKeyPath,
            String intermediateCertPath,
            String caBundlePath,
            String crlPublishBaseUrl,
            long certCacheTtlSeconds
    ) {}

    /**
     * API configuration (V3-API-SPECIFICATION §1).
     */
    public record Api(
            String basePath,
            Pagination pagination,
            RateLimit rateLimit
    ) {
        public record Pagination(int defaultPageSize, int maxPageSize) {}
        public record RateLimit(int perUserPerMinute, int perTenantPerMinute) {}
    }
}
