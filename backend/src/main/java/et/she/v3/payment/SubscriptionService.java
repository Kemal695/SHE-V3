package et.she.v3.payment;

import et.she.v3.entity.Subscription;
import et.she.v3.errors.SheException;
import et.she.v3.repository.SubscriptionRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.TenantContextInterceptor;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

/**
 * Subscription service — check status, activate, suspend, cancel.
 *
 * V3-PAYMENTS §4. Subscription status: ACTIVE | CANCELLED | EXPIRED | SUSPENDED | TRIALING.
 *
 * Suspension flow (V3-PAYMENTS §5):
 *   Payment PENDING → Day 7: SUSPENDED (users can't login, devices still work)
 *   Day 30: EXPIRED (B2C) / TERMINATED (B2B)
 */
@Service
@Transactional
public class SubscriptionService {

    private final SubscriptionRepository subscriptionRepository;
    private final TenantContextInterceptor tenantContextInterceptor;

    public SubscriptionService(SubscriptionRepository subscriptionRepository,
                               TenantContextInterceptor tenantContextInterceptor) {
        this.subscriptionRepository = subscriptionRepository;
        this.tenantContextInterceptor = tenantContextInterceptor;
    }

    /**
     * GET /api/v3/subscriptions/current — current subscription for the authenticated user's tenant.
     */
    public CurrentSubscriptionResponse getCurrentSubscription() {
        AuthenticatedUser user = currentUser();
        if (user.tenantId() == null) {
            // B2C default — return FREE plan
            return new CurrentSubscriptionResponse(null, "B2C_FREE", "ACTIVE", null, null, true);
        }

        Optional<Subscription> sub = subscriptionRepository.findByTenantIdAndStatus(user.tenantId(), "ACTIVE");
        if (sub.isEmpty()) {
            // No active subscription — default to FREE
            return new CurrentSubscriptionResponse(null, "B2C_FREE", "ACTIVE", null, null, true);
        }

        Subscription s = sub.get();
        boolean isPremium = !"B2C_FREE".equals(s.getPlan());
        boolean isExpired = s.getExpiresAt() != null && s.getExpiresAt().isBefore(Instant.now());

        return new CurrentSubscriptionResponse(
                s.getId(),
                s.getPlan(),
                isExpired ? "EXPIRED" : s.getStatus(),
                s.getStartedAt(),
                s.getExpiresAt(),
                isPremium && !isExpired
        );
    }

    /**
     * Check if a tenant has an active premium subscription.
     * Used by feature gates (automations, OTA, energy — all Premium features).
     */
    public boolean isPremium(UUID tenantId) {
        if (tenantId == null) return false;
        return subscriptionRepository.findByTenantIdAndStatus(tenantId, "ACTIVE")
                .map(s -> !"B2C_FREE".equals(s.getPlan()) &&
                          (s.getExpiresAt() == null || s.getExpiresAt().isAfter(Instant.now())))
                .orElse(false);
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }

    // DTO
    public record CurrentSubscriptionResponse(
            UUID subscription_id,
            String plan,
            String status,
            Instant started_at,
            Instant expires_at,
            boolean is_premium
    ) {}
}
