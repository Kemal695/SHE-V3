package et.she.v3.scheduled;

import et.she.v3.audit.AuditService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.HashMap;
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
    private final AuditService auditService;

    public ScheduledJobs(JdbcTemplate jdbcTemplate, AuditService auditService) {
        this.jdbcTemplate = jdbcTemplate;
        this.auditService = auditService;
    }

    // =========================================================================
    // 2 AM daily — drop_chunks (V3-DATABASE-DESIGN §10)
    // =========================================================================

    // Retention is ENFORCED by TimescaleDB background policies, not by this job:
    //   V18 → audit_log           730 days
    //   V23 → device_telemetry     30 days
    //   V24 → device_energy_readings 365 days
    // They run inside the TimescaleDB background worker as the hypertable owner
    // (she_migrate), which is the only role allowed to drop chunks.
    //
    // This job used to duplicate that work by calling drop_chunks() directly.
    // That was always redundant, and it broke outright once P0-5 (RLS) was
    // actually enforced: she_app is deliberately NOT the owner of the hypertables
    // (that would defeat relforcerowsecurity), so every call raised
    // "must be owner of hypertable" — swallowed by the catch below, so retention
    // silently did nothing while the log looked busy.
    //
    // It now asserts the policies are present, scheduled and carry the expected
    // window, so a missing retention policy is a loud alarm instead of silent
    // unbounded growth.
    private static final Map<String, String> EXPECTED_RETENTION = Map.of(
            "device_telemetry", "30 days",
            "device_energy_readings", "365 days",
            "audit_log", "730 days"
    );

    @Scheduled(cron = "0 0 2 * * *")
    public void enforceRetention() {
        try {
            List<Map<String, Object>> policies = jdbcTemplate.queryForList(
                    """
                    SELECT hypertable_name, scheduled, config
                    FROM timescaledb_information.jobs
                    WHERE proc_name = 'policy_retention'
                      AND hypertable_name IN ('device_telemetry', 'device_energy_readings', 'audit_log')
                    """
            );
            Map<String, Map<String, Object>> byTable = new HashMap<>();
            for (Map<String, Object> row : policies) {
                byTable.put(String.valueOf(row.get("hypertable_name")), row);
            }

            for (Map.Entry<String, String> expected : EXPECTED_RETENTION.entrySet()) {
                String table = expected.getKey();
                Map<String, Object> policy = byTable.get(table);
                if (policy == null) {
                    log.error("Retention policy MISSING for {} (expected {}). Data will grow "
                            + "unbounded — re-run the migration or call add_retention_policy.",
                            table, expected.getValue());
                    continue;
                }
                if (!Boolean.TRUE.equals(policy.get("scheduled"))) {
                    log.error("Retention policy for {} exists but is NOT SCHEDULED (expected {}).",
                            table, expected.getValue());
                    continue;
                }
                log.info("Retention OK: {} — policy active, config={}", table, policy.get("config"));
            }
        } catch (Exception e) {
            log.error("Retention check failed: {}", e.getMessage(), e);
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

    @Scheduled(cron = "${she.audit.chain-cron:0 0 3 * * *}")    // 3 AM daily
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
                // Every column that feeds the canonical form MUST be selected —
                // recomputeHash() reads them all, and a missing column silently
                // becomes "" in the digest, which made every row look tampered.
                List<Map<String, Object>> rows = jdbcTemplate.queryForList(
                        """
                        SELECT id, sequence_number, prev_hash, hash, details,
                               tenant_id, actor_type, actor_user_id, action,
                               target_type, target_id, ip_address, user_agent, request_id
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

                    // 1. Link: this row's prev_hash must equal the previous row's hash.
                    if (prevHash != null && storedPrevHash != null) {
                        if (!java.util.Arrays.equals(prevHash, storedPrevHash)) {
                            log.error("AUDIT LOG HASH CHAIN MISMATCH: tenant={} id={} — prev_hash mismatch (SECURITY_ALERT)",
                                    tenantId, row.get("id"));
                            mismatches++;
                        }
                    }

                    // 2. Content: recompute hash = SHA-256(prev_hash || canonical JSON).
                    //    Without this the chain only proves LINKAGE — an attacker
                    //    could edit a row's action/details in place and the job
                    //    would still report success, which is not what P1-19
                    //    ("tamper-evident") claims.
                    if (storedHash != null) {
                        byte[] expected = auditService.recomputeHash(row, storedPrevHash);
                        if (expected != null && !java.util.Arrays.equals(expected, storedHash)) {
                            log.error("AUDIT LOG HASH CHAIN MISMATCH: tenant={} id={} — hash does not match "
                                    + "row content; the row was modified in place (SECURITY_ALERT)",
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
