'use client';

import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Search, UserCircle, Shield, Ban, Trash2, CheckCircle, KeyRound } from 'lucide-react';
import { usersApi } from '@/lib/api';
import type { User } from '@/lib/types';
import { Card, Badge, Button, Input, PageHeader, Skeleton, EmptyState, ErrorState, Modal } from '@/lib/components/ui';
import { useState } from 'react';

export default function UsersPage() {
  const [search, setSearch] = useState('');
  const { data, isLoading, isError, refetch } = useQuery({
    queryKey: ['users'],
    queryFn: () => usersApi.list(),
  });
  const users = (data?.data || []).filter((u: User) =>
    !search || u.email.includes(search) || (u.full_name || '').includes(search)
  );

  return (
    <>
      <PageHeader title="Users" description="Manage users — search, filter, change roles, disable" />
      <div className="relative mb-4">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
        <Input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search by email or name..." className="pl-10" />
      </div>
      {isLoading ? (
        <Card><div className="p-5 space-y-3">{[1,2,3,4].map(i => <Skeleton key={i} className="h-12" />)}</div></Card>
      ) : isError ? (
        <Card><ErrorState message="Failed to load users" onRetry={() => refetch()} /></Card>
      ) : users.length === 0 ? (
        <Card><EmptyState icon={UserCircle} title="No users found" description={search ? "Try a different search" : "Users will appear here once they register"} /></Card>
      ) : (
        <Card className="overflow-hidden">
          <table className="w-full">
            <thead><tr className="border-b border-white/5 text-xs text-text-secondary uppercase tracking-wider">
              <th className="text-left p-4 font-medium">User</th>
              <th className="text-left p-4 font-medium">Platform Role</th>
              <th className="text-left p-4 font-medium">Tenant Role</th>
              <th className="text-left p-4 font-medium">Status</th>
              <th className="text-left p-4 font-medium">Last Login</th>
              <th className="text-right p-4 font-medium">Actions</th>
            </tr></thead>
            <tbody>
              {users.map((u: User) => (
                <tr key={u.id} className="border-b border-white/5 last:border-0 hover:bg-white/5">
                  <td className="p-4">
                    <div className="flex items-center gap-3">
                      <div className="w-8 h-8 rounded-full bg-primary/20 flex items-center justify-center">
                        <UserCircle className="w-5 h-5 text-primary" />
                      </div>
                      <div>
                        <p className="text-sm font-medium">{u.full_name || 'Unknown'}</p>
                        <p className="text-xs text-text-secondary">{u.email}</p>
                      </div>
                    </div>
                  </td>
                  <td className="p-4"><Badge variant={u.platform_role === 'SUPER_ADMIN' ? 'error' : u.platform_role === 'PLATFORM_ADMIN' ? 'warning' : 'primary'}>{u.platform_role}</Badge></td>
                  <td className="p-4 text-sm text-text-secondary">{u.tenant_role || '—'}</td>
                  <td className="p-4"><Badge variant="success">Active</Badge></td>
                  <td className="p-4 text-sm text-text-secondary">{u.last_login_at ? new Date(u.last_login_at).toLocaleDateString() : 'Never'}</td>
                  <td className="p-4"><div className="flex justify-end gap-1">
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Change Role"><Shield className="w-4 h-4 text-text-secondary" /></button>
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Reset MFA"><KeyRound className="w-4 h-4 text-text-secondary" /></button>
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Disable"><Ban className="w-4 h-4 text-warning" /></button>
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Delete"><Trash2 className="w-4 h-4 text-error" /></button>
                  </div></td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </>
  );
}
