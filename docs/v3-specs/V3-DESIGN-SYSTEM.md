# V3 — Design System (Premium Dark-Mode Bento UI)

**Status:** Locked
**Last updated:** 2024-Q4
**Owner:** Mobile/Frontend Engineer

---

## 0. Scope

This document specifies the visual design language for the SHE V3 platform — a premium, dark-mode-first IoT experience with Bento grid dashboard, haptic feedback, and micro-interactions. Designed to feel like a high-end consumer product (Apple Home, Google Home, Tesla app).

> **Update from original V3-DESIGN-SYSTEM.md (Proposed):**
> - Explicitly documents the **NO indigo or blue-purple** rule (per system rules) — original listed `#1D70B8` Medium Royal Blue which is acceptable, but the rule is now explicit
> - Cross-references ADR-009 (dark-mode-first)
> - Adds Lucide iconography section
> - Adds light-mode-as-accessibility-fallback clarification

---

## 1. Color palette

### 1.1 Core brand colors (dark mode — primary)

| Role | Name | Hex | Usage |
|---|---|---|---|
| Background | Deep Navy | `#0B1D37` | Main app background (dark mode default) |
| Primary Action | Bright Sky Blue | `#56B4FA` | Toggle ON state, primary buttons, active nav icons, glow effects |
| Secondary | Medium Royal Blue | `#1D70B8` | Slider tracks, secondary buttons, subtle borders |
| Surface Card | Lighter Navy | `#152946` | Device cards, room cards, modals |
| Text Primary | White | `#FFFFFF` | Headings, active states, high-priority text |
| Text Secondary | Muted Gray-Blue | `#A0AEC0` | Labels, inactive states, helper text |
| Success | Green | `#00C853` | Online status, success toasts |
| Error | Red | `#D50000` | Offline status, errors, destructive actions |
| Warning | Amber | `#FFAB00` | OTA pending, low battery, warnings |

### 1.2 NO indigo or blue-purple (system rule)

**Strictly forbidden hues** (these are reserved by system rules and must never appear in V3 UI, B2B white-label overrides, or marketing assets):

| Forbidden hex | Hue name |
|---|---|
| `#4F46E5` | Indigo 600 |
| `#6366F1` | Indigo 500 |
| `#7C3AED` | Violet 600 |
| `#8B5CF6` | Violet 500 |
| `#A855F7` | Purple 500 |
| `#9333EA` | Purple 600 |
| Any hue in the HSL range `240°-290°` with saturation > 50% | Indigo/violet/purple family |

**Enforcement:**
- B2B tenant admin branding form rejects these hues with: "This hue is reserved for the SHE platform. Please choose a different brand color." (V3-B2B-WHITELABEL.md §3.1)
- CI gate (`design-tokens-lint`) scans all Flutter + Next.js source for forbidden hex codes — fails the build if found
- Design review checklist item: "No indigo/blue-purple present?"

### 1.3 Light mode (accessibility fallback)

Light mode is **secondary** — supported as an accessibility fallback for users with photophobia or in bright sunlight, not the default.

| Role | Hex | Usage |
|---|---|---|
| Background | `#F5F7FA` | Main app background (light mode) |
| Surface | `#FFFFFF` | Cards, modals |
| Primary | `#1D70B8` | Same role as dark mode (Medium Royal Blue, deeper than dark-mode primary for contrast) |
| Text Primary | `#1A1A1A` | Headings |
| Text Secondary | `#6B7280` | Labels, helper text |

Per ADR-009: **Dark mode is the default.** Light mode is opt-in via Settings → Theme. App remembers user preference (shared_preferences). If user doesn't override, follows system setting (most Android phones in Ethiopia default to light — we override to dark on first launch).

### 1.4 B2B white-label overrides

Tenants can override:
- Primary color (e.g., Ethio Telecom = `#0066CC` — a teal-blue, NOT indigo)
- Logo
- App name

All other colors stay from the SHE design system. Forbidden hues apply to tenant overrides too.

---

## 2. Typography

### 2.1 Font family

**Primary (Latin):** Inter (geometric sans-serif)
- Weights: Regular (400), Medium (500), SemiBold (600), Bold (700)
- Variable font: yes (single file, all weights)

**Amharic:** Noto Sans Ethiopic (alongside Inter for Amharic text per V3-I18N.md §3)
- Weights: Regular (400), Medium (500), Bold (700)

**Monospace:** JetBrains Mono (for device IDs, MAC addresses, technical data)

All three fonts bundled in app assets (not loaded from CDN — Ethiopian internet is unreliable).

### 2.2 Type scale

| Style | Size | Weight | Line height | Usage |
|---|---|---|---|---|
| Display | 32px | 700 | 1.2 | Dashboard hero numbers (energy cost) |
| Headline | 24px | 600 | 1.3 | Screen titles |
| Title | 20px | 600 | 1.3 | Card titles, section headers |
| Body | 16px | 400 | 1.5 (English) / 1.6 (Amharic) | Default text |
| Label | 14px | 500 | 1.4 | Form labels, button text |
| Caption | 12px | 400 | 1.4 | Helper text, timestamps |
| Overline | 10px | 600 | 1.2 | Status badges, uppercase labels |

