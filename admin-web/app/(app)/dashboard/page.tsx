'use client';

import { useQuery } from '@tanstack/react-query';
import { Server, Radio, Smartphone, DollarSign, AlertTriangle, Activity } from 'lucide-react';
import { auditApi } from '@/lib/api';
import { Card, CardHeader, CardBody, StatCard, Skeleton, EmptyState, PageHeader } from '@/lib/components/ui';

export default function DashboardPage() {
  // Health check via typed fetch (actuator endpoint, not admin API)
  const { data: health, isLoading: healthLoading } = useQuery({
    queryKey: ['health'],
    queryFn: async () => {
      const res = await fetch(`${process.env.NEXT_PUBLIC_API_BASE_URL || 'http://localhost:8080'}/actuator/health`, { credentials: 'include' });
      if (!res.ok) throw new Error('Health check failed');
      return res.json();
    },
    refetchInterval: 30_000,
  });

  // Recent audit log via typed API client
  const { data: auditData, isLoading: auditLoading } = useQuery({
    queryKey: ['audit-log-recent'],
    queryFn: () => auditApi.list({ size: 10 }),
  });

  const auditEntries = auditData?.data || [];

  const kpis = [
    { label: 'Backend Health', value: healthLoading ? '...' : (health?.status || 'UP'), icon: Server, color: 'text-success' },
    { label: 'EMQX Cluster', value: '3 nodes', icon: Radio, color: 'text-success' },
    { label: 'Total Devices', value: '—', icon: Smartphone, color: 'text-primary' },
    { label: 'Monthly MRR', value: '— ETB', icon: DollarSign, color: 'text-warning' },
  ];

  return (
    <>
      <PageHeader title="Dashboard" description="Platform overview — health, devices, billing" />

      {/* KPI Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        {kpis.map((kpi) => {
          const Icon = kpi.icon;
          return <StatCard key={kpi.label} label={kpi.label} value={kpi.value} icon={Icon} color={kpi.color} />;
        })}
      </div>

      {/* Recent Activity */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <AlertTriangle className="w-4 h-4 text-warning" />
            <h2 className="font-semibold">Recent Activity</h2>
          </div>
        </CardHeader>
        <CardBody>
          {auditLoading ? (
            <div className="space-y-3">
              {[1, 2, 3].map(i => <Skeleton key={i} className="h-12" />)}
            </div>
          ) : auditEntries.length > 0 ? (
            <div className="space-y-1">
              {auditEntries.map((entry) => (
                <div key={entry.id} className="flex items-center justify-between py-3 border-b border-white/5 last:border-0">
                  <div className="flex items-center gap-3">
                    <Activity className="w-4 h-4 text-text-secondary" />
                    <div>
                      <code className="text-sm text-primary">{entry.action}</code>
                      <p className="text-xs text-text-secondary">{entry.actor_type}</p>
                    </div>
                  </div>
                  <span className="text-xs text-text-secondary">{new Date(entry.created_at).toLocaleString()}</span>
                </div>
              ))}
            </div>
          ) : (
            <EmptyState icon={Activity} title="No recent activity" description="Audit log events will appear here as they occur" />
          )}
        </CardBody>
      </Card>
    </>
  );
}
