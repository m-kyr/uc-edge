# UCEdge

Makes Universal Control land the cursor where you expect when one Mac's display sits **above**
another Mac's displays.

## The problem

With a Mac's display stacked above another Mac's displays, and the two shared edges of different
widths, Universal Control (UC) works out the landing point from the wrong offset. Crossing up
from the lower Mac lands the cursor in a corner of the upper display, and crossing down lands it
on the same spot every time, rather than directly above or below where it left. UC also only
crosses where the two edges overlap in its arrangement. Along the rest of a wider edge (the
"dead strip") you can't cross at all.

## What UCEdge does

- A small background helper runs on both Macs.
- When the cursor leaves a Mac, that Mac reads the exact crossing point from UC's own log
  ("Hot Zone: Activating"). It sends that point to the other Mac over the local network, as
  UDP packets signed with a shared key.
- The Mac the cursor lands on moves it to the physically matching point, a few milliseconds
  after UC places it. "Physically matching" means the same fraction along each shared edge. The
  outer ends of the two edges are assumed to line up on your desk.
- Optional, on the lower Mac: a firm push into the dead strip nudges the cursor into UC's zone,
  so it crosses and still lands at the matching point.
- A menu bar app shows whether it's working. It can pause it, or quit it until the next login.

## Does it fit your setup?

- Two Macs, one above the other: the upper Mac's display shares its bottom edge with the top
  edge of one or more of the lower Mac's displays. Side-by-side arrangements aren't supported.
- It was built for and tested on a single setup, on macOS 27: a Mac mini with two monitors side
  by side, below a MacBook driving one 27" display. Expect to tune it for anything else.
- Both Macs must reach each other on the local network (UDP port 47591).

## Install

You need Swift 6 (Xcode or its command line tools) and, ideally, an Apple Development signing
identity. A free Apple ID works in Xcode → Settings → Accounts.

1. **Signing:** run `cp scripts/local.env.example scripts/local.env`, then set
   `UCEDGE_SIGN_IDENTITY`. `security find-identity -v -p codesigning` lists your identities.
   macOS ties the permissions to this signature, so keep using the same identity. Ad-hoc
   signing (`-`) works, but you'll have to grant the permissions again after every rebuild.
2. **Build:** `scripts/build-app.sh && scripts/build-menu.sh`
3. **Find your displays:** run `"build/UCEdge Menu.app/Contents/MacOS/UCEdgeMenu" --displays`.
   For the other Mac, copy the menu app there first (`scripts/deploy-remote.sh --menu
   other-mac.local`, see step 7), then run
   `"$HOME/Applications/UCEdge Menu.app/Contents/MacOS/UCEdgeMenu" --displays` in Terminal there.
4. **Configs:** run `mkdir -p config/local && cp config/examples/*-mac.json config/local/`
   (`config/local/` is gitignored). Fill in each Mac's display UUIDs and the other Mac's host
   name. See `config/examples/README.md`.
5. **Key:** run `scripts/gen-key.sh ~/.config/uc-edge/key` once. Both Macs need the same key.
6. **This Mac:** run `scripts/install-local.sh --config config/local/lower-mac.json && scripts/install-menu.sh`
   (with `upper-mac.json` if this is the upper Mac).
7. **The other Mac:** run
   `scripts/deploy-remote.sh --config config/local/upper-mac.json other-mac.local`. It copies
   both apps and the key over SSH. That needs Remote Login on the other Mac, SSH key login
   (it never asks for a password), and you logged in there. Alternatively, clone, build and
   install there too, and copy the key by hand.
8. **Permissions, on each Mac:**
   - In System Settings → Privacy & Security, allow `~/Applications/UCEdge.app` under
     **Accessibility**, which it needs to move the cursor, and **Input Monitoring**.
   - Allow **Local Network** when macOS asks. If it doesn't ask, open `~/Applications/UCEdge.app`
     once in Finder: it only contacts the other Mac so that macOS asks, then quits. On a Mac with
     several user accounts, every account may have to allow it once.
   - Then restart the helper: `launchctl kickstart -k gui/$(id -u)/local.uc-edge`.

Remove it with `scripts/uninstall.sh`, and on the other Mac with
`ssh other-mac.local bash -s < scripts/uninstall.sh`. Add `--purge` (`bash -s -- --purge` over
SSH) to also delete the config, key and logs.

## Menu bar

The icon shows **Working**, **Waiting for** the other Mac (asleep, away or paused), **Paused**,
**Starting**, **Needs attention** (with the reason) or **Not responding**. The menu lists:

- the connection to the other Mac
- how many landings it has fixed
- whether exact crossing points are available

It has three actions:

- **Pause** stops the helper on this Mac until you resume or log in again. Each Mac needs the
  other's crossing points, so pausing either Mac stops the corrections in both directions.
- **Open Log** opens the helper's log.
- **Quit UCEdge** stops the helper and the menu. Both start again at your next login.

From a shell, `"$HOME/Applications/UCEdge Menu.app/Contents/MacOS/UCEdgeMenu"` with `--print`,
`--pause` or `--resume` does the same, and `~/Applications/UCEdge.app/Contents/MacOS/UCEdge status`
prints full details.

## Limits

- UCEdge depends on an undocumented UC log line and on UC's current behaviour. A macOS update can
  break either. Without the log line it falls back to its own estimate of the crossing point.
  The menu says "Exact crossing points: unavailable" when it can't read UC's log at all; if the
  line itself changes, `UCEdge status` shows few or no matched activations and the log shows
  `src=model` corrections. If landings ever get worse, pause it.
- It can only fix where the cursor lands. It doesn't change when or where UC decides to cross,
  apart from the optional dead-strip nudge.
- More detail: `docs/DEVELOPMENT.md` covers the layout, tuning and log format, and `SPEC.md`
  holds the measurements and design.

Provided as-is under the MIT License (see `LICENSE`). Not affiliated with or endorsed by Apple.
Universal Control and macOS are trademarks of Apple Inc.
