package et.she.v3.service;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import et.she.v3.dto.NodeDtos;
import et.she.v3.entity.Automation;
import et.she.v3.entity.AutomationRule;
import et.she.v3.entity.NodeDevice;
import et.she.v3.errors.SheException;
import et.she.v3.repository.AutomationRepository;
import et.she.v3.repository.AutomationRuleRepository;
import et.she.v3.repository.NodeDeviceRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Duration;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.temporal.ChronoUnit;
import java.util.*;

/**
 * Automation service — CRUD, manual trigger, and action execution.
 *
 * V3-API-SPECIFICATION §7. V3-DATABASE-DESIGN §4.6. Migration V9.
 *
 * Triggers (§7.1): SCHEDULE {cron}, NODE_STATE {node_id, device_name, param_name,
 * comparator, value}, MANUAL.
 * Actions (§7.2): WRITE_PARAM {node_id, device_name, params}, ACTIVATE_SCENE
 * {scene_id}, NOTIFICATION {category, title, body}.
 *
 * As with SceneService, actions are executed SEQUENTIALLY: RLS (P0-5) is enforced
 * through the transaction-scoped app.tenant_id GUC, so work on other threads would
 * not see it.
 */
@Service
public class AutomationService {

    private static final Logger log = LoggerFactory.getLogger(AutomationService.class);

    /**
     * How far back a missed SCHEDULE run may still be caught up after downtime.
     *
     * Bounded deliberately: without a limit, a backend that was down for days
     * would replay every missed run the moment it restarted, hammering devices.
     * 24h covers an overnight outage without a replay storm. (Migration V35.)
     */
    private static final Duration CATCHUP_WINDOW = Duration.ofHours(24);

    private final AutomationRepository automationRepository;
    private final AutomationRuleRepository ruleRepository;
    private final NodeDeviceRepository nodeDeviceRepository;
    private final NodeService nodeService;
    private final SceneService sceneService;
    private final ObjectMapper objectMapper;

    public AutomationService(AutomationRepository automationRepository,
                             AutomationRuleRepository ruleRepository,
                             NodeDeviceRepository nodeDeviceRepository,
                             NodeService nodeService,
                             SceneService sceneService,
                             ObjectMapper objectMapper) {
        this.automationRepository = automationRepository;
        this.ruleRepository = ruleRepository;
        this.nodeDeviceRepository = nodeDeviceRepository;
        this.nodeService = nodeService;
        this.sceneService = sceneService;
        this.objectMapper = objectMapper;
    }

    // ─── DTOs ────────────────────────────────────────────────────────────────
    public record AutomationActionIn(
            @JsonProperty("type") String type,
            @JsonProperty("node_id") UUID nodeId,
            @JsonProperty("device_name") String deviceName,
            Map<String, Object> params,
            @JsonProperty("scene_id") UUID sceneId,
            String category,
            String title,
            String body
    ) {}

    public record CreateAutomationRequest(
            String name,
            String description,
            Boolean enabled,
            Map<String, Object> trigger,
            List<AutomationActionIn> actions
    ) {}

    public record UpdateAutomationRequest(String name, String description, Boolean enabled) {}
    public record SetEnabledRequest(Boolean enabled) {}

    public record AutomationActionOut(String type, Map<String, Object> config) {}
    public record AutomationOut(UUID id, UUID homeId, String name, String description,
                               Boolean enabled, Map<String, Object> trigger,
                               List<AutomationActionOut> actions, Instant createdAt) {}
    public record TriggerResult(UUID automationId, int executed, List<String> failed) {}

    // ─── Queries ─────────────────────────────────────────────────────────────
    @Transactional(readOnly = true)
    public List<AutomationOut> list(UUID homeId) {
        return automationRepository.findAllByHomeId(homeId).stream().map(this::toOut).toList();
    }

    @Transactional(readOnly = true)
    public AutomationOut get(UUID id) {
        return toOut(requireAutomation(id));
    }

