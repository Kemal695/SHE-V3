package et.she.v3.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.UUID;

/**
 * DTOs for Home + Room + Member domain.
 * V3-API-SPECIFICATION §4-5.
 */
public class HomeDtos {

    // ─── Home ────────────────────────────────────────────────────────────────
    public record CreateHomeRequest(@NotBlank @Size(max = 100) String name, String address) {}

    public record UpdateHomeRequest(@Size(max = 100) String name, String address,
                                    Double latitude, Double longitude) {}

    public record HomeResponse(UUID id, String name, String address,
                               Double latitude, Double longitude,
                               UUID owner_user_id, String created_at) {}

    // ─── Room ────────────────────────────────────────────────────────────────
    public record CreateRoomRequest(@NotBlank @Size(max = 100) String name, String icon, Integer sort_order) {}

    public record UpdateRoomRequest(@Size(max = 100) String name, String icon, Integer sort_order) {}

    public record RoomResponse(UUID id, String name, String icon, int sort_order, String created_at) {}

    // ─── Member ──────────────────────────────────────────────────────────────
    public record AddMemberRequest(@NotBlank String email, @NotBlank String role) {}

    public record UpdateMemberRequest(@NotBlank String role) {}

    public record MemberResponse(UUID user_id, String email, String full_name, String role, String granted_at) {}

    public record TransferOwnershipRequest(java.util.UUID to_user_id) {}
}
