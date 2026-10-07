// =============================================================================
// SHE V3 Admin — TypeScript types matching backend DTOs
// =============================================================================
// All types mirror the Java DTOs exactly. Any mismatch = compile error.
// =============================================================================

// ---- Auth ----
export interface AuthResponse {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  token_type: string;
  tenant_branding?: Record<string, unknown>;
}

export interface MeResponse {
  user: User;
  tenant: Tenant | null;
  branding: Record<string, unknown> | null;
}

// ---- User ----
export interface User {
  id: string;
  tenant_id: string;
  email: string;
  platform_role: 'USER' | 'PLATFORM_ADMIN' | 'SUPER_ADMIN';
  tenant_role: 'TENANT_ADMIN' | 'TENANT_INSTALLER' | 'TENANT_VIEWER' | null;
  phone_number: string | null;
  preferred_language: 'am' | 'en';
  full_name: string | null;
  mfa_enabled: boolean;
  created_at: string;
  updated_at: string;
  last_login_at: string | null;
}

// ---- Tenant ----
export interface Tenant {
  id: string;
  name: string;
  subdomain: string;
  plan: 'B2C_FREE' | 'B2C_PREMIUM' | 'B2C_FAMILY' | 'B2B_100' | 'B2B_1000' | 'B2B_UNLIMITED';
  status: 'TRIAL' | 'ACTIVE' | 'SUSPENDED' | 'TERMINATED';
  branding_config: BrandingConfig | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface BrandingConfig {
  app_name?: string;
  logo_url?: string;
  primary_color?: string;
  login_bg_url?: string;
  domain?: string;
  support_email?: string;
  support_phone?: string;
  primary_language?: 'am' | 'en';
}

// ---- Device (Node) ----
export interface Device {
  id: string;
  node_id: string;
  mac_address: string;
  normalized_mac: string;
  sku: 'SHE-R4' | 'SHE-R8' | 'SHE-R16';
  name: string;
  firmware_version: string | null;
  hardware_revision: string | null;
  is_online: boolean;
  is_quarantined: boolean;
  last_seen_at: string | null;
  provisioned_at: string | null;
  home_id: string | null;
  room_id: string | null;
}

// ---- Payment ----
export interface Payment {
  id: string;
  tenant_id: string;
  user_id: string | null;
  idempotency_key: string;
  amount_etb: string;
  plan: string;
  status: 'PENDING' | 'PAID' | 'FAILED' | 'REFUNDED';
  chapa_ref: string | null;
  checkout_url: string | null;
  paid_at: string | null;
  created_at: string;
}

// ---- Subscription ----
export interface Subscription {
  id: string;
  tenant_id: string;
  plan: string;
  status: 'ACTIVE' | 'CANCELLED' | 'EXPIRED' | 'SUSPENDED' | 'TRIALING';
  started_at: string;
  expires_at: string | null;
  payment_id: string | null;
  created_at: string;
}

// ---- API Key ----
export interface ApiKey {
  id: string;
  name: string;
  key_prefix: string;
  scopes: string[];
  expires_at: string | null;
  last_used_at: string | null;
  created_at: string;
}

export interface ApiKeyWithSecret extends ApiKey {
  api_key: string; // Full key — shown once on creation
}

// ---- Audit Log ----
export interface AuditLogEntry {
  id: string;
  created_at: string;
  tenant_id: string | null;
  actor_user_id: string | null;
  actor_type: 'USER' | 'TENANT_ADMIN' | 'PLATFORM_ADMIN' | 'SYSTEM' | 'DEVICE';
  action: string;
  target_type: string | null;
  target_id: string | null;
  details: Record<string, unknown> | null;
  ip_address: string | null;
}

// ---- Feature Flag ----
export interface FeatureFlag {
  id: string;
  flag_key: string;
  enabled: boolean;
  rollout_percent: number;
  config: Record<string, unknown> | null;
  updated_at: string;
}

// ---- Billing ----
export interface BillingOverview {
  mrr_etb: string;
  outstanding_etb: string;
  next_invoice_date: string;
  total_payments: number;
  active_subscription: { plan: string; expires_at: string } | null;
}

// ---- API envelope ----
export interface ApiSuccess<T> {
  data: T;
  meta?: {
    total?: number;
    page?: number;
    size?: number;
    next_cursor?: string;
    has_more?: boolean;
  };
}

export interface ApiError {
  error: {
    code: string;
    message: string;
    http_status: number;
    request_id?: string;
    details?: Record<string, unknown>;
  };
}

// ---- Pagination ----
export interface Paginated<T> {
  data: T[];
  meta: {
    total: number;
    page: number;
    size: number;
    has_more: boolean;
  };
}
