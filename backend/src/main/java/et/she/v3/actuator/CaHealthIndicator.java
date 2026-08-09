package et.she.v3.actuator;

import et.she.v3.ca.StepCaClient;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

/**
 * Custom health indicator for step-ca.
 *
 * Adds a `ca` component to /actuator/health:
 *   {"status":"UP","components":{"ca":{"status":"UP", "details":{...}}, ...}}
 *
 * V3-OPS-RUNBOOK §3.3 — actuator endpoints.
 */
@Component("ca")
public class CaHealthIndicator implements HealthIndicator {

    private final StepCaClient stepCaClient;

    public CaHealthIndicator(StepCaClient stepCaClient) {
        this.stepCaClient = stepCaClient;
    }

    @Override
    public Health health() {
        if (stepCaClient.isHealthy()) {
            return Health.up().withDetail("provider", "step-ca").build();
        }
        return Health.down().withDetail("provider", "step-ca").withDetail("error", "unreachable").build();
    }
}