    // ─── Mutations ───────────────────────────────────────────────────────────
    @Transactional
    public AutomationOut create(UUID homeId, CreateAutomationRequest req) {
        if (req.name() == null || req.name().isBlank()) {
            throw new SheException("VALIDATION_ERROR", "Automation name is required", 422);
        }
        if (req.trigger() == null || req.trigger().isEmpty()) {
            throw new SheException("VALIDATION_ERROR", "trigger is required", 422);
        }
        validateTrigger(req.trigger());
        Automation a = new Automation();
        a.setTenantId(currentTenantId());
        a.setHomeId(homeId);
        a.setName(req.name().trim());
        a.setDescription(req.description());
        a.setEnabled(req.enabled() == null || req.enabled());
        a.setTriggerConfig(objectMapper.valueToTree(req.trigger()));
        a.setCreatedByUserId(currentUserIdOrNull());
        a = automationRepository.save(a);
        replaceRules(a, req.actions());
        return toOut(a);
    }

    @Transactional
    public AutomationOut update(UUID id, UpdateAutomationRequest req) {
        Automation a = requireAutomation(id);
        if (req.name() != null && !req.name().isBlank()) a.setName(req.name().trim());
        if (req.description() != null) a.setDescription(req.description());
        if (req.enabled() != null) a.setEnabled(req.enabled());
        return toOut(automationRepository.save(a));
    }

    @Transactional
    public AutomationOut setEnabled(UUID id, SetEnabledRequest req) {
        Automation a = requireAutomation(id);
        a.setEnabled(req.enabled() == null || req.enabled());
        return toOut(automationRepository.save(a));
    }

    @Transactional
    public void delete(UUID id) {
        Automation a = requireAutomation(id);
        a.setDeletedAt(Instant.now());
        automationRepository.save(a);
    }

    /**
     * Execute an automation's actions now (MANUAL trigger, or a fired SCHEDULE /
     * NODE_STATE trigger). One failing action does not abort the others.
     */
    @Transactional
    public TriggerResult trigger(UUID id) {
        Automation a = requireAutomation(id);
        return execute(a);
    }

    /**
     * NODE_STATE evaluation: run every enabled automation whose trigger is
     * NODE_STATE and matches this param change. Called from the MQTT ingestion path.
     *
     * IMPORTANT: `oldValue` vs `newValue` means this only fires on a TRANSITION.
     * Devices report their full state periodically (params/local every ~20-60 s), so
     * without this guard an automation like "Relay 1 == true -> X" would re-fire on
     * every report — observed 5 re-fires in 95 s during testing, repeatedly
     * re-commanding the target device.
     */
    @Transactional
    public void evaluateNodeState(UUID nodeId, UUID deviceId, String paramName,
                                 Object oldValue, Object newValue) {
        if (nodeId == null || paramName == null) return;

        // Edge-triggered only: a steady value that still matches must not re-fire.
        if (Objects.equals(normalise(oldValue), normalise(newValue))) return;

        for (Automation a : automationRepository.findAllEnabled()) {
            JsonNode t = a.getTriggerConfig();
            if (t == null || !"NODE_STATE".equalsIgnoreCase(t.path("type").asText())) continue;

            String trigNode = t.path("node_id").asText(null);
            if (trigNode == null || !trigNode.equalsIgnoreCase(String.valueOf(nodeId))) continue;
            if (!paramName.equalsIgnoreCase(t.path("param_name").asText())) continue;

            String deviceName = t.path("device_name").asText(null);
            if (deviceName != null) {
                // Restrict to a specific device on the node.
                UUID trigDevice = nodeDeviceRepository.findByNodeAndName(nodeId, deviceName)
                        .map(NodeDevice::getId).orElse(null);
                if (trigDevice == null || !trigDevice.equals(deviceId)) continue;
            }

            if (!matches(t.path("comparator").asText("=="), newValue, t.path("value"))) continue;

            log.info("Automation {} fired by NODE_STATE {}.{}={}", a.getId(), deviceName, paramName, newValue);
            execute(a);
        }
    }

