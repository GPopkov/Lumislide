#!/bin/bash
# ============================================================================
# Notarization релизного .app для прямого распространения (outside MAS).
#
# Использование:
#   ./Scripts/notarize.sh dist/Lumislide.app
#
# Требования:
#   - Apple ID и app-specific password (см. https://appleid.apple.com ->
#     Sign-In and Security -> App-Specific Passwords). Можно передать через
#     переменные окружения:
#       APPLE_ID, APPLE_PASSWORD (или APPLE_TEAM_ID).
#   - Xcode 13+ (xcrun notarytool).
# ============================================================================

set -euo pipefail

APP_PATH="${1:-dist/Lumislide.app}"
if [ ! -d "$APP_PATH" ]; then
    echo "Usage: $0 <path-to.app>"
    exit 1
fi

APPLE_ID="${APPLE_ID:?Set APPLE_ID (e.g. you@example.com)}"
APPLE_PASSWORD="${APPLE_PASSWORD:?Set APPLE_PASSWORD (app-specific password)}"
TEAM_ID="${APPLE_TEAM_ID:-}"

echo "▶ Zipping app for submission..."
ZIP_PATH="$(mktemp -d)/Lumislide.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "▶ Submitting to Apple notary service..."
if [ -n "$TEAM_ID" ]; then
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait
else
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --wait
fi

echo "▶ Staping notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo ""
echo "✅ Notarized: $APP_PATH"
echo "   Ready for distribution (drag to Applications, or publish)."
