package et.she.v3.tenant;

import et.she.v3.entity.ApiKey;
import et.she.v3.errors.SheException;
import et.she.v3.repository.ApiKeyRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.SecureRandom;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * API key service for B2B tenants (B2B-1000 + B2B-UNLIMITED only).
 *
 * V3-B2B-WHITELABEL §5.
 * Key format: she_live_ + alphanumeric (e.g. she_live_8a3b1c2e...)
 * Scopes: devices:read, devices:write, energy:read, users:read
 * Rate limit: 1,000 req/min default
 *
 * Security: key_hash = SHA-256(secret). Key shown ONCE on create.
 */
@Service
@Transactional
public class ApiKeyService {

    private static final Logger log = LoggerFactory.getLogger(ApiKeyService.class);
    private static final String KEY_PREFIX = "she_live_";
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final String CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    private final ApiKeyRepository apiKeyRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public ApiKeyService(ApiKeyRepository apiKeyRepository,
                         TenantContextInterceptor tenantContextInterceptor) {
        this.apiKeyRepository = apiKeyRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    public CreateApiKeyResponse createApiKey(CreateApiKeyRequest req) {
        AuthenticatedUser user = currentUser();

        // Generate secret key: she_live_ + 32 random alphanumeric chars
        StringBuilder secret = new StringBuilder(KEY_PREFIX);
        for (int i = 0; i < 32; i++) {
            secret.append(CHARS.charAt(RANDOM.nextInt(CHARS.length())));
        }
        String fullKey = secret.toString();

        // Compute SHA-256 hash
        String keyHash = sha256Hex(fullKey);
        String keyPrefix = fullKey.substring(0, 16);   // "she_live_8a3b1c2e"

        ApiKey apiKey = new ApiKey();
        apiKey.setTenantId(user.tenantId());
        apiKey.setName(req.name());
        apiKey.setKeyHash(keyHash);
        apiKey.setKeyPrefix(keyPrefix);
        apiKey.setScopes(req.scopes() != null ? req.scopes() : List.of("devices:read"));
        apiKey.setExpiresAt(req.expires_at() != null ? Instant.parse(req.expires_at()) : null);
        apiKey.setCreatedByUserId(user.userId());
        apiKey = apiKeyRepository.save(apiKey);

        log.info("API key created: name={} prefix={} tenant={}", req.name(), keyPrefix, user.tenantId());

        return new CreateApiKeyResponse(
                apiKey.getId(),
                fullKey,   // shown ONCE — caller must save
                keyPrefix,
                apiKey.getScopes(),
                apiKey.getExpiresAt()
        );
    }

    public List<ApiKey> listApiKeys() {
        AuthenticatedUser user = currentUser();
        return apiKeyRepository.findAllByTenantId(user.tenantId());
    }

    public void revokeApiKey(UUID keyId) {
        AuthenticatedUser user = currentUser();
        ApiKey key = apiKeyRepository.findById(keyId)
                .orElseThrow(() -> new SheException("API_KEY_NOT_FOUND", "API key not found", 404));
        if (!key.getTenantId().equals(user.tenantId())) {
            throw new SheException("RBAC_FORBIDDEN", "Cannot revoke key from another tenant", 403);
        }
        key.setRevokedAt(Instant.now());
        key.setRevokedByUserId(user.userId());
        apiKeyRepository.save(key);
        log.info("API key revoked: id={} tenant={}", keyId, user.tenantId());
    }

    /**
     * Validate an API key from an incoming request.
     * Returns the ApiKey entity if valid, null if invalid/expired/revoked.
     */
    public ApiKey validateApiKey(String rawKey) {
        if (rawKey == null || !rawKey.startsWith(KEY_PREFIX)) return null;
        String hash = sha256Hex(rawKey);
        return apiKeyRepository.findByKeyHashAndNotRevoked(hash)
                .filter(k -> k.getExpiresAt() == null || k.getExpiresAt().isAfter(Instant.now()))
                .orElse(null);
    }

    private String sha256Hex(String input) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(input.getBytes());
            StringBuilder sb = new StringBuilder();
            for (byte b : hash) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException("SHA-256 failed", e);
        }
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }

    // DTOs
    public record CreateApiKeyRequest(
            String name,
            List<String> scopes,        // ["devices:read", "energy:read"]
            String expires_at           // ISO-8601, optional
    ) {}

    public record CreateApiKeyResponse(
            UUID id,
            String api_key,             // full key — shown ONCE
            String key_prefix,
            List<String> scopes,
            Instant expires_at
    ) {}
}
