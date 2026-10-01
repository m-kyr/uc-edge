import CoreGraphics
import Foundation
import Testing
import UCEdgeCore

/// Synthetic edge cases a reviewer would try against SPEC v1.1 §5.2 (CrossLatch), §5.4 and §6.
/// Default receiver is the MacBook (bottom of display 3, span [-2560, 0]); peers are V-Mind packets.
@Suite("Detector adversarial cases")
struct DetectorAdversarialTests {
    let mb = Desk.macbook
    let vm = Desk.vmind

    /// A V-Mind packet (span [-1600, 1600]), latched by default with crossX = x (§5.2 v1.1).
    func vPeer(x: Double = 177.1, d: Double = 0, at t: Double, crossX: Double? = nil, latched: Bool = true,
               pushing: Bool? = nil, episodeStart: Double? = nil,
               spanMin: Double = -1600, spanMax: Double = 1600) -> PeerEdgeState {
        PeerEdgeState(x: x, d: d, pushing: pushing ?? (d <= 1.5), spanMin: spanMin, spanMax: spanMax, receivedAt: t,
                      crossX: latched ? (crossX ?? x) : nil, episodeStart: episodeStart)
    }

    /// Signed distance of a target inside the edge (agreed: targets sit 2 pt inside, outside UC's 1 pt zone).
    func inset(_ p: CGPoint, _ g: EdgeGeometry) -> Double {
        g.side == .top ? Double(p.y) - g.edgeY : g.edgeY - Double(p.y)
    }

    /// Puts the cursor at `from` (last change at `frozenAt`) and then lands it at `landing` at `t`,
    /// as UC does: a jump without events after the cursor was frozen.
    func land(_ det: LandingDetector, geometry: EdgeGeometry, from: CGPoint = CGPoint(x: -700, y: -300),
              frozenAt: Double = 0, landing: CGPoint, at t: Double = 1000, buttons: Bool = false,
              peer: PeerEdgeState?) -> Correction? {
        _ = det.onSample(t: frozenAt - 17, p: CGPoint(x: from.x + 5, y: from.y - 5), buttonsDown: false, geometry: geometry, peer: nil)
        _ = det.onSample(t: frozenAt, p: from, buttonsDown: false, geometry: geometry, peer: nil)
        return det.onSample(t: t, p: landing, buttonsDown: buttons, geometry: geometry, peer: peer)
    }

    // MARK: - No peer, stale peer, peer not latched

    @Test("menu-bar pause then move, peer idle, absent or not latched: never corrects")
    func menuBarPause() {
        let peers: [PeerEdgeState?] = [
            nil,
            PeerEdgeState(x: -1000, d: 0, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: -5000, crossX: -1000), // idle 6 s
            PeerEdgeState(x: -1000, d: 0, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: 1490),                 // fresh, unlatched
        ]
        for peer in peers {
            let det = LandingDetector()
            var got: [Correction] = []
            // V-Mind cursor flicks up to the menu bar, rests 500 ms, then slides along it.
            for (t, y) in [(950.0, 60.0), (967, 20), (983, 3), (1000, 0)] {
                if let c = det.onSample(t: t, p: CGPoint(x: 500, y: y), buttonsDown: false, geometry: vm, peer: peer) { got.append(c) }
            }
            for i in 0..<20 {
                let t = 1500 + Double(i) * 16.7
                if let c = det.onSample(t: t, p: CGPoint(x: 500 + Double(i) * 4, y: 0), buttonsDown: false, geometry: vm, peer: peer) { got.append(c) }
                if let p = peer, p.crossX == nil,
                   let c = det.onPeerUpdate(t: t + 1, peer: PeerEdgeState(x: p.x, d: p.d, pushing: true, spanMin: p.spanMin, spanMax: p.spanMax, receivedAt: t + 1),
                                            current: CGPoint(x: 500 + Double(i) * 4, y: 0), buttonsDown: false, geometry: vm) {
                    got.append(c)
                }
            }
            #expect(got.isEmpty, "peer \(String(describing: peer)): \(got)")
        }
    }

    @Test("a fresh at-edge packet that is not latched never corrects (immediate or late)")
    func unlatchedPeer() {
        // The V-Mind pushing in its dead strip: at the edge, pushing, fresh, but UC never crossed.
        let det = LandingDetector()
        #expect(land(det, geometry: mb, landing: .zero, peer: vPeer(x: -1590, at: 990, latched: false)) == nil)
        for t in stride(from: 1005.0, through: 1140, by: 16) {
            #expect(det.onPeerUpdate(t: t, peer: vPeer(x: -1590, at: t, latched: false), current: .zero, buttonsDown: false, geometry: mb) == nil)
        }
    }

