import CoreGraphics
import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

/// A tap event from a recording: time (ms), position and reported integer deltas.
struct UTTapEvent { var t: Double; var p: CGPoint; var dx: Double; var dy: Double }

enum UTTaps {
    /// Reads TAP lines of both recording formats (s2: "t TAP t5 (x,y) dx= dy=", s3: "TAP rx= evts= t5 (x,y) dx= dy=").
    static func load(_ name: String) throws -> [UTTapEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("testdata/\(name)")
        var out: [UTTapEvent] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: " ")
            guard let tapIdx = f.firstIndex(of: "TAP"), let pIdx = f.firstIndex(where: { $0.hasPrefix("(") }), pIdx + 2 < f.count,
                  f[pIdx + 1].hasPrefix("dx="), f[pIdx + 2].hasPrefix("dy=") else { continue }
            let t: Double
            if tapIdx == 1, let ms = Double(f[0]) { t = ms }
            else if let evts = f.first(where: { $0.hasPrefix("evts=") }), let ns = Double(evts.dropFirst(5)) { t = ns / 1e6 }
            else { continue }
            let xy = f[pIdx].dropFirst().dropLast().split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let dx = Double(f[pIdx + 1].dropFirst(3)), let dy = Double(f[pIdx + 2].dropFirst(3)) else { continue }
            out.append(UTTapEvent(t: t, p: CGPoint(x: xy[0], y: xy[1]), dx: dx, dy: dy))
        }
        return out.sorted { $0.t < $1.t }
    }
}

@Suite struct OverrideGuardTests {
    static func mbPeer(_ crossX: Double, _ t: Double) -> PeerEdgeState {
        PeerEdgeState(x: crossX, d: 0, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: t, crossX: crossX, crossSource: .uc)
    }
    static func vmPeer(_ crossX: Double, _ t: Double) -> PeerEdgeState {
        PeerEdgeState(x: crossX, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, receivedAt: t, crossX: crossX, crossSource: .uc)
    }

    /// Lands at `landing` at t = 1000 with a fresh peer, warps, and sees the echo. Returns the correction.
    static func corrected(_ d: LandingDetector, _ g: EdgeGeometry, frozen: CGPoint, landing: CGPoint,
                          peer: PeerEdgeState) throws -> Correction {
        _ = d.onTapEvent(t: 0, p: frozen, dx: 0, dy: 0, buttonsDown: false, geometry: g, peer: nil)
        let c = try #require(d.onSample(t: 1000, p: landing, buttonsDown: false, geometry: g, peer: peer))
        d.didWarp(t: 1000, to: c.target)
        _ = d.onSample(t: 1000.5, p: c.target, buttonsDown: false, geometry: g, peer: peer)
        return c
    }

