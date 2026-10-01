#!/bin/bash
# Stop and remove UCEdge from this Mac: the LaunchAgents local.uc-edge and local.uc-edge.menu,
# ~/Applications/UCEdge.app and ~/Applications/UCEdge Menu.app.
# Keeps ~/.config/uc-edge (config + key), status and logs unless --purge is given.
# Only touches the jobs labelled exactly local.uc-edge and local.uc-edge.menu.
set -euo pipefail

PURGE=0
case "${1:-}" in
    "") ;;
    --purge) PURGE=1 ;;
    *) echo "usage: $0 [--purge]" >&2; exit 64 ;;
esac
DOMAIN=gui/$(id -u)

for LABEL in local.uc-edge.menu local.uc-edge; do
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "stopped $LABEL" || echo "$LABEL was not loaded"
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
done
rm -rf "$HOME/Applications/UCEdge.app" "$HOME/Applications/UCEdge Menu.app"
echo "removed the LaunchAgent plists, ~/Applications/UCEdge.app and ~/Applications/UCEdge Menu.app"

if [[ $PURGE == 1 ]]; then
    rm -rf "$HOME/.config/uc-edge" "$HOME/Library/Application Support/UCEdge" "$HOME/Library/Logs/UCEdge"
    echo "purged config, key, status and logs"
else
    echo "kept ~/.config/uc-edge, ~/Library/Application Support/UCEdge and ~/Library/Logs/UCEdge (--purge removes them)"
fi
