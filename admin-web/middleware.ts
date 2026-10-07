// =============================================================================
// SHE V3 Admin — Next.js middleware (auth gate)
// =============================================================================
// Redirects to /login when no session cookie is present.
//
// The backend is stateless JWT and sets NO cookies, so the session cookie is
// written by the client on successful login (see lib/api/token-store.ts). The
// middleware only checks for its *presence* — it cannot validate a JWT on the
// edge, and it does not need to: the first API call that 401s clears the tokens
// and bounces the user back to /login.
//
// NOTE: the original file ended mid-string — the matcher regex was never closed
// (`['/((?!login|_next|favicon\.ico).*` then `};`), which is a syntax error that
// would fail the build. Fixed below.
// =============================================================================
import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

const REFRESH_COOKIE = 'she_admin_refresh';

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Allow the login page + static assets
  if (
    pathname === '/login' ||
    pathname.startsWith('/_next') ||
    pathname.startsWith('/favicon')
  ) {
    return NextResponse.next();
  }

  // Presence check only — the refresh cookie is set client-side after login.
  if (!request.cookies.get(REFRESH_COOKIE)) {
    const loginUrl = new URL('/login', request.url);
    loginUrl.searchParams.set('redirect', pathname);
    return NextResponse.redirect(loginUrl);
  }

  return NextResponse.next();
}

export const config = {
  // Match everything except the login page, Next.js internals, the favicon, AND
  // the API proxy. `proxy-api` must be excluded: it is a rewrite target for
  // backend calls, and gating it on the auth cookie made every API request
  // bounce to /login (surfacing as "Cannot reach server").
  matcher: ['/((?!login|proxy-api|_next|favicon\\.ico).*)'],
};
