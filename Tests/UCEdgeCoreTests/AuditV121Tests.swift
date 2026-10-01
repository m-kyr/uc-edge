import CoreGraphics
import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

/// Regression tests for the v1.2.1 findings (N1–N5), adapted from the auditor's proofs.
@Suite struct AuditV121Tests {
    // MARK: N1: a small exit-tail move never pre-empts a quick return

    func mbPeer(crossX: Double?, at t: Double, es: Double, pushing: Bool = true) -> PeerEdgeState {
        PeerEdgeState(x: crossX ?? -742.87, d: 0, pushing: pushing, spanMin: -2560, spanMax: 0, receivedAt: t,
                      crossX: crossX, episodeStart: es, senderLagMs: 3, senderSlackMs: 50)
    }

    /// V-Mind exits upward; an exit-tail event may follow after a 51 ms gap; the user reverses at
    /// once, and UC lands V-Mind at its (1599, 0) corner. Returns the corrections and final cursor.
    func quickReturn(tailGap: Bool) -> ([Correction], CGPoint) {
        let det = LandingDetector()
        let g = UTDesk.vmind
        var out: [Correction] = []
        var cursor = CGPoint.zero
        func apply(_ c: Correction?, _ t: Double, _ peer: PeerEdgeState?) {
            guard let c else { return }
            out.append(c)
            det.didWarp(t: t, to: c.target)
            cursor = c.target
            _ = det.onSample(t: t + 0.5, p: c.target, buttonsDown: false, geometry: g, peer: peer)
        }
        func sample(_ t: Double, _ x: Double, _ y: Double, peer: PeerEdgeState?) {
            cursor = CGPoint(x: x, y: y)
            apply(det.onSample(t: t, p: cursor, buttonsDown: false, geometry: g, peer: peer), t, peer)
        }
        sample(0, 500, 300, peer: nil)
        sample(900, 500, 20, peer: nil); sample(916, 500, 5, peer: nil); sample(932, 500, 0, peer: nil)
        sample(948, 502, 0, peer: nil)                                  // UC exit (Activating)
        sample(964, 505, 0, peer: nil); sample(980, 508, 0, peer: nil)  // tail
        if tailGap { sample(1031, 510, 0, peer: nil) }                  // tail event after a 51 ms gap
        _ = det.onPeerUpdate(t: 1060, peer: mbPeer(crossX: nil, at: 1060, es: 1060, pushing: false),
                             current: det.lastPosition ?? cursor, buttonsDown: false, geometry: g)
        let latched = mbPeer(crossX: -742.87, at: 1076, es: 1060)
        apply(det.onPeerUpdate(t: 1076, peer: latched, current: det.lastPosition ?? cursor, buttonsDown: false, geometry: g),
              1076, latched)
        sample(1091, 1599, 0, peer: latched)                            // UC's actual landing
        return (out, cursor)
    }

    @Test func n1QuickReturnIsCorrectedAtUCsLandingNotBeforeIt() {
        let want = physicalMap(peerX: -742.87, peerSpanMin: -2560, peerSpanMax: 0, localSpanMin: -1600, localSpanMax: 1600)
        let (withGap, endWithGap) = quickReturn(tailGap: true)
        let (control, endControl) = quickReturn(tailGap: false)
        #expect(withGap.count == 1 && withGap.first?.kind == .immediate, "\(withGap)")
        #expect(withGap.first?.landing == CGPoint(x: 1599, y: 0))
        #expect(abs(Double(endWithGap.x) - want) < 1, "cursor \(endWithGap) must not stay in UC's corner")
        #expect(abs(Double(endControl.x) - want) < 1 && control.count == 1)
    }

