package et.she.v3.energy;

import et.she.v3.config.SheProperties;
import et.she.v3.entity.Node;
import et.she.v3.repository.NodeRepository;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Energy service — ingests PZEM readings, calculates ETB cost, detects anomalies.
 *
 * V3-ENERGY-MONITORING §3-5. V3-DATABASE-DESIGN §5.2.
 * P1-20: canonical table = device_energy_readings, power column = power_w.
 * P1-21: retention = 365 days.
 *
 * Cost is calculated at ingest (server-side, not firmware) per V3-ENERGY-MONITORING §4.5.
 */
@Service
// Required for RLS: TenantContextAspect applies `app.tenant_id` /
// `app.is_platform_admin` only inside a transaction. Without this annotation
// there is no transaction at all, so the GUCs are never set and every
// tenant-scoped read here is filtered to zero rows by RLS (the /energy and
// /energy/daily endpoints returned 404 as a result).
@Transactional
public class EnergyService {

    private static final Logger log = LoggerFactory.getLogger(EnergyService.class);

    private final JdbcTemplate jdbcTemplate;
    private final NodeRepository nodeRepository;
    private final SheProperties props;

    public EnergyService(JdbcTemplate jdbcTemplate, NodeRepository nodeRepository, SheProperties props) {
        this.jdbcTemplate = jdbcTemplate;
        this.nodeRepository = nodeRepository;
        this.props = props;
    }

    // =========================================================================
    // INGEST (called by MqttSubscriberService on every `energy` MQTT message — every 5s)
    // =========================================================================

    @Transactional
    public void ingestEnergyReading(Instant time, UUID tenantId, UUID nodeId,
                                    double voltage, double current, double powerW,
                                    double energyWh, double powerFactor, double frequency) {
        // Calculate cost — incremental cost since last reading.
        // energyWh is cumulative from PZEM; we compute the delta + apply block tariff.
        double costEtb = calculateIncrementalCostEtb(tenantId, nodeId, energyWh);

        // Determine which tariff block this kWh fell into
        int tariffBlock = determineTariffBlock(tenantId, nodeId, energyWh);

        jdbcTemplate.update(
                """
                INSERT INTO device_energy_readings
                  (time, tenant_id, node_id, voltage, current, power_w,
                   energy_wh, cost_etb, tariff_block, frequency, power_factor)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                java.sql.Timestamp.from(time), tenantId, nodeId,
                voltage, current, powerW,
                energyWh, costEtb, tariffBlock,
                frequency, powerFactor
        );

        log.debug("Energy ingested: node={} power={}W cost={}ETB block={}",
                nodeId, powerW, costEtb, tariffBlock);
    }

    // =========================================================================
    // TELEMETRY INSERT (called by MqttSubscriberService on every `telemetry` MQTT message — every 30s)
    // =========================================================================

    @Transactional
    public void insertTelemetry(Instant time, UUID tenantId, UUID nodeId,
                                UUID deviceId, String paramName, double value, String unit) {
        jdbcTemplate.update(
                """
                INSERT INTO device_telemetry
                  (time, tenant_id, node_id, node_device_id, param_name, value, unit)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                java.sql.Timestamp.from(time), tenantId, nodeId, deviceId,
                paramName, value, unit
        );
    }

    // =========================================================================
    // COST CALCULATION — V3-ENERGY-MONITORING §4.5
    // =========================================================================

    /**
     * Calculate the incremental cost of this energy reading.
     *
     * Strategy: compute the month-to-date cumulative kWh, then apply the block tariff
     * to the incremental delta since the last reading.
     */
    private double calculateIncrementalCostEtb(UUID tenantId, UUID nodeId, double currentEnergyWh) {
        // Get the previous cumulative energy_wh for this node (the most recent reading)
        List<Map<String, Object>> lastRows = jdbcTemplate.queryForList(
                """
                SELECT energy_wh FROM device_energy_readings
                WHERE tenant_id = ? AND node_id = ?
                ORDER BY time DESC LIMIT 1
                """,
                tenantId, nodeId
        );

        double prevEnergyWh = 0;
        if (!lastRows.isEmpty()) {
            prevEnergyWh = ((Number) lastRows.get(0).get("energy_wh")).doubleValue();
        }

        double deltaWh = currentEnergyWh - prevEnergyWh;
        if (deltaWh <= 0) {
            // PZEM reset or no change — no cost
            return 0;
        }
        double deltaKwh = deltaWh / 1000.0;

        // Get month-to-date kWh (sum of all deltas this month in Addis Ababa timezone)
        java.time.ZonedDateTime nowEt = java.time.ZonedDateTime.now(java.time.ZoneId.of("Africa/Addis_Ababa"));
        Instant monthStart = nowEt.withDayOfMonth(1).truncatedTo(ChronoUnit.DAYS).toInstant();

        List<Map<String, Object>> monthStartRows = jdbcTemplate.queryForList(
                """
                SELECT energy_wh FROM device_energy_readings
                WHERE tenant_id = ? AND node_id = ? AND time < ?
                ORDER BY time DESC LIMIT 1
                """,
                tenantId, nodeId, java.sql.Timestamp.from(monthStart)
        );

        double monthStartEnergyWh = 0;
        if (!monthStartRows.isEmpty()) {
            monthStartEnergyWh = ((Number) monthStartRows.get(0).get("energy_wh")).doubleValue();
        }
        double monthToDateKwh = (currentEnergyWh - monthStartEnergyWh) / 1000.0;

        // Apply residential block tariff
        BigDecimal cost = calculateCostEtb(monthToDateKwh, TariffBlock.RESIDENTIAL);
        // Subtract the cost we already accounted for in previous readings this month
        BigDecimal prevCost = calculateCostEtb(monthToDateKwh - deltaKwh, TariffBlock.RESIDENTIAL);
        BigDecimal incrementalCost = cost.subtract(prevCost).max(BigDecimal.ZERO);
        return incrementalCost.setScale(2, RoundingMode.HALF_UP).doubleValue();
    }