    /**
     * SCHEDULE evaluation: fire every enabled SCHEDULE automation whose cron
     * matches the CURRENT MINUTE. Called from ScheduledJobs once a minute.
     *
     * Cron matching is essential: without it every schedule-triggered automation
     * would fire on every sweep, hammering devices once a minute.
     */
    @Transactional
    public int runScheduled() {
        int fired = 0;
        Instant now = Instant.now();
        ZoneId zone = ZoneId.systemDefault();
        LocalDateTime nowMinute = LocalDateTime.now(zone).truncatedTo(ChronoUnit.MINUTES);

        for (Automation a : automationRepository.findAllEnabled()) {
            JsonNode t = a.getTriggerConfig();
            if (t == null || !"SCHEDULE".equalsIgnoreCase(t.path("type").asText())) continue;
            String cron = t.path("cron").asText(null);

            // Bounded lookback: start from the last time we actually fired, but
            // never further back than CATCHUP_WINDOW. Without this bound, a
            // multi-day outage would replay a long queue of missed runs and
            // hammer devices on restart.
            Instant earliest = now.minus(CATCHUP_WINDOW);
            Instant lastFired = a.getLastFiredAt();
            Instant windowStart = (lastFired == null || lastFired.isBefore(earliest))
                    ? earliest
                    : lastFired;

            LocalDateTime due = latestFireAtOrBefore(cron,
                    LocalDateTime.ofInstant(windowStart, zone).truncatedTo(ChronoUnit.MINUTES),
                    nowMinute);
            if (due == null) continue; // no scheduled time fell in the window

            // Already fired for this scheduled time (or a later one)? Then the
            // only reason we are here is a restart inside the same minute.
            if (lastFired != null && !lastFired.isBefore(due.atZone(zone).toInstant())) continue;

            boolean isCatchUp = due.isBefore(nowMinute);
            log.info("Automation {} fired by SCHEDULE cron={} due={}{}",
                    a.getId(), cron, due, isCatchUp ? " (catch-up after downtime)" : "");
            execute(a);
            a.setLastFiredAt(now);
            automationRepository.save(a);
            fired++;
        }
        return fired;
    }

    /**
     * The latest time this cron should have fired at, within {@code (from, to]}
     * (both truncated to the minute), or null if it never falls in that window.
     *
     * Spring's {@code next()} is strictly-after, so stepping forward from
     * {@code from} naturally excludes the last-fired instant — which is exactly
     * the dedup we want.
     */
    private LocalDateTime latestFireAtOrBefore(String cron, LocalDateTime from, LocalDateTime to) {
        var parsed = parseCron(cron);
        if (parsed == null) return null;

        LocalDateTime candidate = from;
        LocalDateTime last = null;
        // Bound the walk: cron fields are at most minute-granularity, so a day's
        // window is at most 1440 iterations. Guard against pathological input.
        for (int i = 0; i < 5000; i++) {
            LocalDateTime next = parsed.next(candidate);
            if (next == null || next.isAfter(to)) break;
            last = next;
            candidate = next;
        }
        return last;
    }

    /**
     * Rejects a trigger whose cron can never fire.
     *
     * Without this, a typo is accepted silently and produces an automation that
     * is enabled, looks healthy in the UI, and simply never runs — exactly the
     * bug found on 2026-09-19 (cron "0 609", two fields, unparseable). Failing
     * loudly at save time is far better than a rule that is quietly dead.
     */
    private void validateTrigger(Map<String, Object> trigger) {
        Object type = trigger.get("type");
        if (type == null || !"SCHEDULE".equalsIgnoreCase(String.valueOf(type))) return;

        Object cron = trigger.get("cron");
        if (cron == null || String.valueOf(cron).isBlank()) {
            throw new SheException("VALIDATION_ERROR",
                    "SCHEDULE trigger requires a 'cron' expression, e.g. \"0 6 * * *\" (daily at 06:00)", 422);
        }
        if (parseCron(String.valueOf(cron)) == null) {
            throw new SheException("VALIDATION_ERROR",
                    "Invalid cron '" + cron + "'. Expected 5 fields: minute hour day-of-month month "
                            + "day-of-week — e.g. \"0 6 * * *\" for daily at 06:00", 422);
        }
    }