### 2.3 Amharic line-height rule

Amharic text uses **1.6 line-height** (vs 1.4 for English) — Amharic glyphs have tall ascenders + descenders that need vertical room. Applied via `TextStyle(height: _locale == 'am' ? 1.6 : 1.4)`.

### 2.4 Button width for Amharic

Amharic text is ~30% wider than equivalent English. Buttons allow 30% more horizontal width for Amharic text. See V3-I18N.md §3.3.

---

## 3. Layout — Bento grid dashboard

### 3.1 Layout (mobile — 2 columns)

```
┌─────────────────────────────────────────────────────────┐
│  Good morning, Abebe                          [⚙️]      │
│  ─────────────────────────────────────────────────────  │
│  [Good Morning] [Leaving Home] [Movie Night] [+] →      │  ← Scenes row (horizontal scroll)
│  ─────────────────────────────────────────────────────  │
│  ┌───────────────┐  ┌───────────────┐                   │
│  │  💡            │  │  ❄️            │                   │
│  │  Living Room  │  │  Bedroom AC   │                   │
│  │  Light        │  │  24°C         │                   │
│  │  [ON toggle]  │  │  [slider]     │                   │
│  └───────────────┘  └───────────────┘                   │
│  ┌───────────────┐  ┌───────────────┐                   │
│  │  🔒           │  │  ⚡           │                   │
│  │  Front Door   │  │  Energy       │                   │
│  │  Locked       │  │  3.2 kWh      │                   │
│  │  [icon]       │  │  12.50 ETB    │                   │
│  └───────────────┘  └───────────────┘                   │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Responsive breakpoints

| Width | Columns | Notes |
|---|---|---|
| ≤ 600px | 2 | Mobile portrait |
| 600-900px | 3 | Tablet / mobile landscape |
| ≥ 900px | 4 | Desktop / foldable |

### 3.3 Card sizing

- **Small (1×1):** Toggle, status, simple on/off device
- **Medium (2×1):** Slider, energy summary, scene card
- **Large (2×2):** Camera preview, room overview, multi-device group

### 3.4 Active state glow

When a device is ON, its card glows:

```dart
Container(
  decoration: BoxDecoration(
    color: V3Colors.surface,
    borderRadius: BorderRadius.circular(V3Radius.lg),
    boxShadow: state.isOn
      ? [BoxShadow(color: V3Colors.primary.withOpacity(0.3), blurRadius: 20, spreadRadius: 0)]
      : [],
  ),
  child: ...,
);
```

---

## 4. Components

### 4.1 Device card

Rounded-corner card with active glow effect (§3.4). Icon fills with `#56B4FA` when active. Title = device display name (e.g., "Kitchen Light"). Subtitle = current state (e.g., "ON", "24°C", "Locked").

### 4.2 Haptic slider

Large vertical or circular drag-slider for dimmers, thermostats, fan speed:
- Smooth animation (300ms ease-out)
- Haptic feedback on drag (`HapticFeedback.selectionClick()`)
- Snap to increments (1% for dimmers, 0.5° for thermostat, 1 for fan speed 1-5)

### 4.3 Toggle switch (custom)

