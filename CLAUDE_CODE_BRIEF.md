# ClaudeUsageBar — Claude Code Session Brief

**Read this first, then `README.md`.** This document is the source of truth for
what we're building, what's already decided, and what each session should do. Do
not re-open settled decisions (see "Locked decisions"). When a session is done,
update the "Status" checkboxes and leave the rest intact.

---

## 1. Product in one line

A native macOS **menu bar** app that shows current Claude session usage (time
left, % used, reset time) so the user never has to open claude.ai → Settings →
Usage. Inspired by a community desktop widget.

## 2. Locked decisions (do NOT revisit)

- **Platform:** native macOS, Swift + SwiftUI + AppKit. Menu bar agent
  (`LSUIElement = true`), no Dock icon, no main window.
- **Min target:** macOS 13.0.
- **Auth:** embedded `WKWebView` login. User signs in once; cookies persist in a
  shared `WKWebsiteDataStore`. No cookie scraping from other browsers, no manual
  token paste, no API key. This is final — chosen for "native + zero manual entry."
- **Data source:** the internal endpoint claude.ai's own usage page calls. There
  is NO official consumer usage API (the admin Rate Limits API does not cover
  Pro/Max/Team chat). This fragility is accepted and **quarantined in
  `ClaudeSession.swift`** — no endpoint/JSON knowledge may leak into other files.
- **No telemetry / no third parties.** Credentials never leave the web view.

## 3. Architecture & invariants

```
ClaudeUsageBarApp.swift   App entry (menu-bar-only scene)
AppDelegate.swift         NSStatusItem, NSPopover, login window, refresh timer
ClaudeSession.swift       Cookie session + usage fetch + parsing  ← fragile, isolated
LoginView.swift           Embedded WKWebView login; persists cookies
UsagePopoverView.swift    SwiftUI popover UI
Usage.swift               Model (Usage) + observable store (UsageStore/UsageState)
```

**Invariants every session must preserve:**

1. **Endpoint isolation.** Only `ClaudeSession.swift` knows URLs, paths, JSON
   keys, or cookie names. UI and model code consume typed Swift values only.
2. **State flows one way:** `ClaudeSession` → `UsageStore.state` (an enum) → UI.
   UI never calls the network directly; it calls closures passed down from
   `AppDelegate` (`onRefresh`, `onLogin`, `onQuit`).
3. **Defensive parsing stays defensive.** `parseUsage` must keep tolerating
   0–1 vs 0–100, multiple key names, and ISO/epoch timestamps. Adding new fields
   must not make existing parsing throw.
4. **Never block the main thread.** Network on `Task`/async; UI updates via
   `MainActor`. The launch-time cookie check is the only bounded wait (2s cap).
5. **Graceful degradation.** Any new "extended data" field is optional. If the
   endpoint doesn't return it, the UI hides that row — it never errors the whole
   popover.
6. **Failure is a state, not a crash.** Everything routes through
   `UsageState.error(String)` / `.needsLogin`.

## 4. How to verify the endpoint (do this before Phase 2)

Before adding extended data, confirm the real response shape — don't guess:

1. Log in at claude.ai in a browser, open DevTools → Network.
2. Open Settings → Usage. Note the request(s) that populate it: path, method,
   and the JSON response keys (percent/utilization, reset timestamp, plus any
   per-model or weekly-vs-session breakdown).
3. Record findings in a new `ENDPOINT_NOTES.md` (gitignored if it contains org
   IDs). Update the `candidates` array and `parseUsage` in `ClaudeSession.swift`
   to match reality, and prune candidates that 404.

Acceptance for this task: the app shows the user's *actual* % and reset, matching
the website, with no guessed paths left in the candidate list.

---

## 5. Roadmap (phased sessions)

Each phase is a self-contained Claude Code session. Ship and verify before moving on.

### Phase 0 — Build & smoke test  ☑ (done 2026-06-16)
- Get it compiling in Xcode per README. Confirm: icon appears, login web view
  loads, after login the popover leaves `.needsLogin`.
- Likely fixes: `NSHostingController` wrapping of the `NSViewRepresentable`
  login view; `@main` + `NSApplicationDelegateAdaptor` wiring; entitlements.
- **Done when:** app runs, you can sign in, and *some* real usage value renders.
- **Status:** whole project created from scratch (6 Swift files + hand-written
  `.xcodeproj` + shared scheme + README/ENDPOINT_NOTES). Builds clean via
  `xcodebuild` and launches as a menu-bar agent (LSUIElement) without crashing —
  no Dock icon. Confirmed end-to-end via screenshot 2026-06-16: signed in through
  the embedded web view; popover shows Session 5% / Weekly 7% / Sonnet 0% and the
  menu-bar `5%` label, matching the website. No App Sandbox yet (deferred to Phase 5).

### Phase 1 — Endpoint truth pass  ☑ (verified 2026-06-16)
- Do "How to verify the endpoint" above. Make the displayed numbers real and
  correct. Remove dead candidate paths.
