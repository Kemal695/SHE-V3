package et.she.v3.service.impl;

import et.she.v3.dto.HomeDtos;
import et.she.v3.entity.Home;
import et.she.v3.entity.HomeMember;
import et.she.v3.entity.Room;
import et.she.v3.entity.User;
import et.she.v3.errors.SheException;
import et.she.v3.repository.HomeMemberRepository;
import et.she.v3.repository.HomeRepository;
import et.she.v3.repository.RoomRepository;
import et.she.v3.repository.UserRepository;
import et.she.v3.security.AuthenticatedUser;
import et.she.v3.service.HomeService;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

@Service
@Transactional
public class HomeServiceImpl implements HomeService {

    private final HomeRepository homeRepository;
    private final RoomRepository roomRepository;
    private final HomeMemberRepository homeMemberRepository;
    private final UserRepository userRepository;

    public HomeServiceImpl(HomeRepository homeRepository, RoomRepository roomRepository,
                           HomeMemberRepository homeMemberRepository, UserRepository userRepository) {
        this.homeRepository = homeRepository;
        this.roomRepository = roomRepository;
        this.homeMemberRepository = homeMemberRepository;
        this.userRepository = userRepository;
    }

    @Override
    public HomeDtos.HomeResponse create(HomeDtos.CreateHomeRequest req) {
        AuthenticatedUser user = currentUser();
        Home home = new Home();
        home.setTenantId(user.tenantId());
        home.setOwnerUserId(user.userId());
        home.setName(req.name());
        home.setAddress(req.address());
        home = homeRepository.save(home);

        // Auto-add owner as OWNER role in home_members
        HomeMember member = new HomeMember();
        member.setTenantId(user.tenantId());
        member.setHomeId(home.getId());
        member.setUserId(user.userId());
        member.setRole("OWNER");
        member.setGrantedByUserId(user.userId());
        homeMemberRepository.save(member);

        return toResponse(home);
    }

    @Override
    @Transactional(readOnly = true)
    public List<HomeDtos.HomeResponse> list() {
        AuthenticatedUser user = currentUser();
        // Scope to homes the current user is an active member of — NOT all homes
        // in the tenant (findAllByTenantId leaks other users' homes across B2C users).
        List<UUID> memberHomeIds = homeMemberRepository.findActiveByUserId(user.userId()).stream()
                .map(HomeMember::getHomeId)
                .toList();
        if (memberHomeIds.isEmpty()) {
            return List.of();
        }
        return homeRepository.findAllById(memberHomeIds).stream()
                .filter(h -> h.getDeletedAt() == null)
                .sorted((a, b) -> b.getCreatedAt().compareTo(a.getCreatedAt()))
                .map(this::toResponse)
                .toList();
    }

    @Override
    @Transactional(readOnly = true)
    public HomeDtos.HomeResponse getById(UUID id) {
        Home home = getAuthorizedHomeOrThrow(id, "GUEST");
        return toResponse(home);
    }

    @Override
    public HomeDtos.HomeResponse update(UUID id, HomeDtos.UpdateHomeRequest req) {
        Home home = getAuthorizedHomeOrThrow(id, "ADMIN");
        if (req.name() != null) home.setName(req.name());
        if (req.address() != null) home.setAddress(req.address());
        homeRepository.save(home);
        return toResponse(home);
    }

    @Override
    public void delete(UUID id) {
        Home home = getAuthorizedHomeOrThrow(id, "OWNER");
        home.setDeletedAt(Instant.now());
        homeRepository.save(home);
    }

    // =========================================================================
    // Rooms
    // =========================================================================

    @Override
    public HomeDtos.RoomResponse createRoom(UUID homeId, HomeDtos.CreateRoomRequest req) {
        AuthenticatedUser user = currentUser();
        getAuthorizedHomeOrThrow(homeId, "ADMIN");

        Room room = new Room();
        room.setTenantId(user.tenantId());
        room.setHomeId(homeId);
        room.setName(req.name());
        room.setIcon(req.icon());
        room.setSortOrder(req.sort_order() != null ? req.sort_order() : 0);
        room = roomRepository.save(room);
        return toRoomResponse(room);
    }

    @Override
    @Transactional(readOnly = true)
    public List<HomeDtos.RoomResponse> listRooms(UUID homeId) {
        getAuthorizedHomeOrThrow(homeId, "GUEST");
        return roomRepository.findAllByHomeId(homeId).stream()
                .map(this::toRoomResponse)
                .toList();
    }

    @Override
    public HomeDtos.RoomResponse updateRoom(UUID homeId, UUID roomId, HomeDtos.UpdateRoomRequest req) {
        getAuthorizedHomeOrThrow(homeId, "ADMIN");
        Room room = roomRepository.findActiveById(roomId)
                .orElseThrow(() -> new SheException("ROOM_NOT_FOUND", "Room " + roomId + " not found", 404));
        if (!room.getHomeId().equals(homeId)) {
            throw new SheException("ROOM_NOT_FOUND", "Room does not belong to home", 404);
        }
        if (req.name() != null) room.setName(req.name());
        if (req.icon() != null) room.setIcon(req.icon());
        if (req.sort_order() != null) room.setSortOrder(req.sort_order());
        roomRepository.save(room);
        return toRoomResponse(room);
    }

    @Override
    public void deleteRoom(UUID homeId, UUID roomId) {
        getAuthorizedHomeOrThrow(homeId, "ADMIN");
        Room room = roomRepository.findActiveById(roomId)
                .orElseThrow(() -> new SheException("ROOM_NOT_FOUND", "Room " + roomId + " not found", 404));
        if (!room.getHomeId().equals(homeId)) {
            throw new SheException("ROOM_NOT_FOUND", "Room does not belong to home", 404);
        }
        room.setDeletedAt(Instant.now());
        roomRepository.save(room);
    }

