# Distribution — signed & notarized .dmg

How to build a `UsageBar.dmg` that anyone can download from a website and
open with no Gatekeeper warning.

The build is automated by [`scripts/package.sh`](scripts/package.sh); the steps
below are the **one-time setup** plus how to run it.

## One-time setup

You need an **Apple Developer Program** membership ($99/yr).

1. **Developer ID Application certificate.** In Xcode → Settings → Accounts, add
   your Apple ID, select your team → *Manage Certificates…* → **+** →
   *Developer ID Application*. (Or create it at
   <https://developer.apple.com/account/resources/certificates>.) It lands in
   your login keychain.

2. **Find your Team ID** (10 chars, e.g. `A1B2C3D4E5`) at
   <https://developer.apple.com/account> → Membership.

3. **App-specific password** for notarization: <https://account.apple.com> →
   Sign-In & Security → App-Specific Passwords → generate one.

4. **Store notary credentials once** (saved in your keychain, not in the repo):

   ```sh
   xcrun notarytool store-credentials "UsageBarNotary" \
     --apple-id "you@example.com" \
     --team-id "A1B2C3D4E5" \
     --password "abcd-efgh-ijkl-mnop"   # the app-specific password
   ```

## Build a release

```sh
DEVELOPMENT_TEAM=A1B2C3D4E5 ./scripts/package.sh
```

Output: `build/UsageBar.dmg` (plus its SHA-256). Upload that to your site.

The script: archives a Release build → exports a Developer-ID-signed app (hardened
runtime) → notarizes it with `notarytool` → staples the ticket into the app →
packs it into a drag-to-Applications `.dmg`.

> Override defaults with env vars: `NOTARY_PROFILE` (default `UsageBarNotary`),
> `CONFIG` (default `Release`).

## Versioning

Bump before each release in the target's build settings (or `project.pbxproj`):
`MARKETING_VERSION` (e.g. `1.0.0`) and `CURRENT_PROJECT_VERSION` (build number).

## Verifying it'll open cleanly

```sh
xcrun stapler validate build/export/UsageBar.app
spctl -a -vvv -t install build/export/UsageBar.app   # expect: accepted, source=Notarized Developer ID
```

## Troubleshooting

- **`notarytool` returns `Rejected`, status code 7000 — "Team is not yet
  configured for notarization"** (and the log shows `"issues": null`): nothing is
  wrong with your build. The Apple Developer *account* doesn't have the notary
  service enabled yet — seen on newly-activated memberships. Check for a pending
  Program License Agreement at <https://developer.apple.com/account>; if there's
  none to accept, contact Developer Programs Support (topic *Development and
  Technical*) and ask them to enable notarization for your team. Until then you
  can ship the signed-but-unnotarized app — users get a one-time "Open Anyway"
  prompt (v0.1.0 shipped this way; `scripts/install.sh` clears the quarantine
  flag so the terminal install skips the prompt entirely).
- **`codesign --verify --strict` or notarization fails with "resource fork,
  Finder information, or similar detritus not allowed"**: macOS stamped extended
  attributes (e.g. `com.apple.FinderInfo`) onto the bundle — common when the repo
  lives in an iCloud-synced folder (Desktop/Documents). `package.sh` strips them
  with `xattr -cr` before submitting; if you build by hand, do the same.
- **Submission stuck "In Progress" for hours**: the queue normally clears in
  minutes; multi-hour waits tend to end in the 7000 rejection above. Check
  <https://developer.apple.com/system-status/> and
  `xcrun notarytool log <submission-id>`.

## Notes

- **Hardened Runtime** is required for notarization and is enabled in the project.
  The app is **not sandboxed** (it doesn't need to be for Developer-ID
  distribution); `WKWebView` + networking work as-is. If a future change needs an
  entitlement, add an entitlements file and reference it in the target.
- **No App Store.** This is direct Developer-ID distribution. Mac App Store
  distribution would require sandboxing and a different signing/submission flow.
- **First run on the user's Mac:** because the app is a menu-bar agent
  (`LSUIElement`), it shows no Dock icon or window — just the menu-bar item.
  Mention that on the download page so people aren't confused when "nothing
  happens" after launch.
