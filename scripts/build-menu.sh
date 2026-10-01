#!/bin/bash
# Build the menu bar app in release mode, assemble "build/UCEdge Menu.app" and sign it.
# It needs no permissions, so its signature only has to be valid.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
ucedge_signing_check

APP="build/UCEdge Menu.app"

swift build -c release --product UCEdgeMenu
BIN="$(swift build -c release --show-bin-path)/UCEdgeMenu"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Menu-Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/UCEdgeMenu"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ucedge_sign "$APP"
echo "built $(pwd)/$APP"
