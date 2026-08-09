package et.she.v3.dto;

import java.util.List;
import java.util.Map;

/**
 * Paginated list response envelope (V3-API-SPECIFICATION §1).
 *
 * <pre>
 * {
 *   "data": [ ... ],
 *   "meta": { "next_cursor": "...", "has_more": true }
 * }
 * </pre>
 *
 * Cursor format: base64-encoded offset marker. Max page size 100.
 */
public record PagedResponse<T>(
        List<T> data,
        Map<String, Object> meta
) {
    public static <T> PagedResponse<T> of(List<T> data, String nextCursor, boolean hasMore, int total) {
        Map<String, Object> meta = new java.util.HashMap<>();
        meta.put("next_cursor", nextCursor);
        meta.put("has_more", hasMore);
        meta.put("total", total);
        return new PagedResponse<>(data, meta);
    }
}
