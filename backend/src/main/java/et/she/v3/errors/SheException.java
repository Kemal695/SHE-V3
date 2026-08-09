package et.she.v3.errors;

import java.util.Map;

/**
 * Root exception for all SHE-domain errors.
 *
 * Mapped to the canonical error envelope by {@link GlobalExceptionHandler}:
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
 * Codes are part of the public API contract (V3-ERROR-CODES.md §12.1) — once shipped
 * they cannot be renamed, only deprecated with a 12-month sunset.
 */
public class SheException extends RuntimeException {

    private final String code;
    private final int httpStatus;
    private final Map<String, Object> details;

    public SheException(String code, String message, int httpStatus) {
        super(message);
        this.code = code;
        this.httpStatus = httpStatus;
        this.details = null;
    }

    public SheException(String code, String message, int httpStatus, Throwable cause) {
        super(message, cause);
        this.code = code;
        this.httpStatus = httpStatus;
        this.details = null;
    }

    public SheException(String code, String message, int httpStatus, Map<String, Object> details) {
        super(message);
        this.code = code;
        this.httpStatus = httpStatus;
        this.details = details;
    }

    public String getCode()      { return code; }
    public int    getHttpStatus(){ return httpStatus; }
    public Map<String, Object> getDetails() { return details; }
}
