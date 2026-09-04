# Changelog

Notable changes to UsageBar. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions track app releases.

## [Unreleased]

### Added
- **Meters** menu-bar style — the session window (and the weekly one, when
  claude.ai exposes it) drawn as a percentage above a small segmented bar.
  Rendered as a template image, so it inverts correctly on light/dark menu bars
  and still picks up the warning tint. Its width is fixed to the widest possible
  label, so the status item never resizes as the numbers change.
- GitHub Actions CI: an unsigned build on every push / pull request.

### Fixed
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
