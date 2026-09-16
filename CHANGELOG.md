# Changelog

Notable changes to UsageBar. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions track app releases.

## [0.1.1] — 2026-09-16

### Added
- **Show in Dock** (off by default) — the app appears in the Dock and its icon
  becomes a live ring of the session %, number in the middle, on a plain white
  tile so it reads on any wallpaper. Blue normally, orange past the warning
  threshold; clicking it opens the dropdown. Toggling it flips the activation
  policy at runtime — no relaunch.
- **Meters** menu-bar style, now the **default** for new installs — the session
  window (and the weekly one, when claude.ai exposes it) drawn as a percentage
  above a small segmented bar.
  Rendered as a template image, so it inverts correctly on light/dark menu bars
  and still picks up the warning tint. Its width is fixed to the widest possible
  label, so the status item never resizes as the numbers change.
- GitHub Actions CI: an unsigned build on every push / pull request.
- The Dock ring's tile now follows macOS 26's **Icon & widget style** (System
  Settings → Appearance): Default, Dark, Clear (frosted glass) or Tinted
  (monochrome in your tint), each with its light/dark base and the Auto option —
  and repaints the moment the setting or the light/dark mode changes.
- **Menu bar color** setting — Auto (follow the menu bar's own text color),
  White, or Black — for bars where the system's choice reads poorly, such as a
  vivid wallpaper it deems "light".

### Removed
- The `Icon only` and `Icon + %` menu-bar styles — the picker is now just
  `Meters` and `% / time left`. A stored preference naming a removed style no
  longer parses, so those installs migrate to `Meters` on next launch.

### Fixed
- The orange warning tint never showed in the Meters style: `NSStatusBarButton`
  doesn't reliably apply `contentTintColor` to images. Label colors are now drawn
  into the image directly.
- Overlapping refreshes (timer + manual + post-login) could race on the shared
  web view and leak a task; refreshes are now coalesced.
- Menu-bar countdown kept ticking while a menu or drag was tracking, and the
  refresh timer no longer restarts when an unrelated setting changes.
- `package.sh` strips extended-attribute detritus (and now strict-verifies the
  signature) so an iCloud-synced checkout can't produce an unnotarizable build.

## [0.1.0] — 2026-07-02 (first public release)

### Added
- Menu-bar app showing claude.ai **session** and **weekly** usage (% + reset
  countdowns), a **per-model** breakdown, and pay-as-you-go **credits** — each row
  shown only when claude.ai exposes that data.
- In-memory **session-history sparkline**.
- Three **menu-bar display modes** — `% / time left`, `Icon + %`, `Icon only` —
  with a configurable warning-threshold tint.
- **Settings** (persisted): launch at login, refresh interval (1 / 5 / 15 / 30
  min), warning threshold, and sign out — in an expandable in-popover panel.
- Embedded claude.ai **web-view login**; credentials never leave the device, no
  telemetry.
- Beak-less, right-aligned dropdown panel with a minimal-width status item.
- Developer-ID **signed** `.dmg` build pipeline (`scripts/package.sh`).
  Notarization is wired up but pending Apple enabling it for the account, so this
  first build opens after a one-time confirmation (see the README's Install note).

### Notes
- Reads claude.ai's **internal** usage endpoint (no public API); isolated to
  `UsageSession.swift` so an upstream change degrades gracefully and is a
  one-file fix.
