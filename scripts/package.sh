#!/usr/bin/env bash
#
# package.sh — build a Developer-ID-signed, Apple-notarized UsageBar.dmg
# ready to host for download. See DISTRIBUTION.md for one-time setup.
#
# Required env:
#   DEVELOPMENT_TEAM   Your 10-char Apple Team ID (e.g. A1B2C3D4E5)
# Optional env:
#   NOTARY_PROFILE     notarytool keychain profile name (default: UsageBarNotary)
#   CONFIG             Xcode configuration (default: Release)
#
# Usage:  DEVELOPMENT_TEAM=A1B2C3D4E5 ./scripts/package.sh
#
set -euo pipefail

# --- resolve paths relative to the repo root (this script lives in scripts/) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

APP_NAME="UsageBar"
SCHEME="UsageBar"
PROJECT="$APP_NAME.xcodeproj"
CONFIG="${CONFIG:-Release}"
NOTARY_PROFILE="${NOTARY_PROFILE:-UsageBarNotary}"
TEAM_ID="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your 10-char Apple Team ID (see DISTRIBUTION.md)}"

BUILD="$ROOT/build"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD/export"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG="$BUILD/$APP_NAME.dmg"
STAGING="$BUILD/dmg"

echo "==> Cleaning $BUILD"
rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "==> Archiving ($CONFIG, Developer ID, hardened runtime)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  ENABLE_HARDENED_RUNTIME=YES

echo "==> Exporting Developer ID app"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

[ -d "$APP" ] || { echo "error: export did not produce $APP"; exit 1; }

# Strip extended-attribute detritus (com.apple.FinderInfo, etc.) that iCloud /
# Finder may stamp onto the bundle. codesign --strict and Apple notarization both
# reject "resource fork, Finder information, or similar detritus" — common when the
# repo lives on an iCloud-synced Desktop/Documents folder.
echo "==> Stripping xattr detritus"
xattr -cr "$APP"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/$APP_NAME.zip"
xcrun notarytool submit "$BUILD/$APP_NAME.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling the ticket into the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Building the .dmg (drag-to-Applications)"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
xattr -cr "$STAGING/$APP_NAME.app"   # re-strip in case iCloud re-stamped during notarization
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "==> Verifying"
spctl -a -vvv -t install "$APP" || true   # informational; the stapled app is what matters
shasum -a 256 "$DMG"

echo ""
echo "Done: $DMG"
echo "Upload that .dmg to your website. The app inside is signed, notarized, and stapled,"
echo "so users just open it — no Gatekeeper warning."
