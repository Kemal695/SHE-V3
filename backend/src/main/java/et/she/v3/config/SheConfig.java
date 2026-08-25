package et.she.v3.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

/**
 * Bind {@link SheProperties} and provide shared beans.
 */
@Configuration
@EnableConfigurationProperties(SheProperties.class)
public class SheConfig {
}
