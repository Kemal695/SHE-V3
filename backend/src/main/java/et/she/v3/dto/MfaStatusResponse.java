package et.she.v3.dto;

import java.util.List;

/**
 * MFA state, and — once, at confirmation time — the recovery codes.
 *
 * @param enabled        whether MFA is on
 * @param recoveryCodes  plain-text codes, returned ONLY when MFA is first
 *                       enabled; empty afterwards because they are stored hashed
 *                       and cannot be shown again
 */
public record MfaStatusResponse(
        boolean enabled,
        List<String> recoveryCodes
) {
}
