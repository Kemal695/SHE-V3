package et.she.v3.websocket;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.JwtService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.time.Instant;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * WebSocket event bus — pushes real-time events to connected Flutter apps.
 *
 * V3-API-SPECIFICATION §14 — WSS /ws/v3.
 * P1-4: auth via Sec-WebSocket-Protocol: bearer.<jwt> subprotocol header.
 *
 * Event types (V3-API-SPECIFICATION §14.3):
 *   - node.state       — per-param update (from MQTT params/local)
 *   - node.telemetry   — diagnostics (RSSI, heap, uptime)
 *   - node.presence    — online/offline (from MQTT LWT)
 *   - energy.update    — real-time power + cost
 *   - ota.progress     — OTA download/flash progress
 *   - scene.activated  — scene execution
 *   - automation.triggered — automation fired
 *   - notification.received — push notification
 *
 * Session management: each session is keyed by user_id + tenant_id.
 * Subscriptions are tracked per session (home_id / node_id scope).
 */
@Component
public class WsEventBus extends TextWebSocketHandler {

    private static final Logger log = LoggerFactory.getLogger(WsEventBus.class);

    private final JwtService jwtService;
    private final ObjectMapper objectMapper;

    /** All active sessions keyed by session ID. */
    private final Map<String, WsSession> sessions = new ConcurrentHashMap<>();

    /** Reverse index: tenant_id → set of session IDs (for fan-out). */
    private final Map<UUID, Set<String>> sessionsByTenant = new ConcurrentHashMap<>();

    public WsEventBus(JwtService jwtService, ObjectMapper objectMapper) {
        this.jwtService = jwtService;
        this.objectMapper = objectMapper;
    }

