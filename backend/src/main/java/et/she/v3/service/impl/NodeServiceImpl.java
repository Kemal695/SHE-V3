package et.she.v3.service.impl;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.config.SheProperties;
import et.she.v3.dto.NodeDtos;
import et.she.v3.entity.*;
import et.she.v3.errors.SheException;
import et.she.v3.audit.AuditService;
import et.she.v3.mqtt.MqttPublishService;
import et.she.v3.repository.*;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.security.JwtService;
import et.she.v3.security.TenantContextInterceptor;
import et.she.v3.service.NodeService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.*;

@Service
@Transactional
public class NodeServiceImpl implements NodeService {

    private static final Logger log = LoggerFactory.getLogger(NodeServiceImpl.class);
    /** Per-node monotonic seq for params/remote replay protection (H15 fix). */
    private static final java.util.concurrent.ConcurrentHashMap<UUID, java.util.concurrent.atomic.AtomicLong> SEQ_BY_NODE =
            new java.util.concurrent.ConcurrentHashMap<>();

    private final NodeRepository nodeRepository;
    private final NodeDeviceRepository nodeDeviceRepository;
    private final NodeParamRepository nodeParamRepository;
    private final DeviceCertRepository deviceCertRepository;
    private final HomeRepository homeRepository;
    private final HomeMemberRepository homeMemberRepository;
    private final JdbcTemplate jdbcTemplate;
    private final ObjectMapper objectMapper;
    private final MqttPublishService mqttPublishService;
    private final TenantContextInterceptor tenantContextInterceptor;
    private final JwtService jwtService;
    private final SheProperties props;
    private final AuditService auditService;

    public NodeServiceImpl(NodeRepository nodeRepository,
                           NodeDeviceRepository nodeDeviceRepository,
                           NodeParamRepository nodeParamRepository,
                           DeviceCertRepository deviceCertRepository,
                           HomeRepository homeRepository,
                           HomeMemberRepository homeMemberRepository,
                           JdbcTemplate jdbcTemplate,
                           ObjectMapper objectMapper,
                           MqttPublishService mqttPublishService,
                           TenantContextInterceptor tenantContextInterceptor,
                           JwtService jwtService,
                           SheProperties props,
                           AuditService auditService) {
        this.nodeRepository = nodeRepository;
        this.nodeDeviceRepository = nodeDeviceRepository;
        this.nodeParamRepository = nodeParamRepository;
        this.deviceCertRepository = deviceCertRepository;
        this.homeRepository = homeRepository;
        this.homeMemberRepository = homeMemberRepository;
        this.jdbcTemplate = jdbcTemplate;
        this.objectMapper = objectMapper;
        this.mqttPublishService = mqttPublishService;
        this.tenantContextInterceptor = tenantContextInterceptor;
        this.jwtService = jwtService;
        this.props = props;
        this.auditService = auditService;
    }

    // =========================================================================
    // POST /api/v3/nodes/claim
    // =========================================================================

