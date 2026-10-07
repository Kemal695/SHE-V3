import type { Metadata } from 'next';
import './globals.css';
import { Sidebar } from '@/lib/components/sidebar';
import { QueryProvider } from '@/lib/providers/query-provider';

export const metadata: Metadata = {
  title: 'SHE Admin — Smart Home Ethiopia',
  description: 'Platform admin console for SHE V3',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="bg-background text-text-primary antialiased">
        <QueryProvider>
          {children}
        </QueryProvider>
      </body>
    </html>
  );
}