    /**
     * Apply the block tariff to a total kWh consumption.
     *
     * V3-ENERGY-MONITORING §4.5 worked example — 250 kWh:
     *   50 @ 0.78 = 39.00
     *   50 @ 1.04 = 52.00
     *   100 @ 1.30 = 130.00
     *   50 @ 1.89 = 94.50
     *   Total = 315.50 ETB
     */
    public BigDecimal calculateCostEtb(double kWh, List<TariffBlock> blocks) {
        BigDecimal cost = BigDecimal.ZERO;
        double remaining = kWh;
        double blockStart = 0;

        for (TariffBlock block : blocks) {
            double blockEnd = block.upperLimit() == null ? Double.MAX_VALUE : block.upperLimit();
            double blockWidth = blockEnd - blockStart;
            double consumedInBlock = Math.min(remaining, blockWidth);
            if (consumedInBlock > 0) {
                cost = cost.add(BigDecimal.valueOf(consumedInBlock * block.pricePerKwh()));
            }
            remaining -= consumedInBlock;
            blockStart = blockEnd;
            if (remaining <= 0) break;
        }
        return cost.setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * Determine which tariff block the current kWh consumption falls into.
     */
    private int determineTariffBlock(UUID tenantId, UUID nodeId, double currentEnergyWh) {
        // Use month-to-date kWh in Addis Ababa timezone
        java.time.ZonedDateTime nowEt = java.time.ZonedDateTime.now(java.time.ZoneId.of("Africa/Addis_Ababa"));
        Instant monthStart = nowEt.withDayOfMonth(1).truncatedTo(ChronoUnit.DAYS).toInstant();

        List<Map<String, Object>> rows = jdbcTemplate.queryForList(
                """
                SELECT energy_wh FROM device_energy_readings
                WHERE tenant_id = ? AND node_id = ? AND time < ?
                ORDER BY time DESC LIMIT 1
                """,
                tenantId, nodeId, java.sql.Timestamp.from(monthStart)
        );

        double monthStartEnergyWh = 0;
        if (!rows.isEmpty()) {
            monthStartEnergyWh = ((Number) rows.get(0).get("energy_wh")).doubleValue();
        }
        double monthToDateKwh = (currentEnergyWh - monthStartEnergyWh) / 1000.0;

        List<TariffBlock> blocks = TariffBlock.RESIDENTIAL;
        for (int i = 0; i < blocks.size(); i++) {
            Integer upper = blocks.get(i).upperLimit();
            if (upper == null || monthToDateKwh <= upper) {
                return i + 1;
            }
        }
        return blocks.size();
    }

    // =========================================================================
    // QUERY — used by /api/v3/nodes/{id}/energy endpoint
    // =========================================================================

    /**
     * Get energy + cost summary for a node over a time range.
     *
     * Reads device_energy_readings directly rather than the energy_hourly
     * continuous aggregate, which lags by ~1h. (An earlier version of this
     * javadoc claimed the opposite; the aggregate is not queried at all here.)
     */
    public Map<String, Object> getEnergySummary(UUID tenantId, UUID nodeId, Instant from, Instant to) {
        // Always read from raw for accuracy (continuous aggregate lags by 1h)
        List<Map<String, Object>> rows = jdbcTemplate.queryForList(
                """
                SELECT
                    COUNT(*)                   AS sample_count,
                    AVG(voltage)               AS avg_voltage,
                    AVG(current)               AS avg_current,
                    AVG(power_w)               AS avg_power_w,
                    MAX(energy_wh) - MIN(energy_wh) AS energy_wh_consumed,
                    SUM(cost_etb)              AS total_cost_etb,
                    AVG(power_factor)          AS avg_pf,
                    AVG(frequency)             AS avg_freq
                FROM device_energy_readings
                WHERE tenant_id = ? AND node_id = ? AND time >= ? AND time <= ?
                """,
                tenantId, nodeId, java.sql.Timestamp.from(from), java.sql.Timestamp.from(to)
        );

        if (rows.isEmpty() || rows.get(0).get("sample_count") == null) {
            return Map.of("energyWh", 0, "costEtb", 0, "avgPowerW", 0);
        }
        return rows.get(0);
    }

    /**
     * Per-day energy history for the mobile 7-day chart (M7 fix).
     * One row per day: {date, energyWh, costEtb}. Days without readings are
     * omitted (the app zero-fills gaps).
     */
    public List<Map<String, Object>> getDailyEnergy(UUID tenantId, UUID nodeId, int days) {
        if (days < 1 || days > 90) days = 7;
        Instant from = Instant.now().minusSeconds((long) days * 86400);
        return jdbcTemplate.queryForList(
                """
                SELECT time_bucket('1 day', time) AS day,
                       MAX(energy_wh) - MIN(energy_wh) AS energy_wh,
                       SUM(cost_etb) AS cost_etb
                FROM device_energy_readings
                WHERE tenant_id = ? AND node_id = ? AND time >= ?
                GROUP BY 1 ORDER BY 1 ASC
                """,
                tenantId, nodeId, java.sql.Timestamp.from(from)
        );
    }

    /**
     * Get today's energy cost for a node — for real-time WebSocket energy.update.
     */
    public double getTodayCostEtb(UUID tenantId, UUID nodeId) {
        // Day boundary in Addis Ababa time (H7 fix — UTC midnight is 3 AM local).
        Instant dayStart = java.time.ZonedDateTime.now(java.time.ZoneId.of("Africa/Addis_Ababa"))
                .truncatedTo(ChronoUnit.DAYS).toInstant();
        List<Map<String, Object>> rows = jdbcTemplate.queryForList(
                """
                SELECT COALESCE(SUM(cost_etb), 0) AS cost
                FROM device_energy_readings
                WHERE tenant_id = ? AND node_id = ? AND time >= ?
                """,
                tenantId, nodeId, java.sql.Timestamp.from(dayStart)
        );
        if (rows.isEmpty()) return 0;
        return ((Number) rows.get(0).get("cost")).doubleValue();
    }

    // =========================================================================
    // ANOMALY DETECTION — V3-ENERGY-MONITORING §4.7
    // 3× power spike vs 7-day baseline AND absolute > 100W → push notification
    // =========================================================================

    @Scheduled(fixedRate = 5 * 60 * 1000)    // every 5 minutes
    @Transactional
    public void detectAnomalies() {
        try {
            // Set platform admin GUC so RLS doesn't block queries (P0-5 / H8 fix)
            jdbcTemplate.execute("SET LOCAL app.is_platform_admin = 'true'");

            // Find all nodes with energy readings in the last 10 min
            List<Map<String, Object>> activeNodes = jdbcTemplate.queryForList(
                    """
                    SELECT DISTINCT tenant_id, node_id
                    FROM device_energy_readings
                    WHERE time > NOW() - INTERVAL '10 minutes'
                    """
            );

            for (Map<String, Object> row : activeNodes) {
                UUID tenantId = (UUID) row.get("tenant_id");
                UUID nodeId = (UUID) row.get("node_id");

                // Current power (latest reading)
                List<Map<String, Object>> latest = jdbcTemplate.queryForList(
                        """
                        SELECT power_w FROM device_energy_readings
                        WHERE tenant_id = ? AND node_id = ?
                        ORDER BY time DESC LIMIT 1
                        """,
                        tenantId, nodeId
                );
                if (latest.isEmpty()) continue;
                double currentPower = ((Number) latest.get(0).get("power_w")).doubleValue();

                // 7-day average baseline
                List<Map<String, Object>> baseline = jdbcTemplate.queryForList(
                        """
                        SELECT AVG(power_w) AS avg_power
                        FROM device_energy_readings
                        WHERE tenant_id = ? AND node_id = ?
                          AND time > NOW() - INTERVAL '7 days'
                          AND time < NOW() - INTERVAL '10 minutes'
                        """,
                        tenantId, nodeId
                );
                if (baseline.isEmpty() || baseline.get(0).get("avg_power") == null) continue;
                double avgPower = ((Number) baseline.get(0).get("avg_power")).doubleValue();

                // Anomaly rule: > 3× baseline AND > 100 W absolute
                if (currentPower > avgPower * 3.0 && currentPower > 100.0) {
                    log.warn("ENERGY ANOMALY: node={} current={}W baseline={}W (3× spike)",
                            nodeId, currentPower, avgPower);
                    // TODO: push notification via NotificationService (Phase 4)
                    // TODO: insert audit_log row with action='energy.anomaly_detected'
                    // For Phase 1: just log — notification service comes in Phase 4
                }
            }
        } catch (Exception e) {
            log.error("Anomaly detection failed: {}", e.getMessage(), e);
        }
    }
}
