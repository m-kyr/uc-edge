import CoreGraphics
import Foundation
import Testing
@testable import UCEdgeCore

/// Drives a LandingDetector with one geometry and a settable peer state.
final class UTDetectorRig {
    let det: LandingDetector
    let g: EdgeGeometry
    var peer: PeerEdgeState?
    var cur = CGPoint.zero

    init(_ g: EdgeGeometry, params: DetectorParams = .init()) {
        self.g = g
        det = LandingDetector(params: params)
    }

    @discardableResult
    func sample(_ t: Double, _ x: Double, _ y: Double, buttons: Bool = false) -> Correction? {
        cur = CGPoint(x: x, y: y)
        return det.onSample(t: t, p: cur, buttonsDown: buttons, geometry: g, peer: peer)
    }

    /// A V-Mind state (span −1600…1600). `crossX` defaults to a latch at `x`.
    static func vmind(x: Double, d: Double = 0, pushing: Bool = true, crossX: Double?? = .none, at t: Double) -> PeerEdgeState {
        PeerEdgeState(x: x, d: d, pushing: pushing, spanMin: -1600, spanMax: 1600, receivedAt: t,
                      crossX: crossX ?? x)
    }

    /// Delivers a V-Mind packet arriving at `t`.
    @discardableResult
    func vmindPacket(_ t: Double, x: Double, d: Double = 0, crossX: Double?? = .none, buttons: Bool = false) -> Correction? {
        let p = Self.vmind(x: x, d: d, crossX: crossX, at: t)
        peer = p
        return det.onPeerUpdate(t: t, peer: p, current: cur, buttonsDown: buttons, geometry: g)
    }

    /// Sets a MacBook peer state (span −2560…0) without delivering it; latched at `x` by default.
    func macbookPeer(x: Double, d: Double = 0, pushing: Bool = true, crossX: Double?? = .none, at t: Double) {
        peer = PeerEdgeState(x: x, d: d, pushing: pushing, spanMin: -2560, spanMax: 0, receivedAt: t,
                             crossX: crossX ?? x)
    }
}

@Suite struct DetectorTests {
    /// MacBook rig whose cursor has been frozen mid-screen since t = 0.
    func macbook() -> UTDetectorRig {
        let r = UTDetectorRig(UTDesk.macbook)
        r.sample(0, -600, -700)
        return r
    }

