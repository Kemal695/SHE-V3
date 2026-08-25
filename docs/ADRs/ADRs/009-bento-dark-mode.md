# ADR-009: Dark-Mode-First Bento Grid Design

**Status:** Locked
**Date:** 2024-Q4
**Decision maker:** Lead Engineer + Mobile/Frontend Lead

## Context

SHE V3's mobile app is the primary daily-use interface for a consumer smart-home product. The user opens it dozens of times per day to toggle a light, check energy usage, or arm an automation. The UI must therefore feel premium, glanceable, and unobtrusive — the same bar set by Apple Home, Google Home, Tesla, and the better Tuya-backed apps.

A consumer smart-home app launched in 2024 must look like it belongs on a 2024 phone. The dominant design language of premium consumer apps (Apple Home, Tesla, Google Home, Linear, Vercel) is **dark-mode-first with bento-grid layouts** — large rounded tiles, deep-navy or near-black backgrounds, bright accent colors, generous whitespace, and subtle micro-interactions (haptic taps, glow effects, animated state transitions). Light-mode-default apps feel dated by comparison.

For the Ethiopian market specifically, dark mode has a secondary benefit: most of our users are on mid-range Android phones (Tecno, Infinix, Samsung A-series) with OLED or AMOLED displays where dark pixels consume materially less power. A dark-mode-default app is a small but real battery-life win for users who may not have reliable charging throughout the day.

