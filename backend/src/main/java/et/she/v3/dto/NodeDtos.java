package et.she.v3.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.util.Map;
import java.util.UUID;

/**
 * DTOs for the Node domain — Phase 1's core endpoints.
 * V3-API-SPECIFICATION §6. V3-DEVICE-MODEL §1.8.
 */
public class NodeDtos {

    // ─── POST /api/v3/nodes/claim (BLE provisioning) ─────────────────────────
    /**
     * V3-FIRMWARE §5.1 + P0-1: BLE provisioning does NOT issue certs.
     * Cert is factory-issued. This endpoint only creates/updates the `nodes` row.
     */
    public record ClaimRequest(
            @NotBlank @Pattern(regexp = "^[0-9a-fA-F:]{12,17}$",
                    message = "mac must be 12 hex chars or AA:BB:CC:DD:EE:FF")
            String mac,

            @NotBlank String claim_token,    // 10-min TTL JWT from /api/v3/auth/claim-token
            @NotBlank @Pattern(regexp = "^(SHE-R4|SHE-R8|SHE-R16|SHE-R24)$") String sku,
            UUID home_id,                    // optional — device can be unassigned initially
            Map<String, Object> config       // node self-description (devices, services, params)
    ) {}

    public record ClaimResponse(
            UUID node_db_id,
            String mqtt_broker,
            String node_id                   // SHE-R8-AABBCC
    ) {}

    // ─── GET /api/v3/nodes/{id} ──────────────────────────────────────────────
    public record NodeResponse(
            UUID id,
            String node_id,                  // SHE-R8-AABBCC
            String mac_address,
            String normalized_mac,
            String sku,
            String name,
            String firmware_version,
            String hardware_revision,
            boolean is_online,
            String last_seen_at,
            String provisioned_at,
            UUID home_id,
            UUID room_id
    ) {}

    // ─── GET /api/v3/nodes/{id}/devices ──────────────────────────────────────
    public record DeviceResponse(
            UUID id,
            String device_name,              // "Relay 1"
            String device_type,              // esp.device.switch
            String display_name,             // "Kitchen Light"
            Short channel_index,
            Map<String, Object> attributes,
            boolean is_service
    ) {}

    // ─── GET /api/v3/nodes/{id}/devices/{deviceId}/params ────────────────────
    public record ParamResponse(
            UUID id,
            String param_name,               // "Power"
            String param_type,               // esp.param.power
            String data_type,                // bool | int | float | string
            String ui_hint,                  // toggle | slider | segmented | read_only
            java.util.List<String> properties,  // ["read","write","persist"]
            Object last_value,
            Object reported_value,           // V38 — device-reported only (source of truth)
            String last_reported_at,
            Double min_value,
            Double max_value
    ) {}

    // ─── PUT /api/v3/nodes/{id}/devices/{deviceId}/params ────────────────────
    /**
     * V3-MQTT-STANDARDS §3.4 — write parameter command.
     * Body: {"Power": true} or {"Brightness": 75}
     */
    public record WriteParamsRequest(Map<String, Object> params) {

        /**
         * Normalize a raw request body into the canonical params map.
         *
         * Canonical contract (V3-API-SPECIFICATION §6) is a FLAT body:
         *   {"Power": true}   or   {"Power": true, "Brightness": 75}
         *
         * Early clients instead sent a WRAPPED body:
         *   {"params": {"Power": true}}
         *
         * Both are accepted so the documented contract works without breaking
         * existing callers. The wrapped form is deprecated — remove it once all
         * clients send the flat shape.
         */
        public static WriteParamsRequest of(Map<String, Object> body) {
            if (body != null && body.size() == 1 && body.get("params") instanceof Map<?, ?> nested) {
                @SuppressWarnings("unchecked")
                Map<String, Object> unwrapped = (Map<String, Object>) nested;
                return new WriteParamsRequest(unwrapped);
            }
            return new WriteParamsRequest(body);
        }
    }

    public record WriteParamsResponse(
            UUID nodeId,
            UUID deviceId,
            Map<String, ParamAck> params,
            boolean accepted
    ) {}

    public record ParamAck(Object last_value, String last_reported_at) {}

    // ─── GET /api/v3/nodes/{id}/telemetry ────────────────────────────────────
    public record TelemetryQuery(
            String from,                     // ISO-8601
            String to,                       // ISO-8601
            String param,                    // optional param filter
            String bucket                    // 5m | 1h | 1d (default 5m)
    ) {}

    public record TelemetryResponse(
            UUID nodeId,
            String bucket,
            java.util.List<TelemetryPoint> points
    ) {}

    public record TelemetryPoint(String time, String param_name, double value, String unit) {}

    // ─── POST /api/v3/nodes/{id}/ota ─────────────────────────────────────────
    public record TriggerOtaRequest(@NotBlank String version) {}

    public record TriggerOtaResponse(UUID batch_id, UUID approval_id, boolean accepted) {}

    // ─── POST /api/v3/nodes/{id}/commands ────────────────────────────────────
    /**
     * Out-of-band system command (V3-MQTT-STANDARDS §3.2).
     *
     * `cmd` is validated against a fixed set before publishing. Deliberately NOT free-form:
     * an unrecognised value must be rejected here rather than published for the device to
     * guess at, because one of these commands wipes the device.
     */
    /**
     * cmd + reason, plus OPTIONAL fields used only by `schedule_add`.
     *
     * Kept as flat extra fields rather than a nested object so the published MQTT
     * payload stays flat, matching the other server→device directions
     * (params/remote, ota/url) and the device's cJSON parsing.
     *
     * days_mask: bit0=Sun … bit6=Sat. 127 = every day; a subset = those weekdays;
     * 0 (or omitted) = ONE-SHOT, which fires once and then disables itself.
     */
    public record CommandRequest(
            @NotBlank String cmd,
            String reason,
            Integer hour,
            Integer minute,
            Integer days_mask,
            Integer relay,
            Integer action,
            /**
             * group_set only: which master to drive — "lights" | "sockets" | "all".
             *
             * A master is an intent over a GROUP of channels, not a channel of its
             * own (ADR-015), so it cannot be expressed as a params write. Kept as a
             * closed set of names rather than a raw bitmask so a client cannot
             * energise an arbitrary combination of circuits by guessing bits.
             */
            String group,
            /** group_set only: target state for the whole group. */
            Boolean on
    ) {}

    public record CommandResponse(UUID nodeId, String cmd, boolean accepted, String topic) {}
}
