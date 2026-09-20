#!/bin/bash
#
# Builds iRecord with Swift Package Manager and assembles a runnable, ad-hoc
# signed .app bundle. Works with Command Line Tools only (no Xcode required).
#
# Usage:
#   ./scripts/build_app.sh            # release build
#   ./scripts/build_app.sh debug      # debug build
#   ./scripts/build_app.sh release run  # build then launch
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="${1:-release}"
APP_NAME="iRecord"
BUNDLE_ID="com.irecord.app"
APP_DIR="$ROOT/build/$APP_NAME.app"

echo "==> Building ($CONFIG) with Swift Package Manager…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC="$BIN_PATH/$APP_NAME"

if [[ ! -f "$EXEC" ]]; then
    echo "error: built executable not found at $EXEC" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXEC" "$APP_DIR/Contents/MacOS/$APP_NAME"
mkdir -p "$APP_DIR/Contents/Helpers"
cp "$BIN_PATH/IRecordCLI" "$APP_DIR/Contents/Helpers/irecord"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# App icon (generate/refresh with ./scripts/render_icon.sh)
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# A persistent signing identity keeps the Screen Recording TCC grant stable
# across upgrades. Ad-hoc remains a development fallback.
SIGN_IDENTITY="${IRECORD_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Code signing (ad-hoc; macOS may request Screen Recording again after rebuild)…"
else
    echo "==> Code signing with $SIGN_IDENTITY…"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP_DIR" 2>/dev/null || \
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"

echo "==> Done: $APP_DIR"

if [[ "${2:-}" == "run" ]]; then
    echo "==> Launching…"
    open "$APP_DIR"
fi