    @Test func immediateCorrectionFromFreshLatchedPeer() throws {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 990)
        let c = try #require(r.sample(1000, 0, 0))
        #expect(c.kind == .immediate)
        #expect(c.target == CGPoint(x: -1280, y: -2))
        #expect(c.landing == CGPoint(x: 0, y: 0))
        #expect(c.peerX == 0)
    }

    @Test func targetMapsCrossXNotCurrentX() throws {
        // A tail packet: current x has run on to 308.65, several pt from the edge, but the
        // latch still holds UC's exit x 177.10.
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 308.65, d: 6, pushing: false, crossX: 177.10, at: 995)
        let c = try #require(r.sample(1000, 0, 0))
        let want = physicalMap(peerX: 177.10, peerSpanMin: -1600, peerSpanMax: 1600, localSpanMin: -2560, localSpanMax: 0)
        #expect(abs(Double(c.target.x) - want) < 1e-9)
        #expect(c.peerX == 177.10)
    }

    @Test func downwardCrossingOnVMind() throws {
        let r = UTDetectorRig(UTDesk.vmind)
        r.sample(0, 1200, 500)
        r.macbookPeer(x: -1600.84, at: 985)
        let c = try #require(r.sample(1000, -1, 0))
        #expect(c.kind == .immediate)
        #expect(abs(c.target.x - (-401.05)) < 0.01)
        #expect(c.target.y == 2, "2 pt inset keeps the target out of UC's hot zone")
    }

    @Test func lateCorrectionWhenPeerPacketArrivesAfterLanding() throws {
        let r = macbook()
        #expect(r.sample(1000, 0, 0) == nil)
        #expect(r.det.isArmed)
        #expect(r.sample(1010, -1, -3) == nil)
        let c = try #require(r.vmindPacket(1040, x: 820, d: 4, crossX: 800))
        #expect(c.kind == .late)
        #expect(c.landing == CGPoint(x: 0, y: 0))
        #expect(c.peerX == 800)
        // physicalMap(800) = −640, plus the 1 pt the cursor moved since landing.
        #expect(c.target == CGPoint(x: -641, y: -3))
        #expect(r.vmindPacket(1050, x: 800) == nil, "pending is consumed")
    }

    @Test func pendingExpiresAfterLateWindow() {
        let r = macbook()
        #expect(r.sample(1000, 0, 0) == nil)
        #expect(r.vmindPacket(1151, x: 800) == nil)
        #expect(!r.det.isArmed)
    }

    @Test func latePathNeedsCursorStillOnEdgeDisplay() {
        let r = macbook()
        #expect(r.sample(1000, 0, 0) == nil)
        r.sample(1020, 40, 60)                   // moved onto display 1
        #expect(r.vmindPacket(1040, x: 800) == nil)
    }

    @Test func snapbackIsCorrectedOnce() throws {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 995)
        let c = try #require(r.sample(1000, 0, 0))
        r.det.didWarp(t: 1000.5, to: c.target)
        #expect(r.sample(1001, c.target.x, c.target.y) == nil, "own-warp echo")
        #expect(r.det.isArmed, "snap-back guard")
        let s = try #require(r.sample(1040, 0.5, 0))
        #expect(s.kind == .snapback)
        #expect(s.target == CGPoint(x: -1279.5, y: -2))
        r.det.didWarp(t: 1040.5, to: s.target)
        #expect(r.sample(1041, s.target.x, s.target.y) == nil)
        #expect(r.sample(1080, 0, 0) == nil, "only once")
    }

    @Test func noSnapbackAfterGuardWindow() throws {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 995)
        let c = try #require(r.sample(1000, 0, 0))
        r.det.didWarp(t: 1000.5, to: c.target)
        r.sample(1001, c.target.x, c.target.y)
        #expect(r.sample(1251, 0.5, 0) == nil)
    }

    @Test func cooldownSuppressesLandings() throws {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 995)
        let c = try #require(r.sample(1000, 0, 0))
        r.det.didWarp(t: 1000.5, to: c.target)
        r.sample(1001, c.target.x, c.target.y)
        r.sample(1016, -1280, -200)
        r.peer = UTDetectorRig.vmind(x: 500, at: 1290)
        #expect(r.sample(1300, -500, -5) == nil, "inside cooldown")
        r.peer = UTDetectorRig.vmind(x: 500, at: 1440)
        let later = try #require(r.sample(1450, -400, 0))
        #expect(later.kind == .immediate)
    }

    @Test func buttonsDownNeverCorrect() {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 995)
        #expect(r.sample(1000, 0, 0, buttons: true) == nil)
        #expect(r.vmindPacket(1020, x: 0) == nil)
        let r2 = macbook()
        #expect(r2.sample(1000, 0, 0) == nil)
        #expect(r2.vmindPacket(1020, x: 0, buttons: true) == nil)
    }

    @Test func noPeerNeverCorrects() {
        let r = macbook()
        var t = 0.0
        for (x, y) in [(0.0, 0.0), (-10, -1), (-2000, -3), (-2000, -800), (-5, 0), (-1600, -0.02)] {
            t += 500
            #expect(r.sample(t, x, y) == nil)
        }
    }

    @Test func stalePeerNeverCorrects() {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 1000 - 301)
        #expect(r.sample(1000, 0, 0) == nil)
        #expect(r.sample(1100, -3, -2) == nil)
    }

    @Test func unlatchedPeerNeverCorrectsEvenAtItsEdge() {
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, d: 0, crossX: .some(nil), at: 995)
        #expect(r.sample(1000, 0, 0) == nil)
        #expect(r.vmindPacket(1030, x: 0, d: 0, crossX: .some(nil)) == nil)
        #expect(r.vmindPacket(1060, x: 0, d: 5, crossX: .some(nil)) == nil)
    }

    @Test func latchedPeerAwayFromItsEdgeStillCounts() throws {
        // v1.1 drops d ≤ 1.5: a tail packet 6 pt from the edge still carries the latch.
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 10, d: 6, pushing: false, crossX: 0, at: 995)
        let c = try #require(r.sample(1000, 0, 0))
        #expect(c.target.x == -1280)
    }

    @Test func invalidPeerValuesNeverCorrect() {
        let r = macbook()
        r.peer = PeerEdgeState(x: 0, d: 0, pushing: true, spanMin: 5, spanMax: 5, receivedAt: 995, crossX: 0)
        #expect(r.sample(1000, 0, 0) == nil)
        r.peer = UTDetectorRig.vmind(x: 0, crossX: Double.nan, at: 1500)
        #expect(r.sample(1600, -30, 0) == nil)
        r.peer = UTDetectorRig.vmind(x: 0, crossX: Double.infinity, at: 2100)
        #expect(r.sample(2200, -60, 0) == nil)
    }

    @Test func smallCorrectionIsSkippedButHandled() throws {
        // UC landed within 2 pt of the physical point: leave the cursor, clear pending, cool down.
        let r = macbook()
        r.peer = UTDetectorRig.vmind(x: 0, at: 995)
        #expect(r.sample(1000, -1279, 0) == nil)
        #expect(r.det.skippedSmallCount == 1)
        #expect(r.det.lastSkippedSmall?.target == CGPoint(x: -1280, y: -2))
        #expect(!r.det.isArmed, "no pending, no snap-back guard")
        r.peer = UTDetectorRig.vmind(x: 800, at: 1290)
        #expect(r.sample(1300, 0, 0) == nil, "the skip started the cooldown")
        // Late path: same rule.
        let r2 = macbook()
        #expect(r2.sample(1000, -640.5, 0) == nil)
        #expect(r2.vmindPacket(1030, x: 800) == nil)
        #expect(r2.det.skippedSmallCount == 1)
        #expect(!r2.det.isArmed)
    }

    @Test func menuBarPauseWithIdlePeerDoesNotCorrect() {
        let r = UTDetectorRig(UTDesk.vmind)
        // A long-idle peer that was last latched 5 s ago.
        r.macbookPeer(x: -1280, at: -5000)
        var t = 0.0
        for y in stride(from: 200.0, through: 0, by: -20) {
            #expect(r.sample(t, 300, y) == nil); t += 16
        }
        t += 500                                          // pause at the menu bar
        for x in stride(from: 305.0, through: 400, by: 5) {
            #expect(r.sample(t, x, 0) == nil); t += 16
        }
        #expect(!r.det.isArmed(at: t + 200))
    }

    @Test func tailOfOwnExitIsNotALanding() {
        // V-Mind pushes up to the edge, UC takes over, and a tail event arrives 52 ms later
        // while the MacBook (which just received the pointer) is already latched-looking.
        let r = UTDetectorRig(UTDesk.vmind)
        r.sample(0, -955, 21.3)
        r.sample(17, -950.82, 0)
        r.sample(34, -948.46, 0)
        r.sample(50, -947.77, 0)
        r.macbookPeer(x: -2038, d: 2, pushing: false, at: 95)     // moving on, not pushing back
        #expect(r.sample(102, -947.66, 0) == nil)
        // v1.2.1: a small tail move along the edge never becomes pending, even for a pushing peer.
        #expect(!r.det.isArmed)
        r.peer = PeerEdgeState(x: -2030, d: 0, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: 110, crossX: -2038)
        #expect(r.det.onPeerUpdate(t: 110, peer: r.peer!, current: r.cur, buttonsDown: false, geometry: r.g) == nil)
    }

    @Test func quickReturnWithPeerPushingIsALanding() throws {
        // Out at the edge, and back only 60 ms later because the peer pushed straight back down.
        let r = UTDetectorRig(UTDesk.vmind)
        r.sample(0, -950, 0)
        r.macbookPeer(x: -1600.84, d: 0.02, pushing: true, at: 55)
        let c = try #require(r.sample(60, -1, 0))
        #expect(c.kind == .immediate)
    }

    @Test func quickReturnWithSlidingPeerAfterTailWindowIsALanding() throws {
        // 96 ms round trip (the fastest recorded), peer sliding along its edge, not pushing.
        let r = UTDetectorRig(UTDesk.vmind)
        r.sample(0, -950, 0)
        r.macbookPeer(x: -1600.84, d: 0.02, pushing: false, at: 90)
        let c = try #require(r.sample(96, -1, 0))
        #expect(c.kind == .immediate)
    }

    @Test func stillnessBelowThresholdIsNotALanding() {
        let r = macbook()
        r.sample(1000, -700, -600)
        r.peer = UTDetectorRig.vmind(x: 0, at: 1010)
        #expect(r.sample(1020, 0, 0) == nil, "20 ms still < minStillMs")
    }

    @Test func paramsDecodeWithDefaults() throws {
        let p = try JSONDecoder().decode(DetectorParams.self, from: Data(#"{"freshMs": 250}"#.utf8))
        var expected = DetectorParams()
        expected.freshMs = 250
        #expect(p == expected)
        #expect(p.exitTailMs == 75 && p.targetInsetPt == 2 && p.minCorrectionPt == 2)
        let round = try JSONDecoder().decode(DetectorParams.self, from: JSONEncoder().encode(expected))
        #expect(round == expected)
    }
}