- **Done when:** popover % and reset time match the website exactly.
- **Status:** captured the real endpoint from a logged-in claude.ai session
  (Chrome). Verified: `GET /api/organizations/{org}/usage` (org from
  `GET /api/organizations`, array → top-level `uuid`). Shape, field mapping, and
  gotchas (utilization is 0–100; microsecond ISO timestamps; nullable resets;
  unordered-dict trap) are documented in `ENDPOINT_NOTES.md`. `ClaudeSession`
  now parses the known shape explicitly (with a defensive loose fallback) and
  the dead 404 candidates are removed. Parse validated against the live payload:
  session 3%, weekly 6%, Sonnet 0% — and `extra_usage` (18.77) correctly NOT
  mistaken for the session value. Final visual match confirmed in the
  running app (screenshot): session/weekly/per-model render and track the website.

### Phase 2 — Dropdown with extended data  ☑ (done 2026-06-16)
> Partial: as a side effect of Phase 1, `Usage` already carries
> `weeklyPercent`/`weeklyReset`/`perModel`, `parseUsage` fills them from
> `seven_day` + `seven_day_opus`/`seven_day_sonnet`, and `UsagePopoverView`
> renders Session + Weekly + per-model rows conditionally (each hides when
> absent). "Last-updated" stamp is shown; `UsageStore` keeps the in-memory
> history ring buffer, now drawn as a session-history **sparkline**
> (`SparklineView` in `UsagePopoverView.swift`: auto-scaled with a minimum span,
> area fill + latest-point dot, and a "collecting" hint until 2+ samples exist).
> Also surfaces the `extra_usage` credit pool as a **Credits** row ($ used + bar
> + monthly limit, hidden when not enabled). **Optional later:** layout polish.

The popover becomes a richer panel. Target contents (show only what the endpoint
actually provides — each row optional):
- **Session window:** time left, % used, reset time (already have).
- **Weekly window** (Max): % used + reset, if exposed.
- **Per-model breakdown** if available (e.g. Opus vs Sonnet), as small rows.
- **Last-updated** timestamp + manual refresh (have refresh; add the stamp).
- **Sparkline/history (optional):** keep an in-memory ring buffer of the last N
  samples to draw a tiny usage-over-time line. In-memory only this phase.

Implementation notes:
- Extend `Usage` with optional fields (`weeklyPercent: Int?`, `weeklyReset:
  Date?`, `perModel: [ModelUsage]?`). Parsing fills what it finds.
- Add a `UsageDetailRow` SwiftUI subview; the popover composes rows conditionally.
- Keep popover width 300; grow height with content. Consider a `Divider` between
  session and weekly sections.
- **Done when:** all fields the endpoint returns are shown, each missing field
  hides cleanly, and the basic view still works if extended data is absent.

### Phase 3 — Menu bar icon: pixel art + animation  ☐
Replace the SF Symbol with a custom pixel-art mascot in the menu bar (the
screenshot mascot vibe). Requirements:
- **Template-image behavior** for the static fallback so it adapts to light/dark
  menu bars — OR explicitly use color art and verify legibility in both modes.
- Menu bar height is ~22pt; provide @1x/@2x assets sized for that. Pixel art must
  stay crisp — disable smoothing (nearest-neighbor); don't let AppKit blur it.
- **Animation:** drive frames with a `Timer` swapping `button.image`, or a
  short looping sequence. Keep it cheap and respectful:
  - Idle: static or very occasional blink.
  - **State-reactive:** a quick animation when usage crosses thresholds (e.g.
    >80% the mascot looks strained, like the `>_<` face in the reference), and a
    subtle tick near reset. Tie frames to `UsageState`, not a free-running loop.
  - Respect Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`)
    — fall back to static.
- Make it a toggle (see Phase 4 settings): "Pixel icon" on/off, default on;
  "Animate" on/off, default on.
- Keep the text label (`55%`) next to the icon optional via setting.
- **Done when:** crisp pixel mascot in the bar, looks right in light & dark,
  animates on threshold/reset, honors Reduce Motion, and can be turned off.

### Phase 4 — Settings & polish  ☐
- **Launch at login** (`SMAppService.mainApp` on macOS 13+).
- Settings popover/window: refresh interval, show-% label, pixel icon, animate,
  warning threshold (default 80%).
- Threshold color: tint icon/label when over threshold.
- Sign-out (clear the data store), re-login flow.
- **Done when:** settings persist (UserDefaults), launch-at-login works, sign-out
  fully clears session.
- **Status (2026-06-16, partial):** `AppSettings` (ObservableObject + UserDefaults)
  scaffold landed early with a **menu-bar display mode** setting — *Icon + %*
  (gauge + "14%") vs *% / time left* ("14%/3h29m", no icon) — chosen via a picker
  in the dropdown, persisted, live-updating (a 60s tick keeps the countdown
  current between 5-min network refreshes). Popover also compacted ~25%
  vertically. Still TODO: launch-at-login, refresh-interval/threshold settings,
  sign-out.

### Phase 5 — Distribution (optional)  ☐
- Code signing + notarization for sharing outside your Mac, or document the
  right-click-Open path for unsigned. Decide later.

---

## 6. Definition of done (every session)

- Compiles clean, no main-thread blocking, no new force-unwraps on network data.
- Invariants in §3 still hold (especially endpoint isolation).
- New data fields are optional and degrade gracefully.
- Update the Status checkboxes in §5 and note any endpoint findings.

## 7. Out of scope (for now)

- Windows/Linux. iOS companion. Multi-account switching. Notifications/alerts
  (could be a later phase). Persisting usage history to disk (Phase 2 keeps it
  in memory).
