'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Plus, Search, Building2 } from 'lucide-react';
import { tenantsApi } from '@/lib/api/tenants';
import type { Tenant } from '@/lib/types';
import { Card, Badge, Button, Input, Modal, PageHeader, Skeleton, EmptyState, ErrorState } from '@/lib/components/ui';

const FORBIDDEN_HUES = ['#4F46E5', '#6366F1', '#7C3AED', '#8B5CF6', '#A855F7', '#9333EA'];

const planBadgeVariant = (plan: string) => {
  if (plan.startsWith('B2B')) return 'primary' as const;
  if (plan === 'B2C_PREMIUM' || plan === 'B2C_FAMILY') return 'success' as const;
  return 'neutral' as const;
};

const statusBadgeVariant = (status: string) => {
  if (status === 'ACTIVE') return 'success' as const;
  if (status === 'SUSPENDED') return 'warning' as const;
  if (status === 'TERMINATED') return 'error' as const;
  return 'neutral' as const;
};

export default function TenantsPage() {
  const router = useRouter();
  const [showCreate, setShowCreate] = useState(false);
  const { data, isLoading, isError, refetch } = useQuery({
    queryKey: ['tenants'],
    queryFn: () => tenantsApi.list(),
  });
  const tenants = data?.data || [];

  return (
    <>
      <PageHeader title="Tenants" description="Manage B2B tenants — create, suspend, terminate" actions={
        <Button onClick={() => setShowCreate(true)}><Plus className="w-4 h-4" /> New Tenant</Button>
      } />

      <div className="relative mb-4">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
        <Input placeholder="Search by name or subdomain..." className="pl-10" />
      </div>

      {isLoading ? (
        <Card><div className="p-5 space-y-3">{[1, 2, 3].map(i => <Skeleton key={i} className="h-12" />)}</div></Card>
      ) : isError ? (
        <Card><ErrorState message="Failed to load tenants" onRetry={() => refetch()} /></Card>
      ) : tenants.length === 0 ? (
        <Card><EmptyState icon={Building2} title="No tenants yet" description="Create your first B2B tenant to get started" action={<Button onClick={() => setShowCreate(true)}><Plus className="w-4 h-4" /> Create Tenant</Button>} /></Card>
      ) : (
        <Card className="overflow-hidden">
          <table className="w-full">
            <thead>
              <tr className="border-b border-white/5 text-xs text-text-secondary uppercase tracking-wider">
                <th className="text-left p-4 font-medium">Name</th>
                <th className="text-left p-4 font-medium">Subdomain</th>
                <th className="text-left p-4 font-medium">Plan</th>
                <th className="text-left p-4 font-medium">Status</th>
                <th className="text-right p-4 font-medium">Created</th>
              </tr>
            </thead>
            <tbody>
              {tenants.map((t: Tenant) => (
                <tr key={t.id} className="border-b border-white/5 last:border-0 hover:bg-white/5 transition-colors cursor-pointer" onClick={() => router.push(`/tenants/${t.id}`)}>
                  <td className="p-4">
                    <div className="flex items-center gap-3">
                      <div className="w-8 h-8 rounded-lg bg-primary/20 flex items-center justify-center">
                        <Building2 className="w-4 h-4 text-primary" />
                      </div>
                      <span className="font-medium text-sm">{t.name}</span>
                    </div>
                  </td>
                  <td className="p-4 text-sm text-text-secondary">{t.subdomain}</td>
                  <td className="p-4"><Badge variant={planBadgeVariant(t.plan)}>{t.plan}</Badge></td>
                  <td className="p-4"><Badge variant={statusBadgeVariant(t.status)}>{t.status}</Badge></td>
                  <td className="p-4 text-right text-sm text-text-secondary">{new Date(t.created_at).toLocaleDateString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}

      {showCreate && <CreateTenantModal onClose={() => setShowCreate(false)} />}
    </>
  );
}

function CreateTenantModal({ onClose }: { onClose: () => void }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState('');
  const [subdomain, setSubdomain] = useState('');
  const [plan, setPlan] = useState('B2B_100');
  const [color, setColor] = useState('#0066CC');
  const [error, setError] = useState('');

  const mutation = useMutation({
    mutationFn: () => tenantsApi.create({
      name, subdomain, plan,
      branding_config: { app_name: name, primary_color: color, primary_language: 'am' },
    }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tenants'] });
      onClose();
    },
    onError: (err: any) => setError(err.message || 'Failed to create tenant'),
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (FORBIDDEN_HUES.includes(color.toUpperCase())) {
      setError('This hue is reserved for the SHE platform. Please choose a different brand color.');
      return;
    }
    mutation.mutate();
  };

  return (
    <Modal open={true} onClose={onClose} title="Create New Tenant" size="md">
      {error && <div className="bg-error/10 border border-error/30 rounded-lg p-3 text-error text-sm mb-4">{error}</div>}
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="block text-sm text-text-secondary mb-1">Tenant Name</label>
          <Input value={name} onChange={e => setName(e.target.value)} placeholder="Ethio Telecom Smart Home" required />
        </div>
        <div>
          <label className="block text-sm text-text-secondary mb-1">Subdomain</label>
          <Input value={subdomain} onChange={e => setSubdomain(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ''))} placeholder="ethiotelecom" required />
          <p className="text-xs text-text-secondary mt-1">Will be accessible at: {subdomain || 'subdomain'}.she.et</p>
        </div>
        <div>
          <label className="block text-sm text-text-secondary mb-1">Plan</label>
          <select value={plan} onChange={e => setPlan(e.target.value)} className="w-full bg-background border border-white/10 rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:border-primary">
            <option value="B2B_100">B2B-100 (≤100 devices, $100/mo)</option>
            <option value="B2B_1000">B2B-1000 (≤1000 devices, $800/mo)</option>
            <option value="B2B_UNLIMITED">B2B-Unlimited ($2000+/mo)</option>
          </select>
        </div>
        <div>
          <label className="block text-sm text-text-secondary mb-1">Primary Color</label>
          <div className="flex gap-2">
            <input type="color" value={color} onChange={e => setColor(e.target.value)} className="w-12 h-10 rounded-lg bg-transparent border border-white/10 cursor-pointer" />
            <Input value={color} onChange={e => setColor(e.target.value)} className="font-mono" />
          </div>
        </div>
        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" onClick={onClose} className="flex-1">Cancel</Button>
          <Button type="submit" loading={mutation.isPending} className="flex-1">Create Tenant</Button>
        </div>
      </form>
    </Modal>
  );
}
