# UCEdge: development notes

How UCEdge is built, configured and debugged. `README.md` is the overview; `SPEC.md` is the
contract (it uses the names of the setup it was measured on: **V-Mind** = the lower Mac,
**the MacBook** = the upper Mac).

UCEdge makes Universal Control crossings between the lower Mac (top edge of its monitors) and
the upper Mac (bottom edge of its display) land the cursor at the physically matching point, in
both directions. UC throws the cursor into a corner; UCEdge warps it to
`physicalMap(peer exit x)` right after UC lands it. On the lower Mac it also lets a deliberate
upward push in the "dead strip" (the part of its edge where UC has no hot zone) cross.

The same signed app (`local.uc-edge`) runs on both Macs as a LaunchAgent. Each side sends
EDGE packets (authenticated UDP) while its cursor is at its shared edge, and corrects landings
on its own edge from the peer's packets. The sender models UC's hot zone (`CrossLatch`): it arms
on the first event within 1 pt of the edge inside UC's zone and latches the x of the next push,
which is exactly the x UC crosses at. That latched `crossX` is what the receiver maps. With no
fresh latched peer packet it never moves the cursor.

## Layout

```
Sources/UCEdgeCore/   pure logic, unit-tested, no CoreGraphics side effects
  Geometry.swift        EdgeGeometry: span, edgeY, landing strip, clampTarget
  Mapping.swift         physicalMap
  CrossLatch.swift      sender's model of UC's hot zone: the latched exit x (SPEC §5.2)
  LandingDetector.swift correction state machine (SPEC §5.4)
  ClockOffset.swift     peer clock offset from HELLO/HELLO_ACK, for sender-time freshness
  UCLogAssist.swift     UC log assist: ndjson parsing, clock conversion, matching, source policy (§13)
  DeadStrip.swift       dead-strip push detector (SPEC §6)
  Wire.swift            packet format, HMAC-SHA256 (16 B), replay filter
  UCArrangement.swift   read-only parser of UC's ByHost plist, UC zone
  Config.swift          config.json (every field optional, defaults in code) + validation
  MenuModel.swift       what the menu bar app shows: lenient status.json reader + state
Sources/UCEdge/       system integration
  main.swift            CLI: run | status | version | selftest
  Engine.swift          wiring; the one lock; input paths; warps; timers
  Engine+Net.swift      receive loop, packet handling, HELLO/ACK, clock offset, DNS
  Engine+Edge.swift     geometry, UC arrangement zone, status snapshot
  Engine+UCLog.swift    UC Activating line → exact crossX, sent at once with crossSource = uc
  UCLogStream.swift     supervised `/usr/bin/log stream` child (UC's Hot Zone lines)
  CursorIO.swift        event tap + supervisor, 1 kHz poller while armed, warp
  Net.swift             dual-stack UDP, peer resolution + learning, send queue
  Displays.swift        UUID -> display bounds, reconfiguration callback
  StatusLog.swift       status.json, rotating log, `status` summary
  SelfTest.swift        read-only checks
Sources/UCEdgeMenu/   menu bar app: status, Pause/Resume, Open Log, Quit (no permissions)
Tests/UCEdgeCoreTests/  Swift Testing: geometry, wire, latch, detector, dead strip, arrangement,
                        config, loopback (two engines over 127.0.0.1), audit regressions,
                        trace replay, adversarial cases, menu model
testdata/ recorded traces and UC log excerpts (identifiers replaced) used by the replay tests
scripts/  build-app.sh build-menu.sh signing.sh gen-key.sh install-local.sh install-menu.sh
          deploy-remote.sh uninstall.sh
config/   examples/ (generic), local/ (your own, gitignored)
Resources/Info.plist Menu-Info.plist
```

## Build and test

```
swift test                 # unit + loopback + trace replay tests (no warps, no events)
scripts/build-app.sh       # release build -> build/UCEdge.app, signed; prints codesign -d -r-
scripts/build-menu.sh      # release build -> "build/UCEdge Menu.app", signed
```

Signing comes from `UCEDGE_SIGN_IDENTITY` (environment or the gitignored `scripts/local.env`, see
`scripts/local.env.example` and `scripts/signing.sh`). Keep the identity the same between builds:
the Accessibility, Input Monitoring and Local Network grants are keyed to the designated
requirement it produces, and `UCEDGE_EXPECTED_DR` makes `build-app.sh` refuse a build that would
lose them.

## Install

