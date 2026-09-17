package et.she.v3.controller;

import et.she.v3.tenant.ApiKeyService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * API key management for B2B tenants (B2B-1000 + B2B-UNLIMITED only).
 * V3-B2B-WHITELABEL §5.
 *
 *   POST   /api/v3/tenant/api-keys       — create key (returns full key ONCE)
 *   GET    /api/v3/tenant/api-keys       — list keys (prefix only, no secret)
 *   DELETE /api/v3/tenant/api-keys/{id}  — revoke key
 */
@RestController
@RequestMapping("/api/v3/tenant/api-keys")
public class ApiKeyController {

    private final ApiKeyService apiKeyService;

    public ApiKeyController(ApiKeyService apiKeyService) {
        this.apiKeyService = apiKeyService;
    }

    @PostMapping
    public ResponseEntity<Map<String, Object>> create(@Valid @RequestBody ApiKeyService.CreateApiKeyRequest req) {
        var resp = apiKeyService.createApiKey(req);
        return ResponseEntity.status(201).body(Map.of("data", resp));
    }

    @GetMapping
    public ResponseEntity<Map<String, Object>> list() {
        var keys = apiKeyService.listApiKeys();
        // Return only safe fields (key_hash, key_prefix — never the full key)
        var safe = keys.stream().map(k -> Map.of(
                "id", k.getId(),
                "name", k.getName(),
                "key_prefix", k.getKeyPrefix(),
                "scopes", k.getScopes(),
                "expires_at", k.getExpiresAt(),
                "last_used_at", k.getLastUsedAt(),
                "created_at", k.getCreatedAt()
        )).toList();
        return ResponseEntity.ok(Map.of("data", safe));
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> revoke(@PathVariable UUID id) {
        apiKeyService.revokeApiKey(id);
        return ResponseEntity.noContent().build();
    }
}
