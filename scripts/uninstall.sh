#!/usr/bin/env bash
#
# uninstall.sh — remove ClaudeUsageBar and the local data it created (settings +
# the saved claude.ai web-view session).
#
#   curl -fsSL https://raw.githubusercontent.com/loonyvoyager/claude-usage/main/scripts/uninstall.sh | bash
#
set -euo pipefail

APP_NAME="ClaudeUsageBar"
BUNDLE_ID="com.local.ClaudeUsageBar"          # keep in sync with PRODUCT_BUNDLE_IDENTIFIER
APP="${PREFIX:-/Applications}/$APP_NAME.app"

echo "==> Quitting $APP_NAME…"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> Removing $APP…"
rm -rf "$APP"

echo "==> Removing local data (settings + saved session/cookies)…"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf \
  "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
  "$HOME/Library/Caches/$BUNDLE_ID" \
  "$HOME/Library/WebKit/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

echo ""
echo "Done."
echo "If you had 'Launch at login' on, also remove it in"
echo "System Settings → General → Login Items (macOS tracks that separately)."
