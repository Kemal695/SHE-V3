package et.she.v3.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.transaction.annotation.EnableTransactionManagement;

/**
 * Pins the transaction advisor to the OUTERMOST slot of the AOP chain.
 *
 * <p><b>Why this exists.</b> {@link et.she.v3.security.TenantContextAspect} issues
 * {@code SET LOCAL app.tenant_id} / {@code SET LOCAL app.is_platform_admin} on the
 * raw JDBC connection. Those GUCs must be applied to the <em>same</em> connection
 * that the business query will use, and they are transaction-scoped — so the aspect
 * has to run <em>inside</em> the transaction.</p>
 *
 * <p>Spring sorts advisors by ascending {@code order}; lower values wrap further out.
 * The transaction interceptor defaults to {@link Ordered#LOWEST_PRECEDENCE}, i.e. the
 * <em>innermost</em> slot. The aspect was pinned to {@code HIGHEST_PRECEDENCE}, which
 * made it the outermost — so it ran <em>before</em> {@code BEGIN}. Postgres then
 * logged {@code WARNING: SET LOCAL can only be used in transaction blocks} and
 * discarded both statements. The RLS GUCs were therefore never set for normal
 * authenticated requests; isolation appeared to work only because the local
 * database role happened to be a superuser (which skips RLS evaluation entirely).</p>
 *
 * <p>Setting the transaction advisor to {@link Ordered#HIGHEST_PRECEDENCE} and the
 * aspect to {@code HIGHEST_PRECEDENCE + 10} reverses that: the transaction opens
 * first, the aspect runs inside it, and the aspect still wraps everything else.</p>
 *
 * <p>Confirmed with {@code log_statement='all'} — the {@code SET LOCAL} issued while
 * serving {@code GET /api/v3/homes} now appears <em>after</em> {@code BEGIN} and no
 * longer emits a warning.</p>
 *
 * <p>Canonical reference: V3-SECURITY-MODEL §10.5 (P0-5).</p>
 */
@Configuration
@EnableTransactionManagement(order = Ordered.HIGHEST_PRECEDENCE)
public class TransactionConfig {
}
