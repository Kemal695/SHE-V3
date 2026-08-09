package et.she.v3;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * SHE V3 — Spring Boot backend entry point.
 *
 * Phase 0 deliverables (V3-ROADMAP §2):
 *   - Health endpoint (/actuator/health)
 *   - Flyway migrations (V1=tenants, V2=users, V3=device_certs)
 *   - Postgres pool (HikariCP, 20 conn/instance per V3-ARCHITECTURE §5.1)
 *   - JWT auth (EdDSA / Ed25519 per P1-6)
 *   - One CRUD endpoint (users)
 *   - Test framework (JUnit 5 + Spring Boot Test + Testcontainers)
 *
 * @see <a href="https://github.com/she-v3/she-v3">she-v3 monorepo</a>
 */
@SpringBootApplication
@ConfigurationPropertiesScan
@EnableScheduling
public class SheBackendApplication {

    public static void main(String[] args) {
        SpringApplication.run(SheBackendApplication.class, args);
    }
}
