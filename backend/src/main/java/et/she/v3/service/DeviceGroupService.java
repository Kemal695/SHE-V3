package et.she.v3.service;

import com.fasterxml.jackson.annotation.JsonProperty;
import et.she.v3.dto.NodeDtos;
import et.she.v3.entity.NodeDevice;
import et.she.v3.entity.NodeGroup;
import et.she.v3.entity.NodeGroupMember;
import et.she.v3.errors.SheException;
import et.she.v3.repository.NodeDeviceRepository;
import et.she.v3.repository.NodeGroupMemberRepository;
import et.she.v3.repository.NodeGroupRepository;
import et.she.v3.repository.NodeRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.*;

/**
 * Device group service — custom, device-level groups ("Bedroom", "Outside").
 *
 * Groups live in {@code node_groups} (group_type = CUSTOM, migration V11) and
 * their members in {@code node_group_members} with a {@code device_id}
 * (migration V36). A group can span several relays of the same board, which the
 * V11 node-level unique constraint would have blocked.
 *
 * Turning a group on/off REUSES {@link NodeService#writeParams} — same rationale
 * as {@link SceneService#activate}: that path resolves the node → MQTT topic,
 * updates the desired-state cache and writes the audit row. One write per member
 * device; a single failure is reported, never fatal.
 */
@Service
public class DeviceGroupService {

    private static final Logger log = LoggerFactory.getLogger(DeviceGroupService.class);

    private final NodeGroupRepository groupRepository;
    private final NodeGroupMemberRepository memberRepository;
    private final NodeDeviceRepository nodeDeviceRepository;
    private final NodeRepository nodeRepository;
    private final NodeService nodeService;

    public DeviceGroupService(NodeGroupRepository groupRepository,
                              NodeGroupMemberRepository memberRepository,
                              NodeDeviceRepository nodeDeviceRepository,
                              NodeRepository nodeRepository,
                              NodeService nodeService) {
        this.groupRepository = groupRepository;
        this.memberRepository = memberRepository;
        this.nodeDeviceRepository = nodeDeviceRepository;
        this.nodeRepository = nodeRepository;
        this.nodeService = nodeService;
    }

    // ─── DTOs ────────────────────────────────────────────────────────────────
    /** Field names are snake_case on the wire; the project's Jackson strategy is camelCase. */
    public record GroupRequest(
            String name,
            @JsonProperty("device_ids") List<UUID> deviceIds,
            /**
             * Optional icon key for the card (e.g. "lights"). Null leaves the
             * existing value untouched on update; the client falls back to
             * deriving an icon from the members' role names when it is absent.
             * (Migration V37.)
             */
            String icon,
            /**
             * Optional hero image key for the detail page (e.g. "home-dusk").
             * Null → the hero shows the icon only, no photo. (Migration V37.)
             */
            String image
    ) {}

    public record SetRequest(boolean on) {}

    public record RenameDeviceRequest(
            @JsonProperty("display_name") String displayName
    ) {}

    /**
     * Serialised with snake_case keys to match the rest of the API — the mobile
     * app reads `device_ids`. It used to emit `deviceIds`, and the mismatch meant
     * the app always saw an empty member list (group showed "0 device(s)" and no
     * devices when expanded) even though the membership was saved correctly.
     */
    public record GroupOut(UUID id, UUID homeId, String name,
                           @JsonProperty("device_ids") List<UUID> deviceIds,
                           String icon,
                           String image,
                           Instant createdAt) {}

    public record SetResult(UUID groupId, int accepted, List<String> failed) {}

    // ─── Queries ─────────────────────────────────────────────────────────────
    @Transactional(readOnly = true)
    public List<GroupOut> list(UUID homeId) {
        return groupRepository.findAllByHomeId(homeId).stream().map(this::toOut).toList();
    }

    // ─── Mutations ───────────────────────────────────────────────────────────
    @Transactional
    public GroupOut create(UUID homeId, GroupRequest req) {
        if (req == null || req.name() == null || req.name().isBlank()) {
            throw new SheException("VALIDATION_ERROR", "Group name is required", 422);
        }
        NodeGroup g = new NodeGroup();
        g.setTenantId(currentTenantId());
        g.setHomeId(homeId);
        g.setName(req.name().trim());
        g.setGroupType(NodeGroup.TYPE_CUSTOM);
        // V37 — icon + hero image keys. Optional; null simply means "derive the
        // icon from the members" / "no hero photo".
        g.setIcon(req.icon());
        g.setImage(req.image());
        g = groupRepository.save(g);
        replaceMembers(g, req.deviceIds());
        return toOut(g);
    }

    @Transactional
    public GroupOut update(UUID id, GroupRequest req) {
        NodeGroup g = requireGroup(id);
        if (req != null && req.name() != null && !req.name().isBlank()) g.setName(req.name().trim());
        // Only overwrite when the key was actually supplied — an update that
        // omits the fields (e.g. a rename from an older client) must not wipe
        // a previously chosen icon or hero image.
        if (req != null && req.icon() != null) g.setIcon(req.icon());
        if (req != null && req.image() != null) g.setImage(req.image());
        g = groupRepository.save(g);
        if (req != null && req.deviceIds() != null) replaceMembers(g, req.deviceIds());
        return toOut(g);
    }