    @Override
    public NodeDtos.ClaimResponse claim(NodeDtos.ClaimRequest req) {
        AuthenticatedUser user = currentUser();

        // Normalize MAC: strip colons, lowercase
        String normalizedMac = req.mac().toLowerCase().replaceAll("[:\\-]", "");
        if (!normalizedMac.matches("^[0-9a-f]{12}$")) {
            throw new SheException("VALIDATION_FAILED", "Invalid MAC format", 400);
        }
        String macAddress = normalizedMac.replaceAll("(.{2})", "$1:").replaceAll(":$", "").toUpperCase();

        // Verify claim_token: 10-min TTL JWT from POST /api/v3/auth/claim-token.
        // decode() validates EdDSA signature + exp + iss + aud (throws 401).
        if (req.claim_token() == null || req.claim_token().isBlank()) {
            throw new SheException("VALIDATION_FAILED", "claim_token required", 400);
        }
        Map<String, Object> claimClaims = jwtService.decode(req.claim_token());
        if (!"claim".equals(claimClaims.get("type"))) {
            throw new SheException("AUTH_TOKEN_INVALID", "Not a claim token (type must be 'claim')", 401);
        }
        Object tokenTenant = claimClaims.get("tenant_id");
        if (tokenTenant == null || !user.tenantId().toString().equals(tokenTenant.toString())) {
            throw new SheException("RBAC_INSUFFICIENT_ROLE",
                    "Claim token was issued for a different tenant", 403);
        }

        // Resolve the home: default to the user's most recent active home when home_id is
        // omitted (mobile app's provisioning flow claims without one). Without this the
        // node gets home_id=null and never appears in the dashboard (which lists by home).
        UUID homeId = req.home_id();
        if (homeId == null) {
            homeId = homeMemberRepository.findActiveByUserId(user.userId()).stream()
                    .sorted(Comparator.comparing(HomeMember::getGrantedAt).reversed())
                    .map(HomeMember::getHomeId)
                    .findFirst()
                    .orElseThrow(() -> new SheException("VALIDATION_FAILED",
                            "No home found — create a home before claiming a device", 400));
        }

        // Look up the node by normalized_mac (should exist from factory registration)
        // RLS: this is a cross-tenant lookup (node is unclaimed) — set platform_admin=on
        tenantContextInterceptor.setRlsGucs(UUID.fromString("00000000-0000-0000-0000-000000000000"), true);

        Optional<Node> nodeOpt = nodeRepository.findByNormalizedMac(normalizedMac);
        Node node;
        if (nodeOpt.isPresent()) {
            node = nodeOpt.get();
            if (node.getTenantId() != null && !node.getTenantId().equals(user.tenantId())) {
                throw new SheException("CONFLICT_DEVICE_MAC_TAKEN",
                        "Device already claimed by another tenant", 409);
            }
            // Claim it
            node.setTenantId(user.tenantId());
            node.setHomeId(homeId);
            node.setProvisionedAt(Instant.now());
            nodeRepository.save(node);
            log.info("Node claimed: nodeId={} tenant={} user={}", node.getNodeId(), user.tenantId(), user.email());
        } else {
            // Node not pre-registered via factory — create it (dev flow).
            // In production, this should not happen; factory register-cert must run first.
            node = new Node();
            node.setTenantId(user.tenantId());
            node.setHomeId(homeId);
            node.setNodeId("SHE-" + req.sku().substring(4) + "-" + normalizedMac.substring(6).toUpperCase());
            node.setMacAddress(macAddress);
            node.setNormalizedMac(normalizedMac);
            node.setSku(req.sku());
            node.setName(node.getNodeId());
            node.setProvisionedAt(Instant.now());
            node = nodeRepository.save(node);
            log.info("Node created+claimed (dev flow): nodeId={} tenant={}", node.getNodeId(), user.tenantId());
        }

        // If config payload is provided, upsert node_devices + node_params (same as MQTT config handler)
        if (req.config() != null && !req.config().isEmpty()) {
            upsertConfigFromClaim(node, req.config());
        }

        // Build the node_id (SHE naming): SHE-{model}-{last_6_MAC_uppercase}
        String nodeId = node.getNodeId();

        return new NodeDtos.ClaimResponse(
                node.getId(),
                props.mqtt().brokerUrl(),
                nodeId
        );
    }

    @SuppressWarnings("unchecked")
    private void upsertConfigFromClaim(Node node, Map<String, Object> config) {
        try {
            JsonNode root = objectMapper.valueToTree(config);
            // Reuse the same upsert logic as MqttSubscriberService.handleConfigMessage
            // (For brevity, we delegate to a simplified inline version)
            JsonNode devicesNode = root.path("devices");
            for (JsonNode devNode : devicesNode) {
                String deviceName = devNode.path("name").asText();
                String deviceType = devNode.path("type").asText();

                NodeDevice device = nodeDeviceRepository.findByNodeAndName(node.getId(), deviceName)
                        .orElseGet(() -> {
                            NodeDevice d = new NodeDevice();
                            d.setTenantId(node.getTenantId());
                            d.setNodeId(node.getId());
                            d.setDeviceName(deviceName);
                            return d;
                        });
                device.setDeviceType(deviceType);
                nodeDeviceRepository.save(device);

                JsonNode paramsNode = devNode.path("params");
                for (JsonNode paramNode : paramsNode) {
                    String paramName = paramNode.path("name").asText();
                    String paramType = paramNode.path("type").asText();
                    String dataType = paramNode.path("data_type").asText();

                    // node_params.properties is NOT NULL (jsonb) — default to the standard
                    // read/write/persist set so new params don't trip the DB constraint.
                    List<String> properties = List.of("read", "write", "persist");

                    NodeParam param = nodeParamRepository.findByDeviceAndName(device.getId(), paramName)
                            .orElseGet(() -> {
                                NodeParam p = new NodeParam();
                                p.setTenantId(node.getTenantId());
                                p.setNodeId(node.getId());
                                p.setNodeDeviceId(device.getId());
                                p.setParamName(paramName);
                                p.setParamType(paramType);
                                p.setDataType(dataType);
                                p.setProperties(properties);
                                return p;
                            });
                    if (param.getProperties() == null) {
                        param.setProperties(properties);
                    }
                    nodeParamRepository.save(param);
                }
            }
        } catch (Exception e) {
            log.warn("Config upsert from claim failed: {}", e.getMessage());
        }
    }

