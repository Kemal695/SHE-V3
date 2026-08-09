package et.she.v3.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.time.Instant;
import java.util.UUID;

/**
 * User entity — Phase 0's single CRUD endpoint target.
 *
 * Schema: V3-DATABASE-DESIGN §4.2
 * Migration: V2__users.sql
 *
 * RBAC roles (V3-SECURITY-MODEL §1.2 + §2):
 *   platform_role: USER | PLATFORM_ADMIN | SUPER_ADMIN
 *   tenant_role:   TENANT_ADMIN | TENANT_INSTALLER | TENANT_VIEWER | NULL
 *   home_roles:    (cached in JWT, refreshed every 5 min from Redis)
 *
 * Password hashing: BCrypt cost 12 (V3-DATABASE-DESIGN §4.2).
 * TOTP secret: AES-256-GCM encrypted with KEK (V3-SECURITY-MODEL §6).
 */
@Entity
@Table(name = "users")
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    @Column(name = "tenant_id", nullable = false)
    private UUID tenantId;

    @Column(name = "email", nullable = false, length = 255)
    private String email;

    @Column(name = "password_hash", nullable = false, length = 255)
    private String passwordHash;

    @Column(name = "platform_role", nullable = false, length = 20)
    private String platformRole;

    @Column(name = "tenant_role", length = 20)
    private String tenantRole;

    @Column(name = "totp_secret_encrypted")
    private byte[] totpSecretEncrypted;

    @Column(name = "totp_recovery_codes", columnDefinition = "jsonb")
    private String totpRecoveryCodes;

    @Column(name = "mfa_enabled", nullable = false)
    private boolean mfaEnabled = false;

    @Column(name = "mfa_failed_attempts", nullable = false)
    private int mfaFailedAttempts = 0;

    @Column(name = "mfa_locked_until")
    private Instant mfaLockedUntil;

    @Column(name = "oauth_subject", length = 200)
    private String oauthSubject;

    @Column(name = "oauth_provider", length = 20)
    private String oauthProvider;

    @Column(name = "phone_number", length = 20)
    private String phoneNumber;

    @Column(name = "preferred_language", nullable = false, length = 5)
    private String preferredLanguage = "en";

    @Column(name = "full_name", length = 200)
    private String fullName;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp
    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @Column(name = "last_login_at")
    private Instant lastLoginAt;

    @Column(name = "deleted_at")
    private Instant deletedAt;

    // ---- Getters / Setters ----
    public UUID getId() { return id; }
    public void setId(UUID id) { this.id = id; }
    public UUID getTenantId() { return tenantId; }
    public void setTenantId(UUID tenantId) { this.tenantId = tenantId; }
    public String getEmail() { return email; }
    public void setEmail(String email) { this.email = email; }
    public String getPasswordHash() { return passwordHash; }
    public void setPasswordHash(String passwordHash) { this.passwordHash = passwordHash; }
    public String getPlatformRole() { return platformRole; }
    public void setPlatformRole(String platformRole) { this.platformRole = platformRole; }
    public String getTenantRole() { return tenantRole; }
    public void setTenantRole(String tenantRole) { this.tenantRole = tenantRole; }
    public byte[] getTotpSecretEncrypted() { return totpSecretEncrypted; }
    public void setTotpSecretEncrypted(byte[] totpSecretEncrypted) { this.totpSecretEncrypted = totpSecretEncrypted; }
    public String getTotpRecoveryCodes() { return totpRecoveryCodes; }
    public void setTotpRecoveryCodes(String totpRecoveryCodes) { this.totpRecoveryCodes = totpRecoveryCodes; }
    public boolean isMfaEnabled() { return mfaEnabled; }
    public void setMfaEnabled(boolean mfaEnabled) { this.mfaEnabled = mfaEnabled; }
    public int getMfaFailedAttempts() { return mfaFailedAttempts; }
    public void setMfaFailedAttempts(int mfaFailedAttempts) { this.mfaFailedAttempts = mfaFailedAttempts; }
    public Instant getMfaLockedUntil() { return mfaLockedUntil; }
    public void setMfaLockedUntil(Instant mfaLockedUntil) { this.mfaLockedUntil = mfaLockedUntil; }
    public String getOauthSubject() { return oauthSubject; }
    public void setOauthSubject(String oauthSubject) { this.oauthSubject = oauthSubject; }
    public String getOauthProvider() { return oauthProvider; }
    public void setOauthProvider(String oauthProvider) { this.oauthProvider = oauthProvider; }
    public String getPhoneNumber() { return phoneNumber; }
    public void setPhoneNumber(String phoneNumber) { this.phoneNumber = phoneNumber; }
    public String getPreferredLanguage() { return preferredLanguage; }
    public void setPreferredLanguage(String preferredLanguage) { this.preferredLanguage = preferredLanguage; }
    public String getFullName() { return fullName; }
    public void setFullName(String fullName) { this.fullName = fullName; }
    public Instant getCreatedAt() { return createdAt; }
    public void setCreatedAt(Instant createdAt) { this.createdAt = createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
    public void setUpdatedAt(Instant updatedAt) { this.updatedAt = updatedAt; }
    public Instant getLastLoginAt() { return lastLoginAt; }
    public void setLastLoginAt(Instant lastLoginAt) { this.lastLoginAt = lastLoginAt; }
    public Instant getDeletedAt() { return deletedAt; }
    public void setDeletedAt(Instant deletedAt) { this.deletedAt = deletedAt; }

    /**
     * Soft-delete check.
     */
    public boolean isDeleted() { return deletedAt != null; }
}
