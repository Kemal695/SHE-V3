package et.she.v3.controller;

import et.she.v3.entity.FeatureFlag;
import et.she.v3.errors.SheException;
import et.she.v3.repository.FeatureFlagRepository;
import et.she.v3.security.AuthenticatedUser;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Admin feature flag endpoints.
 * V3-ADMIN-PLATFORM §4.7.
 *
 *   GET /api/admin/feature-flags          — list all flags for tenant
 *   PUT /api/admin/feature-flags/{flag}  — toggle/update a flag
 *
 * Example flags: voice_enabled, energy_anomaly_alerts, matter_commissioning_v3_1,
 *                family_plan_visible, ota_anti_rollback_enforced
 */
@RestController
@RequestMapping("/api/admin/feature-flags")
public class AdminFeatureFlagController {

    private final FeatureFlagRepository featureFlagRepository;

    public AdminFeatureFlagController(FeatureFlagRepository featureFlagRepository) {
        this.featureFlagRepository = featureFlagRepository;
    }

    @GetMapping
    public ResponseEntity<Map<String, Object>> list() {
        AuthenticatedUser admin = currentUser();
        List<FeatureFlag> flags = featureFlagRepository.findAllByTenantId(admin.tenantId());
        var data = flags.stream()
                .map(f -> Map.of(
                        "id", f.getId(),
                        "flag_key", f.getFlagKey(),
                        "enabled", f.isEnabled(),
                        "rollout_percent", f.getRolloutPercent(),
                        "config", f.getConfig() != null ? f.getConfig() : Map.of(),
                        "updated_at", f.getUpdatedAt().toString()
                ))
                .toList();
        return ResponseEntity.ok(Map.of("data", data));
    }

    public record UpdateFlagRequest(
            Boolean enabled,
            Short rollout_percent,
            Map<String, Object> config
    ) {}

    @PutMapping("/{flagKey}")
    public ResponseEntity<Map<String, Object>> updateFlag(
            @PathVariable String flagKey,
            @RequestBody UpdateFlagRequest req) {

        AuthenticatedUser admin = currentUser();
        FeatureFlag flag = featureFlagRepository.findByTenantAndKey(admin.tenantId(), flagKey)
                .orElseGet(() -> {
                    FeatureFlag f = new FeatureFlag();
                    f.setTenantId(admin.tenantId());
                    f.setFlagKey(flagKey);
                    return f;
                });

        if (req.enabled() != null) flag.setEnabled(req.enabled());
        if (req.rollout_percent() != null) {
            if (req.rollout_percent() < 0 || req.rollout_percent() > 100) {
                throw new SheException("VALIDATION_FAILED", "rollout_percent must be 0-100", 400);
            }
            flag.setRolloutPercent(req.rollout_percent());
        }
        if (req.config() != null) flag.setConfig(req.config());
        flag.setUpdatedByUserId(admin.userId());

        featureFlagRepository.save(flag);

        return ResponseEntity.ok(Map.of("data", Map.of(
                "flag_key", flag.getFlagKey(),
                "enabled", flag.isEnabled(),
                "rollout_percent", flag.getRolloutPercent(),
                "updated_at", flag.getUpdatedAt().toString()
        )));
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
