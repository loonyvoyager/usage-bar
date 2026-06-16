# ClaudeUsageBar

A native macOS **menu bar** app that shows your current Claude usage (session %,
reset time) without opening claude.ai → Settings → Usage.

> Read `CLAUDE_CODE_BRIEF.md` first — it is the source of truth for scope,
> locked decisions, architecture invariants, and the phased roadmap. This README
> is just how to build and run.

## Requirements

- macOS 13.0+
- Xcode 15+ (developed/verified with Xcode 26.5, Swift 5 language mode)

## Build & run (Xcode)

1. Open `ClaudeUsageBar.xcodeproj`.
2. Select the **ClaudeUsageBar** scheme (already shared) and a *My Mac* destination.
3. If prompted about signing: under *Signing & Capabilities*, set **Team** to your
   personal team, or set signing to *Sign to Run Locally* / *None*. This is a
   personal local tool — no paid account needed to run it on your own Mac.
4. **Run** (⌘R).

There is **no Dock icon and no app window** — it's a menu bar agent
(`LSUIElement = true`). Look for the gauge icon in the right side of the menu bar.

### First launch

- On first run you're **not signed in** → click the menu bar icon → **Sign in to
  Claude**. A window opens with claude.ai's real login (embedded `WKWebView`).
- Sign in once. Cookies persist in the shared `WKWebsiteDataStore`, so you stay
  signed in across launches.
- After login the popover should leave the "Not signed in" state and show a usage
  value (see the endpoint caveat below).

## Build & verify (command line)

```sh
xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

This is the fast "does it still compile" check used during development.

## Architecture (see brief §3 for the invariants)

| File | Role |
|------|------|
| `ClaudeUsageBarApp.swift` | `@main` entry; menu-bar-only scene (`Settings{}`). |
| `AppDelegate.swift` | `NSStatusItem`, `NSPopover`, login window, refresh timer. The only place that wires network → store → UI. |
| `ClaudeSession.swift` | **Quarantined** cookie session + usage fetch + parsing. The *only* file that knows URLs / JSON keys / cookies. |
| `LoginView.swift` | Embedded `WKWebView` login; persists cookies in the shared data store. |
| `UsagePopoverView.swift` | SwiftUI popover UI. Reads state, calls closures, never touches the network. |
| `Usage.swift` | `Usage` model + observable `UsageStore` / `UsageState`. |

**Data flow is one way:** `ClaudeSession` → `UsageStore.state` (enum) → UI.

### How usage is fetched

Rather than reverse-engineer request headers, `ClaudeSession` runs the usage
request *inside a hidden `WKWebView` on the claude.ai origin* via
`callAsyncJavaScript("fetch(...)")`. The request therefore carries exactly the
cookies, origin, and credentials the real web app uses — no header guessing, no
httpOnly-cookie copying, no CORS. The login web view and this hidden web view
share `WKWebsiteDataStore.default()`, so one sign-in covers both.

## Endpoint (verified)

There is **no official consumer usage API**. ClaudeUsageBar calls the same
internal endpoint claude.ai's own usage page uses, now **confirmed** (2026-06-16):

- `GET /api/organizations` → array of orgs; each has a top-level `uuid`.
- `GET /api/organizations/{org}/usage` → `{ five_hour, seven_day,
  seven_day_opus/sonnet, extra_usage, … }`, where `five_hour` is the session
  window and `seven_day` the weekly one.

Full shape, field mapping, and parsing gotchas (0–100 utilization scale,
microsecond ISO timestamps, nullable resets) live in `ENDPOINT_NOTES.md`. This
is still an internal endpoint and may change without notice — `ClaudeSession`
parses the known keys explicitly with a defensive fallback, so a future change
degrades to a graceful error rather than a crash.

## Status

- **Phase 0 — Build & smoke test:** ✅ builds clean (CLI + Xcode), launches as a
  menu bar agent without crashing, login window wired. (One human check left:
  open in Xcode, sign in, confirm the popover leaves "Not signed in".)
- **Phase 1 — Endpoint truth pass:** ✅ real endpoint verified and parsed
  correctly (see `ENDPOINT_NOTES.md`); dead candidates removed.
- **Phase 2 — Extended data:** ✅ weekly + per-model (Opus/Sonnet) render
  conditionally, a last-updated stamp, and a session-history sparkline
  (auto-scaled, drawn from the in-memory ring buffer). Optional later:
  surface `extra_usage` credits.

See the roadmap in `CLAUDE_CODE_BRIEF.md` §5 for later phases.
