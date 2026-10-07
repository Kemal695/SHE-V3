'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { LayoutDashboard, Building2, Users, ScrollText, CreditCard, Flag, Settings, Home } from 'lucide-react';
import { cn } from '@/lib/utils';

const navItems = [
  { href: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { href: '/tenants', label: 'Tenants', icon: Building2 },
  { href: '/users', label: 'Users', icon: Users },
  { href: '/audit-log', label: 'Audit Log', icon: ScrollText },
  { href: '/billing', label: 'Billing', icon: CreditCard },
  { href: '/feature-flags', label: 'Feature Flags', icon: Flag },
  { href: '/settings', label: 'Settings', icon: Settings },
];

export function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="w-64 bg-surface flex flex-col border-r border-white/5 flex-shrink-0">
      {/* Logo */}
      <div className="p-5 border-b border-white/5">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center shadow-lg shadow-primary/20">
            <Home className="w-5 h-5 text-white" />
          </div>
          <div>
            <p className="font-semibold text-sm">SHE Admin</p>
            <p className="text-xs text-text-secondary">Smart Home Ethiopia</p>
          </div>
        </div>
      </div>

      {/* Nav */}
      <nav className="flex-1 p-3 space-y-1 overflow-y-auto">
          {navItems.map((item) => {
            // Next 16: usePathname() is nullable
            const current = pathname ?? '';
            const isActive = current === item.href ||
              (item.href !== '/dashboard' && current.startsWith(item.href));
          const Icon = item.icon;
          return (
            <Link
              key={item.href}
              href={item.href}
              className={cn(
                'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-150',
                isActive
                  ? 'bg-primary/15 text-primary'
                  : 'text-text-secondary hover:bg-white/5 hover:text-text-primary'
              )}
            >
              <Icon className="w-4 h-4 flex-shrink-0" />
              {item.label}
            </Link>
          );
        })}
      </nav>

      {/* Footer */}
      <div className="p-4 border-t border-white/5">
        <div className="flex items-center gap-2 text-xs text-text-secondary">
          <div className="w-2 h-2 rounded-full bg-success animate-pulse" />
          <span>v3.0.0 — All systems operational</span>
        </div>
      </div>
    </aside>
  );
}
