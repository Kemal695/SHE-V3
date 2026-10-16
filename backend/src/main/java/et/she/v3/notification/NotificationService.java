package et.she.v3.notification;

import et.she.v3.errors.SheException;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.websocket.WsEventBus;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Notification inbox service — the API behind the mobile Notifications screen
 * (design sheet #15, V3-API-SPECIFICATION §12).
 *
 * <p>Why this class exists: the tables from V12 ({@code notification_preferences},
 * {@code notification_log}) were never reachable — no controller, no service, and
 * nothing ever wrote an inbox row. The mobile screen worked only because it
 * DERIVED notifications from live WebSocket events, which meant anything that
 * happened while the app was closed was lost. This service persists the inbox so
 * history survives and is consistent across a user's devices.</p>
 *
 * <p><b>Two execution contexts.</b> The read/mark methods run in the caller's
 * authenticated {@code @Transactional} context, where {@code TenantContextAspect}
 * has already set the RLS GUCs, so a plain {@code user_id} filter on top of RLS is
 * enough. The {@link #record} emit path is called from SYSTEM context (MQTT
 * ingest, payment webhook) where NO user is authenticated and the GUCs are unset —
 * so it opens its own REQUIRES_NEW transaction and sets
 * {@code app.is_platform_admin} explicitly, exactly like {@code AuditService}. That
 * also keeps a failed notification from rolling back the ingest that triggered it.</p>
 */
@Service
public class NotificationService {

    private static final Logger log = LoggerFactory.getLogger(NotificationService.class);

    /** Hard cap so a client cannot ask for an unbounded page. */
    private static final int MAX_LIMIT = 100;

    private final JdbcTemplate jdbc;
    private final TransactionTemplate txTemplate;
    private final WsEventBus wsEventBus;

    public NotificationService(JdbcTemplate jdbc,
                               PlatformTransactionManager txManager,
                               WsEventBus wsEventBus) {
        this.jdbc = jdbc;
        this.txTemplate = new TransactionTemplate(txManager);
        this.txTemplate.setPropagationBehavior(TransactionTemplate.PROPAGATION_REQUIRES_NEW);
        this.wsEventBus = wsEventBus;
    }

    /**
     * One inbox row as the mobile app expects it. {@code category} is already in
     * the mobile vocabulary (system / devices / security), derived from
     * {@code kind} — the DB column keeps the spec enum.
     */
    public record NotificationOut(String id,
                                  String kind,
                                  String category,
                                  String title,
                                  String body,
                                  String nodeId,
                                  String homeId,
                                  Instant at,
                                  boolean read) {}

    // ─── Reads / marks (authenticated, RLS-scoped) ───────────────────────────

    @Transactional(readOnly = true)
    public List<NotificationOut> recent(int limit) {
        UUID userId = currentUser().userId();
        int lim = Math.max(1, Math.min(limit, MAX_LIMIT));
        return jdbc.query(
                "SELECT id, kind, category, title, body, node_id, home_id, read_at, created_at "
                        + "FROM user_notifications WHERE user_id = ? "
                        + "ORDER BY created_at DESC LIMIT ?",
                (rs, i) -> new NotificationOut(
                        rs.getString("id"),
                        rs.getString("kind"),
                        mobileCategory(rs.getString("kind"), rs.getString("category")),
                        rs.getString("title"),
                        rs.getString("body"),
                        rs.getString("node_id"),
                        rs.getString("home_id"),
                        rs.getTimestamp("created_at").toInstant(),
                        rs.getTimestamp("read_at") != null),
                userId, lim);
    }

    @Transactional(readOnly = true)
    public int unreadCount() {
        UUID userId = currentUser().userId();
        Integer n = jdbc.queryForObject(
                "SELECT count(*) FROM user_notifications WHERE user_id = ? AND read_at IS NULL",
                Integer.class, userId);
        return n == null ? 0 : n;
    }

    @Transactional
    public void markRead(UUID id) {
        UUID userId = currentUser().userId();
        jdbc.update("UPDATE user_notifications SET read_at = now() "
                        + "WHERE id = ? AND user_id = ? AND read_at IS NULL",
                id, userId);
    }

    @Transactional
    public int markAllRead() {
        UUID userId = currentUser().userId();
        return jdbc.update("UPDATE user_notifications SET read_at = now() "
                + "WHERE user_id = ? AND read_at IS NULL", userId);
    }

    // ─── Emit (system-safe; called from MQTT / payment webhook) ──────────────

    /**
     * Persist one notification for one user and push it over WebSocket.
     *
     * <p>Never throws — a notification must not break the ingest or payment that
     * triggered it; failures are logged and swallowed.</p>
     */
    public void record(UUID tenantId,
                       UUID userId,
                       String kind,
                       String category,
                       String title,
                       String body,
                       UUID nodeId,
                       UUID homeId) {
        if (tenantId == null || userId == null || title == null || title.isBlank()) return;

        try {
            txTemplate.execute(status -> {
                // Platform-admin window: no authenticated user in this context, so
                // the RLS policy would otherwise reject the INSERT.
                jdbc.execute("SET LOCAL app.is_platform_admin = 'true'");
                jdbc.update(
                        "INSERT INTO user_notifications "
                                + "(id, tenant_id, user_id, kind, category, title, body, node_id, home_id, created_at) "
                                + "VALUES (?,?,?,?,?,?,?,?,?,now())",
                        UUID.randomUUID(), tenantId, userId, kind, category, title, body, nodeId, homeId);
                return null;
            });
        } catch (Exception e) {
            log.warn("notification persist failed kind={} user={}: {}", kind, userId, e.getMessage());
        }

        // Live push — best effort, tenant-scoped. The mobile client already
        // understands `notification.received` (it was written forward-compatible).
        try {
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("kind", kind);
            payload.put("category", mobileCategory(kind, category));
            payload.put("title", title);
            payload.put("body", body == null ? "" : body);
            if (nodeId != null) payload.put("nodeId", nodeId.toString());
            payload.put("timestamp", Instant.now().toString());
            wsEventBus.publishNotificationReceived(tenantId, payload);
        } catch (Exception e) {
            log.debug("notification WS push failed: {}", e.getMessage());
        }
    }

    /**
     * Fan a home-scoped event out to every active member of that home. Used for
     * events that are not tied to a single user (device went offline, etc.).
     */
    public void recordForHome(UUID tenantId,
                              UUID homeId,
                              String kind,
                              String category,
                              String title,
                              String body,
                              UUID nodeId) {
        if (tenantId == null || homeId == null) return;

        List<UUID> userIds = new ArrayList<>();
        try {
            txTemplate.execute(status -> {
                jdbc.execute("SET LOCAL app.is_platform_admin = 'true'");
                List<String> ids = jdbc.queryForList(
                        "SELECT user_id FROM home_members WHERE home_id = ? AND revoked_at IS NULL",
                        String.class, homeId);
                for (String s : ids) {
                    try {
                        userIds.add(UUID.fromString(s));
                    } catch (IllegalArgumentException ignored) {
                        // Skip a malformed id rather than losing the whole fan-out.
                    }
                }
                return null;
            });
        } catch (Exception e) {
            log.warn("notification member lookup failed home={}: {}", homeId, e.getMessage());
            return;
        }

        for (UUID uid : userIds) {
            record(tenantId, uid, kind, category, title, body, nodeId, homeId);
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /** DB category/kind → the mobile filter vocabulary (system / devices / security). */
    private static String mobileCategory(String kind, String storedCategory) {
        if ("security".equalsIgnoreCase(kind)) return "security";
        if ("presence".equalsIgnoreCase(kind)) return "devices";
        if ("SECURITY".equalsIgnoreCase(storedCategory)) return "security";
        return "system";
    }

    private AuthenticatedUser currentUser() {
        Object principal = SecurityContextHolder.getContext().getAuthentication() != null
                ? SecurityContextHolder.getContext().getAuthentication().getPrincipal()
                : null;
        if (principal instanceof AuthenticatedUser u) return u;
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }
}