    /// U3's tail: after UC took the pointer at x 177.10 the V-Mind kept getting events (308.65, 373.39,
    /// 451.88), some several pt from the edge. The target must come from crossX, whatever x and d say.
    @Test("latched crossX wins over x, and d does not matter", arguments: [(177.1, 0.0), (308.65, 0.0), (373.39, 8.0), (451.88, 20.0)])
    func crossXIsMapped(x: Double, d: Double) throws {
        let c = try #require(land(LandingDetector(), geometry: mb, landing: .zero, peer: vPeer(x: x, d: d, at: 990, crossX: 177.1)))
        #expect(c.kind == .immediate)
        #expect(abs(c.target.x - -1138.32) <= 0.01, "physicalMap(crossX 177.1), not of x \(x): \(c)")
        #expect(c.peerX == 177.1, "peerX reports the mapped crossX")

        let det = LandingDetector()   // late path: pending, then a latched tail packet with d >= 8
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det, geometry: mb, landing: onD3, peer: vPeer(at: 990, latched: false)) == nil)
        let late = try #require(det.onPeerUpdate(t: 1030, peer: vPeer(x: x, d: max(d, 8), at: 1030, crossX: 177.1), current: onD3,
                                                 buttonsDown: false, geometry: mb))
        #expect(late.kind == .late && abs(late.target.x - -1138.32) <= 0.01, "\(late)")
    }

    @Test("freshness: 300 ms old packet is fresh, 301 ms is not")
    func freshnessBoundary() {
        #expect(land(LandingDetector(), geometry: mb, landing: .zero, peer: vPeer(at: 700)) != nil)
        #expect(land(LandingDetector(), geometry: mb, landing: .zero, peer: vPeer(at: 699)) == nil)
    }

    @Test("stillness: 29 ms is a move, 30 ms is a landing")
    func stillnessBoundary() {
        #expect(land(LandingDetector(), geometry: mb, frozenAt: 971, landing: .zero, at: 1000, peer: vPeer(at: 990)) == nil)
        #expect(land(LandingDetector(), geometry: mb, frozenAt: 970, landing: .zero, at: 1000, peer: vPeer(at: 990)) != nil)
    }

    /// Agreed: the strip is -1 <= signedDist <= 30 (closed), x within span +- 1. (0, 345) is the real
    /// S2 side-link landing on display 1's left column, which the v1 clamp-at-0 counted as "at the edge".
    @Test("landing strip: -1 <= signed distance <= 30 and x within span +- 1",
          arguments: [(CGPoint(x: -1000, y: -30), true), (CGPoint(x: -1000, y: -30.5), false),
                      (CGPoint(x: 1, y: 0), true), (CGPoint(x: 1.02, y: 0), false),
                      (CGPoint(x: -2561, y: -0.02), true), (CGPoint(x: -1280, y: -500), false),
                      (CGPoint(x: 0.5, y: 0.9), true), (CGPoint(x: 0, y: 1.5), false), (CGPoint(x: 0, y: 345), false)])
    func stripBoundary(p: CGPoint, corrects: Bool) {
        let c = land(LandingDetector(), geometry: mb, landing: p, peer: vPeer(at: 990))
        #expect((c != nil) == corrects, "landing \(p): \(String(describing: c))")
        if let c {
            #expect(mb.displays[0].contains(c.target), "target \(c.target) must be on display 3")
            #expect(inset(c.target, mb) >= 2 - 0.01 && inset(c.target, mb) <= 30.01, "target \(c.target) must sit 2...30 pt inside")
        }
    }

    // MARK: - Buttons

    @Test("button held: no immediate, no pending, no late")
    func buttonHeld() {
        let det = LandingDetector()
        #expect(land(det, geometry: mb, landing: .zero, buttons: true, peer: vPeer(at: 990)) == nil)
        // Released without moving: still no correction (the landing was not a candidate).
        #expect(det.onSample(t: 1030, p: .zero, buttonsDown: false, geometry: mb, peer: vPeer(at: 1020)) == nil)
        #expect(det.onPeerUpdate(t: 1040, peer: vPeer(at: 1040), current: .zero, buttonsDown: false, geometry: mb) == nil)

        // Clean landing without peer -> pending; the late packet arrives while a button is down.
        let det2 = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det2, geometry: mb, landing: onD3, peer: nil) == nil)
        #expect(det2.onPeerUpdate(t: 1040, peer: vPeer(at: 1040), current: onD3, buttonsDown: true, geometry: mb) == nil)
    }

    // MARK: - The (0,0) corner

    @Test("landing at (0,0) exactly: target moves onto display 3",
          arguments: [(1600.0, -0.5), (-1600.0, -2560.0), (0.0, -1280.0), (177.1, -1138.32)])
    func cornerLanding(peerX: Double, wantX: Double) throws {
        #expect(mb.clampTarget(x: 0, currentY: 0, stripPt: 30) == CGPoint(x: -0.5, y: -2), "SPEC §10.1 v1.1")
        let got = land(LandingDetector(), geometry: mb, landing: .zero, peer: vPeer(x: peerX, at: 990))
        if abs(wantX) < DetectorParams().minCorrectionPt {
            #expect(got == nil, "§5.1 v1.1: |target.x - current.x| < minCorrectionPt is skipped: \(String(describing: got))")
            return
        }
        let c = try #require(got)
        #expect(c.kind == .immediate)
        #expect(abs(c.target.x - wantX) <= 0.01, "peer x \(peerX): \(c)")
        #expect(abs(c.target.y - -2) <= 0.01, "SPEC §10.1 v1.1: (0,0) -> (x, -2); got \(c.target)")
        #expect(mb.displays[0].contains(c.target), "target \(c.target) must be on display 3, not display 1")
        #expect(c.landing == .zero)
        #expect(c.peerX == peerX)
    }

    @Test("late path works for the (0,0) corner landing (G1; UC's usual MacBook landing)")
    func lateCornerLanding() throws {
        let det = LandingDetector()
        #expect(land(det, geometry: mb, landing: .zero, peer: vPeer(at: 990, latched: false)) == nil)
        let c = try #require(det.onPeerUpdate(t: 1020, peer: vPeer(x: -948.46, at: 1020), current: .zero, buttonsDown: false, geometry: mb),
                             "(0,0) touches display 3's border; §5.1 treats it as on the edge, so §5.4.6 must too")
        #expect(c.kind == .late)
        #expect(abs(c.target.x - -2038.77) <= 0.01)
        #expect(mb.displays[0].contains(c.target))
    }

    @Test("V-Mind receiver: (1599,0) corner and the 4/5 boundary",
          arguments: [(-750.78, 661.525), (-1280.0, 0.0), (-1280.4, -0.5), (-73.5, 1508.125), (0.0, 1599.5)])
    func vmindTargets(peerX: Double, wantX: Double) throws {
        let peer = PeerEdgeState(x: peerX, d: 0.02, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: 990, crossX: peerX)
        let got = land(LandingDetector(), geometry: vm, from: CGPoint(x: 400, y: 500), landing: CGPoint(x: 1599, y: 0), peer: peer)
        if abs(wantX - 1599) < DetectorParams().minCorrectionPt {
            #expect(got == nil, "0.5 pt sideways is skipped (§5.1 v1.1): \(String(describing: got))")
            return
        }
        let c = try #require(got)
        #expect(abs(c.target.x - wantX) <= 0.01, "peer x \(peerX): \(c)")
        #expect(abs(c.target.y - 2) <= 0.01, "V-Mind target sits 2 pt below the top edge (outside UC's 1 pt zone): \(c.target)")
        #expect(vm.displays.contains { $0.contains(c.target) }, "target \(c.target) must be on monitor 4 or 5")
    }

    // MARK: - Late window

    @Test("late packet: 149 and 150 ms are in time, 151 ms is not", arguments: [(149.0, true), (150.0, true), (151.0, false)])
    func lateWindow(after: Double, corrects: Bool) {
        let det = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det, geometry: mb, landing: onD3, peer: nil) == nil)
        let c = det.onPeerUpdate(t: 1000 + after, peer: vPeer(x: 0, at: 1000 + after), current: onD3, buttonsDown: false, geometry: mb)
        #expect((c != nil) == corrects, "\(after) ms: \(String(describing: c))")
        if let c {
            #expect(c.kind == .late)
            #expect(abs(c.target.x - -1280) <= 0.01)
            #expect(abs(c.target.y - -2) <= 0.01 && mb.displays[0].contains(c.target), "late path target 2 pt inside display 3: \(c.target)")
            #expect(c.landing == onD3)
        }
    }

    @Test("late path: unlatched packets don't consume pending; local movement is carried over")
    func lateCarriesMovement() throws {
        let det = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det, geometry: mb, landing: onD3, peer: nil) == nil)
        #expect(det.onPeerUpdate(t: 1010, peer: vPeer(x: -20, d: 5, at: 1010, latched: false), current: onD3, buttonsDown: false, geometry: mb) == nil)
        let moved = CGPoint(x: -1589, y: -0.5)
        _ = det.onSample(t: 1017, p: moved, buttonsDown: false, geometry: mb, peer: vPeer(x: -20, d: 5, at: 1010, latched: false))
        let c = try #require(det.onPeerUpdate(t: 1040, peer: vPeer(x: 0, at: 1040), current: moved, buttonsDown: false, geometry: mb))
        #expect(c.kind == .late)
        #expect(abs(c.target.x - (-1280 + 10)) <= 0.01, "physicalMap(0) + (current.x - pending.x); got \(c)")
        #expect(c.landing == onD3, "landing is pending.p for late corrections")
        // Only once.
        #expect(det.onPeerUpdate(t: 1060, peer: vPeer(x: 0, at: 1060), current: moved, buttonsDown: false, geometry: mb) == nil)
    }

    @Test("late path: not if the cursor already left the edge displays")
    func lateNeedsEdgeDisplay() {
        let det = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det, geometry: mb, landing: onD3, peer: nil) == nil)
        let onDisplay1 = CGPoint(x: 100, y: 500)
        _ = det.onSample(t: 1020, p: onDisplay1, buttonsDown: false, geometry: mb, peer: nil)
        #expect(det.onPeerUpdate(t: 1040, peer: vPeer(at: 1040), current: onDisplay1, buttonsDown: false, geometry: mb) == nil)
    }

    @Test("tail packets after an immediate correction don't correct again")
    func noDoubleCorrection() throws {
        let det = LandingDetector()
        let c = try #require(land(det, geometry: mb, landing: .zero, peer: vPeer(x: 177.1, at: 985)))
        det.didWarp(t: 1000.2, to: c.target)
        #expect(det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: mb, peer: vPeer(x: 177.1, at: 985)) == nil)
        // U3's tail: x keeps changing at the edge for ~70 ms after UC started the crossing.
        for (t, x) in [(1002.0, 308.65), (1019, 373.39), (1035, 451.88), (1100, 451.88)] {
            #expect(det.onPeerUpdate(t: t, peer: vPeer(x: x, at: t, crossX: 177.1), current: c.target, buttonsDown: false, geometry: mb) == nil)
        }
    }

    // MARK: - Snap-back guard and cooldown

    @Test("snap-back to the landing within the guard is re-corrected once")
    func snapBackWithinGuard() throws {
        let det = LandingDetector()
        let c = try #require(land(det, geometry: mb, landing: .zero, peer: vPeer(x: 177.1, at: 990)))
        det.didWarp(t: 1000.3, to: c.target)
        #expect(det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: mb, peer: vPeer(at: 990)) == nil, "own-warp echo")
        #expect(det.isArmed, "guard active after a correction")

        let back = CGPoint(x: -1, y: -1)   // within 3 pt of the landing
        let s = try #require(det.onSample(t: 1100, p: back, buttonsDown: false, geometry: mb, peer: vPeer(at: 990)),
                             "UC put the cursor back at the landing point within guardMs")
        #expect(s.kind == .snapback)
        #expect(abs(s.target.x - (c.target.x - 1)) <= 0.6, "target + (p - landing): \(s) after \(c)")
        det.didWarp(t: 1100.3, to: s.target)
        _ = det.onSample(t: 1101, p: s.target, buttonsDown: false, geometry: mb, peer: vPeer(at: 990))
        // A second snap-back is not chased.
        #expect(det.onSample(t: 1150, p: CGPoint(x: -0.5, y: -0.5), buttonsDown: false, geometry: mb, peer: vPeer(at: 990)) == nil)
    }

    @Test("return to the landing point after the guard is left alone")
    func snapBackAfterGuard() throws {
        let det = LandingDetector()
        let c = try #require(land(det, geometry: mb, landing: .zero, peer: vPeer(x: 177.1, at: 990)))
        det.didWarp(t: 1000.3, to: c.target)
        _ = det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: mb, peer: vPeer(at: 990))
        // 260 ms later the peer packet (990) is still fresh, so only the guard and cooldown stop it.
        #expect(det.onSample(t: 1260, p: CGPoint(x: -1, y: -1), buttonsDown: false, geometry: mb, peer: vPeer(at: 990)) == nil)
    }

    @Test("a normal move away from the target is not a snap-back")
    func moveAwayIsNotSnapBack() throws {
        let det = LandingDetector()
        let c = try #require(land(det, geometry: mb, landing: .zero, peer: vPeer(x: 177.1, at: 990)))
        det.didWarp(t: 1000.3, to: c.target)
        _ = det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: mb, peer: vPeer(at: 990))
        for i in 1...10 {
            let p = CGPoint(x: c.target.x + Double(i) * 6, y: c.target.y - Double(i) * 3)
            #expect(det.onSample(t: 1001 + Double(i) * 16.7, p: p, buttonsDown: false, geometry: mb, peer: vPeer(at: 990)) == nil)
        }
    }

    @Test("cooldown: a new landing 399 ms after a correction is ignored, 401 ms is not")
    func cooldown() throws {
        for (gap, corrects) in [(399.0, false), (401.0, true)] {
            let det = LandingDetector()
            let c = try #require(land(det, geometry: mb, landing: .zero, peer: vPeer(at: 990)))
            det.didWarp(t: 1000.3, to: c.target)
            _ = det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: mb, peer: vPeer(at: 990))
            // User goes back to V-Mind (cursor frozen at the target) and crosses up again.
            let t2 = 1000 + gap
            let c2 = det.onSample(t: t2, p: .zero, buttonsDown: false, geometry: mb, peer: vPeer(x: -500, at: t2 - 10))
            #expect((c2 != nil) == corrects, "gap \(gap): \(String(describing: c2))")
        }
    }

    @Test("pending expires: an at-edge packet 160 ms after the landing does nothing")
    func pendingExpires() {
        let det = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det, geometry: mb, landing: onD3, peer: nil) == nil)
        #expect(det.isArmed, "pending landing arms the detector")
        #expect(det.onPeerUpdate(t: 1160, peer: vPeer(at: 1160), current: onD3, buttonsDown: false, geometry: mb) == nil)
    }

    @Test("quick return: UC lands the cursor 100 ms after it left through the shared edge")
    func quickReturn() throws {
        // A flick down into V-Mind at x -750.78 and straight back up. The MacBook cursor's last own
        // position is at the edge; UC's landing comes 100 ms later. §5.4.5 asks only still >= 30 ms.
        let det = LandingDetector()
        let c = try #require(land(det, geometry: mb, from: CGPoint(x: -750.78, y: -0.02), frozenAt: 900,
                                  landing: .zero, at: 1000, peer: vPeer(x: 1023.68, at: 985)),
                             "a real UC landing 100 ms after leaving must be corrected at once (G1, G4)")
        #expect(c.kind == .immediate)
        #expect(abs(c.target.x - -461.06) <= 0.01)
    }

    @Test("exit tail: a change < exitTailMs after an at-edge position is ignored unless the peer is pushing",
          arguments: [(false, false), (true, false), (false, true), (true, true)])
    func exitTail(peerPushing: Bool, beyondWindow: Bool) {
        // Accepted deviation (§5.4 to be updated): the source Mac keeps getting events after UC takes the
        // pointer (s2 V-Mind 153803.3: 51 ms still, at the edge), and the peer that just received it can
        // already look "at edge". Inside exitTailMs only a *pushing* peer marks a genuine quick return,
        // so a quick return after a slide crossing (fact 5: pushing = false) is not corrected. Beyond the
        // window it is (s1's real side-link quick return had 96 ms of stillness).
        let p = DetectorParams()
        let still = beyondWindow ? p.exitTailMs + 25 : (p.minStillMs + p.exitTailMs) / 2
        var peer = vPeer(x: 1023.68, at: 995)
        peer.pushing = peerPushing
        let c = land(LandingDetector(), geometry: mb, from: CGPoint(x: -750.78, y: -0.02), frozenAt: 1000 - still,
                     landing: .zero, at: 1000, peer: peer)
        #expect((c != nil) == (peerPushing || beyondWindow), "still \(still) ms, pushing \(peerPushing): \(String(describing: c))")
        if let c { #expect(abs(c.target.x - -461.06) <= 0.01) }
    }

    @Test("corrections smaller than 2 pt are skipped", arguments: [(-1279.0, false), (-1281.9, false), (-1283.0, true)])
    func tinyCorrectionSkipped(landingX: Double, corrects: Bool) {
        // Peer x 0 maps to -1280; the landing is already 2 pt inside display 3, so only x moves.
        let c = land(LandingDetector(), geometry: mb, landing: CGPoint(x: landingX, y: -2), peer: vPeer(x: 0, at: 990))
        #expect((c != nil) == corrects, "landing x \(landingX): \(String(describing: c))")
    }

    @Test("duplicate samples at the same position don't reset stillness")
    func duplicateSamples() {
        let det = LandingDetector()
        let frozen = CGPoint(x: -700, y: -300)
        _ = det.onSample(t: -17, p: CGPoint(x: -695, y: -305), buttonsDown: false, geometry: mb, peer: nil)
        for t in stride(from: 0.0, through: 990, by: 10) {
            _ = det.onSample(t: t, p: frozen, buttonsDown: false, geometry: mb, peer: nil)
        }
        #expect(det.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: mb, peer: vPeer(at: 995)) != nil)
    }

    // MARK: - Malformed peer state

    @Test("zero-width or inverted peer span: no division by zero, no warp",
          arguments: [(100.0, 100.0), (0.0, 0.0), (1600.0, -1600.0)])
    func degeneratePeerSpan(spanMin: Double, spanMax: Double) {
        let m = physicalMap(peerX: 100, peerSpanMin: spanMin, peerSpanMax: spanMax, localSpanMin: -2560, localSpanMax: 0)
        #expect(m.isFinite && m >= -2560 && m <= 0, "physicalMap must stay finite and clamped, got \(m)")

        let peer = vPeer(x: 100, at: 990, spanMin: spanMin, spanMax: spanMax)
        if spanMin == spanMax {
            #expect(land(LandingDetector(), geometry: mb, landing: .zero, peer: peer) == nil, "degenerate span \(spanMin)...\(spanMax) must not move the cursor")
            let det = LandingDetector()
            let onD3 = CGPoint(x: -1599, y: -0.02)
            _ = land(det, geometry: mb, landing: onD3, peer: nil)
            let late = PeerEdgeState(x: 100, d: 0, pushing: true, spanMin: spanMin, spanMax: spanMax, receivedAt: 1030)
            #expect(det.onPeerUpdate(t: 1030, peer: late, current: onD3, buttonsDown: false, geometry: mb) == nil)
        }
    }

    @Test("NaN / infinity in crossX, span or receivedAt never produces a warp",
          arguments: ["crossX=nan", "crossX=+inf", "crossX=-inf", "spanMin=nan", "spanMax=+inf", "spanMin=-inf", "receivedAt=nan"])
    func nonFinitePacket(field: String) {
        var p = vPeer(x: 177.1, at: 990)
        switch field {
        case "crossX=nan": p.crossX = .nan
        case "crossX=+inf": p.crossX = .infinity
        case "crossX=-inf": p.crossX = -.infinity
        case "spanMin=nan": p.spanMin = .nan
        case "spanMax=+inf": p.spanMax = .infinity
        case "spanMin=-inf": p.spanMin = -.infinity
        default: p.receivedAt = .nan
        }
        let c = land(LandingDetector(), geometry: mb, landing: .zero, peer: p)
        #expect(c == nil, "\(field): \(String(describing: c))")

        let det = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        _ = land(det, geometry: mb, landing: onD3, peer: nil)
        var late = p
        late.receivedAt = field == "receivedAt=nan" ? .nan : 1030
        let lc = det.onPeerUpdate(t: 1030, peer: late, current: onD3, buttonsDown: false, geometry: mb)
        #expect(lc == nil, "late \(field): \(String(describing: lc))")
    }

    @Test("NaN / infinity in x or d: v1.1 maps crossX only, so any correction is finite and from crossX",
          arguments: ["x=nan", "x=+inf", "d=nan", "d=+inf"])
    func nonFiniteInformationalField(field: String) {
        var p = vPeer(x: 177.1, at: 990, crossX: 177.1)
        switch field {
        case "x=nan": p.x = .nan
        case "x=+inf": p.x = .infinity
        case "d=nan": p.d = .nan
        default: p.d = .infinity
        }
        if let c = land(LandingDetector(), geometry: mb, landing: .zero, peer: p) {
            #expect(abs(c.target.x - -1138.32) <= 0.01 && c.target.y.isFinite, "\(field): \(c)")
        }
    }

    @Test("peer x outside its own span never yields an off-display target")
    func peerOutsideSpan() {
        for x in [1601.0, 1700.0, -1700.0, 1e9] {
            if let c = land(LandingDetector(), geometry: mb, landing: .zero, peer: vPeer(x: x, at: 990)) {
                #expect(mb.displays[0].contains(c.target), "peer x \(x): \(c.target)")
            }
        }
    }

    // MARK: - v1.2 (§12)

    @Test("peer episode: a landing is rejected if the local cursor moved during the peer's episode")
    func peerEpisode() throws {
        // Local cursor last moved at 900; UC lands it at 1000 (still 100 ms).
        let late = land(LandingDetector(), geometry: mb, frozenAt: 900, landing: .zero, peer: vPeer(at: 990, episodeStart: 700))
        #expect(late == nil, "episode began 300 ms before the landing, the cursor moved 100 ms before it (slack 120)")
        let ok = land(LandingDetector(), geometry: mb, frozenAt: 900, landing: .zero, peer: vPeer(at: 990, episodeStart: 921))
        #expect(ok != nil, "episode began 79 ms before: within still + slack")
        let tail = land(LandingDetector(), geometry: mb, frozenAt: 900, landing: .zero, peer: vPeer(at: 990, episodeStart: 800))
        #expect(tail != nil, "episode began 200 ms before, cursor still 100 ms: an exit tail within the 120 ms slack (N2)")

        // A rejected immediate landing is not left pending.
        let det = LandingDetector()
        #expect(land(det, geometry: mb, frozenAt: 900, landing: .zero, peer: vPeer(at: 990, episodeStart: 700)) == nil)
        #expect(det.onPeerUpdate(t: 1010, peer: vPeer(at: 1010, episodeStart: 995), current: .zero, buttonsDown: false, geometry: mb) == nil)

        // Late path: pending, then a latched packet whose episode began before the local move.
        let det2 = LandingDetector()
        #expect(land(det2, geometry: mb, frozenAt: 900, landing: .zero, peer: nil) == nil)
        #expect(det2.onPeerUpdate(t: 1020, peer: vPeer(at: 1020, episodeStart: 700), current: .zero, buttonsDown: false, geometry: mb) == nil)
        let det3 = LandingDetector()
        #expect(land(det3, geometry: mb, frozenAt: 900, landing: .zero, peer: nil) == nil)
        #expect(det3.onPeerUpdate(t: 1020, peer: vPeer(at: 1020, episodeStart: 1000), current: .zero, buttonsDown: false, geometry: mb) != nil)
    }

    @Test("exit tail: the immediate exemption needs a pushing packet <= 50 ms old; a tail pending needs a pushing packet")
    func tailPending() throws {
        // Our cursor was still at our own edge until 950; UC lands it at 1000 (50 ms < exitTailMs).
        func tailLanding(_ det: LandingDetector, peer: PeerEdgeState) -> Correction? {
            land(det, geometry: mb, from: CGPoint(x: -750.78, y: -0.02), frozenAt: 950, landing: .zero, at: 1000, peer: peer)
        }
        #expect(tailLanding(LandingDetector(), peer: vPeer(x: 1023.68, at: 960, pushing: true)) != nil, "pushing, 40 ms old")

        let det = LandingDetector()
        #expect(tailLanding(det, peer: vPeer(x: 1023.68, at: 940, pushing: true)) == nil, "pushing but 60 ms old: tail, pending")
        #expect(det.onPeerUpdate(t: 1010, peer: vPeer(x: 1023.68, at: 1010, pushing: false), current: .zero, buttonsDown: false,
                                 geometry: mb) == nil, "a non-pushing packet can't resolve a tail pending")
        let c = try #require(det.onPeerUpdate(t: 1020, peer: vPeer(x: 1023.68, at: 1020, pushing: true), current: .zero,
                                              buttonsDown: false, geometry: mb), "a pushing packet resolves it")
        #expect(c.kind == .late && abs(c.target.x - -461.06) <= 0.01)
    }

    @Test("snap-back needs a jump over 10 pt: walking back to the landing point is the user")
    func snapBackNeedsJump() throws {
        for (via, snaps) in [(CGPoint?.none, true), (CGPoint(x: -9, y: -1), false)] {
            let det = LandingDetector()
            let c = try #require(land(det, geometry: mb, landing: .zero, peer: vPeer(x: 177.1, at: 990)))
            det.didWarp(t: 1000.3, to: c.target)
            _ = det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: mb, peer: vPeer(at: 990))
            if let via { _ = det.onSample(t: 1050, p: via, buttonsDown: false, geometry: mb, peer: vPeer(at: 990)) }
            // (-2, -1) is within 3 pt of the landing; from (-9, -1) that is a 7 pt step, from the target a jump.
            let s = det.onSample(t: 1100, p: CGPoint(x: -2, y: -1), buttonsDown: false, geometry: mb, peer: vPeer(at: 990))
            #expect((s?.kind == .snapback) == snaps, "via \(String(describing: via)): \(String(describing: s))")
        }
    }

    @Test("late target keeps the current y (2 pt inset kept, no pull back into the strip)",
          arguments: [(-0.5, -2.0), (-12.0, -12.0), (-40.0, -40.0)])
    func lateKeepsY(currentY: Double, wantY: Double) throws {
        let det = LandingDetector()
        let onD3 = CGPoint(x: -1599, y: -0.02)
        #expect(land(det, geometry: mb, landing: onD3, peer: nil) == nil)
        let current = CGPoint(x: -1590, y: currentY)
        _ = det.onSample(t: 1017, p: current, buttonsDown: false, geometry: mb, peer: nil)
        let c = try #require(det.onPeerUpdate(t: 1040, peer: vPeer(x: 0, at: 1040), current: current, buttonsDown: false, geometry: mb))
        #expect(c.kind == .late && abs(c.target.x - (-1280 + 9)) <= 0.01 && abs(c.target.y - wantY) <= 0.01, "\(c)")
    }

    // MARK: - CrossLatch (§5.2 v1.1)

    /// Feeds (t, x, y, dy) events to one CrossLatch; returns crossX after each.
    func latch(_ events: [(Double, Double, Double, Double)], geometry: EdgeGeometry? = nil,
               zone: (Double, Double) = (-961, 1600)) -> [Double?] {
        let l = CrossLatch()
        return events.map { l.onEvent(t: $0.0, p: CGPoint(x: $0.1, y: $0.2), dy: $0.3, geometry: geometry ?? vm, zoneMin: zone.0, zoneMax: zone.1) }
    }

    @Test("latch: the event entering UC's zone arms, the next push latches, the tail keeps it (s2 U1)")
    func latchU1() {
        let got = latch([(0, -955.02, 21.30, -30), (16.7, -950.82, 0, -30), (33.5, -948.46, 0, -20),
                         (50, -947.77, 0, -6), (101, -947.66, 0, 0), (117, -940.41, 0, -46)])
        #expect(got == [nil, nil, -948.46, -948.46, -948.46, -948.46], "\(got)")
    }

    @Test("latch: armed at d 0.95, moving away does not disarm, the next push latches (s2 U4)")
    func latchU4() {
        let got = latch([(0, 1578.07, 0.95, 0), (16.6, 1567.86, 7.40, 7), (33.2, 1536.48, 9.50, 2),
                         (50, 1474.58, 0, -11), (66.5, 1372.88, 0, -36)])
        #expect(got == [nil, nil, nil, 1474.58, 1474.58], "\(got)")
    }

    @Test("latch: never in the dead strip; arms and latches after a redirect into the zone")
    func latchDeadStrip() {
        var events = (0..<20).map { (Double($0) * 16.7, -1588.0, 0.0, -5.0) }
        events += [(334, -957, 0, -3), (350.7, -955, 0, -2)]
        let got = latch(events)
        #expect(got.prefix(20).allSatisfy { $0 == nil }, "\(got)")
        #expect(got[20] == nil && got[21] == -955, "\(got.suffix(2))")
    }

    @Test("latch: a gap over 100 ms, or moving more than 30 pt away, starts over")
    func latchResets() {
        let gap = latch([(0, 100, 0, -5), (101, 101, 0, -5), (117.7, 102, 0, -5)])
        #expect(gap == [nil, nil, 102], "after a 101 ms gap the push only re-arms: \(gap)")
        let away = latch([(0, 100, 0, -5), (16.7, 100, 31, 10), (33.4, 101, 0, -5), (50.1, 102, 0, -5)])
        #expect(away == [nil, nil, nil, 102], "d 31 disarms: \(away)")
    }

    @Test("latch: one per edge visit, expired after 150 ms and not re-armed while the cursor stays at the edge")
    func latchExpires() {
        let got = latch((0...14).map { (Double($0) * 16.7, 100 + Double($0), 0, -5) })
        // Latched at 16.7 ms; 150.3 ms is 133.6 ms later (kept); 167 ms is 150.3 ms later (expired).
        #expect(got[1] == 101 && got[9] == 101, "\(got)")
        #expect(got[10...].allSatisfy { $0 == nil }, "§12 v1.2: no second latch in the same visit: \(got)")
    }

    @Test("latch: after expiry, leaving the edge or a pause over 100 ms allows a new latch")
    func latchNewVisit() {
        var stay = (0...10).map { (Double($0) * 16.7, 100 + Double($0), 0.0, -5.0) }   // latched, expired at 167 ms
        let leave = latch(stay + [(183.7, 111, 2, 3), (200.4, 112, 0, -5), (217.1, 113, 0, -5)])
        #expect(leave[11] == nil && leave[12] == nil && leave[13] == 113, "s = 2 left the edge: \(leave.suffix(3))")
        stay += [(268, 111, 0, -5), (284.7, 112, 0, -5)]
        let pause = latch(stay)
        #expect(pause[11] == nil && pause[12] == 112, "101 ms pause: \(pause.suffix(2))")
    }

    @Test("latch: a slide without a push does not latch; beyond the edge never arms")
    func latchNeedsPushAndEdge() {
        let slide = latch([(0, 100, 0, -5), (16.7, 110, 0, 0), (33.4, 120, 0, 0), (50.1, 130, 0, -1)])
        #expect(slide == [nil, nil, nil, 130], "\(slide)")
        // MacBook display 1's left column (0.5, 5) is 5 pt beyond the bottom edge: s = -5 < -1.
        let beyond = latch([(0, 0.5, 5, 3), (16.7, 0.4, 4, 3), (33.4, 0.3, 3, 3)], geometry: mb, zone: (-2561, 1))
        #expect(beyond == [nil, nil, nil], "\(beyond)")
    }

    // MARK: - Dead strip (agreed rule: pinned pushes spanning >= 180 ms, no gap > 100 ms, sum >= 12 pt)

    func deadStripPush(_ det: DeadStripDetector, x: Double = -1590, from t0: Double = 0, every: Double = 16.7, dys: [Double],
                       firstPinned: Bool = true, buttons: Bool = false, y: Double = 0,
                       zone: (Double, Double) = (-961, 1600)) -> [(Double, CGPoint)] {
        var out: [(Double, CGPoint)] = []
        var prevPinned = firstPinned
        for (i, dy) in dys.enumerated() {
            let t = t0 + Double(i) * every
            if let r = det.onEvent(t: t, p: CGPoint(x: x, y: y), dy: dy, prevWasPinned: prevPinned, buttonsDown: buttons,
                                   geometry: vm, zoneMinX: zone.0, zoneMaxX: zone.1) {
                out.append((t, r))
            }
            prevPinned = y <= 0.5
        }
        return out
    }

    func enabledDeadStrip() -> DeadStripDetector {
        var p = DeadStripParams()
        p.enabled = true
        return DeadStripDetector(params: p)
    }

    @Test("dead strip: disabled by default")
    func deadStripDisabledByDefault() {
        #expect(DeadStripParams().enabled == false)
        #expect(deadStripPush(DeadStripDetector(params: DeadStripParams()), dys: Array(repeating: -10, count: 30)).isEmpty)
    }

    @Test("dead strip: an arriving flick alone is not a push")
    func deadStripFlick() {
        #expect(deadStripPush(enabledDeadStrip(), dys: [-100], firstPinned: false).isEmpty)
    }

    @Test("dead strip: a sustained push fires once, when its span reaches 180 ms")
    func deadStripSustained() throws {
        // -2 pt every 20 ms: the sum passes 12 pt at 100 ms, the span reaches 180 ms at the 10th push.
        let r = deadStripPush(enabledDeadStrip(), every: 20, dys: Array(repeating: -2, count: 60))
        #expect(r.count == 1, "one redirect per cooldown (1.2 s of pushing): \(r)")
        let (t, p) = try #require(r.first)
        #expect(t == 180, "fires at the first push that makes the span >= 180 ms, not at \(t)")
        #expect(abs(p.x - -959) <= 0.01 && abs(p.y) <= 0.01, "redirect to (zoneMinX + 2, edgeY), got \(p)")
    }

    @Test("dead strip: a hard but short push is a flick, not a deliberate push")
    func deadStripShortHard() {
        // 240 pt in 117 ms (the s2 burst reached 24 pt in 34 ms of arrival momentum).
        #expect(deadStripPush(enabledDeadStrip(), dys: Array(repeating: -30, count: 8)).isEmpty)
    }

    @Test("dead strip: a long push needs 12 pt in total")
    func deadStripFeeble() throws {
        let det = enabledDeadStrip()
        #expect(deadStripPush(det, every: 30, dys: Array(repeating: -1, count: 11)).isEmpty, "11 pt over 300 ms")
        let r = deadStripPush(det, from: 330, dys: [-1])
        #expect(r.count == 1, "the 12th pt (span 330 ms) fires")
    }

    @Test("dead strip: a gap over 100 ms starts a new push")
    func deadStripGap() throws {
        let det = enabledDeadStrip()
        #expect(deadStripPush(det, dys: Array(repeating: -5, count: 7)).isEmpty, "0...100 ms")
        // 120 ms without pushes, then a second run: it must span 180 ms on its own.
        let r = deadStripPush(det, from: 220.2, dys: Array(repeating: -5, count: 14))
        let t = try #require(r.first).0
        #expect(r.count == 1 && t >= 220.2 + 180 - 0.01, "the run restarted at 220.2 ms, yet fired at \(t)")
    }

    @Test("dead strip: no redirect with a button held, inside the zone, or off the edge")
    func deadStripGuards() {
        let long = Array(repeating: -10.0, count: 24)   // 384 ms
        #expect(deadStripPush(enabledDeadStrip(), dys: long, buttons: true).isEmpty)
        #expect(deadStripPush(enabledDeadStrip(), x: -900, dys: long).isEmpty)
        #expect(deadStripPush(enabledDeadStrip(), x: 1590, dys: long).isEmpty)
        #expect(deadStripPush(enabledDeadStrip(), dys: long, firstPinned: false, y: 0.6).isEmpty, "0.6 pt below the edge is not pinned")
        #expect(deadStripPush(enabledDeadStrip(), dys: Array(repeating: 10.0, count: 24)).isEmpty, "moving away from the edge")
    }

    @Test("dead strip: a slide along the menu bar is not a push (dx dominates, or x spreads over 30 pt)")
    func deadStripSlide() {
        // x zig-zags 10 pt per event (spread 10 pt), dy -2: sum |dy| 48 < 1.5 * sum |dx| 230.
        let det = enabledDeadStrip()
        var fired = 0
        for i in 0..<24 {
            let x = i % 2 == 0 ? -1590.0 : -1580.0
            if det.onEvent(t: Double(i) * 16.7, p: CGPoint(x: x, y: 0), dy: -2, prevWasPinned: true, buttonsDown: false,
                           geometry: vm, zoneMinX: -961, zoneMaxX: 1600) != nil { fired += 1 }
        }
        #expect(fired == 0, "dx dominates")
        // Hard pushes (dy -10) while sliding 5 pt per event: the run restarts whenever x spreads over 30 pt.
        let det2 = enabledDeadStrip()
        var fired2 = 0
        for i in 0..<40 {
            if det2.onEvent(t: Double(i) * 16.7, p: CGPoint(x: -1590 + Double(i) * 5, y: 0), dy: -10, prevWasPinned: true,
                            buttonsDown: false, geometry: vm, zoneMinX: -961, zoneMaxX: 1600) != nil { fired2 += 1 }
        }
        #expect(fired2 == 0, "x spread over 30 pt restarts the run")
        // Control: the same hard push with 1 pt of jitter fires.
        let det3 = enabledDeadStrip()
        var fired3 = 0
        for i in 0..<24 {
            if det3.onEvent(t: Double(i) * 16.7, p: CGPoint(x: -1590 + Double(i % 2), y: 0), dy: -10, prevWasPinned: true,
                            buttonsDown: false, geometry: vm, zoneMinX: -961, zoneMaxX: 1600) != nil { fired3 += 1 }
        }
        #expect(fired3 == 1)
    }

    @Test("dead strip: virtualX replaces only the first latch after a redirect, within 300 ms and 5 pt")
    func deadStripVirtualXOnce() throws {
        func redirected() throws -> (DeadStripDetector, Double) {
            let det = enabledDeadStrip()
            let r = deadStripPush(det, every: 20, dys: Array(repeating: -2, count: 10))
            return (det, try #require(r.first).0)
        }
        let (a, t0) = try redirected()
        #expect(a.consumeRedirect(latchT: t0 + 50, latchX: -957) == -1590, "first latch near the redirect point")
        #expect(a.consumeRedirect(latchT: t0 + 70, latchX: -957) == nil, "consumed")

        let (b, t1) = try redirected()
        #expect(b.consumeRedirect(latchT: t1 + 350, latchX: -957) == nil, "stale: 350 ms after the redirect")
        #expect(b.consumeRedirect(latchT: t1 + 360, latchX: -957) == nil, "consumed even when stale")

        let (c, t2) = try redirected()
        #expect(c.consumeRedirect(latchT: t2 + 50, latchX: -900) == nil, "a latch 59 pt from the redirect point is another crossing")
    }

    @Test("dead strip right of the zone redirects to zoneMaxX - 2")
    func deadStripRightSide() throws {
        let r = deadStripPush(enabledDeadStrip(), x: 1500, dys: Array(repeating: -10, count: 24), zone: (-1600, 800))
        let p = try #require(r.first).1
        #expect(abs(p.x - 798) <= 0.01 && abs(p.y) <= 0.01)
    }
}
