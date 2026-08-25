package et.she.v3.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.springframework.boot.autoconfigure.jackson.Jackson2ObjectMapperBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Ensures {@code java.time.Instant} fields on DTOs and entities serialize as
 * ISO-8601 strings (e.g. {@code "2024-12-01T14:23:45Z"}) rather than numeric
 * timestamps.
 *
 * <p>This is a defensive configuration — Spring Boot's JacksonAutoConfiguration
 * should already do this when {@code spring.jackson.serialization.write-dates-as-timestamps=false}
 * is set in application.yml (which it is). This customizer acts as a backstop
 * in case the property is overridden or a profile disables it.</p>
 *
 * <p>Reference: V3-API-SPECIFICATION §1 — timestamps are ISO-8601 UTC.</p>
 */
@Configuration
public class JacksonConfig {

    @Bean
    public Jackson2ObjectMapperBuilderCustomizer sheJacksonCustomizer() {
        return builder -> builder
                .modulesToInstall(new JavaTimeModule())
                .featuresToDisable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    }
}
