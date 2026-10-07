'use client';

import { useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Home, Mail, Lock, ShieldCheck, AlertCircle } from 'lucide-react';
import { authApi } from '@/lib/api/auth';
import { ApiError } from '@/lib/api/client';
import { Button, Input } from '@/lib/components/ui';

export default function LoginPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [mfaCode, setMfaCode] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [needsMfa, setNeedsMfa] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError('');

    try {
      await authApi.login(email, password, mfaCode || undefined);
      // BUG-18 fix: redirect to original target after login (set by middleware)
      // Next 16: useSearchParams() is nullable, hence the `?.`
      router.push(searchParams?.get('redirect') || '/dashboard');
    } catch (err) {
      if (err instanceof ApiError) {
        if (err.code === 'AUTH_MFA_REQUIRED') {
          setNeedsMfa(true);
          setError('Enter your MFA code to continue');
        } else if (err.code === 'AUTH_INVALID_CREDENTIALS') {
          setError('Invalid email or password');
        } else if (err.code === 'RATE_LIMIT_LOGIN') {
          setError('Too many attempts. Try again in 15 minutes');
        } else {
          setError(err.message);
        }
      } else {
        setError('Cannot reach server. Check your connection.');
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen bg-background flex items-center justify-center p-6">
      <div className="w-full max-w-md">
        {/* Logo */}
        <div className="flex flex-col items-center mb-8">
          <div className="w-16 h-16 rounded-2xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center shadow-lg shadow-primary/30 mb-4">
            <Home className="w-8 h-8 text-white" />
          </div>
          <h1 className="text-2xl font-bold">SHE Admin Console</h1>
          <p className="text-sm text-text-secondary mt-1">Smart Home Ethiopia</p>
        </div>

        <form onSubmit={handleSubmit} className="bg-surface rounded-2xl p-6 space-y-4 border border-white/5">
          {error && (
            <div className="flex items-center gap-2 bg-error/10 border border-error/30 rounded-lg p-3">
              <AlertCircle className="w-4 h-4 text-error flex-shrink-0" />
              <span className="text-error text-sm">{error}</span>
            </div>
          )}

          <div>
            <label className="block text-sm font-medium text-text-secondary mb-1.5">Email</label>
            <div className="relative">
              <Mail className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
              <Input type="email" value={email} onChange={e => setEmail(e.target.value)} placeholder="admin@she.et" required disabled={loading} className="pl-10" />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-text-secondary mb-1.5">Password</label>
            <div className="relative">
              <Lock className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
              <Input type="password" value={password} onChange={e => setPassword(e.target.value)} required disabled={loading} className="pl-10" />
            </div>
          </div>

          {needsMfa && (
            <div>
              <label className="block text-sm font-medium text-text-secondary mb-1.5">MFA Code</label>
              <div className="relative">
                <ShieldCheck className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-text-secondary" />
                <Input type="text" value={mfaCode} onChange={e => setMfaCode(e.target.value)} placeholder="123456" maxLength={6} required disabled={loading} className="pl-10" />
              </div>
            </div>
          )}

          <Button type="submit" loading={loading} className="w-full" size="lg">
            {loading ? 'Signing in...' : 'Sign In'}
          </Button>
        </form>

        <p className="text-center text-xs text-text-secondary mt-6">
          Protected by JWT (EdDSA) + MFA · Bearer tokens · V3-SECURITY-MODEL §1
        </p>
      </div>
    </div>
  );
}
