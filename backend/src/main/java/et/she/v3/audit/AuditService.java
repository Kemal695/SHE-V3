package et.she.v3.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.UUID;

/**
 * Tamper-evident audit log writer (P1-19).
 *
 * <p>V3-DATABASE-DESIGN §5.10 / §7 and CANONICAL-DECISIONS P1-19 define
 * {@code audit_log} as a tamper-evident hash chain:</p>
 *
 * <pre>
 *   prev_hash = previous row's hash (empty for the first row of a tenant)
 *   hash      = SHA-256(prev_hash || canonical JSON of this row)
 * </pre>
 *
 * <p><b>Why this class exists.</b> Until now nothing in the application ever
 * inserted into {@code audit_log}. The table, its retention policy and the
 * nightly verification job all existed, but the table was permanently empty — so
 * the job reported "verified: 0 tenants, 0 mismatches" forever. A signed-off
 * compliance control that silently records nothing.</p>
 *
 * <p><b>Canonical form.</b> "Canonical JSON of this row" has to be reproducible
 * byte-for-byte by the verifier, so it is defined here once and shared: a JSON
 * object with a FIXED key order (below), nulls rendered as {@code ""}, and
 * {@code details} re-serialised with sorted keys so JSONB's key order cannot
 * change the digest. {@code created_at} is deliberately excluded — its text
 * representation varies by JDBC driver and timezone and would make the hash
 * irreproducible.</p>
 *
 * <p>Audit rows are written in their OWN transaction with the platform-admin GUC
 * set, so an entry survives (and records) a failed business operation, and so the
 * writer is not filtered by the caller's tenant context.</p>
 */
@Service
public class AuditService {

    private static final Logger log = LoggerFactory.getLogger(AuditService.class);

    /** Fixed key order — must stay in lockstep with {@link #canonicalJson}. */
    private static final String[] CANONICAL_KEYS = {
            "sequence_number", "tenant_id", "actor_type", "actor_user_id",
            "action", "target_type", "target_id", "ip_address", "user_agent",
            "request_id", "details"
    };

    private final JdbcTemplate jdbcTemplate;
    private final TransactionTemplate txTemplate;
    private final ObjectMapper objectMapper = new ObjectMapper();

    public AuditService(JdbcTemplate jdbcTemplate, PlatformTransactionManager txManager) {
        this.jdbcTemplate = jdbcTemplate;
        this.txTemplate = new TransactionTemplate(txManager);
        this.txTemplate.setPropagationBehavior(TransactionTemplate.PROPAGATION_REQUIRES_NEW);
    }

    /**
     * Append a hash-chained audit entry. Never throws — auditing must not break
     * the operation being audited; a failure is logged at ERROR instead.
     */
    public void record(UUID tenantId,
                       String actorType,
                       UUID actorUserId,
                       String action,
                       String targetType,
                       UUID targetId,
                       Object details,
                       String ipAddress,
                       String userAgent,
                       String requestId) {
        try {
            txTemplate.execute(status -> {
                // Platform-admin window: the writer is not scoped to a tenant.
                jdbcTemplate.execute("SET LOCAL app.is_platform_admin = 'true'");

                // queryForMap() throws EmptyResultDataAccessException when the
                // tenant has no rows yet — this is the common case on every
                // tenant's first audit entry, so use a list and take the head.
                java.util.List<Map<String, Object>> lastRows = jdbcTemplate.queryForList(
                        "SELECT sequence_number, hash FROM audit_log "
                        + "WHERE tenant_id = ? ORDER BY COALESCE(sequence_number, 0) DESC, created_at DESC LIMIT 1",
                        tenantId);

                long sequence = 1;
                byte[] prevHash = new byte[0];
                if (!lastRows.isEmpty()) {
                    Map<String, Object> last = lastRows.get(0);
                    Object sn = last.get("sequence_number");
                    if (sn instanceof Number n) {
                        sequence = n.longValue() + 1;
                    }
                    Object ph = last.get("hash");
                    if (ph instanceof byte[] b) {
                        prevHash = b;
                    }
                }

                // TransactionCallback cannot throw checked exceptions, so the
                // JSON/digest work is wrapped here.
                String detailsJson;
                String canonical;
                byte[] hash;
                try {
                    detailsJson = details == null ? "{}" : objectMapper.writeValueAsString(details);
                    canonical = canonicalJson(sequence, tenantId, actorType, actorUserId,
                            action, targetType, targetId, ipAddress, userAgent, requestId, details);
                    hash = sha256(concat(prevHash, canonical.getBytes(StandardCharsets.UTF_8)));
                } catch (Exception e) {
                    throw new IllegalStateException("audit canonicalisation failed", e);
                }

                jdbcTemplate.update(
                        "INSERT INTO audit_log (id, tenant_id, actor_user_id, actor_type, action, "
                        + "target_type, target_id, details, ip_address, user_agent, request_id, "
                        + "sequence_number, prev_hash, hash, created_at) "
                        + "VALUES (?,?,?,?,?,?,?,?::jsonb,?::inet,?,?,?,?,?,now())",
                        UUID.randomUUID(), tenantId, actorUserId, actorType, action,
                        targetType, targetId,
                        detailsJson,
                        ipAddress, userAgent, requestId,
                        sequence,
                        prevHash.length == 0 ? null : prevHash,
                        hash);
                return null;
            });
        } catch (Exception e) {
            log.error("AUDIT WRITE FAILED action={} tenant={} — {}", action, tenantId, e.getMessage(), e);
        }
    }