    // =========================================================================
    // Members
    // =========================================================================

    @Override
    @Transactional(readOnly = true)
    public List<HomeDtos.MemberResponse> listMembers(UUID homeId) {
        getAuthorizedHomeOrThrow(homeId, "GUEST");
        return homeMemberRepository.findActiveByHomeId(homeId).stream()
                .map(m -> {
                    User u = userRepository.findById(m.getUserId()).orElse(null);
                    return new HomeDtos.MemberResponse(
                            m.getUserId(),
                            u != null ? u.getEmail() : null,
                            u != null ? u.getFullName() : null,
                            m.getRole(),
                            m.getGrantedAt().toString()
                    );
                })
                .toList();
    }

    @Override
    public HomeDtos.MemberResponse addMember(UUID homeId, HomeDtos.AddMemberRequest req) {
        AuthenticatedUser user = currentUser();
        getAuthorizedHomeOrThrow(homeId, "ADMIN");

        // Look up user by email within the tenant
        User invitee = userRepository.findActiveByEmail(user.tenantId(), req.email())
                .orElseThrow(() -> new SheException("USER_NOT_FOUND",
                        "User " + req.email() + " not found in this tenant", 404));

        if (!req.role().matches("^(OWNER|ADMIN|MEMBER|GUEST)$")) {
            throw new SheException("VALIDATION_FAILED", "role must be OWNER|ADMIN|MEMBER|GUEST", 400);
        }

        HomeMember member = new HomeMember();
        member.setTenantId(user.tenantId());
        member.setHomeId(homeId);
        member.setUserId(invitee.getId());
        member.setRole(req.role());
        member.setGrantedByUserId(user.userId());
        member = homeMemberRepository.save(member);

        return new HomeDtos.MemberResponse(invitee.getId(), invitee.getEmail(), invitee.getFullName(),
                member.getRole(), member.getGrantedAt().toString());
    }

    @Override
    public HomeDtos.MemberResponse updateMember(UUID homeId, UUID userId, HomeDtos.UpdateMemberRequest req) {
        getAuthorizedHomeOrThrow(homeId, "ADMIN");
        HomeMember member = homeMemberRepository.findActiveByHomeAndUser(homeId, userId)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "Member not found", 404));
        if (!req.role().matches("^(OWNER|ADMIN|MEMBER|GUEST)$")) {
            throw new SheException("VALIDATION_FAILED", "role must be OWNER|ADMIN|MEMBER|GUEST", 400);
        }
        member.setRole(req.role());
        homeMemberRepository.save(member);
        User u = userRepository.findById(userId).orElse(null);
        return new HomeDtos.MemberResponse(userId, u != null ? u.getEmail() : null,
                u != null ? u.getFullName() : null, member.getRole(), member.getGrantedAt().toString());
    }

    @Override
    public void removeMember(UUID homeId, UUID userId) {
        getAuthorizedHomeOrThrow(homeId, "ADMIN");
        HomeMember member = homeMemberRepository.findActiveByHomeAndUser(homeId, userId)
                .orElseThrow(() -> new SheException("USER_NOT_FOUND", "Member not found", 404));
        if ("OWNER".equals(member.getRole())) {
            throw new SheException("RBAC_LAST_OWNER_CANNOT_LEAVE",
                    "Owner cannot be removed — transfer ownership first", 409);
        }
        member.setRevokedAt(Instant.now());
        homeMemberRepository.save(member);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private Home getAuthorizedHomeOrThrow(UUID homeId, String minRole) {
        AuthenticatedUser user = currentUser();
        Home home = homeRepository.findActiveById(homeId)
                .orElseThrow(() -> new SheException("HOME_NOT_FOUND", "Home " + homeId + " not found", 404));

        if (!home.getTenantId().equals(user.tenantId()) && !user.isSuperAdmin()) {
            throw new SheException("RBAC_INSUFFICIENT_ROLE", "Access denied to home in another tenant", 403);
        }

        boolean isTenantAdmin = "TENANT_ADMIN".equals(user.tenantRole()) || user.isBypassCapable();
        if (user.isSuperAdmin() || isTenantAdmin) {
            return home;
        }

        HomeMember member = homeMemberRepository.findActiveByHomeAndUser(homeId, user.userId())
                .orElseThrow(() -> new SheException("RBAC_INSUFFICIENT_ROLE", "User is not a member of this home", 403));

        if (minRole != null && !hasSufficientRole(member.getRole(), minRole)) {
            throw new SheException("RBAC_INSUFFICIENT_ROLE", "Required role: " + minRole, 403);
        }
        return home;
    }

    private boolean hasSufficientRole(String userRole, String minRole) {
        int userLevel = roleLevel(userRole);
        int minLevel = roleLevel(minRole);
        return userLevel >= minLevel;
    }

    private int roleLevel(String role) {
        return switch (role != null ? role.toUpperCase() : "") {
            case "OWNER" -> 4;
            case "ADMIN" -> 3;
            case "MEMBER" -> 2;
            case "GUEST" -> 1;
            default -> 0;
        };
    }

    private HomeDtos.HomeResponse toResponse(Home h) {
        return new HomeDtos.HomeResponse(h.getId(), h.getName(), h.getAddress(),
                h.getOwnerUserId(), h.getCreatedAt().toString());
    }

    private HomeDtos.RoomResponse toRoomResponse(Room r) {
        return new HomeDtos.RoomResponse(r.getId(), r.getName(), r.getIcon(),
                r.getSortOrder(), r.getCreatedAt().toString());
    }

    private AuthenticatedUser currentUser() {
        return (AuthenticatedUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
    }
}
