package et.she.v3.controller;

import et.she.v3.notification.NotificationService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * Notification inbox endpoints — the API behind the mobile Notifications screen
 * (design sheet #15).
 *
 * <p>V3-API-SPECIFICATION §12. The tables existed since V12 but no controller was
 * ever written, so the app had no way to read notification history — it could only
 * derive notifications from live WebSocket events. This exposes the inbox.</p>
 *
 * <p>Tenant isolation is enforced by RLS on {@code user_notifications}; every
 * handler runs {@code @Transactional} (inside the service) so the
 * {@code app.tenant_id} GUC is set for the connection.</p>
 */
@RestController
@RequestMapping("/api/v3")
public class NotificationController {

    private final NotificationService notificationService;

    public NotificationController(NotificationService notificationService) {
        this.notificationService = notificationService;
    }

    /** GET /api/v3/notifications/recent?limit=50 */
    @GetMapping("/notifications/recent")
    public ResponseEntity<Map<String, Object>> recent(
            @RequestParam(name = "limit", defaultValue = "50") int limit) {
        return ResponseEntity.ok(Map.of("data", notificationService.recent(limit)));
    }

    /** GET /api/v3/notifications/unread-count */
    @GetMapping("/notifications/unread-count")
    public ResponseEntity<Map<String, Object>> unreadCount() {
        return ResponseEntity.ok(Map.of("data", Map.of("count", notificationService.unreadCount())));
    }

    /** POST /api/v3/notifications/{id}/read */
    @PostMapping("/notifications/{id}/read")
    public ResponseEntity<Void> markRead(@PathVariable UUID id) {
        notificationService.markRead(id);
        return ResponseEntity.noContent().build();
    }

    /** POST /api/v3/notifications/read-all */
    @PostMapping("/notifications/read-all")
    public ResponseEntity<Map<String, Object>> markAllRead() {
        return ResponseEntity.ok(Map.of("data", Map.of("updated", notificationService.markAllRead())));
    }
}
