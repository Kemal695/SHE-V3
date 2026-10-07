/** @type {import('tailwindcss').Config} */
// V3-DESIGN-SYSTEM §8 — admin web tokens (Next.js)
// Deep Navy + Bright Sky Blue. NO indigo/blue-purple.
module.exports = {
  content: [
    './app/**/*.{js,ts,jsx,tsx}',
    './lib/**/*.{js,ts,jsx,tsx}',
  ],
  theme: {
    extend: {
      colors: {
        background: '#0B1D37',
        surface: '#152946',
        primary: '#56B4FA',
        secondary: '#1D70B8',
        'text-primary': '#FFFFFF',
        'text-secondary': '#A0AEC0',
        success: '#00C853',
        error: '#D50000',
        warning: '#FFAB00',
      },
      borderRadius: {
        sm: '0.5rem',
        md: '0.75rem',
        lg: '1rem',
        xl: '1.5rem',
      },
      // NOTE: do NOT add `spacing: { xs, sm, md, lg, xl }` here. Tailwind derives
      // its size scales (max-w-*, w-*, h-*, min-w-*, …) FROM `spacing`, so those
      // keys silently hijack them: `max-w-md` became `spacing.md` = 1rem and
      // `max-w-sm` became 0.5rem, collapsing the login card to a ~16px column.
      // The original config had exactly that block, and none of the semantic
      // classes it enabled (p-md, gap-lg, …) were ever used in the app.
      // Use the numeric scale (p-4, gap-2) or add a distinct prefix if you need
      // semantic names.
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'monospace'],
      },
    },
  },
  plugins: [],
}
