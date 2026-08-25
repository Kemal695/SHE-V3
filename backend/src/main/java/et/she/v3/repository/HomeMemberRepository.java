package et.she.v3.repository;

import et.she.v3.entity.HomeMember;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface HomeMemberRepository extends JpaRepository<HomeMember, UUID> {
    @Query("SELECT m FROM HomeMember m WHERE m.homeId = :homeId AND m.revokedAt IS NULL")
    List<HomeMember> findActiveByHomeId(@Param("homeId") UUID homeId);

    @Query("SELECT m FROM HomeMember m WHERE m.homeId = :homeId AND m.userId = :userId AND m.revokedAt IS NULL")
    Optional<HomeMember> findActiveByHomeAndUser(@Param("homeId") UUID homeId, @Param("userId") UUID userId);

    @Query("SELECT m FROM HomeMember m WHERE m.userId = :userId AND m.revokedAt IS NULL")
    List<HomeMember> findActiveByUserId(@Param("userId") UUID userId);
}