    /**
     * Parses a 5- or 6-field cron, or null if invalid.
     *
     * The spec (§7.1) uses 5-field Unix cron ("0 6 * * *" = 06:00 daily), but
     * Spring's CronExpression requires 6 fields (it adds seconds), so a 5-field
     * expression is prefixed with "0". Without this, "0 6 * * *" would be read as
     * "second=0, minute=6, hour=*" — i.e. hourly at :06 instead of daily at 06:00.
     */
    private org.springframework.scheduling.support.CronExpression parseCron(String cron) {
        if (cron == null || cron.isBlank()) return null;
        String expr = cron.trim();
        if (expr.split("\\s+").length == 5) expr = "0 " + expr;
        try {
            return org.springframework.scheduling.support.CronExpression.parse(expr);
        } catch (Exception e) {
            log.warn("Automation has an invalid cron '{}': {}", cron, e.getMessage());
            return null;
        }
    }

    // ─── Execution ───────────────────────────────────────────────────────────
    private TriggerResult execute(Automation a) {
        List<AutomationRule> rules = ruleRepository.findAllByAutomationId(a.getId());
        int executed = 0;
        List<String> failed = new ArrayList<>();

        for (AutomationRule r : rules) {
            try {
                switch (r.getActionType()) {
                    case "WRITE_PARAM" -> writeParam(r);
                    case "ACTIVATE_SCENE" -> activateScene(r);
                    case "NOTIFICATION" -> notify(r);
                    default -> log.warn("Automation {} has unknown action_type {}", a.getId(), r.getActionType());
                }
                executed++;
            } catch (Exception e) {
                log.warn("Automation {} action {} failed: {}", a.getId(), r.getActionType(), e.getMessage());
                failed.add(r.getActionType() + ": " + e.getMessage());
            }
        }
        return new TriggerResult(a.getId(), executed, failed);
    }

    private void writeParam(AutomationRule r) {
        JsonNode c = r.getActionConfig();
        UUID nodeId = UUID.fromString(c.path("node_id").asText());
        String deviceName = c.path("device_name").asText(null);
        UUID deviceId = c.hasNonNull("node_device_id")
                ? UUID.fromString(c.path("node_device_id").asText())
                : nodeDeviceRepository.findByNodeAndName(nodeId, deviceName)
                    .map(NodeDevice::getId)
                    .orElseThrow(() -> new SheException("DEVICE_NOT_FOUND",
                            "Device '" + deviceName + "' not found on node " + nodeId, 404));

        Map<String, Object> params = new LinkedHashMap<>();
        c.path("params").fields().forEachRemaining(e -> params.put(e.getKey(), toPlain(e.getValue())));
        if (params.isEmpty()) {
            throw new SheException("VALIDATION_ERROR", "WRITE_PARAM needs params", 422);
        }
        // SYSTEM path: the user-authorising writeParams() NPEs here, because a
        // scheduled automation has no Authentication. This variant keeps the MQTT
        // publish, desired-state update and audit, but records the actor as SYSTEM.
        nodeService.writeParamsSystem(nodeId, deviceId, params);
    }

    private void activateScene(AutomationRule r) {
        UUID sceneId = UUID.fromString(r.getActionConfig().path("scene_id").asText());
        sceneService.activate(sceneId);
    }

