#!/bin/bash
# Deploy UCEdge to the other Mac over SSH and (re)start its LaunchAgents.
#
# Usage: deploy-remote.sh [--helper | --menu] [--config FILE] [--force-config]
#                         [--control-path PATH] SSH_HOST
#   --helper        deploy only the helper: build/UCEdge.app, its config, the shared key, local.uc-edge
#   --menu          deploy only the menu bar app: "build/UCEdge Menu.app", local.uc-edge.menu
#                   (default: both)
#   --config FILE   the other Mac's config.json; installed only if it has none (or --force-config).
#                   Required with the helper unless the other Mac already has a config.
#   --control-path  reuse an SSH master connection (ssh -o ControlPath=…), e.g. one opened with
#                   ssh -fN -o ControlMaster=yes -o ControlPath=PATH SSH_HOST
#
# Reinstalling the helper replaces its app bundle, which can make macOS re-check its permissions;
# deploy only the menu (--menu) when the helper hasn't changed.
# The key is copied file-to-file and never printed. Only the jobs local.uc-edge and
# local.uc-edge.menu are touched.
set -euo pipefail
cd "$(dirname "$0")/.."

DO_HELPER=1; DO_MENU=1; CONFIG=""; FORCE_CONFIG=0; CONTROL_PATH=""; HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --helper) [[ $DO_HELPER == 1 ]] || { echo "--helper and --menu exclude each other" >&2; exit 64; }; DO_MENU=0 ;;
        --menu) [[ $DO_MENU == 1 ]] || { echo "--helper and --menu exclude each other" >&2; exit 64; }; DO_HELPER=0 ;;
        --config) CONFIG=${2:?--config needs a file}; shift ;;
        --force-config) FORCE_CONFIG=1 ;;
        --control-path) CONTROL_PATH=${2:?--control-path needs a path}; shift ;;
        -*) echo "unknown option $1" >&2; exit 64 ;;
        *) HOST=$1 ;;
    esac
    shift
done
[[ -n "$HOST" ]] || { sed -n '2,17p' "$0" >&2; exit 64; }

SSH_OPTS=(-o BatchMode=yes)
if [[ -n "$CONTROL_PATH" ]]; then
    [[ -S "$CONTROL_PATH" ]] || { echo "error: no SSH control socket at $CONTROL_PATH" >&2; exit 1; }
    SSH_OPTS+=(-o ControlPath="$CONTROL_PATH" -o ControlMaster=no)
fi
SSH=(ssh "${SSH_OPTS[@]}" "$HOST")
SCP=(scp -q "${SSH_OPTS[@]}")
HELPER_APP=build/UCEdge.app
MENU_APP="build/UCEdge Menu.app"
KEY=$HOME/.config/uc-edge/key

if [[ $DO_HELPER == 1 ]]; then
    [[ -d "$HELPER_APP" ]] || { echo "error: $HELPER_APP missing; run scripts/build-app.sh" >&2; exit 1; }
    [[ -f "$KEY" ]] || { echo "error: no key at $KEY; run scripts/gen-key.sh $KEY" >&2; exit 1; }
    [[ -z "$CONFIG" || -f "$CONFIG" ]] || { echo "error: no config at $CONFIG" >&2; exit 1; }
    codesign -v "$HELPER_APP"
fi
if [[ $DO_MENU == 1 ]]; then
    [[ -d "$MENU_APP" ]] || { echo "error: $MENU_APP missing; run scripts/build-menu.sh" >&2; exit 1; }
    codesign -v "$MENU_APP"
fi

STAGE=$(mktemp -d)
REMOTE_STAGE=""
# The remote stage can hold the key: remove it even if a copy or the remote step fails.
cleanup() {
    rm -rf "$STAGE"
    if [[ -n "$REMOTE_STAGE" ]]; then "${SSH[@]}" "rm -rf '$REMOTE_STAGE'" 2>/dev/null || true; fi
}
trap cleanup EXIT
REMOTE_HOME=$("${SSH[@]}" 'printf %s "$HOME"')
FILES=()
if [[ $DO_HELPER == 1 ]]; then
    ditto -c -k --keepParent "$HELPER_APP" "$STAGE/helper.zip"
    scripts/launchagent-plist.sh "$REMOTE_HOME" > "$STAGE/local.uc-edge.plist"
    plutil -lint "$STAGE/local.uc-edge.plist" >/dev/null
    FILES+=("$STAGE/helper.zip" "$STAGE/local.uc-edge.plist")
    if [[ -n "$CONFIG" ]]; then cp "$CONFIG" "$STAGE/config.json"; FILES+=("$STAGE/config.json"); fi
