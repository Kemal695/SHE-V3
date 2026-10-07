'use client';

import { useState, useEffect } from 'react';
import { useParams } from 'next/navigation';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Palette, Key, ScrollText, CreditCard, Save } from 'lucide-react';
import { tenantsApi } from '@/lib/api/tenants';
import type { BrandingConfig } from '@/lib/types';
import { Card, CardBody, Badge, Button, Input, Skeleton, PageHeader, Toggle } from '@/lib/components/ui';

const FORBIDDEN_HUES = ['#4F46E5', '#6366F1', '#7C3AED', '#8B5CF6', '#A855F7', '#9333EA'];

export default function TenantDetailPage() {
    const params = useParams<{ id: string }>();
    // Next 16: useParams() is nullable
    const id = params?.id ?? '';
  const [activeTab, setActiveTab] = useState('branding');
  const tabs = [
    { id: 'branding', label: 'Branding', icon: Palette },
    { id: 'apikeys', label: 'API Keys', icon: Key },
    { id: 'audit', label: 'Audit Log', icon: ScrollText },
    { id: 'billing', label: 'Billing', icon: CreditCard },
  ];

  const { data: tenantData, isLoading } = useQuery({
    queryKey: ['tenant', id],
    queryFn: () => tenantsApi.get(id),
  });
  const tenant = tenantData?.data;

  if (isLoading) return <div className="space-y-4">{[1, 2, 3].map(i => <Skeleton key={i} className="h-24" />)}</div>;
  if (!tenant) return <p className="text-text-secondary">Tenant not found</p>;

  return (
    <>
      <PageHeader title={tenant.name} description={`${tenant.subdomain}.she.et · ${tenant.plan} · ${tenant.status}`} />
      <div className="flex gap-1 bg-surface rounded-lg p-1 mb-6">
        {tabs.map((tab) => {
          const Icon = tab.icon;
          return (
            <button key={tab.id} onClick={() => setActiveTab(tab.id)}
              className={`flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors ${activeTab === tab.id ? 'bg-primary text-white' : 'text-text-secondary hover:text-text-primary'}`}>
              <Icon className="w-4 h-4" />{tab.label}
            </button>
          );
        })}
      </div>

      {activeTab === 'branding' && <BrandingTab tenantId={id} branding={tenant.branding_config} />}
      {activeTab === 'apikeys' && <ApiKeysTab />}
      {activeTab === 'audit' && <div className="text-text-secondary text-center py-16">No audit events for this tenant yet.</div>}
      {activeTab === 'billing' && <div className="text-text-secondary text-center py-16">No invoices yet. B2B invoices auto-generate on the 25th.</div>}
    </>
  );
}

function BrandingTab({ tenantId, branding }: { tenantId: string; branding: BrandingConfig | null }) {
  const queryClient = useQueryClient();
  const [appName, setAppName] = useState(branding?.app_name || '');
  const [color, setColor] = useState(branding?.primary_color || '#0066CC');
  const [supportEmail, setSupportEmail] = useState(branding?.support_email || '');
  const [supportPhone, setSupportPhone] = useState(branding?.support_phone || '');
  const [saved, setSaved] = useState(false);

  // BUG-09 fix: sync local state when branding prop changes (after mutation invalidates + refetches)
  useEffect(() => {
    if (branding) {
      setAppName(branding.app_name || '');
      setColor(branding.primary_color || '#0066CC');
      setSupportEmail(branding.support_email || '');
      setSupportPhone(branding.support_phone || '');
    }
  }, [branding]);

  const mutation = useMutation({
    mutationFn: () => tenantsApi.updateBranding(tenantId, {
      app_name: appName, primary_color: color,
      support_email: supportEmail, support_phone: supportPhone,
      primary_language: branding?.primary_language || 'am',
    }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['tenant', tenantId] });
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    },
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (FORBIDDEN_HUES.includes(color.toUpperCase())) {
      alert('This hue is reserved for the SHE platform. Please choose a different brand color.');
      return;
    }
    mutation.mutate();
  };

  return (
    <Card><CardBody>
      <form onSubmit={handleSubmit} className="space-y-4 max-w-2xl">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm text-text-secondary mb-1">App Name</label>
            <Input value={appName} onChange={e => setAppName(e.target.value)} placeholder="Ethio Telecom Smart Home" />
          </div>
          <div>
            <label className="block text-sm text-text-secondary mb-1">Primary Color</label>
            <div className="flex gap-2">
              <input type="color" value={color} onChange={e => setColor(e.target.value)} className="w-12 h-10 rounded-lg bg-transparent border border-white/10 cursor-pointer" />
              <Input value={color} onChange={e => setColor(e.target.value)} className="font-mono" />
            </div>
          </div>
          <div>
            <label className="block text-sm text-text-secondary mb-1">Support Email</label>
            <Input value={supportEmail} onChange={e => setSupportEmail(e.target.value)} placeholder="support@tenant.she.et" />
          </div>
          <div>
            <label className="block text-sm text-text-secondary mb-1">Support Phone</label>
            <Input value={supportPhone} onChange={e => setSupportPhone(e.target.value)} placeholder="+251911234567" />
          </div>
        </div>
        <Button type="submit" loading={mutation.isPending}>
          <Save className="w-4 h-4" /> {saved ? 'Saved!' : 'Save Branding'}
        </Button>
      </form>
    </CardBody></Card>
  );
}

function ApiKeysTab() {
  return (
    <Card><CardBody>
      <div className="flex justify-between items-center mb-4">
        <h3 className="font-semibold">API Keys</h3>
        <Button size="sm"><Key className="w-4 h-4" /> Generate Key</Button>
      </div>
      <p className="text-sm text-text-secondary text-center py-8">No API keys yet. Available for B2B-1000+ tenants.</p>
    </CardBody></Card>
  );
}
