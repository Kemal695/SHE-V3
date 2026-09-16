package et.she.v3.service;

import et.she.v3.dto.NodeDtos;
import et.she.v3.entity.Node;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * Node service — Phase 1's core service.
 *
 * V3-API-SPECIFICATION §6. V3-DEVICE-MODEL §1.8. ADR-011 (RainMaker hierarchy).
 *
 * Key flows:
 *   - claim: BLE provisioning → creates/updates nodes row (P0-1: cert is factory-issued)
 *   - writeParams: user command → MQTT params/remote publish → device ACK → node_params.last_value update
 *   - getTelemetry: TimescaleDB time-series query
 */
public interface NodeService {

    /**
     * POST /api/v3/nodes/claim
     * Called by ESP32 during BLE provisioning. P0-1: does NOT issue cert (factory-issued).
     * Creates/updates the nodes row with tenant_id + home_id + config from device.
     */
     NodeDtos.ClaimResponse claim(NodeDtos.ClaimRequest req);

     /**
      * Throws 403/404 unless the caller may access the node with at least
      * {@code minRole} home membership (OWNER/ADMIN/MEMBER/GUEST).
      * Used by controllers that don't go through the other NodeService methods
      * (e.g. EnergyController).
      */
     void requireNodeAccess(java.util.UUID nodeId, String minRole);

    /**
     * GET /api/v3/homes/{homeId}/nodes
     */
    List<NodeDtos.NodeResponse> listByHome(UUID homeId);

    /**
     * GET /api/v3/nodes/{id}
     */
    NodeDtos.NodeResponse getById(UUID id);

    /**
     * PATCH /api/v3/nodes/{id} — update name/roomId
     */
    NodeDtos.NodeResponse update(UUID id, String name, UUID roomId);

    /**
     * DELETE /api/v3/nodes/{id} — soft delete + cert revocation + EMQX disconnect
     */
    void delete(UUID id);

    /**
     * GET /api/v3/nodes/{id}/devices
     */
    List<NodeDtos.DeviceResponse> listDevices(UUID nodeId);

    /**
     * GET /api/v3/nodes/{id}/devices/{deviceId}/params
     */
    List<NodeDtos.ParamResponse> listParams(UUID nodeId, UUID deviceId);

    /**
     * PUT /api/v3/nodes/{id}/devices/{deviceId}/params
     * V3-MQTT-STANDARDS §3.4 — publishes to she/.../params/remote (QoS 1).
     */
    NodeDtos.WriteParamsResponse writeParams(UUID nodeId, UUID deviceId, NodeDtos.WriteParamsRequest req);

    /**
     * GET /api/v3/nodes/{id}/telemetry?from=&to=&param=&bucket=
     */
    NodeDtos.TelemetryResponse getTelemetry(UUID nodeId, Instant from, Instant to, String param, String bucket);

    /**
     * POST /api/v3/nodes/{id}/commands — out-of-band system command
     * (reboot / factory_reset / sync_time / ping). V3-MQTT-STANDARDS §3.2.
     */
    NodeDtos.CommandResponse executeCommand(UUID nodeId, NodeDtos.CommandRequest req);
}