    @Test func s3OverrideEventRewarpsOnceToPPlusDelta() throws {
        let d = LandingDetector()
        let g = UTDesk.vmind
        // s3 17:01:54.56: UC landed V-Mind at (1599, 0); the MacBook's crossX −199.09 maps to 1351.1.
        let c = try Self.corrected(d, g, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                                   peer: Self.mbPeer(-199.09, 995))
        #expect(abs(c.target.x - 1351.14) < 0.05 && c.target.y == 2)
        let delta = CGVector(dx: c.target.x - 1599, dy: c.target.y - 0)
        // 26 ms later UC's first forwarded report puts the cursor at its own model position.
        let o = try #require(d.onTapEvent(t: 1026, p: CGPoint(x: 1491.80, y: 84.41), dx: 972, dy: 83,
                                          buttonsDown: false, geometry: g, peer: nil))
        #expect(o.kind == .override)
        #expect(abs(o.target.x - (1491.80 + delta.dx)) < 0.01 && abs(o.target.y - (84.41 + delta.dy)) < 0.01)
        d.didWarp(t: 1026, to: o.target)
        // The following reports are relative again: no further re-warp.
        var p = o.target
        for (t, dx, dy) in [(1043.0, 8.0, 4.0), (1210, 13, 0), (1227, 85, 0)] {
            p = CGPoint(x: p.x + dx, y: p.y + dy)
            #expect(d.onTapEvent(t: t, p: p, dx: dx, dy: dy, buttonsDown: false, geometry: g, peer: nil) == nil)
        }
        #expect(d.overrideRewarpCount == 1)
    }

    /// Replays the recorded tap events after a landing through the guard. The MacBook's events are
    /// relative to our warp (its corrections stick): translated by Δ, including the first one, whose
    /// reported delta is garbage (dx ≈ 1600). V-Mind's first forwarded report is UC's absolute flush
    /// (raw position), later ones are relative. Returns the re-warp count.
    static func replay(_ taps: [UTTapEvent], landingT: Double, landing: CGPoint, frozen: CGPoint, g: EdgeGeometry,
                       peer: PeerEdgeState, vmindFlush: Bool) throws -> (rewarps: Int, firstWasOverride: Bool) {
        let d = LandingDetector()
        _ = d.onTapEvent(t: landingT - 2000, p: frozen, dx: 0, dy: 0, buttonsDown: false, geometry: g, peer: nil)
        var fresh = peer
        fresh.receivedAt = landingT - 5
        let c = try #require(d.onSample(t: landingT, p: landing, buttonsDown: false, geometry: g, peer: fresh))
        d.didWarp(t: landingT, to: c.target)
        var shift = CGVector(dx: c.target.x - landing.x, dy: c.target.y - landing.y)
        var rewarps = 0, first = true, firstWasOverride = false
        for e in taps where e.t > landingT && e.t <= landingT + 300 {
            let p = vmindFlush && first ? e.p : CGPoint(x: e.p.x + shift.dx, y: e.p.y + shift.dy)
            if let o = d.onTapEvent(t: e.t, p: p, dx: e.dx, dy: e.dy, buttonsDown: false, geometry: g, peer: nil) {
                rewarps += 1
                if first { firstWasOverride = true }
                d.didWarp(t: e.t, to: o.target)
                shift = CGVector(dx: o.target.x - e.p.x, dy: o.target.y - e.p.y)
            }
            first = false
        }
        return (rewarps, firstWasOverride)
    }

    @Test func recordedStreamsAfterEachCorrectionDontRewarp() throws {
        let mbTaps = try UTTaps.load("s2-macbook.txt").map { UTTapEvent(t: $0.t + 345.5, p: $0.p, dx: $0.dx, dy: $0.dy) }
        let vmTaps = try UTTaps.load("s2-vmind.txt")
        // s2 MacBook upward landings (V-Mind clock), each corrected far from the (0, 0) corner.
        for (t, x) in [(153750.6, -948.46), (159163.1, 1023.68), (168902.3, 177.10), (169547.9, 1474.58)] {
            let r = try Self.replay(mbTaps, landingT: t, landing: .zero, frozen: CGPoint(x: -1000, y: -700), g: UTDesk.macbook,
                                    peer: Self.vmPeer(x, 0), vmindFlush: false)
            #expect(r.rewarps == 0, "MacBook landing at \(t): \(r)")
        }
        // s2 V-Mind downward landings: only UC's absolute flush (the first report) re-warps.
        for (t, landing, x) in [(126601.3, CGPoint(x: -1, y: 0), -1600.84), (157199.9, CGPoint(x: 1599, y: 0), -742.87),
                                (160537.9, CGPoint(x: 1599, y: 0), -72.04)] {
            let r = try Self.replay(vmTaps, landingT: t, landing: landing, frozen: CGPoint(x: 300, y: 500), g: UTDesk.vmind,
                                    peer: Self.mbPeer(x, 0), vmindFlush: true)
            #expect(r.rewarps <= 1 && (r.rewarps == 0 || r.firstWasOverride), "V-Mind landing at \(t): \(r)")
        }
        // s3 MacBook: the 1.2.1 engine really corrected these landings (target at y = −2), so the
        // recorded events are already relative to our warp: feed them raw.
        let lines = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("testdata/s3-macbook-uclog.txt"), encoding: .utf8).split(separator: "\n")
        let s3mb = try UTTaps.load("s3-macbook-uclog.txt")
        var checked = 0
        for (i, l) in lines.enumerated() where l.contains("Hot Zone: Warped into: bottom") {
            guard let tl = lines[(i + 1)...].first(where: { ($0.hasPrefix("POS") || $0.hasPrefix("TAP")) && $0.contains(",-2.00)") }),
                  let open = tl.firstIndex(of: "("), let close = tl.firstIndex(of: ")") else { continue }
            let xy = tl[tl.index(after: open)..<close].split(separator: ",").compactMap { Double($0) }
            let nsField = tl.split(separator: " ").first { $0.hasPrefix("ns=") || $0.hasPrefix("evts=") }
            guard xy.count == 2, let nsText = nsField?.split(separator: "=").last, let ns = Double(nsText) else { continue }
            let target = CGPoint(x: xy[0], y: xy[1]), t0 = ns / 1e6
            let d = LandingDetector()
            _ = d.onTapEvent(t: t0 - 2000, p: CGPoint(x: -1000, y: -700), dx: 0, dy: 0, buttonsDown: false, geometry: UTDesk.macbook, peer: nil)
            let crossX = (Double(target.x) + 2560) / 2560 * 3200 - 1600
            let c = try #require(d.onSample(t: t0 - 1, p: .zero, buttonsDown: false, geometry: UTDesk.macbook,
                                            peer: Self.vmPeer(crossX, t0 - 5)))
            #expect(abs(c.target.x - target.x) < 0.01)
            d.didWarp(t: t0 - 1, to: c.target)
            var rewarps = 0
            for e in s3mb where e.t >= t0 - 1 && e.t <= t0 + 300 {
                if d.onTapEvent(t: e.t, p: e.p, dx: e.dx, dy: e.dy, buttonsDown: false, geometry: UTDesk.macbook, peer: nil) != nil {
                    rewarps += 1
                }
            }
            #expect(rewarps == 0, "s3 MacBook correction to \(target)")
            checked += 1
        }
        #expect(checked == 2, "both recorded s3 MacBook corrections")
    }

    @Test func clampedEventsDontTrigger() throws {
        let d = LandingDetector()
        let g = UTDesk.vmind
        let c = try Self.corrected(d, g, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                                   peer: Self.mbPeer(-199.09, 995))
        // Pushing up hard at the top edge (dy −60, the cursor pinned at y = 0), toward the landing.
        #expect(d.onTapEvent(t: 1017, p: CGPoint(x: c.target.x + 3, y: 0), dx: 3, dy: -60, buttonsDown: false,
                             geometry: g, peer: nil) == nil)
        // Pushing right into the screen edge at x = 1599.98, as in s3 (dx 155, moved 2.3).
        let d2 = LandingDetector()
        let c2 = try Self.corrected(d2, g, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                                    peer: Self.mbPeer(-5, 995))
        _ = d2.onTapEvent(t: 1017, p: CGPoint(x: 1597.7, y: 40), dx: 1597.7 - Double(c2.target.x), dy: 38,
                          buttonsDown: false, geometry: g, peer: nil)
        #expect(d2.onTapEvent(t: 1034, p: CGPoint(x: 1599.98, y: 60), dx: 155, dy: 20, buttonsDown: false,
                              geometry: g, peer: nil) == nil)
    }

    @Test func rewarpsAreCappedAtTwoAndOnlyWithin300ms() throws {
        let g = UTDesk.vmind
        let d = LandingDetector()
        let c = try Self.corrected(d, g, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                                   peer: Self.mbPeer(-199.09, 995))
        var rewarps = 0
        for t in [1026.0, 1060, 1100, 1140] {
            // Each time UC flushes its model position again: near its landing plus a little motion.
            if let o = d.onTapEvent(t: t, p: CGPoint(x: 1590, y: 20), dx: 900, dy: 20, buttonsDown: false, geometry: g, peer: nil) {
                rewarps += 1
                d.didWarp(t: t, to: o.target)
            }
        }
        #expect(rewarps == 2)
        let d2 = LandingDetector()
        _ = try Self.corrected(d2, g, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                               peer: Self.mbPeer(-199.09, 995))
        #expect(d2.onTapEvent(t: 1301, p: CGPoint(x: 1590, y: 20), dx: 900, dy: 20, buttonsDown: false, geometry: g, peer: nil) == nil,
                "outside the 300 ms guard")
        _ = c
    }

    @Test func userMovingTowardTheLandingNeverRewarps() throws {
        let g = UTDesk.vmind
        let d = LandingDetector()
        let c = try Self.corrected(d, g, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                                   peer: Self.mbPeer(-199.09, 995))
        var p = c.target
        var t = 1000.0
        for _ in 0..<15 {                                   // 17 pt per event toward (1599, 0), consistent deltas
            t += 16
            p = CGPoint(x: p.x + 17, y: p.y)
            #expect(d.onTapEvent(t: t, p: p, dx: 17, dy: 0, buttonsDown: false, geometry: g, peer: nil) == nil)
        }
        #expect(d.overrideRewarpCount == 0)
        // A garbage delta that doesn't bring the cursor back toward the landing (the MacBook's first event).
        let d2 = LandingDetector()
        let c2 = try Self.corrected(d2, UTDesk.macbook, frozen: CGPoint(x: -1000, y: -700), landing: .zero,
                                    peer: Self.vmPeer(-948.46, 995))
        #expect(d2.onTapEvent(t: 1016, p: CGPoint(x: c2.target.x + 0.48, y: c2.target.y - 1.58), dx: 1601, dy: -1,
                              buttonsDown: false, geometry: UTDesk.macbook, peer: nil) == nil)
    }

    @Test func guardCanBeTurnedOff() throws {
        var params = DetectorParams()
        params.overrideGuard = false
        let d = LandingDetector(params: params)
        _ = try Self.corrected(d, UTDesk.vmind, frozen: CGPoint(x: 1560, y: 520), landing: CGPoint(x: 1599, y: 0),
                               peer: Self.mbPeer(-199.09, 995))
        #expect(d.onTapEvent(t: 1026, p: CGPoint(x: 1491.80, y: 84.41), dx: 972, dy: 83, buttonsDown: false,
                             geometry: UTDesk.vmind, peer: nil) == nil)
    }
}

