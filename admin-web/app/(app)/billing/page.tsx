'use client';

import { useQuery } from '@tanstack/react-query';
import { DollarSign, FileText, TrendingUp, Calendar } from 'lucide-react';
import { billingApi } from '@/lib/api';
import type { Payment } from '@/lib/types';
import { Card, CardHeader, CardBody, Badge, StatCard, PageHeader, Skeleton, EmptyState, ErrorState } from '@/lib/components/ui';

export default function BillingPage() {
  const { data: overviewData, isLoading: overviewLoading, isError: overviewError, refetch } = useQuery({
    queryKey: ['billing-overview'],
    queryFn: () => billingApi.overview(),
  });
  const { data: invoicesData, isLoading: invoicesLoading } = useQuery({
    queryKey: ['invoices'],
    queryFn: () => billingApi.invoices(),
  });
  const overview = overviewData?.data;
  const invoices: Payment[] = invoicesData?.data || [];

  const kpis = [
    { label: 'Current MRR', value: overview?.mrr_etb ? `${overview.mrr_etb} ETB` : '0 ETB', icon: DollarSign, color: 'text-success' },
    { label: 'Outstanding', value: overview?.outstanding_etb ? `${overview.outstanding_etb} ETB` : '0 ETB', icon: FileText, color: 'text-error' },
    { label: 'Next Invoice', value: overview?.next_invoice_date ? new Date(overview.next_invoice_date).toLocaleDateString() : '—', icon: Calendar, color: 'text-primary' },
  ];

  const statusVariant = (status: string) => {
    if (status === 'PAID') return 'success' as const;
    if (status === 'PENDING') return 'warning' as const;
    if (status === 'FAILED') return 'error' as const;
    return 'neutral' as const;
  };

  return (
    <>
      <PageHeader title="Billing" description="Invoices, payments, MRR summary" />
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
        {overviewLoading ? (
          [1,2,3].map(i => <Skeleton key={i} className="h-28" />)
        ) : kpis.map(kpi => {
          const Icon = kpi.icon;
          return <StatCard key={kpi.label} label={kpi.label} value={kpi.value} icon={Icon} color={kpi.color} />;
        })}
      </div>

      {overviewError && <Card className="mb-6"><ErrorState message="Failed to load billing overview" onRetry={() => refetch()} /></Card>}

      <Card>
        <CardHeader><h2 className="font-semibold">Invoices</h2></CardHeader>
        {invoicesLoading ? (
          <CardBody><div className="space-y-3">{[1,2,3].map(i => <Skeleton key={i} className="h-12" />)}</div></CardBody>
        ) : invoices.length === 0 ? (
          <CardBody><EmptyState icon={FileText} title="No invoices yet" description="B2B invoices auto-generate on the 25th of each month" /></CardBody>
        ) : (
          <table className="w-full">
            <thead><tr className="border-b border-white/5 text-xs text-text-secondary uppercase tracking-wider">
              <th className="text-left p-4 font-medium">Date</th>
              <th className="text-left p-4 font-medium">Amount</th>
              <th className="text-left p-4 font-medium">Plan</th>
              <th className="text-left p-4 font-medium">Status</th>
              <th className="text-left p-4 font-medium">Paid At</th>
            </tr></thead>
            <tbody>
              {invoices.map((inv) => (
                <tr key={inv.id} className="border-b border-white/5 last:border-0 hover:bg-white/5">
                  <td className="p-4 text-sm">{new Date(inv.created_at).toLocaleDateString()}</td>
                  <td className="p-4 text-sm font-medium">{inv.amount_etb} ETB</td>
                  <td className="p-4"><Badge variant="primary">{inv.plan}</Badge></td>
                  <td className="p-4"><Badge variant={statusVariant(inv.status)}>{inv.status}</Badge></td>
                  <td className="p-4 text-sm text-text-secondary">{inv.paid_at ? new Date(inv.paid_at).toLocaleDateString() : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Card>
    </>
  );
}
