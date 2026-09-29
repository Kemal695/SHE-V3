package et.she.v3.repository;

import et.she.v3.entity.NodeGroupMember;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface NodeGroupMemberRepository extends JpaRepository<NodeGroupMember, UUID> {

    @Query("SELECT m FROM NodeGroupMember m WHERE m.groupId = :groupId ORDER BY m.createdAt")
    List<NodeGroupMember> findAllByGroupId(@Param("groupId") UUID groupId);

    /** Derived delete — Spring Data loads then removes, so it must run in a transaction. */
    void deleteAllByGroupId(UUID groupId);
}