@Suite struct DeadStripV14Tests {
    static var vmindParams: DeadStripParams {
        var p = DeadStripParams()
        p.enabled = true; p.minPushMs = 150; p.pushThresholdPt = 8; p.maxSpreadPt = 60; p.minDyDxRatio = 1.0
        return p
    }

    @Test func recordedPushFiresOnceAndEarlierWithTheV14Tuning() throws {
        let det = DeadStripDetector(params: Self.vmindParams)
        var prevPinned = false
        var fired: [Double] = []
        for e in try UTTrace.taps("s2-vmind.txt") {
            if det.onEvent(t: e.t, p: e.p, dy: e.dy, prevWasPinned: prevPinned, buttonsDown: e.buttons,
                           geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) != nil { fired.append(e.t) }
            prevPinned = UTDesk.vmind.signedDist(e.p) <= 0.5 && UTDesk.vmind.signedDist(e.p) >= -1
        }
        #expect(fired.count == 1, "\(fired)")
        #expect((fired.first ?? 0) < 139_852.2 && (fired.first ?? 0) >= 139_668.7 + 150, "\(fired)")
    }

    @Test(arguments: [4.0, 5.0, 6.0, 7.0, 8.0])
    func menuSlidesNeverFire(dxPerEvent: Double) {
        let det = DeadStripDetector(params: Self.vmindParams)
        var prevPinned = false
        var x = -1595.0
        for i in 0..<120 {
            #expect(det.onEvent(t: Double(i) * 16.7, p: CGPoint(x: x, y: 0), dy: i == 0 ? -30 : -1, prevWasPinned: prevPinned,
                                buttonsDown: false, geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) == nil)
            prevPinned = true
            x += dxPerEvent
            if x > -965 { x = -1595 }                     // back to the left and slide again
        }
        #expect(det.nearMissCount > 0, "slides long enough are reported as near-misses")
        #expect(det.lastNearMiss.map { ["sideways", "wide", "weak"].contains($0.reason) } == true, "\(String(describing: det.lastNearMiss))")
    }

    @Test func nearMissReportsTheReason() {
        let det = DeadStripDetector(params: Self.vmindParams)
        var prevPinned = false
        // A 120 ms push of 0.5 pt per event: too short and too weak; then the cursor leaves the edge.
        for i in 0..<9 {
            _ = det.onEvent(t: Double(i) * 16, p: CGPoint(x: -1590, y: 0), dy: -0.5, prevWasPinned: prevPinned, buttonsDown: false,
                            geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600)
            prevPinned = true
        }
        _ = det.onEvent(t: 160, p: CGPoint(x: -1590, y: 40), dy: 10, prevWasPinned: true, buttonsDown: false,
                        geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600)
        #expect(det.nearMissCount == 1)
        #expect(det.lastNearMiss?.reason == "short")
        #expect((det.lastNearMiss?.durationMs ?? 0) >= 100)
    }
}