    // =========================================================================
    // GET /api/v3/homes/{homeId}/nodes
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public List<NodeDtos.NodeResponse> listByHome(UUID homeId) {
        AuthenticatedUser user = currentUser();
        requireHomeMembership(homeId, user, "GUEST");
        List<Node> nodes = nodeRepository.findAllByTenantAndHome(user.tenantId(), homeId);
        return nodes.stream().map(this::toResponse).toList();
    }

    // =========================================================================
    // GET /api/v3/nodes/{id}
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public NodeDtos.NodeResponse getById(UUID id) {
        return toResponse(getAuthorizedNodeOrThrow(id, "GUEST"));
    }

    @Override
    @Transactional(readOnly = true)
    public void requireNodeAccess(UUID nodeId, String minRole) {
        getAuthorizedNodeOrThrow(nodeId, minRole);
    }

    // =========================================================================
    // PATCH /api/v3/nodes/{id}
    // =========================================================================

    @Override
    public NodeDtos.NodeResponse update(UUID id, String name, UUID roomId) {
        Node node = getAuthorizedNodeOrThrow(id, "MEMBER");
        if (name != null && !name.isBlank()) node.setName(name);
        if (roomId != null) node.setRoomId(roomId);
        nodeRepository.save(node);
        return toResponse(node);
    }

    // =========================================================================
    // DELETE /api/v3/nodes/{id}
    // =========================================================================

    @Override
    public void delete(UUID id) {
        Node node = getAuthorizedNodeOrThrow(id, "OWNER");
        node.setDeletedAt(Instant.now());
        nodeRepository.save(node);
        // TODO: revoke cert via step-ca + disconnect from EMQX
        log.info("Node soft-deleted: {}", node.getNodeId());
    }

    // =========================================================================
    // GET /api/v3/nodes/{id}/devices
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public List<NodeDtos.DeviceResponse> listDevices(UUID nodeId) {
        getAuthorizedNodeOrThrow(nodeId, "GUEST");
        return nodeDeviceRepository.findAllByNodeId(nodeId).stream()
                .map(this::toDeviceResponse)
                .toList();
    }

    // =========================================================================
    // GET /api/v3/nodes/{id}/devices/{deviceId}/params
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public List<NodeDtos.ParamResponse> listParams(UUID nodeId, UUID deviceId) {
        getAuthorizedNodeOrThrow(nodeId, "GUEST");
        NodeDevice device = nodeDeviceRepository.findById(deviceId)
                .orElseThrow(() -> new SheException("NODE_DEVICE_NOT_FOUND", "Device " + deviceId + " not found", 404));
        if (!device.getNodeId().equals(nodeId)) {
            throw new SheException("NODE_DEVICE_NOT_FOUND", "Device does not belong to node", 404);
        }
        return nodeParamRepository.findAllByDeviceId(deviceId).stream()
                .map(this::toParamResponse)
                .toList();
    }

    // =========================================================================
    // PUT /api/v3/nodes/{id}/devices/{deviceId}/params
    // =========================================================================

