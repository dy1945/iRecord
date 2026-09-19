#!/bin/bash
#
# Renders the app icon SVG into a multi-resolution .icns for the app bundle.
# Uses headless Chrome for rasterization (no extra dependencies to install).
#
# Usage:
#   ./scripts/render_icon.sh                 # renders Resources/Icon/AppIcon.svg
#   ./scripts/render_icon.sh path/to/x.svg   # renders an arbitrary SVG
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SRC="${1:-Resources/Icon/AppIcon.svg}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/Resources/AppIcon.icns"
ICONSET="$ROOT/build/AppIcon.iconset"

if [[ ! -f "$SRC" ]]; then
    echo "error: icon source not found: $SRC" >&2
    exit 1
fi
if [[ ! -x "$CHROME" ]]; then
    echo "error: Chrome not found at $CHROME (set CHROME to override)" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Strip the intrinsic width/height from the root <svg> tag only (rect elements
# carry their own width/height and must keep them) so the artwork scales to
# fill the viewport at any --window-size, then rasterize straight from vector.
NOSIZE="$(mktemp /tmp/irecord-icon.XXXXXX)"
mv "$NOSIZE" "$NOSIZE.svg"
NOSIZE="$NOSIZE.svg"
trap 'rm -f "$NOSIZE"' EXIT
sed -E '/^<svg/ s/ width="[0-9]+" height="[0-9]+"//' "$SRC" > "$NOSIZE"

render() { # size -> png
    "$CHROME" --headless --disable-gpu --hide-scrollbars \
        --default-background-color=00000000 \
        --screenshot="$2" --window-size="$1,$1" \
        "file://$NOSIZE" 2>/dev/null
}

render 16   "$ICONSET/icon_16x16.png"
render 32   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_16x16@2x.png" "$ICONSET/icon_32x32.png"
render 64   "$ICONSET/icon_32x32@2x.png"
render 128  "$ICONSET/icon_128x128.png"
render 256  "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_128x128@2x.png" "$ICONSET/icon_256x256.png"
render 512  "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_256x256@2x.png" "$ICONSET/icon_512x512.png"
render 1024 "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> Done: $OUT (from $SRC)"