@Suite(.serialized) struct EpisodeUCCrossTests {
    /// G1: a packet with no crossX ends the episode's UC crossX, so a second crossing in the same
    /// unbroken episode can't reuse the first one's x.
    @Test func packetWithoutCrossXClearsTheEpisodesUCCross() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, raw) = try UTRig.macbookWithRawPeer(dir: dir, cursor: UTThreadAwareCursor(CGPoint(x: -600, y: -700)))
        defer { mb.engine.stop(); raw.socket.shutdownAndClose() }
        func edge(_ cx: Double?, _ src: CrossSource) {
            raw.send(.edge(EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: cx, crossSource: src)),
                     to: mb.socket.port)
        }
        edge(100, .uc); await UTRig.ms(30)
        edge(nil, .model); await UTRig.ms(30)                    // the sender's hold has reset
        edge(500, .model); await UTRig.ms(30)                    // a second crossing, same unbroken episode
        let peer = mb.engine.lock.withLock { mb.engine.peer }
        #expect(peer?.crossX == 500 && peer?.crossSource == .model)
        // Control: without the empty packet the UC x is still preferred.
        edge(700, .uc); await UTRig.ms(30)
        edge(900, .model); await UTRig.ms(30)
        #expect(mb.engine.lock.withLock { mb.engine.peer }?.crossX == 700)
    }
}
