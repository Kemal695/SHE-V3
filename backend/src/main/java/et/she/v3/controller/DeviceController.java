package et.she.v3.controller;

import et.she.v3.dto.NodeDtos;
import et.she.v3.service.DeviceGroupService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

/**
 * Device-level endpoints: custom device groups + device rename.
 *
 * Groups (V3-DATABASE-DESIGN §4.8, migrations V11 + V36):
 *   GET    /api/v3/homes/{homeId}/device-groups
 *   POST   /api/v3/homes/{homeId}/device-groups   body {name, device_ids[]}
 *   PATCH  /api/v3/device-groups/{id}             body {name?, device_ids?}
 *   DELETE /api/v3/device-groups/{id}
 *   POST   /api/v3/device-groups/{id}/set         body {on}
 *
 * Rename one device (node_devices.display_name):
 *   PATCH  /api/v3/nodes/{nodeId}/devices/{deviceId}   body {display_name}
 *
 * The rename lives here rather than on NodeController so the existing
 * NodeService interface/impl stay untouched.
 */
@RestController
@RequestMapping("/api/v3")
public class DeviceController {

    private final DeviceGroupService deviceGroupService;

    public DeviceController(DeviceGroupService deviceGroupService) {
        this.deviceGroupService = deviceGroupService;
    }

    // ─── Groups ──────────────────────────────────────────────────────────────
    @GetMapping("/homes/{homeId}/device-groups")
    public ResponseEntity<Map<String, Object>> listGroups(@PathVariable UUID homeId) {
        return ResponseEntity.ok(Map.of("data", deviceGroupService.list(homeId)));
    }

    @PostMapping("/homes/{homeId}/device-groups")
    public ResponseEntity<Map<String, Object>> createGroup(@PathVariable UUID homeId,
                                                           @RequestBody DeviceGroupService.GroupRequest req) {
        return ResponseEntity.status(201).body(Map.of("data", deviceGroupService.create(homeId, req)));
    }

    @PatchMapping("/device-groups/{id}")
    public ResponseEntity<Map<String, Object>> updateGroup(@PathVariable UUID id,
                                                           @RequestBody DeviceGroupService.GroupRequest req) {
        return ResponseEntity.ok(Map.of("data", deviceGroupService.update(id, req)));
    }

    @DeleteMapping("/device-groups/{id}")
    public ResponseEntity<Void> deleteGroup(@PathVariable UUID id) {
        deviceGroupService.delete(id);
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/device-groups/{id}/set")
    public ResponseEntity<Map<String, Object>> setGroup(@PathVariable UUID id,
                                                        @RequestBody DeviceGroupService.SetRequest req) {
        boolean on = req != null && req.on();
        return ResponseEntity.ok(Map.of("data", deviceGroupService.set(id, on)));
    }

    // ─── Device rename ───────────────────────────────────────────────────────
    @PatchMapping("/nodes/{nodeId}/devices/{deviceId}")
    public ResponseEntity<Map<String, Object>> renameDevice(@PathVariable UUID nodeId,
                                                            @PathVariable UUID deviceId,
                                                            @RequestBody DeviceGroupService.RenameDeviceRequest req) {
        NodeDtos.DeviceResponse out = deviceGroupService.renameDevice(
                nodeId, deviceId, req == null ? null : req.displayName());
        return ResponseEntity.ok(Map.of("data", out));
    }
}