    @Override
    public NodeDtos.WriteParamsResponse writeParams(UUID nodeId, UUID deviceId, NodeDtos.WriteParamsRequest req) {
        Node node = getAuthorizedNodeOrThrow(nodeId, "MEMBER");
        NodeDevice device = nodeDeviceRepository.findById(deviceId)
                .orElseThrow(() -> new SheException("NODE_DEVICE_NOT_FOUND", "Device " + deviceId + " not found", 404));

        if (!device.getNodeId().equals(nodeId)) {
            throw new SheException("NODE_DEVICE_NOT_FOUND", "Device does not belong to node", 404);
        }

        // Update last_value in DB (desired state) + last_commanded_at
        Map<String, NodeDtos.ParamAck> acks = new LinkedHashMap<>();
        // Per-node monotonic seq for params/remote replay protection (H15 fix):
        // strictly increasing within this JVM; seeded from wall-clock so restarts move forward.
        long seq = SEQ_BY_NODE.computeIfAbsent(nodeId,
                        k -> new java.util.concurrent.atomic.AtomicLong(System.currentTimeMillis()))
                .updateAndGet(prev -> Math.max(prev + 1, System.currentTimeMillis()));
        // Accumulate params per device — V3-MQTT-STANDARDS §3.4 payload: {"Relay 1":{"Power":true,"Brightness":75}}
        Map<String, Map<String, Object>> deviceParams = new LinkedHashMap<>();

        for (Map.Entry<String, Object> entry : req.params().entrySet()) {
            String paramName = entry.getKey();
            Object value = entry.getValue();
            if (value == null) {
                throw new SheException("VALIDATION_FAILED", "Param '" + paramName + "' value cannot be null", 400);
            }

            NodeParam param = nodeParamRepository.findByDeviceAndName(deviceId, paramName)
                    .orElseThrow(() -> new SheException("DEVICE_PARAM_UNKNOWN",
                            "Param " + paramName + " not found on device " + device.getDeviceName(), 422));

            // Update DB cache (desired state)
            nodeParamRepository.updateLastValue(param.getId(), value, Instant.now());
            acks.put(paramName, new NodeDtos.ParamAck(value, Instant.now().toString()));
            // Accumulate into device's param map (don't overwrite previous params)
            deviceParams.computeIfAbsent(device.getDeviceName(), k -> new LinkedHashMap<>())
                        .put(paramName, value);
        }

        // Publish to MQTT params/remote — V3-MQTT-STANDARDS §3.4
        // Topic: she/{tenant}/{home}/{room}/{mac}/params/remote
        // For Phase 1 we use the short-form tenant/home IDs (first 8 chars of UUID, base32)
        // In a full implementation, these would be precomputed + cached.
        String tenantShort = shortId(node.getTenantId());
        String homeShort = node.getHomeId() != null ? shortId(node.getHomeId()) : "00000000";
        String roomShort = node.getRoomId() != null ? shortId(node.getRoomId()) : "unassigned";

        try {
            mqttPublishService.publishParamsRemote(
                    tenantShort, homeShort, roomShort,
                    node.getNormalizedMac(),
                    deviceParams,
                    seq
            );
        } catch (Exception e) {
            log.error("MQTT publish failed for node {}: {}", node.getNodeId(), e.getMessage());
            throw new SheException("MQTT_PUBLISH_FAILED", "Failed to publish command to device", 502, e);
        }

        // P1-19: commanding a device is a privileged action — record what was
        // written, not just that a write happened.
        auditService.record(node.getTenantId(), "USER", currentUserIdOrNull(), "node.param.write",
                "node_device", deviceId,
                Map.of("node_id", String.valueOf(nodeId), "params", deviceParams),
                null, null, null);

        return new NodeDtos.WriteParamsResponse(nodeId, deviceId, acks, true);
    }

