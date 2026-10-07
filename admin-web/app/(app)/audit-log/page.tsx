'use client';

import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Download, Search, ScrollText } from 'lucide-react';
import { auditApi } from '@/lib/api';
import type { AuditLogEntry } from '@/lib/types';
import { Card, Badge, Button, Input, PageHeader, Skeleton, EmptyState, ErrorState } from '@/lib/components/ui';

export default function AuditLogPage() {
  const [search, setSearch] = useState('');
  const [actionFilter, setActionFilter] = useState('');
  const { data, isLoading, isError, refetch } = useQuery({
    queryKey: ['audit-log', actionFilter],
    queryFn: () => auditApi.list({ size: 50, action: actionFilter || undefined }),
  });
  const entries = (data?.data || []).filter((e: AuditLogEntry) =>
    !search || e.action.includes(search) || (e.actor_type || '').includes(search)
  );

  const handleExport = () => {
    window.open(`${process.env.NEXT_PUBLIC_API_BASE_URL || 'http://localhost:8080'}/api/admin/audit-log/export`, '_blank');
  };

  return (
    <>
      <PageHeader title="Audit Log" description="Tamper-evident, hash-chained — 2 year retention" actions={
        <Button variant="secondary" onClick={handleExport}><Download className="w-4 h-4" /> Export CSV</Button>
      } />
      <div className="flex gap-3 mb-4">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
          <Input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search events, actors..." className="pl-10" />
        </div>
        <select value={actionFilter} onChange={e => setActionFilter(e.target.value)} className="bg-surface border border-white/10 rounded-lg px-4 py-2.5 text-sm focus:outline-none focus:border-primary">
          <option value="">All Actions</option>
          <option value="admin.tenant.created">Tenant Created</option>
          <option value="admin.tenant.suspended">Tenant Suspended</option>
          <option value="admin.user.disabled">User Disabled</option>
          <option value="admin.impersonate.started">Impersonation Started</option>
          <option value="payment.completed">Payment Completed</option>
        </select>
      </div>
      {isLoading ? (
        <Card><div className="p-5 space-y-3">{[1,2,3,4,5].map(i => <Skeleton key={i} className="h-12" />)}</div></Card>
      ) : isError ? (
        <Card><ErrorState message="Failed to load audit log" onRetry={() => refetch()} /></Card>
      ) : entries.length === 0 ? (
        <Card><EmptyState icon={ScrollText} title="No audit events" description="Events will appear here as admin actions occur" /></Card>
      ) : (
        <Card className="overflow-hidden">
          <table className="w-full">
            <thead><tr className="border-b border-white/5 text-xs text-text-secondary uppercase tracking-wider">
              <th className="text-left p-4 font-medium">Timestamp</th>
              <th className="text-left p-4 font-medium">Event</th>
              <th className="text-left p-4 font-medium">Actor Type</th>
              <th className="text-left p-4 font-medium">IP Address</th>
            </tr></thead>
            <tbody>
              {entries.map((e: AuditLogEntry) => (
                <tr key={e.id} className="border-b border-white/5 last:border-0 hover:bg-white/5">
                  <td className="p-4 text-sm text-text-secondary whitespace-nowrap">{new Date(e.created_at).toLocaleString()}</td>
                  <td className="p-4"><code className="text-xs text-primary bg-primary/10 px-2 py-1 rounded">{e.action}</code></td>
                  {/* actor_type is constrained to USER|TENANT_ADMIN|PLATFORM_ADMIN|SYSTEM|DEVICE
                      (V18 CHECK), so the old 'SUPER_ADMIN' comparison could never match. */}
                  <td className="p-4"><Badge variant={e.actor_type === 'PLATFORM_ADMIN' ? 'error' : e.actor_type === 'SYSTEM' ? 'neutral' : 'primary'}>{e.actor_type}</Badge></td>
                  <td className="p-4 text-sm text-text-secondary font-mono">{e.ip_address || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <p className="text-xs text-text-secondary mt-3">Showing {entries.length} of {data?.meta?.total || 0} total · Retention: 2 years · Hash-chained (P1-19)</p>
    </>
  );
}
