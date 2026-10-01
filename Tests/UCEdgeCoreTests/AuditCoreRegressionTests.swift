import CoreGraphics
import Foundation
import Testing
@testable import UCEdgeCore

/// Regression tests for the v1.2 audit findings that live in UCEdgeCore (adapted from the
/// auditor's scratch proofs). Engine-level ones are in AuditEngineRegressionTests.swift.
@Suite struct AuditCoreRegressionTests {
    static func vmPeer(crossX: Double, at t: Double, pushing: Bool = true, episodeStart: Double? = nil,
                       lag: Double? = nil, slack: Double = 50) -> PeerEdgeState {
        PeerEdgeState(x: crossX, d: 0, pushing: pushing, spanMin: -1600, spanMax: 1600, receivedAt: t,
                      crossX: crossX, episodeStart: episodeStart, senderLagMs: lag, senderSlackMs: slack)
    }

    // MARK: C1(b): one latch per edge visit

    @Test func c1FrozenAtEdgeCursorLatchesOnlyOnce() {
        // The v1.1 fallback fed a frozen at-edge cursor to the latch every 4 ms with a pseudo
        // push; it re-latched every ~154 ms forever, keeping the peer "fresh at edge".
        let latch = CrossLatch()
        var latches = 0
        var last: Double?
        for i in 0..<500 {
            let x = latch.onEvent(t: Double(i) * 4, p: CGPoint(x: -500, y: 0), dy: -1,
                                  geometry: UTDesk.vmind, zoneMin: -961, zoneMax: 1600)
            if x != nil && last == nil { latches += 1 }
            last = x
        }
        #expect(latches == 1)
    }

    // MARK: C1(d): the peer's episode

