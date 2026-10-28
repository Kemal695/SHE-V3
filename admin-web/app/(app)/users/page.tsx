'use client';

import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { Search, UserCircle, Shield, Ban, Trash2, CheckCircle, KeyRound } from 'lucide-react';
import { usersApi } from '@/lib/api';
import type { User } from '@/lib/types';
import { Card, Badge, Button, Input, PageHeader, Skeleton, EmptyState, ErrorState, Modal, Select } from '@/lib/components/ui';
import { useState } from 'react';

const PLATFORM_ROLES = ['USER', 'PLATFORM_ADMIN', 'SUPER_ADMIN'];
const TENANT_ROLES = ['', 'TENANT_ADMIN', 'TENANT_INSTALLER', 'TENANT_VIEWER'];

function errMessage(e: unknown, fallback: string): string {
  return e instanceof Error && e.message ? e.message : fallback;
}

export default function UsersPage() {
  const [search, setSearch] = useState('');
  const [roleTarget, setRoleTarget] = useState<User | null>(null);
  const [platformRole, setPlatformRole] = useState('USER');
  const [tenantRole, setTenantRole] = useState('');
  const [actionError, setActionError] = useState('');
  const queryClient = useQueryClient();

  const { data, isLoading, isError, refetch } = useQuery({
    queryKey: ['users'],
    // API max page size is 100. The search box filters client-side, so anything
    // beyond the loaded page is unreachable — load the maximum up front.
    queryFn: () => usersApi.list(0, 100),
  });

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ['users'] });

  const roleMutation = useMutation({
    mutationFn: ({ id, platform, tenant }: { id: string; platform: string; tenant: string }) =>
      usersApi.updateRole(id, platform, tenant || undefined),
    onSuccess: () => { invalidate(); setRoleTarget(null); setActionError(''); },
    onError: (e) => setActionError(errMessage(e, 'Failed to change role')),
  });

  const mfaMutation = useMutation({
    mutationFn: (id: string) => usersApi.resetMfa(id),
    onSuccess: () => { invalidate(); setActionError(''); },
    onError: (e) => setActionError(errMessage(e, 'Failed to reset MFA')),
  });

  const statusMutation = useMutation({
    mutationFn: ({ id, disable }: { id: string; disable: boolean }) =>
      disable ? usersApi.disable(id) : usersApi.enable(id),
    onSuccess: () => { invalidate(); setActionError(''); },
    onError: (e) => setActionError(errMessage(e, 'Failed to update account status')),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: string) => usersApi.delete(id),
    onSuccess: () => { invalidate(); setActionError(''); },
    onError: (e) => setActionError(errMessage(e, 'Failed to delete user')),
  });

  const busy = roleMutation.isPending || mfaMutation.isPending || statusMutation.isPending || deleteMutation.isPending;

  const openRoleModal = (u: User) => {
    setActionError('');
    setPlatformRole(u.platform_role);
    setTenantRole(u.tenant_role || '');
    setRoleTarget(u);
  };

  const confirmResetMfa = (u: User) => {
    if (window.confirm(`Reset MFA for ${u.email}?\n\nThey will be forced to re-enroll on next login.`)) {
      setActionError('');
      mfaMutation.mutate(u.id);
    }
  };

  const toggleStatus = (u: User) => {
    const disabled = u.deleted_at !== null;
    if (window.confirm(disabled
      ? `Re-enable ${u.email}?`
      : `Disable ${u.email}?\n\nLogin will be blocked; their devices keep working.`)) {
      setActionError('');
      statusMutation.mutate({ id: u.id, disable: !disabled });
    }
  };

  const confirmDelete = (u: User) => {
    if (window.confirm(
      `Delete ${u.email}?\n\nPersonal data (name, phone, credentials, MFA) is permanently wiped. ` +
      `Audit history is kept with the actor link removed. This cannot be undone.`)) {
      setActionError('');
      deleteMutation.mutate(u.id);
    }
  };

  const users = (data?.data || []).filter((u: User) =>
    !search || u.email.includes(search) || (u.full_name || '').includes(search)
  );
  const loadedCount = data?.data?.length ?? 0;
  const totalUsers = data?.meta?.total ?? loadedCount;
  const truncated = totalUsers > loadedCount;

  return (
    <>
      <PageHeader title="Users" description="Manage users — search, filter, change roles, disable" />
      <div className="relative mb-4">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
        <Input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search by email or name..." className="pl-10" />
      </div>
      {actionError && (
        <div className="mb-4 p-3 rounded-lg bg-error/10 border border-error/30 text-sm text-error">
          {actionError}
        </div>
      )}
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
              {users.map((u: User) => {
                // deleted_at is omitted (not null) for active users — Jackson drops null fields.
                // Loose != catches both undefined and null.
                const disabled = u.deleted_at != null;
                return (
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
                  <td className="p-4"><Badge variant={disabled ? 'warning' : 'success'}>{disabled ? 'Disabled' : 'Active'}</Badge></td>
                  <td className="p-4 text-sm text-text-secondary">{u.last_login_at ? new Date(u.last_login_at).toLocaleDateString() : 'Never'}</td>
                  <td className="p-4"><div className="flex justify-end gap-1">
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Change Role" disabled={busy} onClick={() => openRoleModal(u)}><Shield className="w-4 h-4 text-text-secondary" /></button>
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Reset MFA" disabled={busy} onClick={() => confirmResetMfa(u)}><KeyRound className="w-4 h-4 text-text-secondary" /></button>
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title={disabled ? 'Enable account' : 'Disable account'} disabled={busy} onClick={() => toggleStatus(u)}>
                      {disabled ? <CheckCircle className="w-4 h-4 text-success" /> : <Ban className="w-4 h-4 text-warning" />}
                    </button>
                    <button className="p-1.5 rounded-lg hover:bg-white/10" title="Delete user (anonymize)" disabled={busy} onClick={() => confirmDelete(u)}><Trash2 className="w-4 h-4 text-error" /></button>
                  </div></td>
                </tr>
                );
              })}
            </tbody>
          </table>
          <div className="px-4 py-3 border-t border-white/5 text-xs text-text-secondary">
            Showing {loadedCount} of {totalUsers} users
            {truncated && (
              <span className="text-warning"> — more users exist than are loaded; search only covers the loaded set. Ask an engineer to add pagination.</span>
            )}
          </div>
        </Card>
      )}

      {roleTarget && (
        <Modal open onClose={() => setRoleTarget(null)} title={`Change role — ${roleTarget.email}`}>
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-text-secondary mb-1.5">Platform role</label>
              <Select className="w-full" value={platformRole} onChange={e => setPlatformRole(e.target.value)}>
                {PLATFORM_ROLES.map(r => <option key={r} value={r}>{r}</option>)}
              </Select>
              <p className="text-xs text-text-secondary mt-1">SUPER_ADMIN manages tenants + platform. PLATFORM_ADMIN is read-only.</p>
            </div>
            <div>
              <label className="block text-sm font-medium text-text-secondary mb-1.5">Tenant role</label>
              <Select className="w-full" value={tenantRole} onChange={e => setTenantRole(e.target.value)}>
                {TENANT_ROLES.map(r => <option key={r || 'none'} value={r}>{r || '— none —'}</option>)}
              </Select>
              <p className="text-xs text-text-secondary mt-1">TENANT_ADMIN manages users + billing. INSTALLER provisions devices. VIEWER is read-only.</p>
            </div>
            {roleMutation.isError && (
              <p className="text-sm text-error">{errMessage(roleMutation.error, 'Failed to change role')}</p>
            )}
            <div className="flex gap-3 pt-2">
              <Button type="button" variant="secondary" className="flex-1" onClick={() => setRoleTarget(null)}>Cancel</Button>
              <Button type="button" className="flex-1" loading={roleMutation.isPending} onClick={() => roleMutation.mutate({ id: roleTarget.id, platform: platformRole, tenant: tenantRole })}>Save role</Button>
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}