Circular, blue ring when ON — NOT the default Material switch. Custom-painted for premium feel:
- 60ms transition (faster than Material's 200ms — feels snappy)
- Haptic tap on toggle (`HapticFeedback.lightImpact()`)
- Glow effect synchronized with toggle state

### 4.4 Status badge

- Online = green dot (`#00C853`) + "Online" label
- Offline = red dot (`#D50000`) + "Offline" label
- Updating = amber dot (`#FFAB00`) + spinner

### 4.5 Icons — Lucide

[Lucide](https://lucide.dev/) icon set (MIT license, ~1500 icons):
- Thin minimalist line icons
- Default = outlined (1.5px stroke)
- Active = filled with `#56B4FA`
- Size: 24px default, 20px in cards, 32px in detail view

Custom icons (not in Lucide):
- SHE relay icon (custom, represents a relay coil)
- Ethiopian Birr symbol (ብር — uses font glyph, not icon)

---

## 5. Micro-interactions

| Trigger | Animation | Duration | Haptic |
|---|---|---|---|
| Toggle ON | Card fills with glow + icon fills blue | 150ms ease-out | Light tap |
| Toggle OFF | Glow fades + icon returns to outline | 150ms ease-out | Light tap |
| Lock unlock | Padlock morphs locked → unlocked | 400ms | Medium impact |
| Fan ON | Fan blades rotate (speed matches setting) | continuous | None |
| Scene activate | All affected cards flash briefly + stagger to new state | 200ms flash + 300ms stagger | Light tap |
| Long-press card | Radial menu appears (On/Off/Schedule/Settings) | 150ms scale + fade | Medium impact |
| Pull-to-refresh | Custom spinner (not default Material) | continuous | None |
| OTA progress | Progress bar fills + percentage animates | continuous | None |
| Payment success | Checkmark draws + card slides up + confetti | 600ms | Success notification |

**Transition rule:** All transitions use `150ms ease-out` by default. Exception: scene activation (200ms flash + 300ms stagger) and lock morph (400ms — feels more substantial).

---

## 6. Dark mode first (ADR-009)

Dark mode is the **default**. Light mode is supported but secondary (§1.3 above).

- Default: dark mode (Deep Navy `#0B1D37` background)
- User can toggle in Settings → Theme (Dark / Light / System)
- App remembers preference (shared_preferences)
- If user doesn't override, follows system setting
- On first launch: app defaults to dark mode regardless of system setting (Ethiopian users typically have light mode default on Android — we override because dark mode is the premium SHE brand)

**Why dark mode first:**
1. Premium feel — Apple Home, Google Home, Tesla all default to dark
2. OLED battery savings (most Android phones in Ethiopia have OLED screens)
3. Better for evening/night use (Ethiopian homes often have dim lighting)
4. Differentiates from Tuya/Sonoff apps (which default to light mode — feels generic)

---

## 7. Design tokens (Flutter)

```dart
// mobile/lib/core/theme/v3_colors.dart
import 'package:flutter/material.dart';

class V3Colors {
  // Dark mode (primary)
  static const background = Color(0xFF0B1D37);
  static const surface = Color(0xFF152946);
  static const primary = Color(0xFF56B4FA);       // Bright Sky Blue
  static const secondary = Color(0xFF1D70B8);     // Medium Royal Blue
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA0AEC0);
  static const success = Color(0xFF00C853);
  static const error = Color(0xFFD50000);
  static const warning = Color(0xFFFFAB00);
  
  // Light mode (accessibility fallback)
  static const lightBackground = Color(0xFFF5F7FA);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightTextPrimary = Color(0xFF1A1A1A);
  static const lightTextSecondary = Color(0xFF6B7280);
  
  // Forbidden hues (do NOT use — enforced by lint)
  // static const _forbiddenIndigo = Color(0xFF4F46E5);
  // static const _forbiddenViolet = Color(0xFF7C3AED);
  // static const _forbiddenPurple = Color(0xFFA855F7);
}

class V3Spacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class V3Radius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;   // default for cards
  static const xl = 24.0;   // for modals
  static const full = 999.0; // for avatars, circular buttons
}

class V3Duration {
  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 400);
}

class V3FontFamily {
  static const latin = 'Inter';
  static const amharic = 'NotoSansEthiopic';
  static const mono = 'JetBrainsMono';
}
```

---

## 8. Design tokens (Next.js admin web)

```typescript
// admin-web/lib/theme/tokens.ts
export const v3Colors = {
  background: '#0B1D37',
  surface: '#152946',
  primary: '#56B4FA',
  secondary: '#1D70B8',
  textPrimary: '#FFFFFF',
  textSecondary: '#A0AEC0',
  success: '#00C853',
  error: '#D50000',
  warning: '#FFAB00',
} as const;

export const v3Spacing = {
  xs: '0.25rem',   // 4px
  sm: '0.5rem',    // 8px
  md: '1rem',      // 16px
  lg: '1.5rem',    // 24px
  xl: '2rem',      // 32px
} as const;

export const v3Radius = {
  sm: '0.5rem',
  md: '0.75rem',
  lg: '1rem',      // default for cards
  xl: '1.5rem',    // for modals
} as const;
```

Tailwind config extends these tokens — see `admin-web/tailwind.config.ts`.

---

## 9. Accessibility

- **Color contrast:** WCAG AA minimum (4.5:1 for body text, 3:1 for large text). Deep Navy `#0B1D37` + White `#FFFFFF` = 16.1:1 (AAA). Bright Sky Blue `#56B4FA` on Deep Navy = 7.2:1 (AAA).
- **Touch targets:** Minimum 44×44pt (iOS HIG) / 48×48dp (Material). All buttons, toggles, cards meet this.
- **Screen reader:** All interactive elements have semantic labels (`Semantics(label: 'Living room light, on')` in Flutter, `aria-label` in Next.js).
- **Reduced motion:** If system "Reduce Motion" is on, micro-interactions are shortened to 50ms (no glow, no stagger).
- **Font scaling:** App respects system font scale up to 1.5× (Amharic text breaks at higher scales — capped at 1.5× to prevent layout overflow).

---

## 10. References

- V3-MOBILE-APP.md §4 — Flutter implementation of this design system
- V3-ADMIN-WEB-APP.md §1 — Next.js implementation
- V3-I18N.md §3 — Amharic typography (line-height, button width)
- V3-B2B-WHITELABEL.md §3 — white-label branding overrides (no indigo/blue-purple)
- V3-ERROR-CODES.md §4 — `VALIDATION_COLOR_FORBIDDEN` (enforces no-indigo rule at API)
- ADR-009 — dark-mode-first decision
- Inter font: https://rsms.me/inter/
- Noto Sans Ethiopic: https://fonts.google.com/noto/specimen/Noto+Sans+Ethiopic
- Lucide icons: https://lucide.dev/
