# Example configs

One Mac sits above the other: the **upper Mac**'s display shares its *bottom* edge with the
*top* edge of one or more of the **lower Mac**'s displays. Copy the matching file, fill in the
display UUIDs (`"build/UCEdge Menu.app/Contents/MacOS/UCEdgeMenu" --displays` lists them) and the other
Mac's host name, and install it with `scripts/install-local.sh --config FILE`.

| key | lower Mac | upper Mac | why |
|---|---|---|---|
| `side` | `top` | `bottom` | which edge of this Mac's displays is shared |
| `edgeDisplays` | every display along the shared edge | the display along the shared edge | full display UUIDs |
| `peerHosts` | the upper Mac | the lower Mac | host names or addresses; the first answering one is used, and the sender's address is learned |
| `peerName` | | | only for the menu bar app (the helper ignores it) |
| `detector.overrideGuard` | `true` | `false` | Universal Control positions the lower Mac's pointer absolutely after a landing and can undo a correction; the guard re-applies it. On the upper Mac it can double-shift. |
| `deadStrip.enabled` | `true` | `false` | lets a firm push cross where Universal Control has no hot zone: the part of the lower Mac's edge that is wider than the upper display (only tested this way round) |

Everything else has working defaults (see the tuning table in `docs/DEVELOPMENT.md`). The helper
reads its config at start: after editing `~/.config/uc-edge/config.json`, restart it with
`launchctl kickstart -k gui/$(id -u)/local.uc-edge`.
