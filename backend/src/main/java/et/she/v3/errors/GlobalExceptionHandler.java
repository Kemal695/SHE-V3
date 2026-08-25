package et.she.v3.errors;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.http.MediaType;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Maps all exceptions to the canonical error envelope (V3-ERROR-CODES.md §1).
 *
 * Envelope:
 * <pre>
 * {
 *   "error": {
 *     "code": "USER_NOT_FOUND",
 *     "message": "User 8a3b... does not exist",
 *     "http_status": 404,
 *     "request_id": "req-uuid-...",
 *     "details": { ... }
 *   }
 * }
 * </pre>
 *
 * Codes are part of the public API contract (V3-ERROR-CODES.md §12.1) —
 * once shipped they cannot be renamed, only deprecated with a 12-month sunset.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    private final ObjectMapper objectMapper;

    public GlobalExceptionHandler(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    // =========================================================================
    // SHE-domain exceptions
    // =========================================================================

    @ExceptionHandler(SheException.class)
    public void sheException(SheException ex, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        writeError(resp, req, ex.getCode(), ex.getMessage(), ex.getHttpStatus(), ex.getDetails());
    }

    // =========================================================================
    // Validation
    // =========================================================================

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public void validation(MethodArgumentNotValidException ex, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        Map<String, Object> details = new HashMap<>();
        ex.getBindingResult().getFieldErrors().forEach(fe ->
            details.put(fe.getField(), fe.getDefaultMessage()));
        writeError(resp, req, "VALIDATION_FAILED", "Request validation failed", 400, details);
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public void illegalArg(IllegalArgumentException ex, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        writeError(resp, req, "VALIDATION_FAILED", ex.getMessage(), 400, null);
    }

    // =========================================================================
    // Security
    // =========================================================================

    public static void unauthorized(HttpServletRequest req, HttpServletResponse resp,
                                    AuthenticationException ex) throws IOException {
        writeErrorStatic(resp, req, "AUTH_TOKEN_INVALID", ex.getMessage(), 401);
    }

    public static void forbidden(HttpServletRequest req, HttpServletResponse resp,
                                 AccessDeniedException ex) throws IOException {
        writeErrorStatic(resp, req, "RBAC_FORBIDDEN", "Insufficient role for this action", 403);
    }

    @ExceptionHandler(AccessDeniedException.class)
    public void accessDenied(AccessDeniedException ex, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        writeError(resp, req, "RBAC_FORBIDDEN", "Insufficient role for this action", 403, null);
    }

    // =========================================================================
    // Catch-all
    // =========================================================================

    @ExceptionHandler(Exception.class)
    public void unhandled(Exception ex, HttpServletRequest req, HttpServletResponse resp) throws IOException {
        log.error("Unhandled exception — request_id={}", MDC.get("reqId"), ex);
        writeError(resp, req, "INTERNAL_ERROR", "An internal error occurred", 500, null);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private void writeError(HttpServletResponse resp, HttpServletRequest req,
                            String code, String message, int status,
                            Map<String, Object> details) throws IOException {
        resp.setStatus(status);
        resp.setContentType(MediaType.APPLICATION_JSON_VALUE);
        resp.setCharacterEncoding("UTF-8");

        Map<String, Object> error = new HashMap<>();
        error.put("code", code);
        error.put("message", message);
        error.put("http_status", status);
        String reqId = MDC.get("reqId");
        if (reqId == null) reqId = "req-" + UUID.randomUUID();
        error.put("request_id", reqId);
        if (details != null && !details.isEmpty()) {
            error.put("details", details);
        }

        Map<String, Object> body = new HashMap<>();
        body.put("error", error);

        objectMapper.writeValue(resp.getWriter(), body);
    }

    private static void writeErrorStatic(HttpServletResponse resp, HttpServletRequest req,
                                           String code, String message, int status) throws IOException {
        resp.setStatus(status);
        resp.setContentType(MediaType.APPLICATION_JSON_VALUE);
        resp.setCharacterEncoding("UTF-8");
        String reqId = MDC.get("reqId");
        if (reqId == null) reqId = "req-" + UUID.randomUUID();

        Map<String, Object> error = new HashMap<>();
        error.put("code", code);
        error.put("message", message != null ? message : "");
        error.put("http_status", status);
        error.put("request_id", reqId);

        Map<String, Object> body = new HashMap<>();
        body.put("error", error);

        new com.fasterxml.jackson.databind.ObjectMapper().writeValue(resp.getWriter(), body);
    }
}
