# Usage Bar

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple&logoColor=white)](#requirements)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/loonyvoyager/usage-bar?label=release)](https://github.com/loonyvoyager/usage-bar/releases/latest)

A tiny native **macOS menu-bar app** that shows your current **claude.ai usage** at a
glance — session %, weekly %, per-model split, reset countdowns, and pay-as-you-go
credits — so you never have to open claude.ai → Settings → Usage. It sits by your
clock: no Dock icon, no window.

> Glance up and see how much of your session you've burned and when it resets —
> without breaking flow to go check the website.

<p align="left">
  <img src="assets/screenshot.png" width="720"
       alt="UsageBar menu-bar dropdown showing session, weekly, per-model, and credit usage">
</p>

<p align="left">
  <a href="https://github.com/loonyvoyager/usage-bar/releases/latest/download/UsageBar.dmg"><b>⬇&nbsp; Download UsageBar.dmg</b></a><br>
  <sub>Signed &amp; notarized — opens with no Gatekeeper warning.</sub>
</p>

> **Unofficial — not affiliated with, or endorsed by, Anthropic.**
> See [Trademark / not affiliated](#trademark--not-affiliated).

## What it shows

- **Session window** — % used, a reset countdown, and a sparkline of recent samples.
- **Weekly window** — % used + reset (for plans with a weekly cap).
- **By model** — per-model usage (e.g. Opus / Sonnet) when claude.ai exposes it.
- **Credits** — pay-as-you-go "extra usage" spend vs. your monthly cap.
- **Menu-bar label** — choose `% / time left` (e.g. `6%/4h3m`), `Icon + %`, or
  `Icon only`; it tints orange past a warning threshold you set.

Each row appears only if claude.ai returns that data, so the panel stays tidy.

## Requirements

- macOS 13.0 or later
- A claude.ai account (Pro / Max / Team — anything with a usage page)

## Install

1. Download **`UsageBar.dmg`** from
   [Releases](https://github.com/loonyvoyager/usage-bar/releases/latest), open
   it, and drag the app into **Applications**.
2. It's **signed and notarized**, so it just opens — no right-click, no Gatekeeper
   warning.
3. It's menu-bar-only (**no Dock icon, no window**). Click the gauge near your
   clock and **sign in to claude.ai once**; after that it stays signed in.

**Prefer the terminal?** Install or remove it from the command line:

```sh
# install — downloads the latest signed release into /Applications
curl -fsSL https://raw.githubusercontent.com/loonyvoyager/usage-bar/main/scripts/install.sh | bash

# uninstall — removes the app plus its saved session and settings
curl -fsSL https://raw.githubusercontent.com/loonyvoyager/usage-bar/main/scripts/uninstall.sh | bash
```

Settings — launch at login, refresh interval, warning threshold, menu-bar style,
and sign out — live behind the ⚙︎ gear in the dropdown.

## Privacy

Your credentials **never leave your Mac**. Sign-in happens in an embedded
`WKWebView` (the real claude.ai login) and cookies stay in the app's local data
store. **No API key, no telemetry, no third-party servers.**

## How it works

There's no official consumer usage API, so the app reads the same internal
endpoint claude.ai's own usage page calls — by running `fetch()` inside a hidden
web view on the claude.ai origin, so it rides your normal logged-in session.
Because that endpoint is internal, it can change without notice; all of that
knowledge is isolated in one file (`UsageSession.swift`) with defensive parsing,
so a change degrades to a visible "couldn't read usage" message (never a crash)
and is a one-file fix.

## Build from source

Open `UsageBar.xcodeproj` in Xcode and run (⌘R). To build a signed,
notarized release for distribution, see [`DISTRIBUTION.md`](DISTRIBUTION.md).

<details>
<summary>Project layout</summary>

| File | Role |
|------|------|
| `UsageBarApp.swift` | `@main` entry; menu-bar-only scene. |
| `AppDelegate.swift` | Status item, the dropdown panel, login window, refresh timer; the one place that wires network → store → UI. |
| `UsageSession.swift` | **Quarantined** cookie session + usage fetch + parsing — the only file that knows URLs / JSON keys / cookies. |
| `LoginView.swift` | Embedded `WKWebView` login. |
| `UsagePopoverView.swift` | SwiftUI dropdown UI; reads state, never touches the network. |
| `Usage.swift` | `Usage` model + observable store + settings. |

State flows one way: `UsageSession` → `UsageStore` → SwiftUI.
</details>

## Trademark / not affiliated

This is an unofficial, open-source project. **It is not affiliated with, endorsed
by, or sponsored by Anthropic.** "Claude" and the Claude logo are trademarks of
Anthropic. The app reads an internal claude.ai endpoint that has no public API and
may change or break at any time; use it at your own discretion.

## License

[MIT](LICENSE) © 2026 Grigorii Lapin.
