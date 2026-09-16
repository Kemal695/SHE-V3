package et.she.v3.websocket;

import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.JwtService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.WebSocketHandler;
import org.springframework.web.socket.server.HandshakeInterceptor;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * WebSocket handshake interceptor — authenticates via Sec-WebSocket-Protocol header.
 *
 * V3-API-SPECIFICATION §14.2 + P1-4:
 *   Sec-WebSocket-Protocol: bearer.<jwt>
 *
 * NOT ?token= query param (leaks in logs).
 */
@Component
public class WsAuthInterceptor implements HandshakeInterceptor {

    private static final Logger log = LoggerFactory.getLogger(WsAuthInterceptor.class);

    private final JwtService jwtService;

    public WsAuthInterceptor(JwtService jwtService) {
        this.jwtService = jwtService;
    }

    @Override
    public boolean beforeHandshake(ServerHttpRequest request, ServerHttpResponse response,
                                   WebSocketHandler wsHandler, Map<String, Object> attributes) {
        List<String> subprotocols = request.getHeaders().get("Sec-WebSocket-Protocol");
        if (subprotocols == null || subprotocols.isEmpty()) {
            log.warn("WS handshake rejected: no Sec-WebSocket-Protocol header");
            return false;
        }

        // The servlet layer hands us the raw header value, NOT a pre-split list: a
        // client offering "bearer, bearer.<jwt>" arrives as the single element
        // "bearer, bearer.<jwt>", so startsWith("bearer.") is false and the handshake
        // is rejected with a bare 200. Split on commas ourselves.
        List<String> offered = new ArrayList<>();
        for (String value : subprotocols) {
            for (String part : value.split(",")) {
                String trimmed = part.trim();
                if (!trimmed.isEmpty()) {
                    offered.add(trimmed);
                }
            }
        }

        String token = null;
        for (String proto : offered) {
            if (proto.startsWith("bearer.")) {
                token = proto.substring("bearer.".length()).trim();
                break;
            }
        }
        if (token == null) {
            log.warn("WS handshake rejected: no bearer. subprotocol (offered: {})", offered);
            return false;
        }

        try {
            Map<String, Object> claims = jwtService.decode(token);
            AuthenticatedUser user = new AuthenticatedUser(
                    UUID.fromString((String) claims.get("sub")),
                    (String) claims.get("email"),
                    (String) claims.get("platform_role"),
                    claims.get("tenant_id") != null ? UUID.fromString((String) claims.get("tenant_id")) : null,
                    (String) claims.get("tenant_role"),
                    (Map<String, String>) claims.getOrDefault("home_roles", Map.of()),
                    (String) claims.get("jti")
            );
            attributes.put("user", user);

            // RFC 6455 §4.1: the server's chosen subprotocol MUST be one the client
            // offered, or the client is required to fail the connection — dart:io does
            // exactly that, closing with 1002. Echoing a bare "bearer" when the client
            // only offered "bearer.<jwt>" therefore killed every socket the instant it
            // opened, and the app silently received no live updates.
            //
            // So: prefer the non-secret "bearer" (keeps the H13 fix — no JWT echoed into
            // response headers), but only when the client actually offered it; otherwise
            // fall back to echoing the exact protocol that carried the token.
            String selected = offered.contains("bearer")
                    ? "bearer"
                    : offered.stream().filter(p -> p.startsWith("bearer.")).findFirst().orElse("bearer");
            response.getHeaders().set("Sec-WebSocket-Protocol", selected);
            return true;
        } catch (Exception e) {
            log.warn("WS handshake rejected: JWT verification failed: {}", e.getMessage());
            return false;
        }
    }

    @Override
    public void afterHandshake(ServerHttpRequest request, ServerHttpResponse response,
                               WebSocketHandler wsHandler, Exception exception) {
        // No-op
    }
}
