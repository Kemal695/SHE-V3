// =============================================================================
// SHE V3 Admin — Tenants API
// =============================================================================
import { api } from './client';
import type { ApiSuccess, Tenant, BrandingConfig } from '@/lib/types';

export const tenantsApi = {
  list: () =>
    api.get<ApiSuccess<Tenant[]>>('/api/admin/tenants'),

  get: (id: string) =>
    api.get<ApiSuccess<Tenant>>(`/api/admin/tenants/${id}`),

  create: (data: {
    name: string;
    subdomain: string;
    plan: string;
    branding_config?: BrandingConfig;
  }) =>
    api.post<ApiSuccess<Tenant>>('/api/admin/tenants', data),

  updateBranding: (id: string, branding: BrandingConfig) =>
    api.put<ApiSuccess<Tenant>>(`/api/admin/tenants/${id}/branding`, branding),

  updateStatus: (id: string, status: string) =>
    api.put<ApiSuccess<Tenant>>(`/api/admin/tenants/${id}/status`, { status }),

  getBranding: (subdomain?: string) =>
    api.get<ApiSuccess<Record<string, unknown>>>(
      `/api/v3/tenant/branding${subdomain ? `?subdomain=${subdomain}` : ''}`
    ),
};