    @Transactional
    public void delete(UUID id) {
        NodeGroup g = requireGroup(id);
        memberRepository.deleteAllByGroupId(g.getId());
        g.setDeletedAt(Instant.now());
        groupRepository.save(g);
    }

    /** Turn every member device on/off. One write per device; never aborts on one failure. */
    @Transactional
    public SetResult set(UUID id, boolean on) {
        NodeGroup g = requireGroup(id);
        List<NodeGroupMember> members = memberRepository.findAllByGroupId(g.getId());

        int accepted = 0;
        List<String> failed = new ArrayList<>();
        for (NodeGroupMember m : members) {
            if (m.getNodeId() == null || m.getDeviceId() == null) continue;
            String label = nodeDeviceRepository.findById(m.getDeviceId())
                    .map(d -> d.getDisplayName() != null && !d.getDisplayName().isBlank()
                            ? d.getDisplayName() : d.getDeviceName())
                    .orElse(m.getDeviceId().toString());
            try {
                NodeDtos.WriteParamsResponse res = nodeService.writeParams(
                        m.getNodeId(), m.getDeviceId(),
                        new NodeDtos.WriteParamsRequest(Map.of("Power", on)));
                if (res != null && res.accepted()) accepted++;
                else failed.add(label);
            } catch (Exception e) {
                log.warn("Group {} set failed for device {}: {}", id, m.getDeviceId(), e.getMessage());
                failed.add(label);
            }
        }
        return new SetResult(g.getId(), accepted, failed);
    }

    /** Rename one device — writes node_devices.display_name. */
    @Transactional
    public NodeDtos.DeviceResponse renameDevice(UUID nodeId, UUID deviceId, String displayName) {
        nodeService.requireNodeAccess(nodeId, "MEMBER");

        NodeDevice d = nodeDeviceRepository.findById(deviceId)
                .orElseThrow(() -> new SheException("DEVICE_NOT_FOUND", "Device not found", 404));
        if (!nodeId.equals(d.getNodeId())) {
            throw new SheException("DEVICE_NOT_FOUND", "Device does not belong to that node", 404);
        }
        d.setDisplayName(displayName == null || displayName.isBlank() ? null : displayName.trim());
        nodeDeviceRepository.save(d);

        return new NodeDtos.DeviceResponse(d.getId(), d.getDeviceName(), d.getDeviceType(),
                d.getDisplayName(), d.getChannelIndex(), d.getAttributes(), d.isService());
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────
    private void replaceMembers(NodeGroup g, List<UUID> deviceIds) {
        memberRepository.deleteAllByGroupId(g.getId());
        if (deviceIds == null || deviceIds.isEmpty()) return;

        for (UUID deviceId : new LinkedHashSet<>(deviceIds)) {
            if (deviceId == null) continue;
            NodeDevice d = nodeDeviceRepository.findById(deviceId).orElse(null);
            if (d == null) {
                log.warn("Group {} references unknown device {} — skipped", g.getId(), deviceId);
                continue;
            }
            // The device must belong to a node in THIS group's home. RLS only
            // isolates by tenant, so without this check a member of one home
            // could add another home's devices to their own group.
            boolean sameHome = nodeRepository.findById(d.getNodeId())
                    .map(n -> g.getHomeId().equals(n.getHomeId()))
                    .orElse(false);
            if (!sameHome) {
                log.warn("Group {} (home {}) references device {} from another home — skipped",
                        g.getId(), g.getHomeId(), deviceId);
                continue;
            }
            NodeGroupMember m = new NodeGroupMember();
            m.setTenantId(g.getTenantId());
            m.setGroupId(g.getId());
            m.setNodeId(d.getNodeId());
            m.setDeviceId(d.getId());
            memberRepository.save(m);
        }
    }

    private NodeGroup requireGroup(UUID id) {
        return groupRepository.findByIdAndNotDeleted(id)
                .orElseThrow(() -> new SheException("GROUP_NOT_FOUND", "Group not found", 404));
    }

    private GroupOut toOut(NodeGroup g) {
        List<UUID> deviceIds = memberRepository.findAllByGroupId(g.getId()).stream()
                .map(NodeGroupMember::getDeviceId)
                .filter(Objects::nonNull)
                .toList();
        return new GroupOut(g.getId(), g.getHomeId(), g.getName(), deviceIds,
                            g.getIcon(), g.getImage(), g.getCreatedAt());
    }

    private UUID currentTenantId() {
        Object principal = SecurityContextHolder.getContext().getAuthentication() != null
                ? SecurityContextHolder.getContext().getAuthentication().getPrincipal()
                : null;
        if (principal instanceof et.she.v3.security.AuthenticatedUser u) return u.tenantId();
        throw new SheException("AUTH_TOKEN_INVALID", "No authenticated user", 401);
    }
}