    /**
     * Canonical, reproducible serialisation of an audit row. Shared with
     * {@code ScheduledJobs#verifyAuditLogHashChain}, which recomputes the digest
     * from this same form — otherwise the chain would only prove linkage and an
     * attacker could edit a row's payload undetected.
     */
    public String canonicalJson(long sequence, UUID tenantId, String actorType, UUID actorUserId,
                                String action, String targetType, UUID targetId,
                                String ipAddress, String userAgent, String requestId,
                                Object details) throws Exception {
        // LinkedHashMap preserves insertion order, and Jackson escapes embedded
        // quotes properly (hand-rolled quoting did not).
        Map<String, Object> m = new java.util.LinkedHashMap<>();
        m.put("sequence_number", sequence);
        m.put("tenant_id", str(tenantId));
        m.put("actor_type", str(actorType));
        m.put("actor_user_id", str(actorUserId));
        m.put("action", str(action));
        m.put("target_type", str(targetType));
        m.put("target_id", str(targetId));
        m.put("ip_address", str(ipAddress));
        m.put("user_agent", str(userAgent));
        m.put("request_id", str(requestId));
        Object sortedDetails = canonicalDetails(details);
        m.put("details", sortedDetails);
        return objectMapper.writeValueAsString(m);
    }

    /** JSON keys sorted recursively, so JSONB's key order cannot change the digest. */
    private Object canonicalDetails(Object details) throws Exception {
        if (details == null) {
            return new java.util.TreeMap<String, Object>();
        }
        String raw = (details instanceof String s) ? s : objectMapper.writeValueAsString(details);
        if (raw.isBlank()) {
            return new java.util.TreeMap<String, Object>();
        }
        return sortKeys(objectMapper.readValue(raw, Object.class));
    }

    @SuppressWarnings("unchecked")
    private static Object sortKeys(Object node) {
        if (node instanceof Map<?, ?> m) {
            java.util.TreeMap<String, Object> sorted = new java.util.TreeMap<>();
            m.forEach((k, v) -> sorted.put(String.valueOf(k), sortKeys(v)));
            return sorted;
        }
        if (node instanceof java.util.List<?> l) {
            return l.stream().map(AuditService::sortKeys).toList();
        }
        return node;
    }

    private static String str(Object v) {
        return v == null ? "" : String.valueOf(v);
    }

    /**
     * Recompute a stored row's {@code hash} from its current content.
     * Used by the nightly verifier — if this differs from the stored digest the
     * row was modified in place.
     *
     * @param row      a row from {@code audit_log} (as returned by JdbcTemplate)
     * @param prevHash the row's stored {@code prev_hash}, or null for the first row
     * @return the expected hash, or null if the row could not be canonicalised
     */
    public byte[] recomputeHash(Map<String, Object> row, byte[] prevHash) {
        try {
            long sequence = 0;
            Object sn = row.get("sequence_number");
            if (sn instanceof Number n) {
                sequence = n.longValue();
            }
            byte[] prev = prevHash == null ? new byte[0] : prevHash;
            String canonical = canonicalJson(
                    sequence,
                    uuid(row.get("tenant_id")),
                    str(row.get("actor_type")),
                    uuid(row.get("actor_user_id")),
                    str(row.get("action")),
                    str(row.get("target_type")),
                    uuid(row.get("target_id")),
                    str(row.get("ip_address")),
                    str(row.get("user_agent")),
                    str(row.get("request_id")),
                    unwrapJson(row.get("details")));
            return sha256(concat(prev, canonical.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            log.error("Could not recompute audit hash for id={} — {}", row.get("id"), e.getMessage());
            return null;
        }
    }

    /**
     * JDBC may hand back a JSONB column as a driver-specific object rather than a
     * String. The Postgres driver is runtime-scoped, so it cannot be imported
     * here — but {@code PGobject.toString()} returns its value, which is all we
     * need.
     */
    private static Object unwrapJson(Object v) {
        if (v == null) {
            return null;
        }
        if (v instanceof String || v instanceof Map<?, ?> || v instanceof java.util.List<?>) {
            return v;
        }
        String cls = v.getClass().getName();
        if (cls.contains("PGobject") || cls.contains("Json")) {
            return v.toString();
        }
        return v;
    }

    private static UUID uuid(Object v) {
        if (v == null) {
            return null;
        }
        if (v instanceof UUID u) {
            return u;
        }
        String s = String.valueOf(v);
        return s.isBlank() ? null : UUID.fromString(s);
    }

    public static byte[] sha256(byte[] data) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(data);
    }

    public static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }
}
