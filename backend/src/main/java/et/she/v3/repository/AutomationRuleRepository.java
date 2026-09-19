package et.she.v3.repository;

import et.she.v3.entity.AutomationRule;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface AutomationRuleRepository extends JpaRepository<AutomationRule, UUID> {

    @Query("SELECT r FROM AutomationRule r WHERE r.automationId = :automationId ORDER BY r.sortOrder, r.createdAt")
    List<AutomationRule> findAllByAutomationId(@Param("automationId") UUID automationId);
}
