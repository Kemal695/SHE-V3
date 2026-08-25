package et.she.v3.service;

import et.she.v3.dto.HomeDtos;
import et.she.v3.entity.Home;
import et.she.v3.entity.Room;

import java.util.List;
import java.util.UUID;

public interface HomeService {
    HomeDtos.HomeResponse create(HomeDtos.CreateHomeRequest req);
    List<HomeDtos.HomeResponse> list();
    HomeDtos.HomeResponse getById(UUID id);
    HomeDtos.HomeResponse update(UUID id, HomeDtos.UpdateHomeRequest req);
    void delete(UUID id);

    // Rooms
    HomeDtos.RoomResponse createRoom(UUID homeId, HomeDtos.CreateRoomRequest req);
    List<HomeDtos.RoomResponse> listRooms(UUID homeId);
    HomeDtos.RoomResponse updateRoom(UUID homeId, UUID roomId, HomeDtos.UpdateRoomRequest req);
    void deleteRoom(UUID homeId, UUID roomId);

    // Members
    List<HomeDtos.MemberResponse> listMembers(UUID homeId);
    HomeDtos.MemberResponse addMember(UUID homeId, HomeDtos.AddMemberRequest req);
    HomeDtos.MemberResponse updateMember(UUID homeId, UUID userId, HomeDtos.UpdateMemberRequest req);
    void removeMember(UUID homeId, UUID userId);
}