```
scripts/gen-key.sh ~/.config/uc-edge/key               # once, on one Mac; never prints the key
scripts/install-local.sh --config config/local/lower-mac.json   # app, config (if missing), LaunchAgent
scripts/install-menu.sh                                 # menu bar app + its LaunchAgent
scripts/deploy-remote.sh --config config/local/upper-mac.json other-mac   # both apps on the other Mac
                                                        # over SSH; copies the key
scripts/deploy-remote.sh --menu other-mac               # only the menu app
scripts/uninstall.sh [--purge]
```

Files: `~/Applications/UCEdge.app`, `~/Applications/UCEdge Menu.app`,
`~/.config/uc-edge/{config.json,key}`, `~/Library/LaunchAgents/local.uc-edge.plist` and
`local.uc-edge.menu.plist`, log `~/Library/Logs/UCEdge/uc-edge.log` (rotates at 2 MB, keeps `.1`
and `.2`), status `~/Library/Application Support/UCEdge/status.json`.

## Status

```
~/Applications/UCEdge.app/Contents/MacOS/UCEdge status
```

prints alerts (`keyMissing`, `warpFailing`, `ucLinkMissing`, polling fallback, `netError`),
permissions, peer (alive, RTT, address, learned vs DNS), geometry, UC arrangement zone, the UC
log assist (state, lines, activations matched/unmatched/ignored, clock errors, the peer's state),
whether corrections are enabled, counters (incl. crossX sent from `uc` vs `model`) and the last
10 corrections with their crossSource. `UCEdge selftest` runs read-only checks (permissions, displays,
key, arrangement, peer DNS). Run from a terminal it reports the *terminal's* permissions, so
trust the permissions in `status` (written by the LaunchAgent process) instead.

## Tuning

Edit `~/.config/uc-edge/config.json`, then `launchctl kickstart -k gui/$(id -u)/local.uc-edge`.

| key | default | what |
|---|---|---|
| `corrections.enabled` | true | warp landings on this Mac |
| `detector.overrideGuard` | true | re-warp (≤ `overrideMaxRewarps` 2, within `overrideGuardMs` 300) when UC positions the cursor absolutely over a correction (§14) |
| `detector.overrideMismatchPt` / `overrideBackFraction` | 20 / 0.25 | reported vs observed motion mismatch; the event must also move back toward UC's landing by this fraction of the correction |
| `ucLogAssist.enabled` | true | read UC's own Activating log line for the exact crossX (§13) |
| `ucLogAssist.maxLagMs` | 100 | ignore an Activating line delivered later than this (`lateLines` in status) |
| `detector.ucWaitMs` | 25 | a landing with only a model crossX waits this long for UC's (when the peer's assist is active) |
| `detector.stripPt` | 30 | landing strip depth from the edge |
| `detector.minStillMs` | 30 | stillness before a jump counts as a landing |
| `detector.freshMs` | 300 | how old a latched peer packet may be for an immediate correction |
| `detector.lateWindowMs` | 150 | how long a landing waits for a late peer packet |
| `detector.cooldownMs` | 400 | ignore landings after a correction |
| `detector.guardMs` | 250 | snap-back guard window |
| `detector.atEdgePt` | 1.5 | the sender sends while within this of its edge (or latched) |
| `detector.exitTailMs` | 75 | a change this soon after being at our own edge is our exit's tail (see below) |
| `detector.targetInsetPt` | 2 | targets sit this far inside the edge line, outside UC's 1 pt hot zone |
| `detector.minCorrectionPt` | 2 | smaller x corrections are skipped (logged as `skip`, counted) |
| `detector.episodeSlackMs` | 120 | a landing needs the local cursor still for the peer's whole episode, minus this |
| `deadStrip.enabled` | false | dead-strip assist (lower Mac only) |
| `deadStrip.minPushMs` / `maxGapMs` | 180 / 100 | a run of pinned pushes in the dead part must last this long, with no gap longer than `maxGapMs`; lower = faster crossing, but a fast throw into the Apple-menu corner may cross too |
| `deadStrip.pushThresholdPt` | 12 | and its pushes must sum to at least this (pt) |
| `deadStrip.maxSpreadPt` / `minDyDxRatio` | 30 / 1.5 | a run wider than this restarts; Σ|dy| must be ≥ ratio × Σ|dx| (menu-bar slides are not pushes) |
| `deadStrip.cooldownMs` / `virtualXValidMs` | 1500 / 1000 | |
| `deadStrip.zoneMinXFallback` / `zoneMaxXFallback` | unset | UC's zone on this edge while UC's own is unknown (plist unparsable, or before the peer's first HELLO); set both or neither. Unset: the dead strip stays off and the latch uses the whole span until UC's zone is known. Read the zone from the `arrangement:` line of `UCEdge status` once it says `parsed` |
| `armMs` / `duplicateDelayMs` | 400 / 4 | how long a peer packet keeps the 1 kHz poller on; delay of each packet's second copy |

Every correction logs one line:

```
correct kind=immediate src=uc landing=(0.0,0.0) target=(-2038.8,-2.0) peerX=-948.46 age=14ms still=27185ms latency=180us
uccross x=539.41 lagMs=0.67 eventAgeMs=0.57
```

`src` is where the peer's crossX came from (`uc` = UC's log line, `model` = the latch; a model
correction after the `ucWaitMs` wait is kind `late`), `peerX` is that crossX, `age` the peer packet's age when the correction fired
(0 for `late`), `still` the stillness
before the landing, `latency` the time from detecting the landing to the warp returning.
`override rewarp n=… p=… to=…` is a re-warp after UC undid a correction (lower Mac, downward).
`deadstrip near-miss: …` (rate-limited) is a push of ≥ 100 ms that didn't fire, with the reason.
`uccross` (sender side) is a UC Activating line matched to our at-edge event: `lagMs` is the
log delivery lag, `eventAgeMs` how long before the line the matched event was. Dead-strip
redirects log `deadstrip from=… to=…`. Rejected packets and send errors are counted
in status and logged at most once per 10 s per reason.