    // =========================================================================
    // GET /api/v3/nodes/{id}/telemetry
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public NodeDtos.TelemetryResponse getTelemetry(UUID nodeId, Instant from, Instant to, String param, String bucket) {
        getAuthorizedNodeOrThrow(nodeId, "GUEST");
        if (bucket == null || bucket.isBlank()) bucket = "5m";
        if (from == null) from = Instant.now().minusSeconds(86400);   // default: last 24h
        if (to == null) to = Instant.now();

        // Bucketed aggregation via TimescaleDB time_bucket (H14 fix — bucket is honored).
        // Interval literal comes from a whitelist, never from user input.
        String interval = switch (bucket) {
            case "1h" -> "1 hour";
            case "1d" -> "1 day";
            default -> "5 minutes";
        };
        String effectiveBucket = ("1 hour".equals(interval)) ? "1h" : ("1 day".equals(interval) ? "1d" : "5m");

        String sql;
        List<Object> args = new ArrayList<>();
        args.add(nodeId);
        args.add(java.sql.Timestamp.from(from));
        args.add(java.sql.Timestamp.from(to));

        if (param != null && !param.isBlank()) {
            sql = """
                SELECT time_bucket('%s', time) AS bucket, param_name, AVG(value) AS value, MAX(unit) AS unit
                FROM device_telemetry
                WHERE node_id = ? AND time >= ? AND time <= ? AND param_name = ?
                GROUP BY 1, 2 ORDER BY 1 ASC
                LIMIT 10000
                """.formatted(interval);
            args.add(param);
        } else {
            sql = """
                SELECT time_bucket('%s', time) AS bucket, param_name, AVG(value) AS value, MAX(unit) AS unit
                FROM device_telemetry
                WHERE node_id = ? AND time >= ? AND time <= ?
                GROUP BY 1, 2 ORDER BY 1 ASC
                LIMIT 10000
                """.formatted(interval);
        }

        List<Map<String, Object>> rows = jdbcTemplate.queryForList(sql, args.toArray());
        List<NodeDtos.TelemetryPoint> points = rows.stream()
                .map(r -> new NodeDtos.TelemetryPoint(
                        r.get("bucket").toString(),
                        (String) r.get("param_name"),
                        ((Number) r.get("value")).doubleValue(),
                        (String) r.get("unit")
                ))
                .toList();

        return new NodeDtos.TelemetryResponse(nodeId, effectiveBucket, points);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private Node verifyNodeExists(UUID nodeId) {
        return nodeRepository.findActiveById(nodeId)
                .orElseThrow(() -> new SheException("NODE_NOT_FOUND", "Node " + nodeId + " does not exist", 404));
    }

    /**
     * Home-membership authorization for node access (H1/H3 fix).
     * B2C users share the default tenant, so tenant-scoping alone does NOT
     * isolate users — the home membership (OWNER/ADMIN/MEMBER/GUEST) is the
     * real boundary. Unclaimed nodes (home_id=NULL) are invisible to regular
     * users (404 — don't leak existence); platform admins bypass.
     */
    private Node getAuthorizedNodeOrThrow(UUID nodeId, String minRole) {
        AuthenticatedUser user = currentUser();
        Node node = verifyNodeExists(nodeId);
        if (node.getHomeId() == null) {
            if (user.isSuperAdmin() || user.isBypassCapable()) return node;
            throw new SheException("NODE_NOT_FOUND", "Node " + nodeId + " does not exist", 404);
        }
        requireHomeMembership(node.getHomeId(), user, minRole);
        return node;
    }

    private void requireHomeMembership(UUID homeId, AuthenticatedUser user, String minRole) {
        if (user.isSuperAdmin() || user.isBypassCapable()
                || "TENANT_ADMIN".equals(user.tenantRole())) {
            return;
        }
        HomeMember membership = homeMemberRepository.findActiveByHomeAndUser(homeId, user.userId())
                .orElseThrow(() -> new SheException("RBAC_INSUFFICIENT_ROLE",
                        "User is not a member of this home", 403));
        if (minRole != null && roleLevel(membership.getRole()) < roleLevel(minRole)) {
            throw new SheException("RBAC_INSUFFICIENT_ROLE", "Required home role: " + minRole, 403);
        }
    }

    private int roleLevel(String role) {
        return switch (role != null ? role.toUpperCase() : "") {
            case "OWNER" -> 4;
            case "ADMIN" -> 3;
            case "MEMBER" -> 2;
            case "GUEST" -> 1;
            default -> 0;
        };
    }

    private NodeDtos.NodeResponse toResponse(Node n) {
        return new NodeDtos.NodeResponse(
                n.getId(), n.getNodeId(), n.getMacAddress(), n.getNormalizedMac(),
                n.getSku(), n.getName(), n.getFirmwareVersion(), n.getHardwareRevision(),
                n.isOnline(),
                n.getLastSeenAt() != null ? n.getLastSeenAt().toString() : null,
                n.getProvisionedAt() != null ? n.getProvisionedAt().toString() : null,
                n.getHomeId(), n.getRoomId()
        );
    }

    private NodeDtos.DeviceResponse toDeviceResponse(NodeDevice d) {
        return new NodeDtos.DeviceResponse(
                d.getId(), d.getDeviceName(), d.getDeviceType(), d.getDisplayName(),
                d.getChannelIndex(), d.getAttributes(), d.isService()
        );
    }

    private NodeDtos.ParamResponse toParamResponse(NodeParam p) {
        return new NodeDtos.ParamResponse(
                p.getId(), p.getParamName(), p.getParamType(), p.getDataType(),
                p.getUiHint(), p.getProperties(), p.getLastValue(),
                p.getLastReportedAt() != null ? p.getLastReportedAt().toString() : null,
                p.getMinValue(), p.getMaxValue()
        );
    }

    /**
     * Short-form ID for MQTT topic: first 8 chars of UUID (base32-ish, lowercase).
     * V3-MQTT-STANDARDS §2 — tenant_id/home_id/room_id are 8-char short forms.
     */
    private String shortId(UUID id) {
        if (id == null) return "00000000";
        return id.toString().replace("-", "").substring(0, 8);
    }

    private AuthenticatedUser currentUser() {
        var principal = SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        if (!(principal instanceof AuthenticatedUser auth)) {
            throw new SheException("AUTH_TOKEN_INVALID", "Not authenticated", 401);
        }
        return auth;
    }

    /** Audit rows are best-effort: never fail a write because the actor is unknown. */
    private UUID currentUserIdOrNull() {
        try {
            return currentUser().userId();
        } catch (Exception e) {
            return null;
        }
    }
}
