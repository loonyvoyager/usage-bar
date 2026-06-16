# Endpoint Notes

**Phase 1 — VERIFIED 2026-06-16** (captured from a logged-in claude.ai session
via DevTools/Chrome). The guessed candidate list has been replaced in
`ClaudeSession.swift` with the real endpoint below.

> This file is redacted (no real org UUID / email) and is safe to commit. If you
> paste a real organization UUID in, uncomment the entry in `.gitignore`.

## Org discovery

- **`GET /api/organizations`** → `200`, a JSON **array** of orgs; each element
  has a top-level **`uuid`** (this is the org id used to scope usage).
  - ⚠️ Do *not* use `/api/bootstrap` → `account.uuid`: that's the **account**
    id, not the org id. (`/api/bootstrap` is kept only as a last-resort fallback.)
  - This account has 2 orgs; the app tries each org's `/usage` and uses the
    first that returns a parseable body.

## Usage request

- **`GET /api/organizations/{org}/usage`** → `200`. No special headers needed
  (cookies via `credentials: 'include'`, `accept: application/json`).

### Response shape

```json
{
  "five_hour":  { "utilization": 3, "resets_at": "2026-06-16T16:09:59.853052+00:00" },
  "seven_day":  { "utilization": 6, "resets_at": "2026-06-20T13:59:59.853073+00:00" },
  "seven_day_oauth_apps": null,
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization": 0, "resets_at": null },
  "seven_day_cowork": null,
  "seven_day_omelette": null,
  "tangelo": null,
  "iguana_necktie": null,
  "omelette_promotional": null,
  "cinder_cove": null,
  "extra_usage": {
    "is_enabled": true, "monthly_limit": 10000, "used_credits": 1877,
    "utilization": 18.77, "currency": "USD", "decimal_places": 2,
    "disabled_reason": null, "daily": null, "weekly": null
  }
}
```

### Field mapping (→ `Usage`)

| JSON | Meaning | Maps to |
|------|---------|---------|
| `five_hour` | **Session** window (5-hour rolling) | `sessionPercent`, `sessionReset` |
| `seven_day` | **Weekly** window (Max plan) | `weeklyPercent`, `weeklyReset` |
| `seven_day_opus`, `seven_day_sonnet` | per-model weekly (nullable) | `perModel` (only these two surfaced) |
| `extra_usage` | pay-as-you-go credit pool | `credits` (Credits row: $ used + bar + monthly limit) |
| `seven_day_cowork`, `tangelo`, `iguana_necktie`, `omelette*`, `cinder_cove` | internal/experimental buckets | intentionally ignored |

### Gotchas (handled in code)

- **`utilization` is on a 0–100 scale** (e.g. `3` == 3%, `18.77` == 18.77%).
  Do **not** apply a 0–1 → 0–100 fraction rescale to it — that would turn a real
  0.5% into 50%. `clampPercent` rounds/clamps only.
- **Timestamps carry microsecond fractions + a numeric offset**
  (`...59.853052+00:00`). `ISO8601DateFormatter` with `.withFractionalSeconds`
  parses this on recent macOS, but to be safe on macOS 13 `parseDate` also
  strips the sub-second fraction and retries.
- **`resets_at` can be `null`** (e.g. `seven_day_sonnet`) — `Window.reset` is optional.
- Don't recursively grab "the first `utilization`": the payload has several
  (`five_hour`, `seven_day`, `seven_day_sonnet`, `extra_usage`). Swift dict order
  is non-deterministic, so the known keys are read **explicitly**.

## Verification

Parsing the captured payload yields: session **3%** (resets 16:09:59Z), weekly
**6%** (resets 2026-06-20 13:59:59Z), Sonnet **0%**, Opus absent. Confirmed via a
standalone Swift run of the parse logic.

## Acceptance (brief §4)

✅ App shows the user's actual % and reset; only the real, verified path remains
in `usageCandidates` (the 404 guesses were removed).
