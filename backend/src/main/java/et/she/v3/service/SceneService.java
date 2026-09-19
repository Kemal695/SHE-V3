package et.she.v3.service;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.dto.NodeDtos;
import et.she.v3.entity.NodeDevice;
import et.she.v3.entity.Scene;
import et.she.v3.entity.SceneAction;
import et.she.v3.errors.SheException;
import et.she.v3.repository.NodeDeviceRepository;
import et.she.v3.repository.SceneActionRepository;
import et.she.v3.repository.SceneRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.*;

/**
 * Scene service — CRUD + one-shot activation.
 *
 * V3-API-SPECIFICATION §8.1. V3-DATABASE-DESIGN §4.7. Migration V10.
 *
 * Activation deliberately REUSES {@link NodeService#writeParams} rather than
 * publishing MQTT directly: that path already resolves the node → topic,
 * updates the desired-state cache, and writes the privileged
 * "node.param.write" audit row (P1-19). Duplicating it here would silently
 * lose auditing and could drift from the command path.
 *
 * Concurrency note: the spec describes fanning publishes out in parallel, but
 * RLS (P0-5) is enforced through the transaction-scoped
 * app.tenant_id GUC — work on other threads would not see it and reads would
 * be filtered. So actions are grouped per device and executed sequentially;
 * each device still gets ONE publish containing all of its params, which is
 * the part that actually matters for latency.
 */
@Service
public class SceneService {

    private static final Logger log = LoggerFactory.getLogger(SceneService.class);

    private final SceneRepository sceneRepository;
    private final SceneActionRepository sceneActionRepository;
    private final NodeDeviceRepository nodeDeviceRepository;
    private final NodeService nodeService;
    private final ObjectMapper objectMapper;

    public SceneService(SceneRepository sceneRepository,
                        SceneActionRepository sceneActionRepository,
                        NodeDeviceRepository nodeDeviceRepository,
                        NodeService nodeService,
                        ObjectMapper objectMapper) {
        this.sceneRepository = sceneRepository;
        this.sceneActionRepository = sceneActionRepository;
        this.nodeDeviceRepository = nodeDeviceRepository;
        this.nodeService = nodeService;
        this.objectMapper = objectMapper;
    }

    // ─── DTOs ────────────────────────────────────────────────────────────────
    /**
     * One WRITE_PARAM action. Field names are snake_case on the wire (the API
     * spec is snake_case) but the project's Jackson naming strategy is camelCase,
     * so each field needs an explicit @JsonProperty or it silently binds null.
     */
    public record SceneActionIn(
            @JsonProperty("node_id") UUID nodeId,
            @JsonProperty("device_name") String deviceName,
            Map<String, Object> params
    ) {}
    public record CreateSceneRequest(String name, String icon, List<SceneActionIn> actions) {}
    public record UpdateSceneRequest(String name, String icon, List<SceneActionIn> actions) {}
    public record SceneActionOut(UUID nodeDeviceId, String paramName, Object value) {}
    public record SceneOut(UUID id, UUID homeId, String name, String icon, Integer sortOrder,
                           List<SceneActionOut> actions, Instant createdAt) {}
    public record FailedAction(UUID nodeId, String deviceName, String reason) {}
    public record ActivationResult(UUID executionId, int acceptedCount, List<FailedAction> failed) {}

    // ─── Queries ─────────────────────────────────────────────────────────────
    @Transactional(readOnly = true)
    public List<SceneOut> list(UUID homeId) {
        return sceneRepository.findAllByHomeId(homeId).stream()
                .map(this::toOut)
                .toList();
    }

    @Transactional(readOnly = true)
    public SceneOut get(UUID id) {
        return toOut(requireScene(id));
    }

    // ─── Mutations ───────────────────────────────────────────────────────────
    @Transactional
    public SceneOut create(UUID homeId, CreateSceneRequest req) {
        if (req.name() == null || req.name().isBlank()) {
            throw new SheException("VALIDATION_ERROR", "Scene name is required", 422);
        }
        Scene scene = new Scene();
        scene.setTenantId(currentTenantId());
        scene.setHomeId(homeId);
        scene.setName(req.name().trim());
        scene.setIcon(req.icon());
        scene.setSortOrder(0);
        scene = sceneRepository.save(scene);
        replaceActions(scene, req.actions());
        return toOut(scene);
    }

    @Transactional
    public SceneOut update(UUID id, UpdateSceneRequest req) {
        Scene scene = requireScene(id);
        if (req.name() != null && !req.name().isBlank()) scene.setName(req.name().trim());
        if (req.icon() != null) scene.setIcon(req.icon());
        if (req.actions() != null) replaceActions(scene, req.actions());
        return toOut(sceneRepository.save(scene));
    }

    @Transactional
    public void delete(UUID id) {
        Scene scene = requireScene(id);
        scene.setDeletedAt(Instant.now());
        sceneRepository.save(scene);
    }

