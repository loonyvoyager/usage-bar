# Changelog

Notable changes to UsageBar. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions track app releases.

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
