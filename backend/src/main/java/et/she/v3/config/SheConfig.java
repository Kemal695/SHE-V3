package et.she.v3.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Bind {@link SheProperties} and provide shared beans.
 */
@Configuration
@EnableConfigurationProperties(SheProperties.class)
public class SheConfig {

    /**
     * Reusable ObjectMapper for internal use (separate from Spring's default
     * to allow custom module registration without affecting MVC).
     */
    @Bean("sheInternalObjectMapper")
    public ObjectMapper sheInternalObjectMapper() {
        return new ObjectMapper();
    }
}