    // =========================================================================
    // WebSocketHandler
    // =========================================================================

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        AuthenticatedUser user = (AuthenticatedUser) session.getAttributes().get("user");
        if (user == null || user.tenantId() == null) {
            log.warn("WS connect rejected: no authenticated user or null tenant_id in session attributes");
            closeQuietly(session, CloseStatus.POLICY_VIOLATION);
            return;
        }
        WsSession ws = new WsSession(session, user);
        sessions.put(session.getId(), ws);
        sessionsByTenant.computeIfAbsent(user.tenantId(), k -> ConcurrentHashMap.newKeySet())
                .add(session.getId());
        log.info("WS connected: user={} tenant={} sessionId={}", user.email(), user.tenantId(), session.getId());
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) {
        try {
            JsonNode root = objectMapper.readTree(message.getPayload());
            String action = root.path("action").asText();
            WsSession ws = sessions.get(session.getId());
            if (ws == null) return;

            switch (action) {
                case "subscribe" -> {
                    String scope = root.path("scope").asText();
                    String targetId = root.path("home_id").asText(root.path("node_id").asText());
                    if ("home".equals(scope)) {
                        ws.subscribedHomeIds.add(UUID.fromString(targetId));
                    } else if ("node".equals(scope)) {
                        ws.subscribedNodeIds.add(UUID.fromString(targetId));
                    }
                }
                case "unsubscribe" -> {
                    String scope = root.path("scope").asText();
                    String targetId = root.path("home_id").asText(root.path("node_id").asText());
                    if ("home".equals(scope)) {
                        ws.subscribedHomeIds.remove(UUID.fromString(targetId));
                    } else if ("node".equals(scope)) {
                        ws.subscribedNodeIds.remove(UUID.fromString(targetId));
                    }
                }
                case "ping" -> session.sendMessage(new TextMessage("{\"event\":\"pong\"}"));
            }
        } catch (Exception e) {
            log.warn("WS message handling error: {}", e.getMessage());
        }
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        WsSession ws = sessions.remove(session.getId());
        if (ws != null) {
            Set<String> tenantSessions = sessionsByTenant.get(ws.user.tenantId());
            if (tenantSessions != null) {
                tenantSessions.remove(session.getId());
                if (tenantSessions.isEmpty()) {
                    sessionsByTenant.remove(ws.user.tenantId());
                }
            }
        }
        log.info("WS closed: sessionId={} status={}", session.getId(), status);
    }

    // =========================================================================
    // Event publishers (called by MqttSubscriberService + services)
    // =========================================================================

    public void publishNodeState(UUID tenantId, UUID nodeId, UUID deviceId,
                                 String deviceName, String paramName, JsonNode value) {
        broadcast(tenantId, Map.of(
                "event", "node.state",
                "data", Map.of(
                        "nodeId", nodeId,
                        "deviceId", deviceId,
                        "deviceName", deviceName,
                        "paramName", paramName,
                        "value", value,
                        "timestamp", Instant.now().toString()
                )
        ));
    }

    public void publishNodeTelemetry(UUID tenantId, UUID nodeId, JsonNode telemetry) {
        broadcast(tenantId, Map.of(
                "event", "node.telemetry",
                "data", Map.of(
                        "nodeId", nodeId,
                        "telemetry", telemetry,
                        "timestamp", Instant.now().toString()
                )
        ));
    }

    public void publishNodePresence(UUID tenantId, UUID nodeId, boolean isOnline, Instant lastSeenAt) {
        broadcast(tenantId, Map.of(
                "event", "node.presence",
                "data", Map.of(
                        "nodeId", nodeId,
                        "isOnline", isOnline,
                        "lastSeenAt", lastSeenAt != null ? lastSeenAt.toString() : null
                )
        ));
    }

    public void publishEnergyUpdate(UUID tenantId, UUID nodeId, double powerW, double energyWh) {
        broadcast(tenantId, Map.of(
                "event", "energy.update",
                "data", Map.of(
                        "nodeId", nodeId,
                        "powerW", powerW,
                        "energyWh", energyWh,
                        "timestamp", Instant.now().toString()
                )
        ));
    }

    public void publishOtaProgress(UUID tenantId, String normalizedMac, String status, Integer progress, String version) {
        // OTA events broadcast to sessions in the specific tenant (P0-5 / H4 fix)
        Map<String, Object> data = new java.util.LinkedHashMap<>();
        data.put("event", "ota.progress");
        Map<String, Object> payload = new java.util.LinkedHashMap<>();
        payload.put("mac", normalizedMac);
        payload.put("status", status);
        if (progress != null) payload.put("progress", progress);
        if (version != null) payload.put("version", version);
        payload.put("timestamp", Instant.now().toString());
        data.put("data", payload);
        if (tenantId != null) {
            broadcast(tenantId, data);
        } else {
            broadcastToAll(data);
        }
    }

    // =========================================================================
    // Broadcast helpers
    // =========================================================================

    private void broadcast(UUID tenantId, Map<String, Object> event) {
        Set<String> sessionIds = sessionsByTenant.get(tenantId);
        if (sessionIds == null || sessionIds.isEmpty()) return;

        String json;
        try {
            json = objectMapper.writeValueAsString(event);
        } catch (Exception e) {
            log.error("Failed to serialize WS event: {}", e.getMessage());
            return;
        }

        TextMessage msg = new TextMessage(json);
        for (String sessionId : sessionIds) {
            WsSession ws = sessions.get(sessionId);
            if (ws != null && ws.session.isOpen()) {
                try {
                    ws.session.sendMessage(msg);
                } catch (Exception e) {
                    log.debug("WS send failed for session {}: {}", sessionId, e.getMessage());
                }
            }
        }
    }

    private void broadcastToAll(Map<String, Object> event) {
        String json;
        try {
            json = objectMapper.writeValueAsString(event);
        } catch (Exception e) {
            return;
        }
        TextMessage msg = new TextMessage(json);
        for (WsSession ws : sessions.values()) {
            if (ws.session.isOpen()) {
                try {
                    ws.session.sendMessage(msg);
                } catch (Exception ignored) {}
            }
        }
    }

    private void closeQuietly(WebSocketSession session, CloseStatus status) {
        try {
            session.close(status);
        } catch (Exception ignored) {}
    }

    // =========================================================================
    // Session wrapper
    // =========================================================================

    private static class WsSession {
        final WebSocketSession session;
        final AuthenticatedUser user;
        final Set<UUID> subscribedHomeIds = ConcurrentHashMap.newKeySet();
        final Set<UUID> subscribedNodeIds = ConcurrentHashMap.newKeySet();

        WsSession(WebSocketSession session, AuthenticatedUser user) {
            this.session = session;
            this.user = user;
        }
    }
}