## Deviations and implementation choices

The v1.2 audit fixes are listed in SPEC §12. Beyond the spec:

- **Episode rule placement:** the engine passes `episodeStart` in `PeerEdgeState` (nil turns
  the rule off, so older tests keep working); `LandingDetector` applies it.
- **Late path `current`:** `LandingDetector.onPeerUpdate` still uses the `current` it is given
  (its API); the engine passes the detector's own `lastPosition`, read under the lock.
- **Sender-time freshness** is carried in `PeerEdgeState.senderLagMs` / `senderSlackMs`
  (nil = unknown, no check), computed by the engine from the packet's `wallMs` and the clock offset.
- **Tap supervision** runs on its own queue and checks the tap every second: a disabled tap is
  re-enabled; a lost or uncreatable one is retried with backoff (1 s doubling to 60 s, reset
  after 60 s healthy). The engine switches the poller between tap mode and the 250 Hz fallback.
- **launchd.log** (launchd's stdout/stderr) is trimmed at startup to its last 64 KB when over 1 MB.
- **`log stream` child:** killed on every exit path UCEdge controls; after a SIGKILL or crash it is
  killed at the next start (uid, ppid 1 and our exact argv only). Activating lines are matched 3 ms
  after they arrive; lines later than `ucLogAssist.maxLagMs`, or for an earlier edge visit, are ignored.
- **Receive loop:** 50 consecutive errors → log, write status, `exit(1)` (launchd restarts).
- **Key:** a malformed (not exactly 64 hex digits) or group/other-accessible key keeps
  UCEdge idle with `keyMissing` / `keyInsecure` in status, re-checked every 10 s.
- **Config errors** (bad UUID, bad port, no edge displays): UCEdge logs them, writes them to
  status, waits 60 s and exits 78, as for a missing config.

- **Snap-back guard** only arms when the correction moved the cursor more than 6 pt.
- **Missing edge display** (one of the edge displays unplugged): geometry is disabled, so UCEdge neither
  sends nor corrects until all configured displays are back (a partial span maps wrongly).
- **Dead strip** only redirects while the peer is alive and a UC zone is known; with
  `ucLinkMissing` it stays off. Before the peer's first HELLO the fallback zone is used.
  A dead-strip run ends when the cursor leaves the edge or the dead part, or after a gap.
- **Latch with `ucLinkMissing`** (lower Mac): the latch never arms, since UC crosses nowhere.
- **Polling fallback** (no tap): only position changes reach the latch (and the sender);
  the second consecutive at-edge change in the zone latches.
- **Skipped small corrections** clear pending and start the cooldown, and never arm the
  snap-back guard.
- **Sleep.** Detector timing uses uptime as specified; when wall time outruns uptime by more
  than 2 s (a sleep), peer and detector state are reset so a pre-sleep packet can't look fresh.
- Duplicate packets reuse the same seq (identical bytes), so the replay filter drops
  the copy when the original arrived. An equal seq is reported as `duplicate` (counted, not
  logged); a lower seq is a `replay` reject.
