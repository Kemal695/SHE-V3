package et.she.v3.websocket;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

/**
 * WebSocket configuration — registers /ws/v3 endpoint.
 * V3-API-SPECIFICATION §14.
 */
@Configuration
@EnableWebSocket
public class WebSocketConfig implements WebSocketConfigurer {

    private final WsEventBus wsEventBus;
    private final WsAuthInterceptor wsAuthInterceptor;

    public WebSocketConfig(WsEventBus wsEventBus, WsAuthInterceptor wsAuthInterceptor) {
        this.wsEventBus = wsEventBus;
        this.wsAuthInterceptor = wsAuthInterceptor;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(wsEventBus, "/ws/v3")
                .addInterceptors(wsAuthInterceptor)
                .setAllowedOrigins("*");    // CORS handled at gateway (Cloudflare + Nginx)
    }
}
