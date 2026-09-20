#!/bin/bash
# Install an already-built bundle and its per-user CLI. No sudo required when
# the destination is writable. Does not kill a running App or discard recordings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/build/iRecord.app}"
DESTINATION="${2:-/Applications/iRecord.app}"
PARENT="$(dirname "$DESTINATION")"
[[ "$DESTINATION" == *.app && -d "$SOURCE" ]] || { echo "Expected source and destination .app paths" >&2; exit 2; }
[[ -w "$PARENT" ]] || { echo "Destination is not writable; install into ~/Applications instead." >&2; exit 1; }
STAGE="$(mktemp -d "$PARENT/.irecord-install-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$SOURCE" "$STAGE/iRecord.app"
/usr/bin/codesign --verify --deep --strict "$STAGE/iRecord.app"
[[ -x "$STAGE/iRecord.app/Contents/Helpers/irecord" ]] || { echo "Bundle has no CLI" >&2; exit 1; }
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGE/previous.bundle-backup"; fi
if ! mv "$STAGE/iRecord.app" "$DESTINATION"; then
    [[ ! -d "$STAGE/previous.bundle-backup" ]] || mv "$STAGE/previous.bundle-backup" "$DESTINATION"
    exit 1
fi
"$DESTINATION/Contents/Helpers/irecord" install
printf 'Installed: %s\nRestart the App when any current recording is finished.\n' "$DESTINATION"