    /**
     * Fan the scene's writes out to the devices. One publish per device,
     * containing all of that device's params. Never throws for a single device
     * failure — the result reports per-device outcomes so one offline device
     * doesn't abort the rest of the scene.
     */
    @Transactional
    public ActivationResult activate(UUID id) {
        Scene scene = requireScene(id);
        List<SceneAction> actions = sceneActionRepository.findAllBySceneId(scene.getId());
        if (actions.isEmpty()) {
            return new ActivationResult(UUID.randomUUID(), 0, List.of());
        }

        // Group by (node, device) so each device gets a single write.
        Map<String, List<SceneAction>> byDevice = new LinkedHashMap<>();
        for (SceneAction a : actions) {
            if (a.getNodeId() == null || a.getNodeDeviceId() == null) {
                log.warn("Scene {} has an action with no node/device — skipping", id);
                continue;
            }
            byDevice.computeIfAbsent(a.getNodeId() + "|" + a.getNodeDeviceId(), k -> new ArrayList<>()).add(a);
        }

        int accepted = 0;
        List<FailedAction> failed = new ArrayList<>();

        for (List<SceneAction> group : byDevice.values()) {
            SceneAction head = group.get(0);
            Map<String, Object> params = new LinkedHashMap<>();
            for (SceneAction a : group) params.put(a.getParamName(), toPlain(a.getValue()));

            try {
                NodeDtos.WriteParamsResponse res = nodeService.writeParams(
                        head.getNodeId(),
                        head.getNodeDeviceId(),
                        new NodeDtos.WriteParamsRequest(params));
                if (res != null && res.accepted()) accepted++;
                else failed.add(new FailedAction(head.getNodeId(), deviceName(head), "Device did not accept the write"));
            } catch (Exception e) {
                log.warn("Scene {} activation failed for device {}: {}", id, head.getNodeDeviceId(), e.getMessage());
                failed.add(new FailedAction(head.getNodeId(), deviceName(head), e.getMessage()));
            }
        }

        return new ActivationResult(UUID.randomUUID(), accepted, failed);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────
    private void replaceActions(Scene scene, List<SceneActionIn> incoming) {
        sceneActionRepository.deleteAll(sceneActionRepository.findAllBySceneId(scene.getId()));
        if (incoming == null || incoming.isEmpty()) return;

        int order = 0;
        for (SceneActionIn in : incoming) {
            if (in.nodeId() == null) {
                throw new SheException("VALIDATION_ERROR", "Scene action requires node_id", 422);
            }
            UUID deviceId = resolveDeviceId(in);
            if (in.params() == null || in.params().isEmpty()) {
                throw new SheException("VALIDATION_ERROR", "Scene action requires params", 422);
            }
            for (Map.Entry<String, Object> e : in.params().entrySet()) {
                SceneAction a = new SceneAction();
                a.setTenantId(scene.getTenantId());
                a.setSceneId(scene.getId());
                a.setNodeId(in.nodeId());
                a.setNodeDeviceId(deviceId);
                a.setParamName(e.getKey());
                a.setValue(objectMapper.valueToTree(e.getValue()));
                a.setSortOrder(order++);
                sceneActionRepository.save(a);
            }
        }
    }

    /** Resolve the spec's device_name (or a direct node_device_id) to a device UUID. */
    private UUID resolveDeviceId(SceneActionIn in) {
        if (in.deviceName() == null || in.deviceName().isBlank()) {
            throw new SheException("VALIDATION_ERROR", "Scene action requires device_name", 422);
        }
        return nodeDeviceRepository.findByNodeAndName(in.nodeId(), in.deviceName())
                .map(NodeDevice::getId)
                .orElseThrow(() -> new SheException("DEVICE_NOT_FOUND",
                        "Device '" + in.deviceName() + "' not found on node " + in.nodeId(), 404));
    }

    private String deviceName(SceneAction a) {
        return nodeDeviceRepository.findById(a.getNodeDeviceId())
                .map(NodeDevice::getDeviceName).orElse(null);
    }

    private Scene requireScene(UUID id) {
        return sceneRepository.findByIdAndNotDeleted(id)
                .orElseThrow(() -> new SheException("SCENE_NOT_FOUND", "Scene not found", 404));
    }

    private SceneOut toOut(Scene s) {
        List<SceneActionOut> outs = sceneActionRepository.findAllBySceneId(s.getId()).stream()
                .map(a -> new SceneActionOut(a.getNodeDeviceId(), a.getParamName(), toPlain(a.getValue())))
                .toList();
        return new SceneOut(s.getId(), s.getHomeId(), s.getName(), s.getIcon(), s.getSortOrder(), outs, s.getCreatedAt());
    }

    /** JsonNode → plain Java so it can go into the params map and serialize cleanly. */
    private Object toPlain(JsonNode n) {
        if (n == null || n.isNull()) return null;
        if (n.isBoolean()) return n.booleanValue();
        if (n.isInt()) return n.intValue();
        if (n.isLong()) return n.longValue();
        if (n.isNumber()) return n.decimalValue();
        if (n.isTextual()) return n.textValue();
        return n.toString();
    }

    private UUID currentTenantId() {
        Object principal = SecurityContextHolder.getContext().getAuthentication() != null
                ? SecurityContextHolder.getContext().getAuthentication().getPrincipal()
                : null;
        if (principal instanceof et.she.v3.security.AuthenticatedUser u) return u.tenantId();
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }
}
