#!/usr/bin/env bash
#
# install.sh — download the latest signed & notarized ClaudeUsageBar and install
# it to /Applications. For people who'd rather not click around a .dmg.
#
#   curl -fsSL https://raw.githubusercontent.com/loonyvoyager/claude-usage/main/scripts/install.sh | bash
#
# Override the install location with PREFIX (e.g. PREFIX="$HOME/Applications").
#
set -euo pipefail

APP_NAME="ClaudeUsageBar"
REPO="loonyvoyager/claude-usage"
DEST="${PREFIX:-/Applications}"
DMG_URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.dmg"

tmp="$(mktemp -d)"
mnt=""
cleanup() { [ -n "$mnt" ] && hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

echo "==> Downloading the latest $APP_NAME…"
curl -fL --progress-bar "$DMG_URL" -o "$tmp/$APP_NAME.dmg"

echo "==> Mounting…"
mnt="$(hdiutil attach "$tmp/$APP_NAME.dmg" -nobrowse -readonly | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -d "$mnt/$APP_NAME.app" ] || { echo "error: $APP_NAME.app not found in the disk image"; exit 1; }

echo "==> Installing to $DEST…"
rm -rf "$DEST/$APP_NAME.app"
if ! cp -R "$mnt/$APP_NAME.app" "$DEST/" 2>/dev/null; then
  echo "Couldn't write to $DEST. Re-run with sudo, or pick a writable spot:"
  echo "  PREFIX=\"\$HOME/Applications\" bash install.sh"
  exit 1
fi

echo "==> Launching…"
open "$DEST/$APP_NAME.app"
echo ""
echo "Installed. Look for the gauge in your menu bar — click it and sign in to claude.ai once."
echo "Uninstall any time with scripts/uninstall.sh."
