# UCEdge: specification (v1)

UCEdge makes Universal Control (UC) crossings between **V-Mind** (Mac mini) and the **MacBook Pro** land the cursor at the **physically matching point**, in both directions. It works around a UC bug that throws the cursor into a corner. It also lets the user cross upward from the part of monitor 5 that has nothing above it in macOS's layout (the "dead strip").

This file is the contract for the build and the audit. When the code and this file disagree, the code is wrong unless the spec says a point is open.

It describes the setup UCEdge was built and measured on: **V-Mind** is the name of the lower Mac (a Mac mini with two monitors, "4" and "5"), **the MacBook** is the upper Mac (its 27" display "3" sits above both monitors). In the generic docs and example configs these are the *lower* and *upper* Mac.

---

## 1. The physical desk and the numbering

```
            ┌──────────── display 3 (MacBook, 27", 2560x1440 pt) ────────────┐┌── display 2 ──┐
            │ MacBook global x -2560 … 0, y -1440 … 0                          ││  x 0…2560     │
            └──────────────────────────────────────────────────────────────────┘└───────────────┘
            ┌──── monitor 5 (V-Mind "Left") ────┐┌──── monitor 4 (V-Mind "Right", main) ───┐┌ display 1 ┐
            │ V-Mind x -1600 … 0, y 0 … 1000    ││ V-Mind x 0 … 1600, y 0 … 1000           ││ MacBook   │
            └───────────────────────────────────┘└─────────────────────────────────────────┘│ built-in  │
                                                                                            └───────────┘
```

- **Physically:** 5's left edge lines up with 3's left edge, and 4's right edge with 3's right edge. 5 sits under 3's left half and 4 under 3's right half. There's a gap of a few mm between 4 and 5, which we ignore.
- **Display UUIDs:**
  - MacBook display 3 = `8A000000-0000-4000-8000-0000000000A1`
  - V-Mind monitor 4 = `E5000000-0000-4000-8000-0000000000B1`
  - V-Mind monitor 5 = `8D000000-0000-4000-8000-0000000000B2`
  - MacBook built-in (display 1) = `3C000000-0000-4000-8000-0000000000C1`
- **Physical mapping (both directions):** the fraction along one shared edge equals the fraction along the other.
  - `local_x = localSpanMin + (peer_x - peerSpanMin) / (peerSpanMax - peerSpanMin) * (localSpanMax - localSpanMin)`
  - V-Mind span: [-1600, 1600], the union of monitors 4 and 5.
  - MacBook span: [-2560, 0], display 3.
  - Check: V-Mind x = 0 (the 4/5 boundary) maps to MacBook x = -1280 (3's middle).

## 2. What UC does wrong (measured 2026-09-25 and 2026-09-29, recordings in `testdata/`)

- **UC's current arrangement** has two links (from UC's ByHost plist, head entry):
  - edge 1 (side): display 1 ↔ 4. Frac 0.3762 along 1's left edge meets frac 0.5 along 4's right edge.
  - edge 2 (top/bottom): display 3 ↔ 4. Frac 0.6875 along 3's bottom meets frac 0.5 along 4's top (4's midpoint sits under 3's x = 1760 from 3's left).
- **V-Mind's hot zone for going up** is `top:<3>:[-961 0 1600 1]`, meaning x from -961 to 1600 at y 0 to 1. So V-Mind x < -961, the leftmost 639 pt of monitor 5, has **no hot zone**: pushing up there does nothing. That's the dead strip.
- **Upward crossing (V-Mind → MacBook):**
  - V-Mind sends `offset = (x + 961) / 961`. This fits every crossing measured (−930.9 → 0.02, 1564.9 → 2.63, −33.5 → 0.95, 20.4 → 1.03, 785.2 → 1.82, 1553.1 → 2.61).
  - s1's listed x values are the final frozen positions after tail events. UC's own exit x, from the offsets, are −941.59, 1564.9, −48.18, 27.43, 792.69 and 1551.0.
  - The MacBook clamps anything above 1, so crossings from monitor 4 land at a corner: (0, 0) or (−1599, 0) were observed.
  - Where the cursor lands is **not predictable**. An offset of 0.02 was seen landing at (0, 0).
- **Downward crossing (MacBook → V-Mind):**
  - Crossings into monitor 5 are correct. UC's zone `bottom:<5>:[-2560 -1 -1599 0]` gives offset 0.998 for x = −1600.8, landing at V-Mind (−1, 0).
  - Crossings into monitor 4 are **also broken**. Zone `bottom:<4>:[-1601 -1 1 0]` gives offset −742.87 for x = −750.8, and the cursor lands at V-Mind's (1599, 0) corner. Arrangement-correct would be 849.
- **Consequence:** never trust where UC lands the cursor. Always place it from the **peer's exit x**.

### Facts UCEdge relies on (all measured)

1. **Pointing device.** The only pointing device is a Magic Trackpad paired to the **MacBook**. On V-Mind it appears as a UC virtual HID device.
2. **The inactive Mac's cursor is frozen.** While the pointer is on the other Mac, a Mac's own cursor position doesn't change at all (12.7 s and 27 s frozen spans recorded). Its session event tap sees **no** events, except the tail of the crossing within about 15 ms.
3. **Landing is a jump without an event.** UC moves the cursor to the landing point at "Target Begin / Warp Location", with the cursor hidden. It shows the cursor about 30–45 ms later ("Target Reply: Accept / Show cursor"). The first real pointer event arrives about 16–65 ms after the landing. Trackpad events come at about 60 Hz (16–17 ms apart).
4. **Our warp sticks.** `CGWarpMouseCursorPosition` followed by `CGAssociateMouseAndMouseCursorPosition(1)` was applied 270 ms after a UC landing. The cursor then carried on from the new point, with no snap-back. An **immediate** warp (within about 1 ms of landing, before UC's Show cursor) is **untested**, so there's a snap-back guard (§5.4).
5. **The in-zone push threshold is about zero.** UC goes from Entering to Target Ready in about 30 ms, and even sliding along the menu bar crosses. The recorded dead-strip push was 92 events over 1.65 s, x ≈ −1599 pinned at y = 0, with dy mostly −1…−2 (total −122).
6. **Permissions on macOS 27.** Warping the cursor **requires Accessibility**; without it the call returns 1003. The user has granted Accessibility, Input Monitoring and Local Network to the bundle identity `local.uc-edge` on both Macs. The grants are keyed to the code signature (§9) and survived rebuilds.
7. **Network.** V-Mind is on Ethernet (`lower-mac.local`, a fixed address). The MacBook is on Wi-Fi with a DHCP address, reached by name (`upper-mac.local`). UDP round trip is about 5 ms median, max about 75 ms. V-Mind's application firewall is **on**; the MacBook's is off. Local Network privacy is enforced on both.

## 3. Goals and non-goals

**Goals:**
- **G1:** Every upward crossing lands on 3 at the physically matching x.
- **G2:** Every downward crossing lands on 4 or 5 at the physically matching x.
- **G3:** A deliberate upward push in V-Mind's dead strip crosses to 3 at the physically matching x.
- **G4:** Corrections are invisible where possible. Warp before UC shows the cursor, and never while a mouse button is down.
- **G5:** Self-running: a LaunchAgent, reconnects on its own, survives sleep, display changes and the peer going away, uses negligible CPU when idle, and has a status command.
- **G6:** Never degrades normal use. With no fresh peer "at edge" signal, UCEdge never moves the cursor.

**Non-goals:**
- Changing UC's arrangement or its plist. We **read** it only.
- The side link (4 ↔ display 1), which works.
- Drags across machines. Skip correction while any button is down.

## 4. Architecture

One code base, one app bundle `UCEdge.app` (bundle id `local.uc-edge`), the same binary on both Macs. Behaviour comes from `~/.config/uc-edge/config.json`. The two sides are symmetric: each machine has one **shared edge** (a side plus the displays on that edge).

- It **sends** EDGE packets about its own cursor near its shared edge.
- It **corrects** landings on its shared edge using the peer's packets.

```
SwiftPM package  Package.swift (repo root)
  Sources/UCEdgeCore/   pure logic, no CoreGraphics side effects, fully unit-tested
      Geometry.swift        EdgeGeometry (built from display rects + side)
      Mapping.swift         physicalMap(...)
      Wire.swift            packet encode/decode, HMAC-SHA256 (CryptoKit), replay window
      LandingDetector.swift the correction state machine (§5), public API in §5.6
      DeadStrip.swift       dead-strip push detector (§6)
      UCArrangement.swift   best-effort parser of UC's ByHost plist (§7)
      Config.swift          Codable config + defaults
  Sources/UCEdge/       system integration (thin)
      main.swift            CLI: `run` (default), `status`, `version`, `selftest`
      Engine.swift          wires Core to the system; owns the single state lock
      Displays.swift        UUID → CGDirectDisplayID → bounds; reconfiguration callback
      CursorIO.swift        listen-only CGEventTap thread; 1 kHz poller while armed; warp
      Net.swift             UDP (dual-stack), peer address resolution and learning, heartbeats
      StatusLog.swift       status.json + rotating log file
  Tests/UCEdgeCoreTests/  Swift Testing (`import Testing`), incl. trace replay (§10)
  scripts/  build-app.sh, build-menu.sh, install-local.sh, install-menu.sh, deploy-remote.sh, uninstall.sh, gen-key.sh
  config/   examples/ (generic), local/ (ours, gitignored)
  Resources/Info.plist, Menu-Info.plist
  Sources/UCEdgeMenu/  menu bar app (reads status.json, runs launchctl; no permissions)
```

**Threads.** Everything that touches detector or engine state is serialized by **one lock** (`os_unfair_lock` or `NSLock`). CoreGraphics calls happen outside the lock where practical.
- **Tap thread:**
  - Listen-only `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly)` for mouseMoved, left/right/other MouseDragged, and mouse down/up.
  - Its own CFRunLoop. Re-enable the tap on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
  - The callback must return quickly: do no network I/O inside the lock, and hand packet sends to the send path without blocking.
- **Poll thread:** QoS userInteractive.
  - While **armed**, sample `CGEvent(source: nil)?.location` every 1 ms. Armed means: a fresh peer EDGE packet (≤ `armMs`, default 400) **or** a pending late landing **or** the snap-back guard is active.
  - Otherwise, block on a semaphore with a timeout (default 250 ms). A packet arrival signals the semaphore, so arming takes effect immediately.
  - Idle CPU must stay about 0.
- **Net thread:** blocking `recvfrom` on a dual-stack UDP socket, `[::]:port`, `IPV6_V6ONLY` = 0.
- **Timers** on a utility DispatchQueue:
  - heartbeat every 2 s
  - geometry and UC-arrangement refresh every 10 s, plus the display reconfiguration callback
  - status.json write every 5 s and after each correction
  - DNS re-resolve every 30 s
- **Main thread:** `dispatchMain()` / CFRunLoop, used for the display reconfiguration callback.

**Fallback if the tap can't be created:** poll continuously at 250 Hz and derive samples from position changes. There are no deltas in that mode, so `pushing` means "at edge and moved", and the dead strip is disabled. Log it loudly and show it in status.

## 5. Correction algorithm (the heart)

### 5.1 Edge geometry
- The shared edge comes from the live bounds of the configured display UUIDs.
- **Span** = [min minX, max maxX] of those rects, measured on the side of the edge.
  - `top`: `edgeY` = min(minY). The inner direction is +y.
  - `bottom`: `edgeY` = max(maxY). The inner direction is −y; cursor y is at most `edgeY` − ε, and −0.02 has been seen.
- `signedDist(p)`:
  - top: `p.y − edgeY`
  - bottom: `edgeY − p.y`
  - Positive means inside the edge displays. `distToEdge` = max(0, signedDist).
  - On the MacBook, landing at (0, 0) gives y = 0 = edgeY → dist 0.
- **Landing strip / at edge (v1.1):** `−1 ≤ signedDist(p) ≤ stripPt` (default 30) and `spanMin − 1 ≤ p.x ≤ spanMax + 1`.
  - Both ends are **closed**, because the corner landing at (0, 0) sits exactly on 3's rectangle border.
  - Points more than 1 pt beyond the edge are another display, e.g. display 1 at (0, 345), and are never in the strip.
- **Clamping a correction target (v1.1):**
  - x into [spanMin, spanMax − 0.5].
  - y at least `targetInsetPt` (default 2) inside the edge line, which is outside UC's 1-pt hot zone, so a slide right after landing can't bounce back. Otherwise keep the current y, capped at `stripPt` from the edge.
  - The result must lie on one of the configured edge displays. This matters on the MacBook, where (0, 0) is display 1's pixel; the target there becomes (−0.5, −2).
- **Minimum correction (v1.1):** if `|target.x − current.x| < minCorrectionPt` (default 2), return no correction. The cursor stays where UC put it.

### 5.2 Sender (runs on every local tap event)

**crossX latch (v1.1).** This models UC's own hot-zone logic. It was validated on all 7 recorded crossings at 0–40 ms delay, with 0 pt error; see `Tests/UCEdgeCoreTests/Support/latchrules.py`.
- **Terms:**
  - `zone` = §7's [zoneMinX, zoneMaxX] on a side with a dead strip (V-Mind, configured fallback −961 / 1600). Everywhere else, and on a dead-strip side while UC's zone is unknown with no fallback configured, it's [spanMin − 1, spanMax + 1].
  - `s = signedDist(e.p)`, positive inside the edge displays.
  - `push` = `e.dy < 0` (top edge) or `e.dy > 0` (bottom edge).
  - State: `armed`, `crossX` (nil = not latched), `latchT`, `prevT`.
- **On every local tap event `e`, in order:**
  1. Set `armed = false` and `crossX = nil` if any of these holds:
     - `e.t − prevT > 100 ms`
     - `s > 30` or `s < −1`
     - `crossX ≠ nil` and `e.t − latchT > 150 ms`
  2. If `crossX == nil`:
     - If `armed && push`: `crossX = e.p.x`, `latchT = e.t`. This is UC's "Activating".
     - Else if `!armed`, `−1 ≤ s < 1` and `zone.min ≤ e.p.x ≤ zone.max`: `armed = true`. This is UC's "Entering"; this event itself never latches.
  3. `prevT = e.t`.
- **Polling fallback (no tap):** latch the x of the second consecutive at-edge sample inside the zone.

**Packets:**
- Send an **EDGE** packet on every local event where `−1 ≤ s ≤ atEdgePt` (1.5) **or** `crossX ≠ nil`, and x is within [spanMin − 1, spanMax + 1]. No approach band.
- **Fields:**
  - `x` (current)
  - `d`
  - `pushing`: at edge and `push`
  - span min/max
  - `crossX`: NaN when not latched. While a dead-strip `virtualX` is valid, a latched `crossX` is replaced by `virtualX`.
- **Redundancy:** each packet is **sent twice**, the second copy about 4 ms later (asynchronously, never sleeping on the tap thread). That covers Wi-Fi loss.
- Send nothing periodic except HELLO.

### 5.3 Receiver state
- `PeerEdgeState` = last EDGE packet decoded: `x`, `d`, `pushing`, `spanMin`, `spanMax`, `crossX: Double?`, `receivedAt` (local monotonic ms).
- **Fresh at edge (v1.1):** `now − receivedAt ≤ freshMs` (default 300) **and** a latched, finite `crossX`, and **not** `d ≤ 1.5`. Tail packets can be several pt from the edge, and the latch is the strong signal.
  - Both the immediate and the late target use `physicalMap(crossX)`.
- **Arming** (1 kHz poll): any authenticated EDGE packet received within `armMs` (400). Packets now only flow while the peer is at its edge or latched.
- Packets from an old sender session, or out-of-order ones, are dropped by the wire layer (§8).

### 5.4 LandingDetector state machine
The input is local samples `(t ms, p, buttonsDown)` from the tap and the poller. They're merged in time order under the lock, and duplicate positions are ignored.

1. **Change detection.** Keep `lastPos` and `lastChangeT`. On a sample whose position differs by more than 0.01 pt: `still = t − lastChangeT`, `prev = lastPos`. Then update both.
2. **Own-warp echo.** If `didWarp(to:)` was called and this sample is within 1.5 pt of that target, consume the expectation and do nothing.
3. **Snap-back guard.** For `guardMs` (default 250) after a correction:
   - If the cursor reappears within 3 pt of the UC landing point we corrected away from, UC has put it back.
   - Re-issue the correction **once**, as `target + (p − landing)`.
   - Kind `.snapback`. Count it.
4. **Cooldown.** Ignore landings for `cooldownMs` (default 400) after a correction.
   - **Exit tail (v1.1, `exitTailMs` default 75).** A change that comes less than `exitTailMs` after the previous change, where that previous position was at our own edge, is the tail of our own exit, not a landing. Tail events keep arriving for 51–100 ms after UC takes the pointer.
   - Exception: the peer is fresh and `pushing`.
   - Cost: a return by menu-bar slide within 75 ms isn't corrected.
5. **Landing candidate:** `still ≥ minStillMs` (default 30) **and** p is in the landing strip **and** no button is down.
   - If the peer is **fresh at edge**, return an **immediate** correction with target x = `physicalMap(peer.crossX, peerSpan → localSpan)` and y = the clamped current y.
   - Otherwise store `pending = (t, p)`.
6. **Late path.** On each peer packet (`onPeerUpdate`), if all of these hold, correct to `physicalMap(peer.crossX) + (current.x − pending.p.x)` with the clamped current y, kind `.late`, and clear pending:
   - `pending` exists
   - `t − pending.t ≤ lateWindowMs` (default 150)
   - the packet is fresh at edge per §5.3 (a latched crossX)
   - no button is down
   - the current cursor is still on an edge display
7. Pending expires after `lateWindowMs`.

**Why this can't fire during normal use:** "peer fresh at edge" can only be true while the user's pointer is on the peer (fact 2). A local landing-strip change after stillness, with the pointer on the peer moments earlier, can only be a UC crossing.

A known, harmless ambiguity: a side-link crossing from 4's exact top-right corner into display 1's top-left pixel row may qualify. The correction moves it by about 1 pt. Accept it.

### 5.5 Warp
- `CGWarpMouseCursorPosition(target)` then `CGAssociateMouseAndMouseCursorPosition(1)`, which removes the 250 ms local-event suppression.
- Check the returned CGError. On 1003, set status `warpFailing` and count it.
- Then call `detector.didWarp(t, to:)`.
- Never warp while a mouse button is down. Check again right before warping with `CGEventSource.buttonState(.combinedSessionState, …)` for buttons 0–2.

### 5.6 Required public API (UCEdgeCore)

The test agent writes against this API in parallel, so implement **exactly** these names and signatures. Adding more is fine.

```swift
import CoreGraphics   // CGPoint/CGRect only; Core must not call CGWarp/CGEvent functions

public enum EdgeSide: String, Codable, Sendable { case top, bottom }

public struct EdgeGeometry: Sendable, Equatable {
    public let side: EdgeSide
    public let displays: [CGRect]          // live bounds of the configured edge displays
    public let edgeY: Double
    public let spanMin: Double
    public let spanMax: Double
    public init(side: EdgeSide, displays: [CGRect])          // derives edgeY/span (§5.1)
    public func distToEdge(_ p: CGPoint) -> Double
    public func inLandingStrip(_ p: CGPoint, stripPt: Double) -> Bool
    public func clampTarget(x: Double, currentY: Double, stripPt: Double) -> CGPoint
}

public func physicalMap(peerX: Double, peerSpanMin: Double, peerSpanMax: Double,
                        localSpanMin: Double, localSpanMax: Double) -> Double   // clamped to [localSpanMin, localSpanMax]

public struct PeerEdgeState: Sendable, Equatable {
    public var x: Double; public var d: Double; public var pushing: Bool
    public var spanMin: Double; public var spanMax: Double
    public var receivedAt: Double          // local monotonic ms
    public var crossX: Double?             // v1.1: latched UC exit x (§5.2); nil = not latched
    public init(x: Double, d: Double, pushing: Bool, spanMin: Double, spanMax: Double, receivedAt: Double,
                crossX: Double? = nil)
}

public struct DetectorParams: Sendable, Codable, Equatable {
    public var stripPt = 30.0, minStillMs = 30.0, freshMs = 300.0, lateWindowMs = 150.0
    public var cooldownMs = 400.0, guardMs = 250.0, atEdgePt = 1.5
    public var exitTailMs = 75.0, targetInsetPt = 2.0, minCorrectionPt = 2.0   // v1.1
    public init()
}
// v1.1: the sender latch is its own Core type so it can be unit- and replay-tested:
public final class CrossLatch {             // not thread-safe
    public init()
    /// zoneMin/zoneMax per §5.2. Returns the latched crossX after processing this event (nil = none).
    public func onEvent(t: Double, p: CGPoint, dy: Double, geometry: EdgeGeometry,
                        zoneMin: Double, zoneMax: Double) -> Double?
    public func reset()
}

public enum CorrectionKind: String, Sendable, Codable { case immediate, late, snapback }

public struct Correction: Sendable, Equatable {
    public let kind: CorrectionKind
    public let target: CGPoint
    public let landing: CGPoint           // where UC put the cursor (pending.p for late)
    public let peerX: Double
}

public final class LandingDetector {        // not thread-safe; caller serializes
    public init(params: DetectorParams = .init())
    public func onSample(t: Double, p: CGPoint, buttonsDown: Bool,
                         geometry: EdgeGeometry, peer: PeerEdgeState?) -> Correction?
    public func onPeerUpdate(t: Double, peer: PeerEdgeState, current: CGPoint, buttonsDown: Bool,
                             geometry: EdgeGeometry) -> Correction?
    public func didWarp(t: Double, to: CGPoint)
    public var isArmed: Bool { get }      // pending or guard active (engine adds peer freshness)
}

public struct DeadStripParams: Sendable, Codable, Equatable {
    public var enabled = false, pushThresholdPt = 12.0, minPushMs = 180.0, maxGapMs = 100.0   // v1.1
    public var cooldownMs = 1500.0, virtualXValidMs = 1000.0
    public init()
}
public final class DeadStripDetector {      // not thread-safe
    public init(params: DeadStripParams)
    /// zone = the x range of the local shared edge that UC *does* cover (§7). Returns the redirect
    /// point to warp to when a deliberate push in the uncovered part is detected.
    public func onEvent(t: Double, p: CGPoint, dy: Double, prevWasPinned: Bool, buttonsDown: Bool,
                        geometry: EdgeGeometry, zoneMinX: Double, zoneMaxX: Double) -> CGPoint?
    public func virtualX(at t: Double) -> Double?   // original x while a redirect is valid
}
```

## 6. Dead-strip assist (V-Mind only, `deadStrip.enabled`)

- The dead part of the local edge is the span outside UC's zone `[zoneMinX, zoneMaxX]` (§7). On V-Mind today that's x in [−1600, −961).
- A **pinned push** is an event with the cursor exactly at the edge (d ≤ 0.5) whose **previous** event was also pinned, and whose dy points into the edge. Arriving flicks therefore don't count.
- **Sustained push (v1.1).** The current run of pinned pushes, with x in the dead part and no gap > 100 ms between them, must meet both:
  - it spans at least `minPushMs` (default 180)
  - its magnitudes sum to at least `pushThresholdPt` (default 12)
  - A flick to the Apple menu (arrival momentum lasts about 50 ms) doesn't qualify. The recorded deliberate push fires at 184 ms.
- When both hold, no button is down, and it's not in cooldown:
  - return the redirect point `(zoneMinX + 2 if dead part is left of zone else zoneMaxX − 2, edgeY)`
  - remember `virtualX = p.x` for `virtualXValidMs`
  - start the cooldown
- The engine warps there. The user is still pushing, so UC sees a push inside its zone and crosses.
- While `virtualX` is valid, it replaces a latched `crossX` in EDGE packets (§5.2), so the MacBook places the cursor above the original point.
- If the crossing doesn't happen, the cursor stays at the redirect point. Don't warp back.
- Tune the threshold after the live test. Keep it configurable.

## 7. UC arrangement (best effort, read-only)

- **File:** `~/Library/Preferences/ByHost/com.apple.universalcontrol.*.plist`. Reading the key `Configuration` gives bytes, which are a bplist dict `{vers, head, heap, refs}`.
- **heap** is a list of entries `[hash(32B), ts, 1, parentHash, count, link...]`. The head entry's links are the current arrangement.
- A **link** is `[ts, edgeCode, devA, dispA_UUID, devB, dispB_UUID, fracA_u16, fracB_u16]`, where frac = value / 65535, measured along each display's shared edge from its left (minX).
- **What to compute:** find the link whose two display UUIDs are {one local edge display, the peer's edge display}. The peer's edge display UUIDs and bounds widths arrive in its HELLO packets.
  - Local link point: `localDisp.minX + fracLocal * localDisp.width`
  - `zoneMinX = linkPoint − fracPeer * peerDisp.width`
  - `zoneMaxX = zoneMinX + peerDisp.width`
  - Today on V-Mind: 800 − 0.6875·2560 = −960 and 1600.
- **Fallbacks:**
  - On any parse failure (and before the peer's first HELLO), use `deadStrip.zoneMinXFallback` / `zoneMaxXFallback` from config (V-Mind: −961 / 1600). Report `arrangement: fallback` in status. They have no default (the values are layout-specific): with neither set, the dead strip stays off and the latch uses the whole span until UC's zone is known. Both or neither; an incomplete or inverted pair is dropped with a config warning.
  - If the file parses but **no link** joins a local edge display to the peer's edge display, set status `ucLinkMissing = true` and log a warning once per change. This happened on 2026-09-28: the user's arrangement lost the top link, and nothing crossed.
- Re-read when the file's mtime changes, checked every 10 s.

## 8. Wire protocol (UDP, default port 47591)

- **Fixed header:** magic `"UCE1"` (4 B), `type` (u8: 1 = HELLO, 2 = EDGE, 3 = HELLO_ACK), `senderId` (u64, random per process start), `seq` (u64, strictly increasing per sender), `wallMs` (i64, ms since 1970).
- **Body:** fixed little-endian binary fields.
  - EDGE: `x f64`, `d f64`, `pushing u8`, `spanMin f64`, `spanMax f64`, `crossX f64` (NaN = not latched; v1.1).
  - Decoders reject non-finite x/d/span values. crossX may only be NaN, or finite.
  - HELLO / HELLO_ACK:
    - version string (u8 length + bytes)
    - side (u8)
    - edge display list: count u8, then per display: UUID 16 B, minX f64, width f64
    - `axTrusted u8`
    - `echoWallMs` i64 (ACK only)
- **Trailer:** HMAC-SHA256 over everything before it, truncated to 16 bytes.
- **Key:** 32 random bytes, hex in `~/.config/uc-edge/key`, mode 0600, the same on both Macs. Refuse to start correcting without it; show `keyMissing` in status.
  - **Never log or print key material.**
- **Receive checks, in order:**
  1. length and magic
  2. constant-time HMAC compare
  3. `|now − wallMs| ≤ 10 000` (clock sanity against replay across sessions)
  4. per-senderId `seq` > last seen, keeping at most the 8 newest senderIds (LRU)
- Count and rate-limit logging of rejects.
- **Peer address:**
  - Resolve `peerHosts` (getaddrinfo, AF_UNSPEC, prefer IPv4) at start and every 30 s.
  - Also learn the source address of the latest **authenticated** packet and prefer it.
  - Send to the single preferred address.
  - Send errors (EHOSTUNREACH, …) are counted and shown in status (`netError`). They're not fatal.
- **HELLO** every 2 s. The peer answers with HELLO_ACK echoing `wallMs`, which gives RTT. Peer "alive" means an authenticated packet within the last 10 s.

## 9. Build, signing, install

- **Build:** `scripts/build-app.sh` runs `swift build -c release`, assembles `build/UCEdge.app` (Info.plist from `Resources/`) and signs it:
  - `codesign --force --timestamp=none --options runtime --sign <SHA1 of $UCEDGE_SIGN_IDENTITY>`, an Apple Development identity set in the environment or the gitignored `scripts/local.env` (`scripts/signing.sh`).
  - The designated requirement must stay `identifier "local.uc-edge" and anchor apple generic and certificate leaf[subject.CN] = "<that identity>" …`. The permission grants depend on it; `UCEDGE_EXPECTED_DR` makes the build refuse anything else.
  - Verify with `codesign -v` and `codesign -d -r-`.
- **Info.plist:** CFBundleIdentifier `local.uc-edge`, CFBundleExecutable `UCEdge`, LSUIElement true, `NSLocalNetworkUsageDescription`, version fields.
- **Install** (done by the orchestrator, **not** by build agents):
  - `~/Applications/UCEdge.app`
  - `~/.config/uc-edge/{config.json,key}`
  - LaunchAgent `~/Library/LaunchAgents/local.uc-edge.plist`: ProgramArguments `[…/UCEdge, run]`, RunAtLoad, KeepAlive, ProcessType Interactive, stdout/stderr to `~/Library/Logs/UCEdge/launchd.log`
- **App log:** `~/Library/Logs/UCEdge/uc-edge.log`. Rotate at 2 MB and keep 2.
- **Status:** `~/Library/Application Support/UCEdge/status.json`. `UCEdge status` prints a human summary: permissions, peer alive/RTT/address, geometry, arrangement (zone, linkMissing), counters, and the last 10 corrections with kind, landing, target, peerX and latency.
- **Configs:**
  - V-Mind: side top, displays [4, 5], peerHosts [the MacBook's name], deadStrip enabled
  - MacBook: side bottom, displays [3], peerHosts [V-Mind's name, V-Mind's fixed address], deadStrip disabled
  - Our own configs live in the gitignored `config/local/`; generic ones are in `config/examples/`.

## 10. Tests (Swift Testing, `swift test` must pass)

1. **Geometry and mapping:**
   - Spans and edgeY for both configs.
   - `physicalMap` endpoints and midpoint: V-Mind −1600 → −2560, 0 → −1280, 1600 → 0, and the inverse.
   - The closed strip includes (0, 0) for the MacBook.
   - clampTarget keeps targets on the edge displays: (0, 0) becomes (−0.5, −2) on the MacBook (2 pt inset, v1.1).
2. **Wire:**
   - Round trip.
   - Tampered byte → reject.
   - Wrong key → reject.
   - Replayed seq → reject.
   - Stale wallMs → reject.
   - New senderId accepted.
3. **Detector:**
   - Unit scenarios: immediate, late, pending expiry, snapback, cooldown, buttons down, no peer → never, peer stale → never, peer not at edge → never.
   - The menu-bar case: the local cursor pauses 500 ms at the strip and then moves while the peer is idle → no correction.
4. **Trace replay (the important one).** Parse the recordings in `testdata/`.
   - **Format:** `t_ms x y bN still=…` for polled positions. `t_ms TAP t<type> (x,y) dx= dy=` for tap events. `t_ms WARP …` marks our test warps in s1. `start` and `display` header lines.
   - Feed the MacBook trace into LandingDetector, **synthesizing peer packets from the V-Mind trace**, and vice versa. The two recorders' clocks differ by an unknown offset, under 1 s. Align them using the UC logs (`uc-log-*.txt`): the V-Mind "Target Ready: edge=top" time ≈ the MacBook landing time, and the MacBook "Target Ready: edge=bottom" ≈ the V-Mind landing time.
   - **Assert, for session s2:**
     - every real top-edge crossing yields exactly one correction on the MacBook side
     - every real downward crossing yields exactly one correction on the V-Mind side
     - targets match `physicalMap(exit x)` within 5 pt
     - **no other corrections** anywhere in either trace
   - Session s1 has only the MacBook trace (V-Mind exits: −930.9, 1564.9, −33.5, 20.4, 785.2, 1553.1 at UC Target Ready times in `uc-log-vmind.txt`). Use it for the "no false positives while working on the MacBook" assertion across its whole length. Ignore samples right after its two WARP lines.
   - The dead-strip detector on `s2-vmind.txt` fires exactly once during the burst at about 139.6–141.3 s with the default threshold, and never on in-zone top-edge events.
5. **Loopback integration** (no CoreGraphics): two engines with fake cursor sources talking UDP over 127.0.0.1 on different ports. A simulated crossing produces the correct correction target on the receiver within 20 ms.

## 11. Hard rules for everyone working on this

- **The user may be at this computer.** Don't warp the cursor, post events, or run anything that does, except the orchestrator during agreed live tests. Unit tests must not call CGWarp or CGEvent posting.
- **Don't install, load or unload LaunchAgents.**
  - Don't touch `~/Applications/UCEdge.app` or `~/Library/LaunchAgents/*`.
  - Don't stop the existing `local.uc-edge.*` jobs.
  - Don't SSH anywhere.
- **Don't read `~/.ssh`, `.env` files, keychains or TCC databases.** Don't print key material. Don't work around macOS privacy controls (TCC, Local Network); the user grants permissions normally.
- **Builds:** `swift build` / `swift test` need the Bash sandbox disabled (the module cache is outside the sandbox). Use `dangerouslyDisableSandbox: true` for those commands only.
- Match the house style: small files, clear names, comments only where the *why* isn't obvious.

## 12. v1.2 (audit fixes)

These behaviour changes override the sections above where they differ.

- **Latch, one per edge visit (§5.2).** After a latch expires, CrossLatch can't re-arm until the cursor leaves the edge (s ≥ 1 or s < −1) or events pause for > 100 ms.
  - In the polling fallback, only position **changes** feed the latch.
- **Tap supervision (§4).** A disabled tap is re-enabled. A tap that's lost (its run loop ends, or it can't be re-enabled) is recreated. In fallback, `tapCreate` is retried every 10 s. Status shows the current mode.
- **Peer episode (§5.3/§5.4).** `episodeStart` = local arrival of the first EDGE packet after a > 150 ms gap in packets.
  - A landing (immediate or late) is accepted only if `stillBeforeLanding ≥ (landingT − episodeStart) − 20 ms`.
  - A rejected immediate landing is not left pending.
- **Sender-time freshness (§5.3).** The clock offset comes from HELLO/HELLO_ACK: the NTP-style midpoint, smoothed, from samples with RTT < 50 ms only.
  - Fresh also requires sender age (offset-corrected) ≤ freshMs + 50.
  - With no offset estimate yet, the raw sender age must be ≤ freshMs + 500.
- **Exit tail (§5.4).** A tail-suppressed landing stays pending, flagged `tail`. Only a *pushing* peer packet resolves it.
  - The immediate-path exemption needs a pushing packet received ≤ 50 ms ago.
- **Snap-back (§5.4).** Only a jump of > 10 pt from the previous sample counts.
- **Late target (§5.4).** y = current y (no pull back into the strip, 2 pt inset kept); x = physicalMap(crossX) + (current.x − landing.x). `current` is the detector's own last sample.
- **Dead strip (§6).**
  - A run whose x spread exceeds 30 pt restarts, and firing also needs Σ|dy| ≥ 1.5·Σ|dx| over the run.
  - virtualX replaces only the **first** latch after a redirect, and only within 300 ms and 5 pt of the redirect point; the redirect is consumed either way.
- **Wire and key (§8).**
  - HELLO display values must be finite, with width > 0.
  - The key file must be exactly 64 hex digits plus an optional trailing newline, and not group- or other-accessible (`keyInsecure`).
  - No trapping arithmetic on peer timestamps; an RTT outside 0…10 000 ms is ignored.
- **Robustness.**
  - The receive loop logs errors and retries every 100 ms; after 50 in a row it exits for launchd to restart it.
  - Log and status writes never throw or abort.
  - DNS runs on its own queue.
- **Config.**
  - An invalid display UUID or port is an error: UCEdge refuses to run and says so in status.
  - Out-of-range numbers fall back to their defaults with a warning.
  - A peer HELLO with our own side is flagged.
- **Misc.**
  - Tap deltas are integers.
  - The ByHost file is `com.apple.universalcontrol.<gethostuuid>.plist`, falling back to the only match.
- **v1.2.1:**
  - **Tail pending needs a jump.** Only a landing sample more than 40 pt from the previous position can be stored as tail-pending. A small exit-tail move along the edge never becomes pending, so it can't pre-empt a quick return; UC's real landing jump is corrected by the immediate path (≤ 50 ms pushing exemption) or, as tail-pending, by the late path.
  - **Episode slack** is `detector.episodeSlackMs`, default 120 ms, because an exit tail can run ~100 ms.
  - **Clock steps.** A clock-offset sample with RTT < 50 ms that differs from the estimate by more than 200 ms is adopted at once.
  - **Tap recreation** backs off exponentially, from 1 s doubling to 60 s, and the backoff resets once the tap has stayed healthy for 60 s. Health is checked every second.
  - **launchd.log.** At startup, if `~/Library/Logs/UCEdge/launchd.log` is over 1 MB, it's truncated in place to its last 64 KB.
  - **Config.** V-Mind's config sets `deadStrip.minPushMs` = 250 (the code default stays 180), so an Apple-menu corner throw can't fire it.

---

## 13. v1.3: UC log assist; the receiving side is one-way (live test 2026-09-29)

### 13.1 What the live test showed
- **Upward (V-Mind → MacBook)** works. 18 of 20 crossings were corrected to the latched x. The **2 misses** were slow slides: UC logged "Hot Zone: Entering" when the cursor touched its zone, then **"Activating" 617–784 ms later**, with the cursor by then outside the zone horizontally (x −1192, −1230).
  - UC's entered state is **sticky** while the cursor stays on the edge. Its activation criterion is **not** "the next push event".
  - In s3, UC activated on a dy = −1 event after a dy = −4 one. The CrossLatch picked the earlier event and was 6.6 pt off.
- **Downward (MacBook → V-Mind) can't be corrected by warping.** On V-Mind the pointer is driven by UC's virtual HID device, and **UC positions it absolutely from its own model**. In s3, V-Mind was warped to (1351, 2), and the next forwarded event (26 ms later, reported dx = 972) put it at UC's landing (1599, 0) plus the user's motion.
  - The dead-strip redirect on V-Mind is undone the same way, but first it makes UC log "Entering". The next push then activates UC where UC's model has the cursor: the original x plus motion.
- **Exact UC x from the log.** The unified log line `Hot Zone: Activating: <edge>:<device>:<peer display UUID>` is emitted **0.3–5 ms after the event UC activated on**. That event's x equals UC's `Target Ready` offset back-computed to x, exactly (s3: 539.41, 1313.00).
  - `log stream` delivers the line **0.3–2.5 ms** later, at **~0 CPU** (predicate filtered in logd).
  - Target Ready, and the receiver's landing, follow Activating by about 12–15 ms. So a UC-sourced crossX normally reaches the receiver **before** the landing.

### 13.2 Behaviour changes
1. **`ucLog` source, on both Macs (`ucLogAssist.enabled`, default true).**
   - **Process:**
     - Supervise a child `/usr/bin/log stream --style ndjson --predicate 'process == "UniversalControl" AND (eventMessage BEGINSWITH "Hot Zone: Activating" OR eventMessage BEGINSWITH "Hot Zone: Entering")'`.
     - Restart it with backoff (1 s → 60 s) if it exits. Kill it on shutdown.
     - Parse each ndjson line (`eventMessage`, `machTimestamp`).
   - **Clocks:**
     - `machTimestamp` is in the **mach_continuous_time** domain (it includes sleep; on the MacBook it differed from mach_absolute_time by ~12 711 s).
     - `CGEvent.timestamp` is **uptime nanoseconds** (mach_absolute_time converted by the timebase).
     - Convert with `ns = (machTimestamp − (mach_continuous_time() − mach_absolute_time())) × numer / denom`. The offset is sampled when the line is received.
     - **Sanity:** the receive lag `nowUptimeNs − ns` must be in [−5 ms, 2 s]. Otherwise ignore the line and count `ucLogClockErrors`.
   - **Ring buffer:** keep the last 2 s of local tap events: `(eventTimestampNs, x, y, s, dy)`.
   - **On an `Activating` line:**
     - Its edge must equal our shared side (`top` on V-Mind, `bottom` on the MacBook).
     - Its display UUID must be one of the peer's edge displays, as known from the peer's HELLO.
     - Then **crossX = x of the latest buffered event with `eventTimestampNs ≤ ns` and −1 ≤ s ≤ 1.5**, within 100 ms before `ns`.
     - Dead-strip redirect: if a redirect happened in the last 1 s and that x is within 5 pt of the redirect point, use the redirect's original x (`consumeRedirect`).
     - Send an EDGE packet at once, plus the usual duplicate, with `crossX` and **`crossSource = 1` (uc)**.
     - Log a line: `uccross x=… lagMs=… eventAgeMs=…`.
   - **Tail packets:** later EDGE packets in the same episode, until the latch rules reset (gap > 100 ms, s > 30, or 150 ms after), keep carrying that crossX with `crossSource = 1`.
2. **Wire:** EDGE gains `crossSource u8` after crossX (0 = model latch, 1 = uc). HELLO gains `ucLogActive u8`: true while the child is running and has delivered at least one parsable line since start, or within the last 10 min.
3. **Receiver preference:**
   - If the peer's HELLO says `ucLogActive`, only `crossSource = 1` packets can make the peer "fresh at edge". Model-latched packets still arm the poller.
   - If the peer's log assist is inactive, fall back to the v1.2 model latch.
4. **`corrections.enabled` (per machine, default true; V-Mind = false).** When false, the detector never warps: no landing corrections and no snap-back. Everything else still runs (sending, ucLog, HELLO, the dead-strip redirect). This replaces the interim `freshMs: 1` hack on V-Mind.
5. **Dead strip on V-Mind (unchanged trigger).** The redirect's only job now is to make UC enter its zone; the UC-sourced crossX supplies the real x. Keep `consumeRedirect` for the case where UC activates at the redirect point.
6. **Status** gains:
   - `ucLog`: running / restarting / disabled, lines parsed, last line age, clock errors
   - counters `ucCross`, `modelCross`
   - per correction, the crossSource
7. **Tests:**
   - ndjson parsing
   - the continuous→uptime conversion
   - matching against `testdata/s3-vmind-uclog.txt`: two top crossings must give crossX 539.41 and 1313.00 exactly. Its UCLOG `mach=` values are continuous-domain ticks; V-Mind hadn't slept, so the offset is ~0. `rx=` and TAP `evts=` are uptime ns.
   - `s3-macbook-uclog.txt`: its continuous offset wasn't recorded (~12 711 s). Derive it by aligning, or skip the MacBook file.
   - filtering: side-link Activating lines (`right:`/`left:`) and a foreign display UUID must be ignored
   - the dead-strip substitution
   - the receiver preference logic, and `corrections.enabled = false`

### 13.3 v1.3 implementation notes
- **Core** (`UCLogAssist.swift`, unit-tested): `UCLogParser` (ndjson → `UCLogEvent`; it skips the text header `log stream` prints first), `UCLogClock` (continuous → uptime with full-width integer maths, and the [−5 ms, 2 s] lag check), `UCLogFilter`, `UCCrossMatcher` (2 s buffer; latest at-edge event ≤ activation, ≤ 100 ms), `UCCrossHold` (tail packets, latch reset rules) and `CrossSourcePolicy` (§13.2.3).
- **System:** `UCLogStream` runs the child, with backoff 1 s doubling to 60 s, reset after a 60 s run. The child is killed on SIGTERM, and launchd also cleans up the process group. The tap now passes each event's own `CGEvent.timestamp`; the polling fallback uses the sample time.
- **`ucLogActive`:** true when the child is running and has delivered a parsable line since it started, or delivered one within the last 10 min. Until the first crossing after start the peer therefore uses the model latch. A change sends a HELLO at once.
- **Dead strip:** the UC path has its own copy of the redirect (`consumeRedirectForUC`, 1 s, 5 pt), so the model latch consuming its copy first doesn't hide it.
- **Wire:** the magic is now `UCE2`, so a 1.2 peer's packets fail with `badMagic`. An unknown `crossSource` value is `badBody`.
- **Checked on s3:** V-Mind gives 539.41 and 1313.00 exactly (offset 0). The MacBook matches −199.09 with an offset derived from its minimum receive lag (≈ 12 711.196 s); that equals UC's `Target Ready offset=-199.093750`, which confirms zone ⟨4⟩ reports the absolute x.
- **Idle cost:** the `log stream` child used 0.01 s of CPU in 30 s idle, with RSS ~4 MB.

### 13.4 v1.3.1 (audit fixes)
- **F1 (clock sampling).** The reader reads `mach_absolute_time()` first, then `mach_continuous_time()`, and clamps a negative difference to 0. The engine also treats a wrapped (negative) offset as 0.
- **F2 (receiver).** This replaces the §13.2.3 `ucLogActive` gate.
  - A UC-sourced crossX is preferred for the whole peer episode.
  - A landing with only a model crossX, from a peer that advertises `ucLogActive`, is held for `detector.ucWaitMs` (25 ms) waiting for a UC-sourced packet: `src=uc` if one comes, otherwise the model crossX (`src=model`). Both are kind `late`.
  - The fire-time checks still apply: no button down, still on an edge display, the episode rule, and `current` = the detector's last sample; the cursor's movement since the landing is kept.
  - Without `ucLogActive`, the model crossX is used at once.
  - `ucLogActive` now means: the child is running and has matched an Activating line in the last 24 h, or has parsed any line since it started.
- **F3 (late lines).** An Activating line delivered more than `ucLogAssist.maxLagMs` (100 ms) after its timestamp is ignored and counted (`lateLines`). A match whose event lies before the current edge visit (the latch's reset rules) is ignored (`staleVisit`), so a crossX can't carry into a later visit.
- **F4 (child lifetime).**
  - The child is killed on `exit()` (atexit), on SIGTERM/SIGINT/SIGHUP, on `onFatal`, and on crash signals.
  - At startup, `log stream` processes left by an earlier instance are killed. The match is our uid, ppid 1, and exactly our argv (`/usr/bin/log stream --style ndjson --predicate <ours>`); nothing else is touched.
- **F5 (matching).** Each Activating line is matched 3 ms after it is read, so the tap callback for the activating event is in the buffer.
- **F6 (housekeeping).**
  - The reader drops a partial line over 64 KB and counts it.
  - `status.ucLog.lastLineAgeMs` is set.
  - With `corrections.enabled = false` the 1 kHz poller is never armed.

---

## 14. v1.4: downward override guard; dead-strip tuning (live test 2026-09-29 19:05)

### 14.1 Evidence
- **Upward in 1.3.1 is exact.** Every upward crossing was corrected, almost all `src=uc`, 1–5 ms after landing.
- **Downward into monitor 4 is UC's native bug:** offsets like −1071, −848, −994 land at V-Mind (1599, 0). With V-Mind corrections off, the user immediately noticed ("did you break 3→4?"). In 1.2.1 the corrections had partly masked it.
- **The override is one identifiable event.** In s3 (1.2.1) the V-Mind correction to (1351, 2) was undone by a **single** forwarded event, 26 ms later.
  - That event reported `dx=972 dy=83`, but the cursor moved (140.8, 82.4) from our target, to UC's landing (1599, 0) plus the user's motion.
  - Every normal event in the traces moves the cursor by its reported delta within ~1 pt (8→7.2, 13→12.9, 85→85.7).
  - The events after the override were relative again. Working hypothesis: UC applies its own absolute position once, when it flushes the first report after the handoff.
- **The dead strip didn't fire** in the 1.3.1 test. The user: "it crosses but takes a long time". It crossed only after drifting into UC's zone. The v1.2.1 limits are too strict for real pushes: spread ≤ 30, dy ≥ 1.5·dx, 250 ms.

### 14.2 Changes
1. **Override guard (detector, both Macs; `detector.overrideGuard`, default true).** For `overrideGuardMs` (default 300) after any correction warp:
   - Keep `lastTapPos` = the position after the previous **tap event**, or our warp target if we warped since then. Poller samples must not update it.
   - **An override event** is a tap event whose observed motion `p − lastTapPos` differs from its reported delta (dx, dy) by more than `overrideMismatchPt` (default 20) in x or y, **and** is not explained by clamping: p isn't within 1 pt of a display boundary on the axis concerned.
   - **On an override,** re-warp to `p + (target − landing)`. That shifts the cursor by the same Δ as the original correction, clamped onto the edge displays. At most `overrideMaxRewarps` (default 2) per correction. Log `override rewarp n=… p=… to=…` and count it (`overrideRewarps`).
   - **No false triggers:** normal events (consistent deltas) never re-warp, and neither does the user moving toward the landing point.
   - Keep the existing snap-back rule as is.
2. **V-Mind `corrections.enabled` = true again** in V-Mind's config, with the override guard on.
3. **Dead strip, looser but still safe from menu slides (V-Mind config):**
   - `minPushMs` 150, `pushThresholdPt` 8, `maxSpreadPt` 60, `minDyDxRatio` 1.0
   - An x-dominant slide (the Apple → File menu) still never fires.
   - Also log rate-limited **near-misses**: runs of ≥ 100 ms that didn't fire, with duration, sum, spread, ratio and the reason. That's for tuning.
4. **Status:** `overrideRewarps`, and the last near-miss reason.
5. **Tests:**
   - the s3 override event (synthesized from `testdata/s3-vmind-uclog.txt` around the 17:01:54.56 correction) triggers exactly one re-warp to `p + Δ`
   - no re-warp on the s2/s3 normal event streams (replay every tap event after each correction in the traces through the guard)
   - edge-clamp events don't trigger
   - the rewarp cap
   - the dead-strip replay of s2's recorded push still fires once (now earlier), and synthetic menu slides at 4–8 pt/event dx with dy −1 never fire

### 14.3 v1.4 implementation notes
- **Override guard API.** It lives in `LandingDetector.onTapEvent(t:p:dx:dy:buttonsDown:geometry:peer:displays:)`, added next to the unchanged §5.6 `onSample`.
  - The engine sends tap events there, with integer deltas and all display bounds for the clamping check. Poller samples still go to `onSample` and never touch `lastTapPos`.
  - Re-warps are `CorrectionKind.override` and are logged as `override rewarp n=… p=… to=…`.
- **Deviation (safer): the event must also move the cursor back toward UC's landing,** by at least `overrideBackFraction` (0.25) of the correction's shift, i.e. `|p − landing| ≤ |lastTapPos − landing| − 0.25·|Δ|`.
  - Reason: the MacBook's first event after a handoff also reports a garbage delta (s2 `dx=1601`; s3 `dx=−850 dy=−707`, `dx=238 dy=217`), but it moves relative to our warp; MacBook corrections stick.
  - The mismatch rule alone would re-warp those MacBook corrections by Δ a second time.
  - V-Mind's override (s3: 248 → 136 pt from the landing) and the s2 V-Mind first reports (400 → 10 pt) qualify.
- **Replays:**
  - s3's V-Mind override re-warps once to p + Δ, then the following relative events don't.
  - s2's four MacBook corrections (events translated by Δ) and s3's two real MacBook corrections (events raw) never re-warp.
  - On s2's V-Mind landings, only the first forwarded report can re-warp (UC's absolute flush).
- **G1.** A packet with no crossX clears the receiver's episode UC crossX.
- **Dead strip.** Near-misses (runs ≥ 100 ms that didn't fire) are logged at most once per 10 s, with one of the reasons short / weak / sideways / wide / button / cooldown. `status.deadStripLastNearMiss` holds the last one.
