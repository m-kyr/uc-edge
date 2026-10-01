#!/bin/bash
# Write a new shared key (32 random bytes, hex) to PATH with mode 0600. Never prints the key.
# Both Macs need the same key: generate once, then deploy-remote.sh copies it.
# Refuses to overwrite an existing key unless FORCE=1.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 PATH   (e.g. ~/.config/uc-edge/key)" >&2
    exit 64
fi
OUT=$1
if [[ -e "$OUT" && "${FORCE:-0}" != 1 ]]; then
    echo "error: $OUT exists; refusing to replace the shared key (FORCE=1 to override)" >&2
    exit 1
fi

umask 077
DIR=$(dirname "$OUT")
mkdir -p "$DIR"
TMP=$(mktemp "$DIR/.key.XXXXXX")
trap 'rm -f "$TMP"' EXIT
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$TMP"
printf '\n' >> "$TMP"
if [[ $(tr -d '\n' < "$TMP" | wc -c | tr -d ' ') -ne 64 ]]; then
    echo "error: key generation failed" >&2
    exit 1
fi
chmod 600 "$TMP"
mv -f "$TMP" "$OUT"
trap - EXIT
echo "wrote a 32-byte key to $OUT (mode 0600)"
