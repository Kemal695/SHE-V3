'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { User, Lock, Shield, LogOut, Mail, Phone } from 'lucide-react';
import { authApi } from '@/lib/api/auth';
import { Card, CardHeader, CardBody, Button, Input, PageHeader, Badge } from '@/lib/components/ui';

export default function SettingsPage() {
  const router = useRouter();
  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [logoutLoading, setLogoutLoading] = useState(false);

  const handleLogout = async () => {
    setLogoutLoading(true);
    try {
      await authApi.logout();
    } catch {}
    router.push('/login');
  };

  return (
    <>
      <PageHeader title="Settings" description="Manage your profile, password, and security" />
      <div className="max-w-2xl space-y-6">
        {/* Profile */}
        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <User className="w-4 h-4 text-primary" />
              <h2 className="font-semibold">Profile</h2>
            </div>
          </CardHeader>
          <CardBody className="space-y-4">
            <div>
              <label className="block text-sm text-text-secondary mb-1">Full Name</label>
              <Input placeholder="Your name" />
            </div>
            <div>
              <label className="block text-sm text-text-secondary mb-1">Email (read-only)</label>
              <div className="relative">
                <Mail className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
                <Input value="admin@she.et" disabled className="pl-10 bg-background/50" />
              </div>
            </div>
            <div>
              <label className="block text-sm text-text-secondary mb-1">Phone</label>
              <div className="relative">
                <Phone className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
                <Input placeholder="+251911234567" className="pl-10" />
              </div>
            </div>
            <Button>Save Profile</Button>
          </CardBody>
        </Card>

        {/* Password */}
        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <Lock className="w-4 h-4 text-primary" />
              <h2 className="font-semibold">Change Password</h2>
            </div>
          </CardHeader>
          <CardBody className="space-y-4">
            <div>
              <label className="block text-sm text-text-secondary mb-1">Current Password</label>
              <Input type="password" value={currentPassword} onChange={e => setCurrentPassword(e.target.value)} />
            </div>
            <div>
              <label className="block text-sm text-text-secondary mb-1">New Password</label>
              <Input type="password" value={newPassword} onChange={e => setNewPassword(e.target.value)} />
              <p className="text-xs text-text-secondary mt-1">Min 12 chars: 1 upper, 1 lower, 1 digit, 1 special</p>
            </div>
            <Button>Update Password</Button>
          </CardBody>
        </Card>

        {/* MFA */}
        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <Shield className="w-4 h-4 text-success" />
              <h2 className="font-semibold">Two-Factor Authentication</h2>
              <Badge variant="success">Enabled</Badge>
            </div>
          </CardHeader>
          <CardBody>
            <p className="text-sm text-text-secondary mb-4">Your account is protected with TOTP (Google Authenticator, Authy, FreeOTP).</p>
            <div className="flex gap-3">
              <Button variant="secondary" size="sm">Regenerate Backup Codes</Button>
              <Button variant="danger" size="sm">Disable MFA</Button>
            </div>
          </CardBody>
        </Card>

        {/* Logout */}
        <Card>
          <CardBody>
            <Button variant="danger" onClick={handleLogout} loading={logoutLoading}>
              <LogOut className="w-4 h-4" /> Logout
            </Button>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
