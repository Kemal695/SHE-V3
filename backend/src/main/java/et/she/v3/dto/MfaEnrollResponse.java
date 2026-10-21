package et.she.v3.dto;

/**
 * Response to starting MFA enrolment.
 *
 * @param secret      Base32 secret to type in manually if the QR will not scan
 * @param otp_auth_uri  otpauth:// URI to render as a QR code
 * @param issuer      Name shown in the authenticator app
 */
public record MfaEnrollResponse(
        String secret,
        String otp_auth_uri,
        String issuer
) {
}
