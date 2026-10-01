#!/bin/bash
# Install "build/UCEdge Menu.app" on this Mac and (re)start its LaunchAgent local.uc-edge.menu.
# Idempotent. Does not touch the helper (local.uc-edge).
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=local.uc-edge.menu
SRC_APP="build/UCEdge Menu.app"
DEST_APP="$HOME/Applications/UCEdge Menu.app"
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

[[ -d "$SRC_APP" ]] || { echo "error: $SRC_APP missing; run scripts/build-menu.sh" >&2; exit 1; }
codesign -v "$SRC_APP"

mkdir -p "$HOME/Applications" "$HOME/Library/Logs/UCEdge" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"
codesign -v "$DEST_APP"

scripts/menu-agent-plist.sh "$HOME" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
# Right after a bootout, bootstrap can fail with EIO (5) for a moment: retry.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if launchctl bootstrap "$DOMAIN" "$PLIST"; then break; fi
    [[ $attempt == 10 ]] && { echo "error: launchctl bootstrap failed 10 times" >&2; exit 1; }
    sleep 0.5
done
sleep 1
launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|pid|last exit code)' || true
echo "installed; check with: \"$DEST_APP/Contents/MacOS/UCEdgeMenu\" --print"
