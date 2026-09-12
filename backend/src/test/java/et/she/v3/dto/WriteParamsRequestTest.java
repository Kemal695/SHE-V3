package et.she.v3.dto;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for {@link NodeDtos.WriteParamsRequest#of(Map)} — the request-body
 * normalization for PUT /api/v3/nodes/{id}/devices/{deviceId}/params.
 *
 * Canonical contract (V3-API-SPECIFICATION §6) is a FLAT body:
 *   {"Power": true}
 * The legacy wrapped form {"params": {"Power": true}} must still be accepted so
 * existing callers keep working during the transition.
 */
class WriteParamsRequestTest {

    @Test
    @DisplayName("Flat body (canonical) is passed through unchanged")
    void flatBodyPassedThrough() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("Power", true);

        NodeDtos.WriteParamsRequest req = NodeDtos.WriteParamsRequest.of(body);

        assertEquals(1, req.params().size());
        assertEquals(Boolean.TRUE, req.params().get("Power"));
    }

    @Test
    @DisplayName("Flat body with multiple params is passed through unchanged")
    void flatBodyMultipleParams() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("Power", true);
        body.put("Brightness", 75);

        NodeDtos.WriteParamsRequest req = NodeDtos.WriteParamsRequest.of(body);

        assertEquals(2, req.params().size());
        assertEquals(Boolean.TRUE, req.params().get("Power"));
        assertEquals(75, req.params().get("Brightness"));
    }

    @Test
    @DisplayName("Legacy wrapped body is unwrapped")
    void legacyWrappedBodyUnwrapped() {
        Map<String, Object> nested = new LinkedHashMap<>();
        nested.put("Power", true);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("params", nested);

        NodeDtos.WriteParamsRequest req = NodeDtos.WriteParamsRequest.of(body);

        assertEquals(1, req.params().size());
        assertEquals(Boolean.TRUE, req.params().get("Power"),
                "wrapped {\"params\":{...}} must be unwrapped to the inner map");
    }

    @Test
    @DisplayName("A genuine single param literally named 'params' is not unwrapped when it isn't a map")
    void nonMapParamsValueIsNotUnwrapped() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("params", "not-a-map");

        NodeDtos.WriteParamsRequest req = NodeDtos.WriteParamsRequest.of(body);

        assertEquals(1, req.params().size());
        assertEquals("not-a-map", req.params().get("params"));
    }

    @Test
    @DisplayName("Null body yields null params rather than throwing")
    void nullBodyTolerated() {
        NodeDtos.WriteParamsRequest req = NodeDtos.WriteParamsRequest.of(null);
        assertNull(req.params());
    }
}
