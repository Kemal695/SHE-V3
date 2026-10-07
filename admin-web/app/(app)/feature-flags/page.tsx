'use client';

import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Flag } from 'lucide-react';
import { featureFlagsApi } from '@/lib/api';
import type { FeatureFlag } from '@/lib/types';
import { Card, Toggle, PageHeader, Skeleton, EmptyState } from '@/lib/components/ui';

export default function FeatureFlagsPage() {
  const { data, isLoading } = useQuery({
    queryKey: ['feature-flags'],
    queryFn: () => featureFlagsApi.list(),
  });
  const queryClient = useQueryClient();
  const flags: FeatureFlag[] = data?.data || [];

  const mutation = useMutation({
    mutationFn: ({ key, enabled }: { key: string; enabled: boolean }) =>
      featureFlagsApi.update(key, { enabled }),
    onMutate: async ({ key, enabled }) => {
      await queryClient.cancelQueries({ queryKey: ['feature-flags'] });
      const prev = queryClient.getQueryData<{ data: FeatureFlag[] }>(['feature-flags']);
      // Guard against undefined cache (BUG-08 fix)
      if (!prev) return { prev };
      queryClient.setQueryData<{ data: FeatureFlag[] }>(['feature-flags'], {
        ...prev,
        data: prev.data.map(f => f.flag_key === key ? { ...f, enabled } : f),
      });
      return { prev };
    },
    onError: (_err, _vars, ctx) => {
      if (ctx?.prev) queryClient.setQueryData(['feature-flags'], ctx.prev);
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['feature-flags'] }),
  });

  return (
    <>
      <PageHeader title="Feature Flags" description="Toggle features per tenant — changes take effect immediately" />
      {isLoading ? (
        <Card><div className="p-5 space-y-3">{[1,2,3,4,5].map(i => <Skeleton key={i} className="h-16" />)}</div></Card>
      ) : flags.length === 0 ? (
        <Card><EmptyState icon={Flag} title="No feature flags configured" description="Feature flag toggles will appear here" /></Card>
      ) : (
        <Card className="overflow-hidden">
          <table className="w-full">
            <thead><tr className="border-b border-white/5 text-xs text-text-secondary uppercase tracking-wider">
              <th className="text-left p-4 font-medium">Flag</th>
              <th className="text-left p-4 font-medium">Rollout</th>
              <th className="text-left p-4 font-medium">Last Updated</th>
              <th className="text-right p-4 font-medium">State</th>
            </tr></thead>
            <tbody>
              {flags.map((f) => (
                <tr key={f.id} className="border-b border-white/5 last:border-0 hover:bg-white/5">
                  <td className="p-4">
                    <div className="flex items-center gap-2">
                      <Flag className={`w-4 h-4 ${f.enabled ? 'text-primary' : 'text-text-secondary'}`} />
                      <code className={`text-sm ${f.enabled ? 'text-primary' : 'text-text-secondary'}`}>{f.flag_key}</code>
                    </div>
                  </td>
                  <td className="p-4 text-sm text-text-secondary">{f.rollout_percent}%</td>
                  <td className="p-4 text-sm text-text-secondary">{new Date(f.updated_at).toLocaleDateString()}</td>
                  <td className="p-4 text-right">
                    <Toggle checked={f.enabled} onChange={(v) => mutation.mutate({ key: f.flag_key, enabled: v })} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      <p className="text-xs text-text-secondary mt-3">Changes are applied immediately via optimistic UI update. If the server rejects, the toggle reverts.</p>
    </>
  );
}