    /**
     * NOTIFICATION is not wired to a delivery channel yet — record it in the log so
     * a fired automation is still observable, and so this is an explicit gap rather
     * than a silently-dropped action.
     */
    private void notify(AutomationRule r) {
        JsonNode c = r.getActionConfig();
        log.info("Automation NOTIFICATION (no delivery channel yet): category={} title={}",
                c.path("category").asText("AUTOMATION"), c.path("title").asText(""));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────
    private void replaceRules(Automation a, List<AutomationActionIn> incoming) {
        ruleRepository.deleteAll(ruleRepository.findAllByAutomationId(a.getId()));
        if (incoming == null || incoming.isEmpty()) return;

        int order = 0;
        for (AutomationActionIn in : incoming) {
            if (in.type() == null || in.type().isBlank()) {
                throw new SheException("VALIDATION_ERROR", "Automation action requires type", 422);
            }
            AutomationRule r = new AutomationRule();
            r.setAutomationId(a.getId());
            r.setActionType(in.type());
            r.setActionConfig(objectMapper.valueToTree(actionConfigOf(in)));
            r.setSortOrder(order++);
            ruleRepository.save(r);
        }
    }

    /** Collapse the inbound action into the stored config shape for its type. */
    private Map<String, Object> actionConfigOf(AutomationActionIn in) {
        Map<String, Object> cfg = new LinkedHashMap<>();
        switch (in.type()) {
            case "WRITE_PARAM" -> {
                cfg.put("node_id", in.nodeId());
                cfg.put("device_name", in.deviceName());
                cfg.put("params", in.params());
            }
            case "ACTIVATE_SCENE" -> cfg.put("scene_id", in.sceneId());
            case "NOTIFICATION" -> {
                cfg.put("category", in.category() == null ? "AUTOMATION" : in.category());
                cfg.put("title", in.title());
                cfg.put("body", in.body());
            }
            default -> throw new SheException("VALIDATION_ERROR",
                    "Unsupported action type: " + in.type(), 422);
        }
        return cfg;
    }

    private boolean matches(String comparator, Object actual, JsonNode expected) {
        Object exp = toPlain(expected);
        int cmp = compare(actual, exp);
        return switch (comparator == null ? "==" : comparator) {
            case "==" -> Objects.equals(normalise(actual), normalise(exp));
            case "!=" -> !Objects.equals(normalise(actual), normalise(exp));
            case ">" -> cmp > 0;
            case ">=" -> cmp >= 0;
            case "<" -> cmp < 0;
            case "<=" -> cmp <= 0;
            default -> false;
        };
    }

    /** Compare numerically when both sides look numeric, else as strings. */
    private int compare(Object a, Object b) {
        if (a instanceof Number na && b instanceof Number nb) {
            return Double.compare(na.doubleValue(), nb.doubleValue());
        }
        return String.valueOf(a).compareTo(String.valueOf(b));
    }

    private Object normalise(Object o) {
        if (o instanceof Boolean || o instanceof Number) return o;
        return String.valueOf(o);
    }

    private AutomationOut toOut(Automation a) {
        List<AutomationActionOut> outs = ruleRepository.findAllByAutomationId(a.getId()).stream()
                .map(r -> new AutomationActionOut(r.getActionType(), toMap(r.getActionConfig())))
                .toList();
        return new AutomationOut(a.getId(), a.getHomeId(), a.getName(), a.getDescription(),
                a.getEnabled(), toMap(a.getTriggerConfig()), outs, a.getCreatedAt());
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> toMap(JsonNode n) {
        if (n == null || n.isNull()) return Map.of();
        return objectMapper.convertValue(n, Map.class);
    }

    private Object toPlain(JsonNode n) {
        if (n == null || n.isNull()) return null;
        if (n.isBoolean()) return n.booleanValue();
        if (n.isInt()) return n.intValue();
        if (n.isLong()) return n.longValue();
        if (n.isNumber()) return n.decimalValue();
        if (n.isTextual()) return n.textValue();
        return n.toString();
    }

    private Automation requireAutomation(UUID id) {
        return automationRepository.findByIdAndNotDeleted(id)
                .orElseThrow(() -> new SheException("AUTOMATION_NOT_FOUND", "Automation not found", 404));
    }

    private UUID currentTenantId() {
        if (currentUser() instanceof et.she.v3.security.AuthenticatedUser u) return u.tenantId();
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }

    private UUID currentUserIdOrNull() {
        if (currentUser() instanceof et.she.v3.security.AuthenticatedUser u) return u.userId();
        return null;
    }

    private Object currentUser() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        return auth != null ? auth.getPrincipal() : null;
    }
}