fi
if [[ $DO_MENU == 1 ]]; then
    ditto -c -k --keepParent "$MENU_APP" "$STAGE/menu.zip"
    scripts/menu-agent-plist.sh "$REMOTE_HOME" > "$STAGE/local.uc-edge.menu.plist"
    plutil -lint "$STAGE/local.uc-edge.menu.plist" >/dev/null
    FILES+=("$STAGE/menu.zip" "$STAGE/local.uc-edge.menu.plist")
fi

REMOTE_STAGE=$("${SSH[@]}" 'umask 077; mktemp -d /tmp/uc-edge-deploy.XXXXXX')
"${SCP[@]}" "${FILES[@]}" "$HOST:$REMOTE_STAGE/"
[[ $DO_HELPER == 1 ]] && "${SCP[@]}" "$KEY" "$HOST:$REMOTE_STAGE/key"

"${SSH[@]}" bash -s -- "$REMOTE_STAGE" "$DO_HELPER" "$DO_MENU" "$FORCE_CONFIG" <<'REMOTE'
set -euo pipefail
STAGE=$1; DO_HELPER=$2; DO_MENU=$3; FORCE_CONFIG=$4
DOMAIN=gui/$(id -u)
CFG_DIR=$HOME/.config/uc-edge
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$HOME/Applications" "$HOME/Library/Logs/UCEdge" "$HOME/Library/LaunchAgents"

# bootstrap LABEL: (re)load ~/Library/LaunchAgents/LABEL.plist; right after a bootout it can
# fail with EIO (5) for a moment, so retry.
bootstrap() {
    local label=$1
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if launchctl bootstrap "$DOMAIN" "$HOME/Library/LaunchAgents/$label.plist"; then break; fi
        [[ $attempt == 10 ]] && { echo "remote: launchctl bootstrap $label failed 10 times" >&2; exit 1; }
        sleep 0.5
    done
    sleep 1
    launchctl print "$DOMAIN/$label" | grep -E '^\s*(state|pid|last exit code) =' || true
}

if [[ $DO_HELPER == 1 ]]; then
    mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
    launchctl bootout "$DOMAIN/local.uc-edge" 2>/dev/null || true
    rm -rf "$HOME/Applications/UCEdge.app"
    ditto -x -k "$STAGE/helper.zip" "$HOME/Applications"
    codesign -v "$HOME/Applications/UCEdge.app"
    if [[ -f "$STAGE/config.json" ]]; then
        if [[ ! -f "$CFG_DIR/config.json" || $FORCE_CONFIG == 1 ]]; then
            cp "$STAGE/config.json" "$CFG_DIR/config.json"
            echo "remote: wrote $CFG_DIR/config.json"
        elif ! cmp -s "$STAGE/config.json" "$CFG_DIR/config.json"; then
            echo "remote: note: keeping existing config.json (differs; --force-config to replace)"
        fi
    elif [[ ! -f "$CFG_DIR/config.json" ]]; then
        echo "remote: WARNING: no config.json; pass --config FILE" >&2
    fi
    install -m 600 "$STAGE/key" "$CFG_DIR/key"
    cp "$STAGE/local.uc-edge.plist" "$HOME/Library/LaunchAgents/local.uc-edge.plist"
    bootstrap local.uc-edge
    echo "remote: installed $("$HOME/Applications/UCEdge.app/Contents/MacOS/UCEdge" version)"
fi

if [[ $DO_MENU == 1 ]]; then
    launchctl bootout "$DOMAIN/local.uc-edge.menu" 2>/dev/null || true
    rm -rf "$HOME/Applications/UCEdge Menu.app"
    ditto -x -k "$STAGE/menu.zip" "$HOME/Applications"
    codesign -v "$HOME/Applications/UCEdge Menu.app"
    cp "$STAGE/local.uc-edge.menu.plist" "$HOME/Library/LaunchAgents/local.uc-edge.menu.plist"
    bootstrap local.uc-edge.menu
    echo "remote: menu: $("$HOME/Applications/UCEdge Menu.app/Contents/MacOS/UCEdgeMenu" --print | head -1)"
fi
REMOTE
REMOTE_STAGE=""   # the remote step removed it
