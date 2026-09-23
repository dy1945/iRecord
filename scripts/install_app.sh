#!/bin/bash
# Install an already-built bundle and its per-user CLI. No sudo required when
# the destination is writable. Quit the App first; never replace a running bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/build/iRecord.app}"
DESTINATION="${2:-/Applications/iRecord.app}"
PARENT="$(dirname "$DESTINATION")"
[[ "$DESTINATION" == *.app && -d "$SOURCE" ]] || { echo "Expected source and destination .app paths" >&2; exit 2; }
[[ -w "$PARENT" ]] || { echo "Destination is not writable; install into ~/Applications instead." >&2; exit 1; }

require_app_stopped() {
    [[ -d "$DESTINATION" ]] || return 0
    local executable pids status
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DESTINATION/Contents/Info.plist")"
    # Match the actual executable vnode, not an app name or argv substring.
    # Moving it while mapped leaves the old process tied to a renamed backup.
    if pids="$(/usr/sbin/lsof -t -a -d txt "$DESTINATION/Contents/MacOS/$executable" 2>/dev/null)"; then
        echo "iRecord is running (PID: $pids). Finish recording, save any preview, quit iRecord, then run the installer again." >&2
        exit 1
    else
        status=$?
        [[ "$status" == 1 ]] || { echo "Unable to check whether iRecord is running; installation stopped." >&2; exit 1; }
    fi
}

require_app_stopped
STAGE="$(mktemp -d "$PARENT/.irecord-install-XXXXXX")"
APP_NAME="$(basename "$DESTINATION")"
BACKUP="$STAGE/backup/$APP_NAME"
INCOMING="$STAGE/incoming/$APP_NAME"
cleanup() {
    # Preserve the last working App even if installation fails or is interrupted.
    if [[ -d "$BACKUP" && ! -e "$DESTINATION" ]]; then
        if ! mv "$BACKUP" "$DESTINATION"; then
            echo "Could not restore the previous App. Backup retained at: $BACKUP" >&2
            return
        fi
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/incoming" "$STAGE/backup"
/usr/bin/ditto "$SOURCE" "$INCOMING"
/usr/bin/codesign --verify --deep --strict "$INCOMING"
[[ -x "$INCOMING/Contents/Helpers/irecord" ]] || { echo "Bundle has no CLI" >&2; exit 1; }
require_app_stopped
# Keep the .app name even for backups; macOS can retain moved bundle paths.
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$BACKUP"; fi
mv "$INCOMING" "$DESTINATION"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DESTINATION" || echo "Installed, but macOS application registration could not be refreshed." >&2
"$DESTINATION/Contents/Helpers/irecord" install
printf 'Installed: %s\nOpen iRecord to use the new version.\n' "$DESTINATION"