The branding decision is to use a **Deep Navy primary background (#0B1D37)** with a **Bright Sky Blue accent (#56B4FA)** — these are NOT the typical "tech startup" indigo/blue (à la Stripe, Linear, Vercel) but a distinct navy-sky palette we own. Per the design system, **indigo and pure blue are explicitly excluded** to avoid the generic "Linear-clone" look.

## Decision

Build the SHE V3 mobile app (Flutter) and admin web app (Next.js) **dark-mode-first** with a **Bento grid dashboard layout**. The design language is:

- **Background:** Deep Navy `#0B1D37` (primary), Darker Navy `#061226` (recessed panels), Lighter Navy `#142544` (raised cards)
- **Accent:** Bright Sky Blue `#56B4FA` (primary CTA, active state glow), Soft Sky Blue `#8FCAF7` (hover, secondary)
- **Text:** Off-white `#F2F5FA` (primary), Cool Grey `#A0B0C8` (secondary), Dim Grey `#6E7E96` (tertiary)
- **State:** Green `#3DD68C` (on/success), Red `#FF6B6B` (off/error), Amber `#FFB23E` (warning)
- **Excluded colors:** Indigo (`#6366F1` family), pure blue (`#3B82F6` family), violet, purple — these are the "every SaaS startup" palette and we explicitly avoid them

**Bento grid layout:** the home dashboard is a responsive grid of rounded-corner tiles (16px radius), each tile representing a device, group, or summary. Active devices have a subtle Sky Blue glow on their tile border. Tiles support long-press for quick actions (rename, move to room, delete). The grid reflows from 2-column on phones to 3-column on tablets and 4-column on the admin web.

**Micro-interactions:** haptic feedback on every toggle (Flutter HapticFeedback), animated state transitions (200ms ease-out), glow-pulse on active relay tiles, animated energy-usage sparkline. Dark mode is the default; light mode is supported as a toggle (Material 3 adaptive theme) but not the default.

**Light mode** (when user toggles): Off-white `#F2F5FA` background, Deep Navy `#0B1D37` text, same Bright Sky Blue accent. Designed for daylight outdoor visibility — relevant for users in bright Ethiopian highland sun.

## Alternatives Considered

### Alternative A: Light-mode default (with dark mode toggle)
- **Pros:** Conventional; easier to read in direct sunlight; closer to existing Ethiopian fintech/banking app conventions (CBE, Dashen, Bank of Abyssinia all default to light mode); lower contrast-ratio requirements to pass WCAG AA.
- **Cons:** Feels dated next to premium 2024 consumer apps; does not differentiate from the Tuya/Sonoff default-light-theme competitors; loses the OLED battery-saving benefit; Apple Home, Google Home, and Tesla all default to dark — a light-default app signals "enterprise-y" or "old." **Rejected for V3 — revisit only if beta user feedback strongly favors light default.**

### Alternative B: Material Design 3 default (Google's design system)
- **Pros:** Free, well-documented, dynamic color theming on Android 12+, Flutter has first-class Material 3 widgets.
- **Cons:** Generic — every Flutter app looks like Material 3 by default; no brand differentiation; Google's color palette is the excluded indigo/blue family; Material 3's default typography (Roboto) is flat and corporate; would look like "yet another Flutter app." **Rejected as the design *language* — we use Material 3 *widgets* but with our own theme/colors/typography layered on top.**

### Alternative C: Custom design language (build our own design system from scratch)
- **Pros:** Maximum differentiation; no Material/Cupertino constraints; could be uniquely "Ethiopian" (e.g., inspired by traditional textile patterns, local color symbolism).
- **Cons:** Massive design + engineering investment; we don't have a dedicated design team; Flutter's widget catalog is built around Material/Cupertino, deviating means writing custom widgets for everything (buttons, switches, sliders, dialogs); risk of inconsistent UX; accessibility compliance harder to audit. **Rejected for V3 — revisit in V4 if we hire a design team.**

### Alternative D: Cupertino-first (Apple design language)
- **Pros:** Premium feel on iOS; recognizable to Apple users; clean typography.
- **Cons:** Most of our users are on Android (Ethiopian mobile market is ~85% Android); Cupertino widgets look wrong on Android (back-button placement, modal sheets, typography); Apple HIG conventions don't translate well to a smart-home Bento grid. **Rejected.**

## Consequences

### Positive
- Premium feel that benchmarks against Apple Home / Tesla / Google Home — differentiates from Tuya/Sonoff/Shelly default-light-theme apps
- OLED battery savings on mid-range Android phones (real, measurable — dark pixels on OLED consume ~0.3 W vs ~1.2 W for white pixels at full brightness)
- Brand differentiation — the navy/sky palette is distinct from the indigo-blue every SaaS startup uses
- Bento grid is glanceable — user can see and toggle 8–16 devices without scrolling
- Micro-interactions (haptic feedback, glow, animated sparklines) make the app feel "alive" — small but real user delight
- Light mode supported as a fallback for direct-sunlight use (highland Ethiopia is bright)
- Works across Flutter (mobile) and Next.js (admin web) — same design tokens, same color palette, same component shapes

### Negative
- **Light mode must also be supported** — doubles the design + QA effort (every screen tested in both modes, every screenshot in marketing materials needs both versions)
- **Dark mode is harder for accessibility** — contrast ratios must be carefully checked (Deep Navy `#0B1D37` background with Cool Grey `#A0B0C8` secondary text = 4.6:1 contrast, just barely WCAG AA; tertiary Dim Grey `#6E7E96` text = 2.8:1, fails AA for body text — must only be used for non-essential labels)
- **No indigo/blue** is a self-imposed constraint that rules out some otherwise-good color choices — the team must resist the temptation to "just use Linear's blue"
- **Bento grid requires careful empty-state design** — when a user has no devices yet, the grid looks empty and sad; we need onboarding tiles ("Add your first device", "Watch setup video")
- **Custom theming** means we maintain our own design tokens file — Material 3's dynamic color (Android 12+) won't apply automatically

### Neutral
- The dark-mode-first decision is reversible in principle (a theme toggle is just a few lines of code) but expensive in practice (every screen, every screenshot, every marketing asset assumes dark default)
- The Bento grid pattern is increasingly common (Apple Home, Google Home, SmartThings, Tesla all use it) — we are not inventing a layout, we are adopting a convention
- The haptic feedback requires platform-specific code (Flutter `HapticFeedback.selectionClick` on Android, `HapticFeedback.lightImpact` on iOS) — minor engineering cost
- The design tokens are shared between the Flutter mobile app and the Next.js admin web (single source of truth in `design-tokens.json`) — keeps the visual language consistent across surfaces
- Typography uses a single sans-serif family (Plus Jakarta Sans for headings, Inter for body) — both are open-source, support Amharic characters via fallback, and avoid the licensing cost of premium fonts
- The exclusion of indigo/blue is a brand guideline, not a technical constraint — engineers may push back; the design-system owner has final say on color choices

## References
- V3-MOBILE-APP.md (full mobile app design spec, theme tokens, Bento grid layout)
- V3-ADMIN-WEB-APP.md (admin web design — same design tokens, Next.js implementation)
- V3-I18N.md (Amharic + English typography in both dark and light modes)
- V3-DESIGN-SYSTEM.md (color palette, typography, component shapes — to be created in V3.1)
- ADR-010 (Ethiopia-only scope — design language is for the Ethiopian market)