    @Test func n1JumpIsStillTailPendingWhenTheExemptionHasExpired() throws {
        // Same return, but the pushing packet is 60 ms old at UC's landing: the landing jump waits
        // (tail-pending) and the next pushing packet resolves it.
        let det = LandingDetector()
        let g = UTDesk.vmind
        for (t, x, y) in [(0.0, 500.0, 300.0), (900, 500, 20), (916, 500, 5), (932, 500, 0), (948, 502, 0),
                          (964, 505, 0), (980, 508, 0), (1031, 510, 0)] {          // exit, then a small tail move
            _ = det.onSample(t: t, p: CGPoint(x: x, y: y), buttonsDown: false, geometry: g, peer: nil)
        }
        #expect(!det.isArmed(at: 1060), "the small tail move at 1031 is not pending")
        let old = mbPeer(crossX: -742.87, at: 1031, es: 1000)
        #expect(det.onSample(t: 1091, p: CGPoint(x: 1599, y: 0), buttonsDown: false, geometry: g, peer: old) == nil)
        #expect(det.isArmed, "the landing jump is tail-pending")
        let c = try #require(det.onPeerUpdate(t: 1100, peer: mbPeer(crossX: -742.87, at: 1100, es: 1000),
                                              current: CGPoint(x: 1599, y: 0), buttonsDown: false, geometry: g))
        #expect(c.kind == .late && c.landing == CGPoint(x: 1599, y: 0))
    }

    // MARK: N2: the episode slack covers a full exit tail

    func u4(lastChangeBeforeLanding: Double, episodeBeforeLanding: Double = 199.3) -> Correction? {
        let det = LandingDetector()
        let L = 10_000.0
        _ = det.onSample(t: L - lastChangeBeforeLanding - 17, p: CGPoint(x: 70, y: -340), buttonsDown: false, geometry: UTDesk.macbook, peer: nil)
        _ = det.onSample(t: L - lastChangeBeforeLanding, p: CGPoint(x: 68.11, y: -342.41), buttonsDown: false, geometry: UTDesk.macbook, peer: nil)
        let peer = PeerEdgeState(x: 1474.58, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, receivedAt: L - 10,
                                 crossX: 1474.58, episodeStart: L - episodeBeforeLanding, senderLagMs: 3, senderSlackMs: 50)
        return det.onSample(t: L, p: .zero, buttonsDown: false, geometry: UTDesk.macbook, peer: peer)
    }

    @Test func n2EpisodeSlackCoversALongExitTail() {
        #expect(DetectorParams().episodeSlackMs == 120)
        #expect(u4(lastChangeBeforeLanding: 222.2) != nil, "U4 as recorded")
        #expect(u4(lastChangeBeforeLanding: 172.2) != nil, "the MacBook's last change 50 ms later")
        #expect(u4(lastChangeBeforeLanding: 500, episodeBeforeLanding: 1000) == nil,
                "the local cursor moved 500 ms into the peer's episode")
    }

    // MARK: N3: a clock step is adopted at once

    @Test func n3ClockStepIsAdoptedAfterOneSample() {
        var est = ClockOffsetEstimator()
        let base: Int64 = 1_800_000_000_000
        for i in 0..<10 {
            est.add(sentWallMs: base + Int64(i) * 2000, peerWallMs: base + Int64(i) * 2000 + 2, receivedWallMs: base + Int64(i) * 2000 + 4)
        }
        let step: Int64 = 3000
        let now = base + 30_000
        func fresh(_ now: Int64) -> Bool {
            let lag = est.senderLag(wallMs: now - 5 - step, nowWallMs: now)
            return PeerEdgeState(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, receivedAt: 1000, crossX: 0,
                                 senderLagMs: lag.lagMs, senderSlackMs: lag.slackMs).isFreshAtEdge(now: 1000, params: DetectorParams())
        }
        #expect(!fresh(now), "before a HELLO sees the step")
        est.add(sentWallMs: now, peerWallMs: now + 2 - step, receivedWallMs: now + 4)
        #expect(fresh(now + 2000), "one sample later")
        #expect(abs((est.offsetMs ?? 0) - Double(-step)) < 1)
    }

    // MARK: N4: tap recreation backs off 1 s → 60 s, reset after 60 s healthy

    @Test func n4TapRetriesBackOffExponentially() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir)
        defer { side.socket.shutdownAndClose() }
        let clock = UTClock()
        let failing = UTFakeTap(startOK: false)
        var current: UTFakeTap = failing
        let sup = TapSupervisor(engine: side.engine, log: Logger(path: nil), now: { clock.now }) { current }
        sup.startTap()
        var attemptTimes: [Double] = []
        var last = sup.attempts
        for s in 0...400 {                                              // 400 s, ticking once a second
            clock.now = Double(s)
            sup.check()
            if sup.attempts != last { attemptTimes.append(clock.now); last = sup.attempts }
        }
        let gaps = zip(attemptTimes.dropFirst(), attemptTimes).map { $0 - $1 }
        #expect(Array(gaps.prefix(6)) == [2, 4, 8, 16, 32, 60], "\(attemptTimes)")
        #expect(gaps.dropFirst(5).allSatisfy { $0 == 60 })
        // A working tap that stays healthy for 60 s resets the backoff.
        let good = UTFakeTap(startOK: true)
        current = good
        clock.now = 1000
        sup.check()
        #expect(side.engine.snapshot().permissions.tapActive)
        for s in 1001...1061 { clock.now = Double(s); sup.check() }
        #expect(sup.backoffSec == 1)
        sup.stop()
    }

    // MARK: N5: launchd.log is trimmed at startup

    @Test func n5LaunchdLogIsTrimmedToItsTail() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("launchd.log").path
        var text = ""
        var i = 0
        while text.utf8.count < 1_200_000 { text += "line \(i) \(String(repeating: "x", count: 40))\n"; i += 1 }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        #expect(LaunchdLog.trim(path: path))
        let kept = try String(contentsOfFile: path, encoding: .utf8)
        #expect(kept.utf8.count <= 64 * 1024 && kept.utf8.count > 60 * 1024)
        #expect(kept.hasPrefix("line ") && kept.hasSuffix("line \(i - 1) \(String(repeating: "x", count: 40))\n"))
        #expect(!LaunchdLog.trim(path: path), "under 1 MB: left alone")
        #expect(!LaunchdLog.trim(path: path + ".absent"))
    }
}
