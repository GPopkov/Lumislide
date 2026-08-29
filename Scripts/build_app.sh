#!/bin/bash
# ============================================================================
# Сборка релизного .app бандла Lumislide из Swift Package.
#
# Использование:
#   ./Scripts/build_app.sh [mas|direct]
#
#   mas     — конфигурация для Mac App Store (sandbox-подпись)
#   direct  — конфигурация для прямого распространения (notarized,
#             sandbox + hardened runtime)
#
# Требования:
#   - Xcode (для подписи и не только SPM): xcode-select должен указывать
#     на Xcode, либо задайте DEVELOPER_DIR.
#   - Валидный signing identity для macOS (см. `security find-identity`).
# ============================================================================

set -euo pipefail

CHANNEL="${1:-direct}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Конфигурация -----------------------------------------------------------

APP_NAME="Lumislide"
BUNDLE_ID="com.lumislide.app"

# Подпись: первый доступный Apple Development identity.
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | grep -Eo 'Apple Development: [^\"]+' | head -1)}"
if [ -z "$IDENTITY" ]; then
    echo "ERROR: no Apple Development signing identity found."
    echo "Set IDENTITY=<name> or create one in Xcode > Settings > Accounts."
    exit 1
fi

case "$CHANNEL" in
  mas)
    ENTITLEMENTS="Supporting/Entitlements/MAS.entitlements"
    ;;
  direct)
    ENTITLEMENTS="Supporting/Entitlements/Direct.entitlements"
    ;;
  *)
    echo "Usage: $0 [mas|direct]"
    exit 1
    ;;
esac

echo "▶ Channel:     $CHANNEL"
echo "▶ Identity:    $IDENTITY"
echo "▶ Entitlements: $ENTITLEMENTS"

# --- Сборка бинаря через SPM (release) --------------------------------------

echo "▶ Building (swift build -c release)..."
swift build -c release --product Lumislide

BIN_PATH=".build/release/Lumislide"

# --- Сборка .app бандла ------------------------------------------------------

APP_DIR="dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Supporting/Info.plist" "$APP_DIR/Contents/Info.plist"

# Иконка приложения (.icns) в Resources — по CFBundleIconFile из Info.plist.
cp "Supporting/Lumislide.icns" "$APP_DIR/Contents/Resources/Lumislide.icns"

# Копируем ресурсные бандлы Swift Package (Metal-шейдеры Transitions.metal,
# сгенерированный Bundle.module) в Contents/Resources. Без этого
# `Bundle.module` падает с fatalError при первом Metal-переходе.
for bundle in .build/release/*.bundle; do
    if [ -d "$bundle" ]; then
        echo "▶ Copying resource bundle: $(basename "$bundle")"
        cp -R "$bundle" "$APP_DIR/Contents/Resources/"
    fi
done

# --- Подпись ----------------------------------------------------------------

echo "▶ Signing with entitlements..."
codesign --force --options runtime \
    --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR"

echo "▶ Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR" || {
    echo "ERROR: signature verification failed"
    exit 1
}

echo ""
echo "✅ Built: $APP_DIR"
echo "   Signed with: $IDENTITY"
echo ""
if [ "$CHANNEL" = "direct" ]; then
    echo "Next step: ./Scripts/notarize.sh dist/$APP_NAME.app"
fi
