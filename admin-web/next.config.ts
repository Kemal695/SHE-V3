import type { NextConfig } from 'next';

// The backend (Spring Boot on :8080) has NO CORS configuration, so a browser
// request from this app's origin to http://localhost:8080 is blocked by the
// same-origin policy — `fetch` throws, which surfaced as "Cannot reach server.
// Check your connection." on the login page.
//
// Rather than change backend security config, proxy the API through this server:
// the browser only ever talks to THIS origin (no preflight, no CORS), and Next
// forwards to the backend. Works in `next dev` and `next start`.
//
// NEXT_PUBLIC_API_BASE_URL is set to /proxy-api, so a call to
//   /proxy-api/api/v3/auth/login
// becomes
//   http://localhost:8080/api/v3/auth/login
//
// In production you can either keep this proxy or add a real CORS policy on the
// backend (allow the console origin + Authorization/Content-Type headers). Point
// PROXY_API_TARGET at the real API host when deploying.
const API_TARGET = process.env.PROXY_API_TARGET ?? 'http://localhost:8080';

const nextConfig: NextConfig = {
  async rewrites() {
    return [
      {
        source: '/proxy-api/:path*',
        destination: `${API_TARGET}/:path*`,
      },
    ];
  },
};

export default nextConfig;
