import CoreGraphics
import Foundation
import Testing
@testable import UCEdgeCore

@Suite struct DeadStripTests {
    static func enabled() -> DeadStripDetector {
        var p = DeadStripParams()
        p.enabled = true
        return DeadStripDetector(params: p)
    }

    /// Feeds a pinned upward push on V-Mind at `x`, one event every 16 ms; returns redirects.
    static func push(_ d: DeadStripDetector, x: Double, from t0: Double = 0, events: Int = 60, dy: Double = -1.3,
                     buttons: Bool = false, zone: (Double, Double) = (-961, 1600)) -> [(t: Double, p: CGPoint)] {
        var fired: [(Double, CGPoint)] = []
        var prevPinned = false
        for i in 0..<events {
            let t = t0 + Double(i) * 16
            if let r = d.onEvent(t: t, p: CGPoint(x: x, y: 0), dy: dy, prevWasPinned: prevPinned, buttonsDown: buttons,
                                 geometry: UTDesk.vmind, zoneMinX: zone.0, zoneMaxX: zone.1) {
                fired.append((t, r))
            }
            prevPinned = true
        }
        return fired
    }

    @Test func disabledNeverFires() {
        #expect(Self.push(DeadStripDetector(params: DeadStripParams()), x: -1590).isEmpty)
    }

    @Test func sustainedPushFiresOnceAfterMinPushMs() throws {
        let d = Self.enabled()
        let fired = Self.push(d, x: -1590)
        #expect(fired.count == 1)
        let f = try #require(fired.first)
        #expect(f.p == CGPoint(x: -959, y: 0))
        // The run starts at the first pinned push (t = 16); 180 ms later is t = 196 -> event at 208.
        #expect(f.t == 208)
        #expect(d.virtualX(at: f.t + 10) == -1590)
        #expect(d.virtualX(at: f.t + 1001) == nil)
    }

    @Test func weakPushWaitsForThePushSum() throws {
        // 0.5 pt per event: 180 ms is reached before 12 pt, which needs 24 pushes (t = 384).
        let f = try #require(Self.push(Self.enabled(), x: -1590, dy: -0.5).first)
        #expect(f.t == 24 * 16)
    }

    @Test func flickToTheAppleMenuDoesNotFire() {
        // ~50 ms of arrival momentum at the edge, then the cursor rests (dy = 0) and leaves.
        let d = Self.enabled()
        var prevPinned = false
        var t = 0.0
        for dy in [-30.0, -20, -12, -6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] {
            #expect(d.onEvent(t: t, p: CGPoint(x: -1590, y: 0), dy: dy, prevWasPinned: prevPinned, buttonsDown: false,
                              geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) == nil)
            prevPinned = true
            t += 16
        }
    }

    @Test func gapOver100msRestartsTheRun() {
        let d = Self.enabled()
        // 150 ms of pushing, a 120 ms pause (no events), 150 ms more: neither run reaches 180 ms.
        #expect(Self.push(d, x: -1590, from: 0, events: 10).isEmpty)
        #expect(Self.push(d, x: -1590, from: 144 + 120, events: 10).isEmpty)
    }

    @Test func leavingTheEdgeRestartsTheRun() {
        let d = Self.enabled()
        var fired = 0
        var prevPinned = false
        for i in 0..<40 {
            let t = Double(i) * 16
            let y = i % 8 == 7 ? 3.0 : 0.0                    // hop off the edge every 8th event
            if d.onEvent(t: t, p: CGPoint(x: -1590, y: y), dy: -2, prevWasPinned: prevPinned, buttonsDown: false,
                         geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) != nil { fired += 1 }
            prevPinned = y <= 0.5
        }
        #expect(fired == 0)
    }

    @Test func cooldownThenFiresAgain() {
        let fired = Self.push(Self.enabled(), x: -1590, events: 200)
        #expect(fired.count == 2)
        #expect(fired[1].t - fired[0].t >= 1500)
    }

    @Test func inZonePushesNeverFire() {
        #expect(Self.push(Self.enabled(), x: -500).isEmpty)
        #expect(Self.push(Self.enabled(), x: -961).isEmpty)
        #expect(Self.push(Self.enabled(), x: 1500).isEmpty)
    }

    @Test func buttonsDownNeverFire() {
        #expect(Self.push(Self.enabled(), x: -1590, buttons: true).isEmpty)
    }

    @Test func arrivingFlicksDoNotCount() {
        let d = Self.enabled()
        var t = 0.0
        for _ in 0..<40 {
            // Each flick arrives from below: the previous event was not pinned.
            #expect(d.onEvent(t: t, p: CGPoint(x: -1590, y: 0), dy: -30, prevWasPinned: false, buttonsDown: false,
                              geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) == nil)
            t += 16
        }
    }

    @Test func pushesAwayFromEdgeDoNotCount() {
        #expect(Self.push(Self.enabled(), x: -1590, dy: 1.3).isEmpty)
        #expect(Self.push(Self.enabled(), x: -1590, dy: 0).isEmpty)
    }

    @Test func deadPartRightOfZoneRedirectsToZoneMax() throws {
        let fired = Self.push(Self.enabled(), x: 1500, zone: (-1600, 1000))
        let f = try #require(fired.first)
        #expect(f.p == CGPoint(x: 998, y: 0))
    }

    @Test func paramsDecodeWithDefaults() throws {
        let p = try JSONDecoder().decode(DeadStripParams.self, from: Data(#"{"enabled": true, "windowMs": 400}"#.utf8))
        var expected = DeadStripParams()
        expected.enabled = true
        #expect(p == expected)
        #expect(p.pushThresholdPt == 12 && p.minPushMs == 180 && p.maxGapMs == 100)
    }
}
