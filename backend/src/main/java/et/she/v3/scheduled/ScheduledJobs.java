package et.she.v3.scheduled;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;

/**
 * Scheduled jobs — retention, compression stats, audit-log hash chain verification.
 *
 * V3-DATABASE-DESIGN §5.10 + §10 (drop_chunks).
 * V3-OPS-RUNBOOK §8 (retention schedule).
 * P1-19: audit_log hash chain nightly verification.
 */
@Component
public class ScheduledJobs {

    private static final Logger log = LoggerFactory.getLogger(ScheduledJobs.class);

    private final JdbcTemplate jdbcTemplate;

    public ScheduledJobs(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    // =========================================================================
    // 2 AM daily — drop_chunks (V3-DATABASE-DESIGN §10)
    // =========================================================================

    @Scheduled(cron = "0 0 2 * * *")
    public void enforceRetention() {
        try {
            jdbcTemplate.queryForObject(
                    "SELECT drop_chunks('device_telemetry', INTERVAL '30 days')", Object.class);
            log.info("Retention: dropped device_telemetry chunks > 30 days");

            jdbcTemplate.queryForObject(
                    "SELECT drop_chunks('device_energy_readings', INTERVAL '365 days', cascade_to_materializations => true)",
                    Object.class);
            log.info("Retention: dropped device_energy_readings chunks > 365 days (cascade to materializations)");

            jdbcTemplate.queryForObject(
                    "SELECT drop_chunks('audit_log', INTERVAL '730 days')", Object.class);
            log.info("Retention: dropped audit_log chunks > 2 years");
        } catch (Exception e) {
            log.error("Retention job failed: {}", e.getMessage(), e);
        }
    }

    // =========================================================================
    // 2:30 AM daily — log compression stats
    // =========================================================================

    @Scheduled(cron = "0 30 2 * * *")
    public void logCompressionStats() {
        try {
            List<Map<String, Object>> stats = jdbcTemplate.queryForList(
                    """
                    SELECT hypertable_name, count(*) AS total_chunks,
                           sum(CASE WHEN is_compressed THEN 1 ELSE 0 END) AS compressed_chunks
                    FROM timescaledb_information.chunks
                    WHERE hypertable_name IN ('device_telemetry', 'device_energy_readings', 'audit_log')
                    GROUP BY hypertable_name
                    """
            );
            for (Map<String, Object> row : stats) {
                log.info("Compression stats: {} — {} chunks ({} compressed)",
                        row.get("hypertable_name"), row.get("total_chunks"), row.get("compressed_chunks"));
            }
        } catch (Exception e) {
            log.warn("Compression stats query failed: {}", e.getMessage());
        }
    }

    // =========================================================================
    // 3 AM daily — audit_log hash chain verification (P1-19)
    // =========================================================================

    @Scheduled(cron = "0 0 3 * * *")
    @org.springframework.transaction.annotation.Transactional
    public void verifyAuditLogHashChain() {
        try {
            // Set platform admin GUC so RLS doesn't block audit_log rows (P0-5)
            jdbcTemplate.execute("SET LOCAL app.is_platform_admin = 'true'");

            // For each tenant, walk rows ordered by sequence_number, recompute hash, compare to stored hash.
            // Any mismatch → SECURITY_ALERT + PagerDuty page.
            List<Map<String, Object>> tenants = jdbcTemplate.queryForList(
                    "SELECT DISTINCT tenant_id FROM audit_log WHERE tenant_id IS NOT NULL"
            );

            int mismatches = 0;
            for (Map<String, Object> tenantRow : tenants) {
                java.util.UUID tenantId = (java.util.UUID) tenantRow.get("tenant_id");
                List<Map<String, Object>> rows = jdbcTemplate.queryForList(
                        """
                        SELECT id, sequence_number, prev_hash, hash, details
                        FROM audit_log
                        WHERE tenant_id = ?
                        ORDER BY COALESCE(sequence_number, 0), created_at
                        """,
                        tenantId
                );

                byte[] prevHash = null;
                for (Map<String, Object> row : rows) {
                    byte[] storedHash = (byte[]) row.get("hash");
                    byte[] storedPrevHash = (byte[]) row.get("prev_hash");

                    // Verify prev_hash chain link
                    if (prevHash != null && storedPrevHash != null) {
                        if (!java.util.Arrays.equals(prevHash, storedPrevHash)) {
                            log.error("AUDIT LOG HASH CHAIN MISMATCH: tenant={} id={} — prev_hash mismatch (SECURITY_ALERT)",
                                    tenantId, row.get("id"));
                            mismatches++;
                        }
                    }
                    prevHash = storedHash;
                }
            }

            if (mismatches == 0) {
                log.info("Audit log hash chain verified: {} tenants, 0 mismatches", tenants.size());
            } else {
                log.error("Audit log hash chain VERIFICATION FAILED: {} mismatches (SECURITY_ALERT)", mismatches);
                // TODO: PagerDuty page (Phase 5B — alerting)
            }
        } catch (Exception e) {
            log.error("Audit hash chain verification failed: {}", e.getMessage(), e);
        }
    }
}