    @Test func c1LandingRejectedWhenLocalCursorMovedDuringPeerEpisode() {
        // The peer has been "at edge" since t = 0 (episode start); the local user moved at t = 900.
        let det = LandingDetector()
        let g = UTDesk.macbook
        _ = det.onSample(t: 0, p: CGPoint(x: -1000, y: -300), buttonsDown: false, geometry: g, peer: nil)
        _ = det.onSample(t: 900, p: CGPoint(x: -1000, y: -290), buttonsDown: false, geometry: g, peer: nil)
        let peer = Self.vmPeer(crossX: -500, at: 995, episodeStart: 0)
        #expect(det.onSample(t: 1000, p: CGPoint(x: -1003, y: -10), buttonsDown: false, geometry: g, peer: peer) == nil)
        #expect(det.episodeRejectCount == 1)
        #expect(det.onPeerUpdate(t: 1010, peer: Self.vmPeer(crossX: -500, at: 1010, episodeStart: 0),
                                 current: CGPoint(x: -1003, y: -10), buttonsDown: false, geometry: g) == nil,
                "a rejected landing is not left pending")
    }

    @Test func c1LandingAcceptedWhenStillForTheWholeEpisode() throws {
        let det = LandingDetector()
        let g = UTDesk.macbook
        _ = det.onSample(t: 0, p: CGPoint(x: -600, y: -700), buttonsDown: false, geometry: g, peer: nil)
        // Episode began 40 ms before the landing; the cursor was still for 1000 ms.
        let c = try #require(det.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g,
                                          peer: Self.vmPeer(crossX: 0, at: 995, episodeStart: 960)))
        #expect(c.target == CGPoint(x: -1280, y: -2))
        // Slack: stillness up to episodeSlackMs shorter than the episode is still fine.
        let det2 = LandingDetector()
        _ = det2.onSample(t: 0, p: CGPoint(x: -600, y: -700), buttonsDown: false, geometry: g, peer: nil)
        _ = det2.onSample(t: 900, p: CGPoint(x: -600, y: -690), buttonsDown: false, geometry: g, peer: nil)
        #expect(det2.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g,
                              peer: Self.vmPeer(crossX: 0, at: 995, episodeStart: 880)) != nil)
    }

    @Test func c1LatePathChecksTheEpisodeAtLandingTime() {
        let det = LandingDetector()
        let g = UTDesk.macbook
        _ = det.onSample(t: 0, p: CGPoint(x: -600, y: -700), buttonsDown: false, geometry: g, peer: nil)
        _ = det.onSample(t: 900, p: CGPoint(x: -600, y: -650), buttonsDown: false, geometry: g, peer: nil)
        #expect(det.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil)   // pending, still 100
        let late = det.onPeerUpdate(t: 1020, peer: Self.vmPeer(crossX: 0, at: 1020, episodeStart: 500),
                                    current: .zero, buttonsDown: false, geometry: g)
        #expect(late == nil, "episode began 500 ms before the landing but the cursor moved 100 ms before it")
    }

    // MARK: C2: virtualX only for the first latch after a redirect

    @Test func c2RedirectIsConsumedByTheFirstLatchOnly() throws {
        var p = DeadStripParams()
        p.enabled = true
        let d = DeadStripDetector(params: p)
        var prevPinned = false
        var redirect: (t: Double, p: CGPoint)?
        for i in 0..<30 where redirect == nil {
            let t = Double(i) * 16
            if let r = d.onEvent(t: t, p: CGPoint(x: -1599, y: 0), dy: -2, prevWasPinned: prevPinned,
                                 buttonsDown: false, geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) {
                redirect = (t, r)
            }
            prevPinned = true
        }
        let (firedAt, r) = try #require(redirect)
        // Too far from the redirect point: no substitution, and the redirect is gone.
        #expect(d.consumeRedirect(latchT: firedAt + 30, latchX: 1000) == nil)
        #expect(d.consumeRedirect(latchT: firedAt + 40, latchX: Double(r.x)) == nil, "consumed")
        #expect(d.virtualX(at: firedAt + 50) == nil)
    }

    @Test func c2RedirectSubstitutionWindowAndTolerance() throws {
        func fired() throws -> (DeadStripDetector, Double, CGPoint) {
            var p = DeadStripParams()
            p.enabled = true
            let d = DeadStripDetector(params: p)
            var prevPinned = false
            for i in 0..<30 {
                let t = Double(i) * 16
                if let r = d.onEvent(t: t, p: CGPoint(x: -1599, y: 0), dy: -2, prevWasPinned: prevPinned,
                                     buttonsDown: false, geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) {
                    return (d, t, r)
                }
                prevPinned = true
            }
            throw CancellationError()
        }
        let (d1, t1, r1) = try fired()
        #expect(d1.consumeRedirect(latchT: t1 + 40, latchX: Double(r1.x) + 4) == -1599)
        let (d2, t2, r2) = try fired()
        #expect(d2.consumeRedirect(latchT: t2 + 301, latchX: Double(r2.x)) == nil, "older than 300 ms")
        let (d3, t3, r3) = try fired()
        #expect(d3.consumeRedirect(latchT: t3 + 40, latchX: Double(r3.x) + 6) == nil, "more than 5 pt away")
    }

    // MARK: C3: menu-bar slides are not pushes

    static func slide(dx: Double, dy: (Int) -> Double, events: Int) -> CGPoint? {
        var params = DeadStripParams()
        params.enabled = true
        let det = DeadStripDetector(params: params)
        var prevPinned = false
        var x = -1590.0
        for i in 0..<events {
            if let r = det.onEvent(t: 1000 + Double(i) * 16.7, p: CGPoint(x: x, y: 0), dy: dy(i), prevWasPinned: prevPinned,
                                   buttonsDown: false, geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) {
                return r
            }
            prevPinned = true
            x += dx
        }
        return nil
    }

    @Test func c3MenuBarSlidesDoNotFire() {
        #expect(Self.slide(dx: 8, dy: { $0 == 0 ? -30 : -1 }, events: 40) == nil, "auditor's fast slide")
        #expect(Self.slide(dx: 6, dy: { $0 % 2 == 0 ? -1 : 0 }, events: 60) == nil, "auditor's slow slide")
        #expect(Self.slide(dx: 1.2, dy: { _ in -1 }, events: 60) == nil, "slow drift: Σ|dy| < 1.5·Σ|dx|")
        #expect(Self.slide(dx: 0.3, dy: { _ in -2 }, events: 60) != nil, "a push with a little drift still fires")
    }

    @Test func c3RecordedDeliberatePushFiresOnceAndNothingElseDoes() throws {
        var params = DeadStripParams()
        params.enabled = true
        let det = DeadStripDetector(params: params)
        var prevPinned = false
        var fired: [Double] = []
        for e in try UTTrace.taps("s2-vmind.txt") {
            if det.onEvent(t: e.t, p: e.p, dy: e.dy, prevWasPinned: prevPinned, buttonsDown: e.buttons,
                           geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) != nil {
                fired.append(e.t)
            }
            prevPinned = UTDesk.vmind.signedDist(e.p) <= 0.5 && UTDesk.vmind.signedDist(e.p) >= -1
        }
        #expect(fired.count == 1, "\(fired)")
        #expect(fired.allSatisfy { (139_600...141_800).contains($0) }, "\(fired)")
    }

    // MARK: C4: no trapping arithmetic on peer timestamps

    @Test func c4ClockOffsetSurvivesExtremeTimestamps() {
        var c = ClockOffsetEstimator()
        for (a, b, r) in [(Int64.min, Int64.max, Int64.min), (Int64.max, Int64.min, 0), (0, Int64.max, Int64.max)] {
            #expect(c.add(sentWallMs: a, peerWallMs: b, receivedWallMs: r) == nil)
        }
        #expect(c.offsetMs == nil)
        let lag = c.senderLag(wallMs: Int64.min, nowWallMs: Int64.max)
        #expect(lag.lagMs.isFinite)
    }

    // MARK: M4: a tail-suppressed landing stays pending for a pushing peer

    @Test func m4TailPendingIsResolvedByAPushingPeerPacket() throws {
        let det = LandingDetector()
        let g = UTDesk.vmind
        _ = det.onSample(t: 900, p: CGPoint(x: 480, y: 0), buttonsDown: false, geometry: g, peer: nil)
        _ = det.onSample(t: 1000, p: CGPoint(x: 500, y: 0), buttonsDown: false, geometry: g, peer: nil)   // last tail event
        #expect(det.onSample(t: 1050, p: CGPoint(x: 1599, y: 0), buttonsDown: false, geometry: g, peer: nil) == nil)
        let mb = { (pushing: Bool, t: Double) in
            PeerEdgeState(x: -750, d: 0, pushing: pushing, spanMin: -2560, spanMax: 0, receivedAt: t, crossX: -750)
        }
        #expect(det.onPeerUpdate(t: 1055, peer: mb(false, 1055), current: CGPoint(x: 1599, y: 0),
                                 buttonsDown: false, geometry: g) == nil, "not pushing: stays pending")
        let late = try #require(det.onPeerUpdate(t: 1060, peer: mb(true, 1060), current: CGPoint(x: 1599, y: 0),
                                                 buttonsDown: false, geometry: g))
        #expect(late.kind == .late)
        #expect(abs(late.target.x - 662.5) < 0.01)
    }

    // MARK: M5: freshness by the sender's clock

    @Test func m5ClockOffsetMidpointFilterAndSmoothing() throws {
        var c = ClockOffsetEstimator()
        // Peer clock 100 ms ahead; RTT 10 ms.
        #expect(c.add(sentWallMs: 1000, peerWallMs: 1105, receivedWallMs: 1010) == 10)
        #expect(c.offsetMs == 100)
        #expect(c.add(sentWallMs: 2000, peerWallMs: 2200, receivedWallMs: 2060) == nil, "RTT 60 ms is ignored")
        #expect(c.offsetMs == 100)
        c.add(sentWallMs: 3000, peerWallMs: 3115, receivedWallMs: 3010)                // sample 110
        #expect(abs((c.offsetMs ?? 0) - 102) < 1e-9, "smoothed")
        let lag = c.senderLag(wallMs: 5102, nowWallMs: 5010)
        #expect(abs(lag.lagMs - 10) < 1e-9 && lag.slackMs == 50)
        let raw = ClockOffsetEstimator().senderLag(wallMs: 5000, nowWallMs: 5010)
        #expect(raw.lagMs == 10 && raw.slackMs == 500)
    }

    @Test func m5PacketDelayedInFlightIsNotFresh() {
        let params = DetectorParams()
        #expect(Self.vmPeer(crossX: 0, at: 1000, lag: 5).isFreshAtEdge(now: 1000, params: params))
        #expect(!Self.vmPeer(crossX: 0, at: 1000, lag: 400).isFreshAtEdge(now: 1000, params: params),
                "sent 400 ms ago by the sender's clock")
        #expect(Self.vmPeer(crossX: 0, at: 1000, lag: 400, slack: 500).isFreshAtEdge(now: 1000, params: params),
                "no offset estimate yet: 500 ms slack")
        #expect(!Self.vmPeer(crossX: 0, at: 1000, lag: 250).isFreshAtEdge(now: 1150, params: params),
                "sender age grows with arrival age")
    }

    // MARK: Minor items

    @Test func minorSnapbackNeedsAJumpNotUserMotion() throws {
        let det = LandingDetector()
        let g = UTDesk.macbook
        let peer = Self.vmPeer(crossX: 1590, at: 990)                      // maps to MacBook x = -8
        _ = det.onSample(t: 0, p: CGPoint(x: -600, y: -700), buttonsDown: false, geometry: g, peer: nil)
        let c = try #require(det.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: peer))
        det.didWarp(t: 1000, to: c.target)
        #expect(det.onSample(t: 1001, p: c.target, buttonsDown: false, geometry: g, peer: peer) == nil)
        _ = det.onSample(t: 1040, p: CGPoint(x: -5, y: -2), buttonsDown: false, geometry: g, peer: peer)
        #expect(det.onSample(t: 1056, p: CGPoint(x: -2, y: -1), buttonsDown: false, geometry: g, peer: peer) == nil)
    }

    @Test func minorLateCorrectionKeepsVerticalProgress() throws {
        let det = LandingDetector()
        let g = UTDesk.vmind
        _ = det.onSample(t: 0, p: CGPoint(x: 300, y: 500), buttonsDown: false, geometry: g, peer: nil)
        #expect(det.onSample(t: 1000, p: CGPoint(x: 1599, y: 0), buttonsDown: false, geometry: g, peer: nil) == nil)
        let peer = PeerEdgeState(x: -750, d: 0, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: 1100, crossX: -750)
        let c = try #require(det.onPeerUpdate(t: 1100, peer: peer, current: CGPoint(x: 1560, y: 120), buttonsDown: false, geometry: g))
        #expect(c.target.y == 120)
        #expect(abs(c.target.x - (662.5 + (1560 - 1599))) < 0.01)
    }

    @Test func minorExitTailExemptionNeedsARecentPushingPacket() {
        let det = LandingDetector()
        let g = UTDesk.vmind
        _ = det.onSample(t: 0, p: CGPoint(x: -950, y: 0), buttonsDown: false, geometry: g, peer: nil)
        let stale = PeerEdgeState(x: -1600.84, d: 0, pushing: true, spanMin: -2560, spanMax: 0, receivedAt: 5, crossX: -1600.84)
        #expect(det.onSample(t: 60, p: CGPoint(x: -1, y: 0), buttonsDown: false, geometry: g, peer: stale) == nil,
                "pushing packet 55 ms old does not exempt")
    }

    @Test func minorHelloValuesMustBeFinite() {
        let key = WireKey(hex: String(repeating: "5a", count: 32))!
        for w in [Double.nan, .infinity, 0, -5] {
            let h = HelloPayload(version: "x", side: .bottom,
                                 displays: [EdgeDisplayInfo(uuid: UUID(), minX: -2560, width: w)], axTrusted: true)
            let data = Wire.encode(Packet(senderId: 1, seq: 1, wallMs: 0, body: .hello(h)), key: key)
            #expect(throws: WireError.badBody) { try Wire.decodeAuthenticated(data, key: key) }
        }
    }

    @Test func minorKeyParserIsStrict() {
        #expect(WireKey(hex: String(repeating: "+f", count: 32)) == nil)
        #expect(WireKey(hex: " " + String(repeating: "ab", count: 32)) == nil)
        #expect(WireKey(hex: String(repeating: "ab", count: 32) + "\n\n") == nil)
        #expect(WireKey(hex: String(repeating: "ab", count: 32) + "\r\n") == nil)
        #expect(WireKey(hex: String(repeating: "aB", count: 32) + "\n") != nil)
        #expect(WireKey(hex: String(repeating: "09", count: 32)) != nil)
    }

    @Test func minorKeyFileModeCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key").path
        FileManager.default.createFile(atPath: path, contents: Data((String(repeating: "ab", count: 32) + "\n").utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(!WireKey.fileIsPrivate(path: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(WireKey.fileIsPrivate(path: path))
        #expect(!WireKey.fileIsPrivate(path: path + ".absent"))
    }

    @Test func minorConfigValidation() throws {
        let bad = try JSONDecoder().decode(Config.self, from: Data(
            #"{"side":"top","edgeDisplays":["E5000000-0000-4000-8000-0000000000B1","8D000000-0000-4000-8000-0000000000B"]}"#.utf8))
        #expect(bad.validated().errors.count == 1, "a malformed UUID is an error, not silently dropped")
        var c = Config()
        c.edgeDisplays = ["8A000000-0000-4000-8000-0000000000A1"]
        c.peerHosts = ["lower-mac.local"]
        c.idleWaitMs = 1
        c.detector.freshMs = 0
        c.deadStrip.maxGapMs = .nan
        c.port = 70000
        let v = c.validated()
        #expect(v.errors == ["port 70000 is not a UDP port"])
        #expect(v.warnings.count == 3)
        #expect(v.config.idleWaitMs == 250 && v.config.detector.freshMs == 300 && v.config.deadStrip.maxGapMs == 100)
        #expect(Config().validated().errors.contains("edgeDisplays is empty"))
    }

    @Test func minorByHostFileIsChosenForThisHost() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-home-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("Library/Preferences/ByHost")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func touch(_ n: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        touch("com.apple.universalcontrol.AAAA.plist")
        #expect(UCArrangement.defaultPlistPath(home: home.path, hostUUID: "ZZZZ")?.hasSuffix("AAAA.plist") == true,
                "the only file")
        touch("com.apple.universalcontrol.BBBB.plist")
        #expect(UCArrangement.defaultPlistPath(home: home.path, hostUUID: "BBBB")?.hasSuffix("BBBB.plist") == true)
        #expect(UCArrangement.defaultPlistPath(home: home.path, hostUUID: "ZZZZ") == nil, "ambiguous")
    }
}

/// Minimal reader of the recorded TAP lines (the trace-replay suite has the full parser).
enum UTTrace {
    struct Tap { var t: Double; var p: CGPoint; var dy: Double; var buttons: Bool }

    static func taps(_ name: String) throws -> [Tap] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("testdata/\(name)")
        var out: [Tap] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 6, f[1] == "TAP", f[3].hasPrefix("("), let t = Double(f[0]) else { continue }
            let xy = f[3].dropFirst().dropLast().split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let dy = Double(f[5].dropFirst(3)) else { continue }
            out.append(Tap(t: t, p: CGPoint(x: xy[0], y: xy[1]), dy: dy, buttons: f[2] != "t5"))
        }
        return out.sorted { $0.t < $1.t }
    }
}
