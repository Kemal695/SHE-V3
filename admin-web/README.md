# SHE V3 Admin Web Console

**Next.js 16 / React 19 / Tailwind CSS 4** admin console — 9 screens per V3-ADMIN-WEB-APP.

## Screens (V3-ADMIN-WEB-APP §4.2)

| # | Route | Purpose | Roles |
|---|---|---|---|
| 1 | `/login` | Login with email + password + MFA | All |
| 2 | `/dashboard` | Overview: health + KPIs + alerts feed | All |
| 3 | `/tenants` | List + create + suspend + terminate tenants | SUPER_ADMIN |
| 4 | `/tenants/[id]` | Tenant detail + branding editor + API keys + audit + billing | SUPER_ADMIN |
| 5 | `/users` | User management (search, filter, role change, disable) | TENANT_ADMIN+ |
| 6 | `/audit-log` | Searchable audit log + CSV export (≤100k rows) | TENANT_ADMIN+ |
| 7 | `/billing` | Invoices, payments, MRR summary | TENANT_ADMIN+ |
| 8 | `/feature-flags` | Feature flag toggles (per-tenant + global) | SUPER_ADMIN + TENANT_ADMIN |
| 9 | `/settings` | Profile + password change + MFA management | All |

## Design tokens (V3-DESIGN-SYSTEM §8)

```typescript
colors: {
  background: '#0B1D37',   // Deep Navy
  surface: '#152946',       // Lighter Navy (cards)
  primary: '#56B4FA',       // Bright Sky Blue
  secondary: '#1D70B8',    // Medium Royal Blue
  text-primary: '#FFFFFF',
  text-secondary: '#A0AEC0',
  success: '#00C853',
  error: '#D50000',
  warning: '#FFAB00',
}
// NO indigo/blue-purple (forbidden hues enforced in branding editor)
```

## Build + run

```bash
cd admin-web
cp .env.example .env.local
npm ci
npm run dev    # → http://localhost:3000

# Production
npm run build
npm run start  # → port 3000, behind Nginx
```

## Auth model

- HTTP-only cookies (`she_admin_access` + `she_admin_refresh`) — no localStorage
- Middleware checks access cookie on every request
- CSRF token in `X-CSRF-Token` header, rotated every 24 hours
- Session idle timeout: 30 min (configurable per tenant)

## Hosting

- Platform admin: `https://admin.she.et` (SUPER_ADMIN + PLATFORM_ADMIN)
- Tenant admin: `https://{tenant}.she.et/admin` (TENANT_ADMIN + TENANT_INSTALLER + TENANT_VIEWER)
