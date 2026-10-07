package et.she.v3.repository;

import et.she.v3.entity.NodeGroupMember;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface NodeGroupMemberRepository extends JpaRepository<NodeGroupMember, UUID> {

    @Query("SELECT m FROM NodeGroupMember m WHERE m.groupId = :groupId ORDER BY m.createdAt")
    List<NodeGroupMember> findAllByGroupId(@Param("groupId") UUID groupId);

    /**
     * Bulk DELETE executed synchronously (NOT queued through the persistence
     * context). This is required: when a group is edited we delete its members
     * and then re-insert the same (group_id, device_id) rows. Hibernate flushes
     * inserts BEFORE deletions, so the previous derived load-then-remove would
     * attempt the INSERT while the old row was still present and trip the
     * uq_ngm_group_device unique index. A direct DELETE runs immediately,
     * clearing the rows before the new inserts are queued.
     *
     * RLS still applies (the TenantContextAspect sets app.tenant_id inside the
     * surrounding @Transactional), so only this tenant's rows are removed.
     */
    @Modifying
    @Query("DELETE FROM NodeGroupMember m WHERE m.groupId = :groupId")
    void deleteAllByGroupId(@Param("groupId") UUID groupId);
}
