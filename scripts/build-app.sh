#!/bin/bash
# Build UCEdge in release mode, assemble build/UCEdge.app and sign it (SPEC §9).
# Signing settings: scripts/signing.sh (UCEDGE_SIGN_IDENTITY, optional UCEDGE_EXPECTED_DR).
# Keep the identity the same between builds: the Accessibility / Input Monitoring / Local
# Network grants are keyed to the designated requirement it produces.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
ucedge_signing_check

APP=build/UCEdge.app

swift build -c release --product UCEdge
BIN="$(swift build -c release --show-bin-path)/UCEdge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/UCEdge"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ucedge_sign "$APP"

# The permission grants are keyed to the designated requirement: refuse anything else.
if [[ -n "${UCEDGE_EXPECTED_DR:-}" ]]; then
    if ! codesign -v -R="$UCEDGE_EXPECTED_DR" "$APP"; then
        echo "error: $APP does not satisfy UCEDGE_EXPECTED_DR" >&2
        exit 1
    fi
    echo "designated requirement: OK"
fi
codesign -d -r- "$APP"
echo "built $(pwd)/$APP ($("$APP/Contents/MacOS/UCEdge" version))"
