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
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
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

    /**
     * A catch-up may only EXECUTE the missed action when the missed occurrence is
     * at most this many minutes old — i.e. the server was briefly down around the
     * scheduled time. Anything older is advanced (last_fired_at) WITHOUT running
     * the action; see runScheduled().
     */
    private static final long CATCHUP_EXECUTE_LIMIT_MINUTES = 5;

    private final AutomationRepository automationRepository;
    private final AutomationRuleRepository ruleRepository;
    private final NodeDeviceRepository nodeDeviceRepository;
    private final NodeService nodeService;
    private final SceneService sceneService;
    private final ObjectMapper objectMapper;

    private final JdbcTemplate jdbcTemplate;

    /**
     * Used ONLY to persist {@code last_fired_at} in its own transaction — see
     * {@link #markFired}. Modelled on AuditService, which writes with
     * REQUIRES_NEW for the same reason: the record must survive regardless of
     * what happens to the work it describes.
     */
    private final TransactionTemplate markFiredTx;

    public AutomationService(AutomationRepository automationRepository,
                             AutomationRuleRepository ruleRepository,
                             NodeDeviceRepository nodeDeviceRepository,
                             NodeService nodeService,
                             SceneService sceneService,
                             ObjectMapper objectMapper,
                             JdbcTemplate jdbcTemplate,
                             PlatformTransactionManager txManager) {
        this.automationRepository = automationRepository;
        this.ruleRepository = ruleRepository;
        this.nodeDeviceRepository = nodeDeviceRepository;
        this.nodeService = nodeService;
        this.sceneService = sceneService;
        this.jdbcTemplate = jdbcTemplate;
        this.markFiredTx = new TransactionTemplate(txManager);
        this.markFiredTx.setPropagationBehavior(TransactionTemplate.PROPAGATION_REQUIRES_NEW);
        this.objectMapper = objectMapper;
    }

    // ─── DTOs ────────────────────────────────────────────────────────────────
    public record AutomationActionIn(
            @JsonProperty("type") String type,
            @JsonProperty("node_id") UUID nodeId,
            @JsonProperty("device_name") String deviceName,
            // STABLE device id. The app sends this so a later rename cannot
            // orphan the rule; it was being dropped here and never stored.
            @JsonProperty("node_device_id") UUID nodeDeviceId,
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

    /**
     * PUT body. `trigger` and `actions` are optional: when present they REPLACE
     * the stored rule (so the editor can actually change what an automation
     * does, not just its name), when null the existing rule is left alone.
     */
    public record UpdateAutomationRequest(
            String name, String description, Boolean enabled,
            Map<String, Object> trigger,
            List<AutomationActionIn> actions) {}
    public record SetEnabledRequest(Boolean enabled) {}

    public record AutomationActionOut(String type, Map<String, Object> config) {}
    public record AutomationOut(UUID id, UUID homeId, String name, String description,
                               Boolean enabled, Map<String, Object> trigger,
                               List<AutomationActionOut> actions, Instant createdAt,
                               // Exposed so the app can answer "has this ever run?".
                               // Without it, a rule that saves but silently never
                               // fires is indistinguishable from one that fires and
                               // whose action fails — both just "do nothing".
                               Instant lastFiredAt) {}
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
        // Only touch the trigger when the client actually sent one, so a
        // name-only PUT (e.g. an inline rename) never wipes the rule.
        if (req.trigger() != null) a.setTriggerConfig(objectMapper.valueToTree(req.trigger()));
        Automation saved = automationRepository.save(a);
        if (req.actions() != null) replaceRules(saved, req.actions());
        return toOut(saved);
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

        // Fire only on a TRANSITION INTO the matching region: the new value must
        // match the trigger while the previous one did not.
        //
        // For a boolean (Power ON/OFF) trigger this is identical to a change guard
        // — a boolean only "changes" at a real transition. For a NUMERIC sensor
        // threshold (e.g. Temperature >= 30) it is essential: a sensor that stays
        // above 30 would otherwise re-fire on every periodic report (~30 s),
        // re-commanding the target device forever. The first report of a param is
        // never passed here (the MQTT path seeds it instead of evaluating), so a
        // freshly-seen value cannot spuriously fire.
        for (Automation a : automationRepository.findAllEnabled()) {
            JsonNode t = a.getTriggerConfig();
            if (t == null || !"NODE_STATE".equalsIgnoreCase(t.path("type").asText())) continue;

            String trigNode = t.path("node_id").asText(null);
            if (trigNode == null || !trigNode.equalsIgnoreCase(String.valueOf(nodeId))) continue;
            if (!paramName.equalsIgnoreCase(t.path("param_name").asText())) continue;

            String deviceName = t.path("device_name").asText(null);
            String trigDeviceId = t.path("node_device_id").asText(null);
            if (trigDeviceId != null && !trigDeviceId.isBlank()) {
                // Prefer the STABLE device id. The name in the config goes stale
                // the moment the device is renamed, which used to stop the
                // automation matching its own device.
                if (!UUID.fromString(trigDeviceId).equals(deviceId)) continue;
            } else if (deviceName != null) {
                // Legacy configs that only carry a name.
                UUID trigDevice = nodeDeviceRepository.findByNodeAndName(nodeId, deviceName)
                        .map(NodeDevice::getId).orElse(null);
                if (trigDevice == null || !trigDevice.equals(deviceId)) continue;
            }

            final String comparator = t.path("comparator").asText("==");
            final boolean oldMatches = matches(comparator, oldValue, t.path("value"));
            final boolean newMatches = matches(comparator, newValue, t.path("value"));
            if (!newMatches || oldMatches) continue;

            log.info("Automation {} fired by NODE_STATE {}.{}={} ({} -> {})",
                    a.getId(), deviceName, paramName, newValue, oldValue, newValue);
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
            if (t == null) continue;

            // SOLAR — "At sunrise or sunset". The time moves through the year, so
            // it cannot be a fixed cron; compute today's time for the home's
            // coordinates and fire on the matching minute.
            if ("SOLAR".equalsIgnoreCase(t.path("type").asText())) {
                String event = t.path("event").asText("sunrise");
                LocalDateTime due = solarTimeFor(event, nowMinute.toLocalDate(), zone);
                if (due == null || !due.equals(nowMinute)) continue;
                if (a.getLastFiredAt() != null
                        && !a.getLastFiredAt().isBefore(due.atZone(zone).toInstant())) continue;
                log.info("Automation {} fired by SOLAR {} ({})", a.getId(), event, due);
                // Same ordering rule as the SCHEDULE branch — record first, then
                // act, so a throwing action cannot cause an infinite re-fire.
                markFired(a.getId(), now);
                try {
                    execute(a);
                } catch (Exception e) {
                    log.error("Automation {} execution failed: {}", a.getId(), e.getMessage());
                }
                fired++;
                continue;
            }

            if (!"SCHEDULE".equalsIgnoreCase(t.path("type").asText())) continue;
            String cron = t.path("cron").asText(null);

            // Where to start looking for a due time.
            //
            // NEVER-FIRED (lastFiredAt == null): only match the CURRENT minute, so
            // the automation waits for its next scheduled time.
            //
            // 🔴 This used to open a 24-hour catch-up window here too, which meant a
            // freshly created automation whose time had ALREADY PASSED today fired
            // on the very next sweep — ~60 s after being saved. Observed on
            // 2026-10-07: an automation set to 00:28 was created at 22:40 and fired
            // at 22:42, i.e. ~22 hours early, and the user reasonably reported "it
            // runs whenever, not at my time". The catch-up window exists to recover
            // runs missed while the SERVER WAS DOWN; a brand-new automation has no
            // downtime to recover, so it must not use it.
            //
            // ALREADY-FIRED: keep the bounded lookback, so a missed 06:00 during an
            // outage is not lost forever. Without the bound, a multi-day outage
            // would replay a long queue of missed runs and hammer devices on restart.
            final Instant lastFired = a.getLastFiredAt();
            final LocalDateTime searchFrom;
            if (lastFired == null) {
                // next() is strictly-after, so starting one minute back lets the
                // current minute itself match.
                searchFrom = nowMinute.minusMinutes(1);
            } else {
                final Instant earliest = now.minus(CATCHUP_WINDOW);
                final Instant windowStart = lastFired.isBefore(earliest) ? earliest : lastFired;
                searchFrom =
                        LocalDateTime.ofInstant(windowStart, zone).truncatedTo(ChronoUnit.MINUTES);
            }

            LocalDateTime due = latestFireAtOrBefore(cron, searchFrom, nowMinute);
            if (due == null) continue; // no scheduled time fell in the window

            // Already fired for this scheduled time (or a later one)? Then the
            // only reason we are here is a restart inside the same minute.
            if (lastFired != null && !lastFired.isBefore(due.atZone(zone).toInstant())) continue;

            boolean isCatchUp = due.isBefore(nowMinute);

            // A catch-up must only EXECUTE when the missed run is genuinely recent
            // — i.e. the server was down for a few minutes around the scheduled
            // time. A stale occurrence (up to CATCHUP_WINDOW = 24h old) must NOT be
            // run now: that is what made a 20:35 schedule fire at 13:09 the next
            // day and turn a socket on with no user action (observed 2026-10-27,
            // automation "bfgg" -> "Socket 1"). Advance the marker so the missed
            // run is not replayed on every sweep, and wait for the next real
            // occurrence instead.
            if (isCatchUp
                    && Duration.between(due, nowMinute).toMinutes() > CATCHUP_EXECUTE_LIMIT_MINUTES) {
                log.warn("Automation {} skipping stale catch-up: due={} is {} min old "
                                + "(execute limit {} min) — advancing last_fired_at only, not executing",
                        a.getId(), due, Duration.between(due, nowMinute).toMinutes(),
                        CATCHUP_EXECUTE_LIMIT_MINUTES);
                markFired(a.getId(), now);
                continue;
            }

            log.info("Automation {} fired by SCHEDULE cron={} due={}{}",
                    a.getId(), cron, due, isCatchUp ? " (catch-up after downtime)" : "");

            // 🔴 ORDER MATTERS. Record the fire FIRST, in its own transaction, and
            // only then run the actions.
            //
            // This used to be execute() -> setLastFiredAt() -> save(), all in the
            // sweep's single transaction. Anything that threw during execution
            // marked that transaction rollback-only, so the marker was LOST and the
            // automation re-fired on EVERY subsequent 60 s sweep — indefinitely.
            // Observed 2026-10-08: a SCHEDULE automation re-wrote its devices every
            // minute from 01:14 onward while last_fired_at stayed frozen at the
            // previous day's value. The audit rows survived because AuditService
            // writes with REQUIRES_NEW, and that asymmetry is what exposed it.
            //
            // The marker means "this scheduled run has been attempted". It must not
            // depend on whether the device write succeeded — a failed action is
            // still reported via the log and the audit trail, but it must never
            // cause an infinite re-fire loop.
            markFired(a.getId(), now);

            try {
                execute(a);
            } catch (Exception e) {
                // One misbehaving automation must not abort the rest of the sweep.
                log.error("Automation {} execution failed: {}", a.getId(), e.getMessage());
            }
            fired++;
        }
        return fired;
    }

    /**
     * Persist {@code last_fired_at} in its OWN transaction (REQUIRES_NEW).
     *
     * Raw JDBC rather than {@code automationRepository.save(a)}: the entity was
     * loaded in the caller's persistence context, and re-saving it from a nested
     * transaction invites exactly the detachment problems this method exists to
     * avoid. A targeted UPDATE is unambiguous.
     *
     * The RLS GUC has to be set again here — {@code set_config(..., is_local=true)}
     * is scoped to a single transaction, and this is a different one.
     */
    private void markFired(UUID automationId, Instant when) {
        try {
            markFiredTx.executeWithoutResult(status -> {
                jdbcTemplate.execute("SELECT set_config('app.is_platform_admin','on',true)");
                int n = jdbcTemplate.update(
                        "UPDATE automations SET last_fired_at = ? WHERE id = ?",
                        Timestamp.from(when), automationId);
                if (n == 0) {
                    log.error("last_fired_at not recorded for automation {} — 0 rows updated "
                            + "(RLS or missing row). It may fire again on the next sweep.",
                            automationId);
                }
            });
        } catch (Exception e) {
            log.error("Could not record last_fired_at for automation {}: {}",
                    automationId, e.getMessage());
        }
    }

    /**
     * Sunrise/sunset for a date, in the given zone.
     *
     * Standard NOAA solar-position algorithm. Coordinates default to Addis Ababa
     * (9.03 N, 38.74 E) — the launch market — until homes carry their own.
     */
    private LocalDateTime solarTimeFor(String event, LocalDate date, ZoneId zone) {
        final double lat = 9.03, lon = 38.74;
        final boolean sunrise = !"sunset".equalsIgnoreCase(event);
        int n = date.getDayOfYear();
        double lngHour = lon / 15.0;
        double t = n + ((sunrise ? 6.0 : 18.0) - lngHour) / 24.0;
        double m = (0.9856 * t) - 3.289;
        double l = m + (1.916 * Math.sin(Math.toRadians(m)))
                + (0.020 * Math.sin(Math.toRadians(2 * m))) + 282.634;
        l = ((l % 360) + 360) % 360;

        double ra = Math.toDegrees(Math.atan(0.91764 * Math.tan(Math.toRadians(l))));
        ra = ((ra % 360) + 360) % 360;
        // Put RA in the same quadrant as L.
        double lQuadrant = Math.floor(l / 90.0) * 90.0;
        double raQuadrant = Math.floor(ra / 90.0) * 90.0;
        ra = (ra + (lQuadrant - raQuadrant)) / 15.0;

        double sinDec = 0.39782 * Math.sin(Math.toRadians(l));
        double cosDec = Math.cos(Math.asin(sinDec));
        double cosH = (Math.cos(Math.toRadians(90.833))
                - (sinDec * Math.sin(Math.toRadians(lat))))
                / (cosDec * Math.cos(Math.toRadians(lat)));
        if (cosH > 1 || cosH < -1) return null; // sun never rises/sets that day

        double h = sunrise
                ? 360.0 - Math.toDegrees(Math.acos(cosH))
                : Math.toDegrees(Math.acos(cosH));
        h = h / 15.0;
        double localT = h + ra - (0.06571 * t) - 6.622;
        double ut = ((localT - lngHour) % 24 + 24) % 24;

        int hour = (int) ut;
        int minute = (int) Math.round((ut - hour) * 60);
        if (minute == 60) {
            minute = 0;
            hour = (hour + 1) % 24;
        }

        // The formula yields UTC, so shift into the app's zone.
        LocalDateTime utc = LocalDateTime.of(date, LocalTime.of(hour, minute));
        return utc.atZone(ZoneOffset.UTC).withZoneSameInstant(zone).toLocalDateTime();
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
                if (in.nodeDeviceId() != null) cfg.put("node_device_id", in.nodeDeviceId());
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
                a.getEnabled(), toMap(a.getTriggerConfig()), outs, a.getCreatedAt(),
                a.getLastFiredAt());
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
