// =============================================================================
// SHE V3 Admin — Users, Devices, Audit, Billing, Feature Flags API
// =============================================================================
import { api } from './client';
import type { ApiSuccess, User, Device, AuditLogEntry, Payment, BillingOverview, FeatureFlag, Paginated } from '@/lib/types';

export const usersApi = {
  list: (page = 0, size = 20) =>
    api.get<ApiSuccess<User[]>>(`/api/admin/users?page=${page}&size=${size}`),
  get: (id: string) =>
    api.get<ApiSuccess<User>>(`/api/admin/users/${id}`),
  updateRole: (id: string, platform_role: string, tenant_role?: string) =>
    api.patch<ApiSuccess<User>>(`/api/admin/users/${id}/role`, { platform_role, tenant_role }),
  disable: (id: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/users/${id}/disable`, {}),
  enable: (id: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/users/${id}/enable`, {}),
  delete: (id: string) =>
    api.delete<void>(`/api/admin/users/${id}`),
  resetMfa: (id: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/users/${id}/reset-mfa`, {}),
};

export const devicesApi = {
  list: () =>
    api.get<ApiSuccess<Device[]>>('/api/admin/devices'),
  get: (id: string) =>
    api.get<ApiSuccess<Device>>(`/api/admin/devices/${id}`),
  quarantine: (id: string, reason?: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/devices/${id}/quarantine`, { reason }),
  unquarantine: (id: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/devices/${id}/unquarantine`, {}),
  delete: (id: string) =>
    api.delete<void>(`/api/admin/devices/${id}`),
  revokeCert: (id: string, reason?: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/devices/${id}/revoke-cert`, { reason }),
};

export const auditApi = {
  list: (params: { page?: number; size?: number; action?: string; actor_type?: string } = {}) => {
    const qs = new URLSearchParams();
    if (params.page !== undefined) qs.set('page', String(params.page));
    if (params.size !== undefined) qs.set('size', String(params.size));
    if (params.action) qs.set('action', params.action);
    if (params.actor_type) qs.set('actor_type', params.actor_type);
    return api.get<Paginated<AuditLogEntry>>(`/api/admin/audit-log?${qs.toString()}`);
  },
};

export const billingApi = {
  overview: () =>
    api.get<ApiSuccess<BillingOverview>>('/api/admin/billing/overview'),
  invoices: () =>
    api.get<ApiSuccess<Payment[]>>('/api/admin/billing/invoices'),
  getInvoice: (id: string) =>
    api.get<ApiSuccess<Payment>>(`/api/admin/billing/invoices/${id}`),
  markPaid: (id: string, paymentMethod: string) =>
    api.post<ApiSuccess<unknown>>(`/api/admin/billing/invoices/${id}/mark-paid`, { payment_method: paymentMethod }),
};

export const featureFlagsApi = {
  list: () =>
    api.get<ApiSuccess<FeatureFlag[]>>('/api/admin/feature-flags'),
  update: (flagKey: string, data: { enabled?: boolean; rollout_percent?: number }) =>
    api.put<ApiSuccess<FeatureFlag>>(`/api/admin/feature-flags/${flagKey}`, data),
};
