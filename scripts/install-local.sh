#!/bin/bash
# Install build/UCEdge.app on this Mac and (re)start the LaunchAgent local.uc-edge.
# Usage: install-local.sh [--config FILE] [--force-config]
#   Copies the app to ~/Applications, writes ~/.config/uc-edge/config.json from FILE if there is
#   none yet (or with --force-config), writes the LaunchAgent plist and bootstraps it. The key
#   (~/.config/uc-edge/key) is not created here: use gen-key.sh. See config/examples/.
# Only touches the job labelled exactly local.uc-edge.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=""
FORCE_CONFIG=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG=${2:?--config needs a file}; shift ;;
        --force-config) FORCE_CONFIG=1 ;;
        *) echo "usage: $0 [--config FILE] [--force-config]" >&2; exit 64 ;;
    esac
    shift
done
[[ -z "$CONFIG" || -f "$CONFIG" ]] || { echo "error: no config at $CONFIG" >&2; exit 1; }

LABEL=local.uc-edge
SRC_APP=build/UCEdge.app
DEST_APP=$HOME/Applications/UCEdge.app
CFG_DIR=$HOME/.config/uc-edge
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)

[[ -d "$SRC_APP" ]] || { echo "error: $SRC_APP missing; run scripts/build-app.sh" >&2; exit 1; }
codesign -v "$SRC_APP"

mkdir -p "$HOME/Applications" "$CFG_DIR" "$HOME/Library/Logs/UCEdge" "$HOME/Library/LaunchAgents"
chmod 700 "$CFG_DIR"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"
codesign -v "$DEST_APP"

if [[ -n "$CONFIG" ]]; then
    if [[ ! -f "$CFG_DIR/config.json" || $FORCE_CONFIG == 1 ]]; then
        cp "$CONFIG" "$CFG_DIR/config.json"
        echo "wrote $CFG_DIR/config.json from $CONFIG"
    elif ! cmp -s "$CONFIG" "$CFG_DIR/config.json"; then
        echo "note: keeping existing $CFG_DIR/config.json (differs from $CONFIG; --force-config to replace)"
    fi
elif [[ ! -f "$CFG_DIR/config.json" ]]; then
    echo "WARNING: no $CFG_DIR/config.json; pass --config FILE (see config/examples/)"
fi
if [[ ! -f "$CFG_DIR/key" ]]; then
    echo "WARNING: no key at $CFG_DIR/key; UCEdge will stay idle (keyMissing). Run scripts/gen-key.sh $CFG_DIR/key"
else
    chmod 600 "$CFG_DIR/key"
fi

scripts/launchagent-plist.sh "$HOME" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
# Right after a bootout, bootstrap can fail with EIO (5) for a moment: retry.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if launchctl bootstrap "$DOMAIN" "$PLIST"; then break; fi
    [[ $attempt == 10 ]] && { echo "error: launchctl bootstrap failed 10 times" >&2; exit 1; }
    sleep 0.5
done
sleep 1
launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|pid|last exit code)' || true
# Report only (read-only, no sudo): with the application firewall on, UDP must get in.
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
if [[ -x $FW ]]; then
    echo "firewall: $("$FW" --getglobalstate 2>&1 | tr -s ' ' | head -1)"
    echo "firewall for UCEdge: $("$FW" --getappblocked "$DEST_APP" 2>&1 | tr -s ' ' | head -1)"
fi
echo "installed; check with: $DEST_APP/Contents/MacOS/UCEdge status"
