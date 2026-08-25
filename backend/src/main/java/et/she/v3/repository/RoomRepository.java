package et.she.v3.repository;

import et.she.v3.entity.Room;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface RoomRepository extends JpaRepository<Room, UUID> {
    @Query("SELECT r FROM Room r WHERE r.homeId = :homeId AND r.deletedAt IS NULL ORDER BY r.sortOrder ASC")
    List<Room> findAllByHomeId(@Param("homeId") UUID homeId);

    @Query("SELECT r FROM Room r WHERE r.id = :id AND r.deletedAt IS NULL")
    Optional<Room> findActiveById(@Param("id") UUID id);
}
