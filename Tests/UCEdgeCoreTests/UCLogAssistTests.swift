import CoreGraphics
import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

/// Reader of the s3 recordings: TAP events (uptime ns) and UCLOG lines (continuous ticks).
enum UTUCLogRecording {
    enum Item { case tap(UCTapRecord), line(rxNs: UInt64, mach: UInt64, message: String) }

    static func load(_ name: String, geometry: EdgeGeometry) throws -> [Item] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("testdata/\(name)")
        var out: [Item] = []
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: false)
            if f.first == "TAP", f.count >= 7, let ns = UInt64(f[2].dropFirst(5)) {
                let xy = f[4].dropFirst().dropLast().split(separator: ",").compactMap { Double($0) }
                guard xy.count == 2, let dy = Double(f[6].dropFirst(3)) else { continue }
                let p = CGPoint(x: xy[0], y: xy[1])
                out.append(.tap(UCTapRecord(ns: ns, x: xy[0], y: xy[1], s: geometry.signedDist(p), dy: dy)))
            } else if f.first == "UCLOG", f.count >= 6, let rx = UInt64(f[1].dropFirst(3)), let mach = UInt64(f[2].dropFirst(5)),
                      let msg = line.range(of: " msg=") {
                out.append(.line(rxNs: rx, mach: mach, message: String(line[msg.upperBound...])))
            }
        }
        return out
    }
}

@Suite struct UCLogAssistTests {
    static let apple = UCLogClock(numer: 125, denom: 3)
    static let d3 = UUID(uuidString: "8A000000-0000-4000-8000-0000000000A1")!
    static let d4 = UUID(uuidString: "E5000000-0000-4000-8000-0000000000B1")!
    static let d5 = UUID(uuidString: "8D000000-0000-4000-8000-0000000000B2")!

    // MARK: parsing

    @Test func parsesNdjsonActivatingAndEnteringLines() throws {
        let act = #"{"traceID":1,"eventMessage":"Hot Zone: Activating: top:31000000:8a000000-0000-4000-8000-0000000000a1","machTimestamp":1481968516918,"processID":672}"#
        let e = try #require(UCLogParser.parse(ndjsonLine: act))
        #expect(e == UCLogEvent(kind: .activating, edge: "top", device: "31000000",
                                displayUUID: "8A000000-0000-4000-8000-0000000000A1", machTimestamp: 1481968516918))
        let ent = #"{"eventMessage":"Hot Zone: Entering: top:31000000:8A000000-0000-4000-8000-0000000000A1:[-961.0 0.0 1600.0 1.0]:guarded=false","machTimestamp":5}"#
        #expect(UCLogParser.parse(ndjsonLine: ent)?.kind == .entering)
        #expect(UCLogParser.parse(ndjsonLine: ent)?.displayUUID == "8A000000-0000-4000-8000-0000000000A1")
    }

    @Test func ignoresHeadersOtherMessagesAndJunk() {
        for line in [#"Filtering the log data using "process == "UniversalControl"""#,
                     #"{"eventMessage":"Hot Zone: Leaving: right:31000000:3C000000-0000-4000-8000-0000000000C1","machTimestamp":1}"#,
                     #"{"eventMessage":"Hide cursor 552707","machTimestamp":1}"#,
                     #"{"eventMessage":"Hot Zone: Activating: top:31000000:not-a-uuid","machTimestamp":1}"#,
                     #"{"eventMessage":"Hot Zone: Activating: sideways:31000000:8A000000-0000-4000-8000-0000000000A1","machTimestamp":1}"#,
                     #"{"eventMessage":"Hot Zone: Activating: top:31000000:8A000000-0000-4000-8000-0000000000A1"}"#,
                     #"{"eventMessage":"Hot Zone: Activating: top:31000000:8A000000-0000-4000-8000-0000000000A1","machTimestamp":-5}"#,
                     "{not json", ""] {
            #expect(UCLogParser.parse(ndjsonLine: line) == nil, "\(line)")
        }
    }

    // MARK: clocks

    @Test func continuousToUptimeConversion() throws {
        // V-Mind (no sleep): offset 0; 125/3 timebase.
        #expect(Self.apple.uptimeNs(machContinuous: 1481968516918, continuousMinusAbsolute: 0) == 61748688204916)
        // MacBook: continuous ran ~12 711 s ahead after sleeps.
        let offsetTicks = Self.apple.ticks(uptimeNs: 12_711_195_579_542)
        let ns = try #require(Self.apple.uptimeNs(machContinuous: 1726578382296, continuousMinusAbsolute: offsetTicks))
        #expect(abs(Int64(ns) - 59_229_571_341_875) < 1_000_000, "within 1 ms of the recorded receipt")
        #expect(Self.apple.uptimeNs(machContinuous: 5, continuousMinusAbsolute: 6) == nil)
        #expect(UCLogClock(numer: 1, denom: 1).uptimeNs(machContinuous: 42, continuousMinusAbsolute: 2) == 40)
        #expect(Self.apple.uptimeNs(machContinuous: .max, continuousMinusAbsolute: 0) == nil, "overflow")
    }

    @Test func receiveLagSanity() {
        let now: UInt64 = 10_000_000_000
        #expect(UCLogClock.lagIsSane(eventNs: now - 1_000_000, nowNs: now))
        #expect(UCLogClock.lagIsSane(eventNs: now - 2_000_000_000, nowNs: now))
        #expect(!UCLogClock.lagIsSane(eventNs: now - 2_000_000_001, nowNs: now))
        #expect(UCLogClock.lagIsSane(eventNs: now + 5_000_000, nowNs: now))
        #expect(!UCLogClock.lagIsSane(eventNs: now + 5_000_001, nowNs: now))
    }

    // MARK: matching the s3 recordings

    /// Runs the §13 pipeline over a recording: taps into the matcher in receive order, each
    /// UCLOG line through parse → filter → convert → match.
    static func replay(_ name: String, side: EdgeSide, geometry: EdgeGeometry, peerDisplays: [UUID],
                       offsetTicks: UInt64) throws -> (crossX: [Double], ignored: Int) {
        let matcher = UCCrossMatcher()
        var xs: [Double] = []
        var ignored = 0
        for item in try UTUCLogRecording.load(name, geometry: geometry) {
            switch item {
            case .tap(let r):
                matcher.record(r)
            case let .line(rx, mach, message):
                guard let e = UCLogParser.parse(message: message, machTimestamp: mach), e.kind == .activating else { continue }
                guard UCLogFilter.accepts(e, localSide: side, peerDisplays: peerDisplays) else { ignored += 1; continue }
                let ns = try #require(apple.uptimeNs(machContinuous: mach, continuousMinusAbsolute: offsetTicks))
                #expect(UCLogClock.lagIsSane(eventNs: ns, nowNs: rx))
                if let hit = matcher.match(activationNs: ns) { xs.append(hit.x) }
            }
        }
        return (xs, ignored)
    }

    @Test func s3VMindActivationsGiveUCsExactCrossX() throws {
        let r = try Self.replay("s3-vmind-uclog.txt", side: .top, geometry: UTDesk.vmind, peerDisplays: [Self.d3], offsetTicks: 0)
        #expect(r.crossX == [539.41, 1313.00], "UC Target Ready offsets 1.561305 and 2.366281 back-computed")
        #expect(r.ignored == 1, "the right: side-link activation")
        // Check against UC's own offsets: x = offset·961 − 961.
        #expect(abs(1.561305 * 961 - 961 - 539.41) < 0.01 && abs(2.366281 * 961 - 961 - 1313.00) < 0.01)
    }

    @Test func s3MacBookActivationMatchesWithADerivedOffset() throws {
        // The MacBook's continuous offset wasn't recorded: take it as the smallest receive lag.
        var maxDiff: Int64 = .min
        for case let .line(rx, mach, _) in try UTUCLogRecording.load("s3-macbook-uclog.txt", geometry: UTDesk.macbook) {
            let ns = try #require(Self.apple.uptimeNs(machContinuous: mach, continuousMinusAbsolute: 0))
            maxDiff = max(maxDiff, Int64(ns) - Int64(rx))
        }
        let offsetTicks = Self.apple.ticks(uptimeNs: UInt64(maxDiff))
        let r = try Self.replay("s3-macbook-uclog.txt", side: .bottom, geometry: UTDesk.macbook,
                                peerDisplays: [Self.d4, Self.d5], offsetTicks: offsetTicks)
        // UC's broken zone <4> reports the absolute x as its "offset": −199.093750.
        #expect(r.crossX.count == 1 && abs((r.crossX.first ?? 0) - -199.09375) < 0.01, "\(r.crossX)")
        #expect(r.ignored == 1, "the left: side-link activation")
    }

    // MARK: filtering, matcher, hold

    @Test func filterNeedsOurSideAndAPeerDisplay() {
        let base = UCLogEvent(kind: .activating, edge: "top", device: "D", displayUUID: Self.d3.uuidString, machTimestamp: 1)
        #expect(UCLogFilter.accepts(base, localSide: .top, peerDisplays: [Self.d3]))
        var e = base; e.edge = "right"
        #expect(!UCLogFilter.accepts(e, localSide: .top, peerDisplays: [Self.d3]), "side link")
        e = base; e.edge = "left"
        #expect(!UCLogFilter.accepts(e, localSide: .top, peerDisplays: [Self.d3]))
        e = base; e.displayUUID = "3C000000-0000-4000-8000-0000000000C1"
        #expect(!UCLogFilter.accepts(e, localSide: .top, peerDisplays: [Self.d3]), "foreign display")
        #expect(!UCLogFilter.accepts(base, localSide: .top, peerDisplays: []), "peer displays not known yet")
        #expect(!UCLogFilter.accepts(base, localSide: .bottom, peerDisplays: [Self.d3]))
        e = base; e.kind = .entering
        #expect(!UCLogFilter.accepts(e, localSide: .top, peerDisplays: [Self.d3]))
    }

    @Test func matcherTakesTheLatestAtEdgeEventWithin100ms() {
        let m = UCCrossMatcher()
        let ms: UInt64 = 1_000_000
        m.record(UCTapRecord(ns: 1000 * ms, x: 1, y: 0, s: 0, dy: -1))
        m.record(UCTapRecord(ns: 1016 * ms, x: 2, y: 3, s: 3, dy: -1))          // not at edge
        m.record(UCTapRecord(ns: 1032 * ms, x: 3, y: 0, s: 0, dy: -1))
        #expect(m.match(activationNs: 1033 * ms)?.x == 3)
        #expect(m.match(activationNs: 1031 * ms)?.x == 1, "events after the activation don't count")
        #expect(m.match(activationNs: 1100 * ms)?.x == 1 || m.match(activationNs: 1100 * ms)?.x == 3)
        #expect(m.match(activationNs: 1133 * ms) == nil, "latest candidate is 101 ms old")
        #expect(m.match(activationNs: 999 * ms) == nil)
        m.record(UCTapRecord(ns: 4000 * ms, x: 4, y: 0, s: 0, dy: -1))
        #expect(m.count == 1, "only 2 s are kept")
    }

    @Test func ucCrossIsHeldForTheTailWithTheLatchRules() {
        var h = UCCrossHold()
        h.onEvent(t: 0, s: 0)
        h.set(539.41, at: 1)
        #expect(h.onEvent(t: 16, s: 0) == 539.41)
        #expect(h.onEvent(t: 100, s: 12) == 539.41)
        #expect(h.onEvent(t: 151, s: 0) == 539.41)
        #expect(h.onEvent(t: 152, s: 0) == nil, "150 ms after it was set")
        h.set(1, at: 200); h.onEvent(t: 200, s: 0)
        #expect(h.onEvent(t: 301, s: 0) == nil, "gap")
        h.set(1, at: 400); h.onEvent(t: 400, s: 0)
        #expect(h.onEvent(t: 410, s: 31) == nil, "left the edge")
    }

    // MARK: dead strip

    @Test func deadStripSubstitutionForUCActivation() throws {
        func fired() throws -> (DeadStripDetector, Double) {
            var p = DeadStripParams(); p.enabled = true
            let d = DeadStripDetector(params: p)
            var prevPinned = false
            for i in 0..<40 {
                let t = Double(i) * 16
                if d.onEvent(t: t, p: CGPoint(x: -1599, y: 0), dy: -2, prevWasPinned: prevPinned, buttonsDown: false,
                             geometry: UTDesk.vmind, zoneMinX: -961, zoneMaxX: 1600) != nil { return (d, t) }
                prevPinned = true
            }
            throw CancellationError()
        }
        let (d, t) = try fired()
        // The model latch consumes its own copy first; the UC path still gets the original x.
        #expect(d.consumeRedirect(latchT: t + 20, latchX: -959) == -1599)
        #expect(d.consumeRedirectForUC(t: t + 25, latchX: -956) == -1599)
        #expect(d.consumeRedirectForUC(t: t + 30, latchX: -956) == nil, "once")
        let (d2, t2) = try fired()
        #expect(d2.consumeRedirectForUC(t: t2 + 1001, latchX: -959) == nil, "older than 1 s")
        let (d3, t3) = try fired()
        #expect(d3.consumeRedirectForUC(t: t3 + 100, latchX: -953) == nil, "6 pt from the redirect point")
        #expect(d3.consumeRedirectForUC(t: t3 + 100, latchX: -955) == -1599)
    }

    // MARK: receiver preference

    @Test func receiverPrefersUCSourcedCrossXWhenThePeersAssistIsActive() {
        #expect(CrossSourcePolicy.usableCrossX(10, source: .uc, peerUCLogActive: true) == 10)
        #expect(CrossSourcePolicy.usableCrossX(10, source: .model, peerUCLogActive: true) == nil)
        #expect(CrossSourcePolicy.usableCrossX(10, source: .model, peerUCLogActive: false) == 10)
        #expect(CrossSourcePolicy.usableCrossX(10, source: .uc, peerUCLogActive: false) == 10)
        #expect(CrossSourcePolicy.usableCrossX(nil, source: .uc, peerUCLogActive: true) == nil)
    }

    @Test func configTogglesDefaultOn() throws {
        #expect(Config().corrections.enabled && Config().ucLogAssist.enabled)
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"corrections":{"enabled":false},"ucLogAssist":{}}"#.utf8))
        #expect(!c.corrections.enabled && c.ucLogAssist.enabled)
        // Per-side settings of the published examples: ArrangementConfigTests.
    }
}

/// Engine-level v1.3 behaviour over loopback.
@Suite(.serialized) struct UCLogAssistEngineTests {
    static let clock = UCLogClock.local

    /// A fake `log stream`: an Activating line stamped `afterNs` after `eventNs`.
    static func activation(on eventNs: UInt64, afterNs: UInt64 = 300_000, display: UUID = UTRig.d3,
                           edge: String = "top") -> UCLogEvent {
        UCLogEvent(kind: .activating, edge: edge, device: "31000000", displayUUID: display.uuidString,
                   machTimestamp: clock.ticks(uptimeNs: eventNs + afterNs))
    }

    static func tap(_ s: UTRig.Side, _ x: Double, _ y: Double, dy: Double) -> UInt64 {
        let ns = DispatchTime.now().uptimeNanoseconds
        let p = CGPoint(x: x, y: y)
        s.cursor.position = p
        s.engine.onTapEvent(p: p, dx: 0, dy: dy, buttonsDown: false, eventNs: ns)
        return ns
    }

    @Test func fakeLogSourceDrivesAUCSourcedCrossingEndToEnd() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await UTRig.pair(dir: dir, vmStart: CGPoint(x: -700, y: 400), mbStart: CGPoint(x: -600, y: -700))
        defer { mb.engine.stop(); vm.engine.stop() }
        mb.engine.onPollSample(p: mb.cursor.position, buttonsDown: false)
        // V-Mind's log assist starts and delivers a first line: it advertises ucLogActive.
        vm.engine.ucLogStarted()
        vm.engine.onUCLogEvent(UCLogEvent(kind: .entering, edge: "right", device: "x", displayUUID: UTRig.d3.uuidString,
                                          machTimestamp: 1), receivedNs: DispatchTime.now().uptimeNanoseconds, continuousMinusAbsolute: 0)
        let deadline = monotonicMs() + 2000
        while monotonicMs() < deadline && !mb.engine.snapshot().ucLog.peerActive { await UTRig.ms(10) }
        #expect(mb.engine.snapshot().ucLog.peerActive)

        // Upward push; the model latch would pick −948.46, UC activates on the −950.82 event.
        _ = Self.tap(vm, -955, 21.3, dy: -30); await UTRig.ms(16)
        let activatedOn = Self.tap(vm, -950.82, 0, dy: -30); await UTRig.ms(16)
        _ = Self.tap(vm, -948.46, 0, dy: -20); await UTRig.ms(2)
        vm.engine.onUCLogEvent(Self.activation(on: activatedOn), receivedNs: DispatchTime.now().uptimeNanoseconds,
                               continuousMinusAbsolute: 0)
        await UTRig.ms(10)
        let land = monotonicMs()
        mb.cursor.position = .zero
        await UTRig.ms(100)
        let w = try #require(mb.cursor.warpLog.first { $0.t >= land })
        #expect(abs(Double(w.p.x) - UTRig.vmToMb(-950.82)) < 0.01, "UC's x, not the model latch's")
        let s = mb.engine.snapshot()
        #expect(s.lastCorrections.last?.crossSource == "uc")
        let v = vm.engine.snapshot()
        #expect(v.counters.ucCross == 1 && v.ucLog.matched == 1 && v.ucLog.active)
        vm.engine.log.flush()
        #expect(try String(contentsOfFile: vm.engine.config.logPath, encoding: .utf8).contains("uccross x=-950.82"))
    }

    @Test func activePeerAssistWaitsBrieflyThenUsesTheModelCrossX() async throws {
        // v1.3.1 (F2): a model-latched packet from a peer whose assist is active waits up to
        // ucWaitMs (25 ms) for a UC-sourced one, then corrects with the model crossX.
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cursor = UTThreadAwareCursor(CGPoint(x: -600, y: -700))
        let (mb, raw) = try UTRig.macbookWithRawPeer(dir: dir, cursor: cursor)
        defer { mb.engine.stop(); raw.socket.shutdownAndClose() }
        raw.send(.hello(HelloPayload(version: "1.3.1", side: .top, displays: [], axTrusted: true, ucLogActive: true)),
                 to: mb.socket.port)
        mb.engine.onPollSample(p: cursor.position, buttonsDown: false)
        await UTRig.ms(100)
        raw.send(.edge(EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: 0, crossSource: .model)),
                 to: mb.socket.port)
        await UTRig.ms(20)
        let land = monotonicMs()
        cursor.position = .zero
        mb.engine.onPollSample(p: .zero, buttonsDown: false)
        await UTRig.ms(10)
        #expect(cursor.warpLog.isEmpty, "still waiting for UC's crossX")
        await UTRig.ms(60)
        let w = try #require(cursor.warpLog.first)
        #expect(w.p == CGPoint(x: -1280, y: -2))
        #expect(w.t - land >= 24 && w.t - land <= 40, "fired at the end of the 25 ms wait: \(w.t - land) ms")
        #expect(mb.engine.snapshot().lastCorrections.last?.crossSource == "model")
    }

    @Test func correctionsDisabledNeverWarpsButTheDeadStripStillRedirects() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = try UTRawPeer()
        var side = try UTRig.side(macbook: false, cursor: UTThreadAwareCursor(CGPoint(x: 300, y: 500)),
                                  peerPort: raw.socket.port, dir: dir, deadStrip: true)
        var c = side.engine.config
        c.corrections.enabled = false
        side = UTRig.Side(engine: Engine(config: c, key: UTRig.key, env: side.engine.env, log: side.engine.log),
                          cursor: side.cursor, socket: side.socket)
        try side.engine.start(tapActive: true, socket: side.socket)
        defer { side.engine.stop(); raw.socket.shutdownAndClose() }
        raw.send(.hello(HelloPayload(version: "1.3.0", side: .bottom,
                                     displays: [EdgeDisplayInfo(uuid: UTRig.d3, minX: -2560, width: 2560)], axTrusted: true)),
                 to: side.socket.port)
        side.engine.onPollSample(p: side.cursor.position, buttonsDown: false)
        await UTRig.ms(100)
        // A fresh latched MacBook packet, then UC lands V-Mind at (1599, 0): no correction.
        raw.send(.edge(EdgePayload(x: -750.78, d: 0, pushing: true, spanMin: -2560, spanMax: 0, crossX: -750.78, crossSource: .uc)),
                 to: side.socket.port)
        await UTRig.ms(20)
        side.cursor.position = CGPoint(x: 1599, y: 0)
        side.engine.onPollSample(p: CGPoint(x: 1599, y: 0), buttonsDown: false)
        raw.send(.edge(EdgePayload(x: -750.78, d: 0, pushing: true, spanMin: -2560, spanMax: 0, crossX: -750.78, crossSource: .uc)),
                 to: side.socket.port)
        await UTRig.ms(100)
        #expect(side.cursor.warpLog.isEmpty, "no landing correction, immediate or late")
        #expect(!side.engine.snapshot().correctionsEnabled)
        // The dead-strip redirect still runs.
        await UTRig.ms(400)
        var prev = CGPoint(x: -1599, y: 0)
        side.cursor.position = prev
        side.engine.onTapEvent(p: prev, dx: 0, dy: -40, buttonsDown: false)
        for _ in 0..<30 {
            await UTRig.ms(16)
            prev = side.cursor.position
            if prev.x > -1000 { break }
            side.engine.onTapEvent(p: prev, dx: 0, dy: -2, buttonsDown: false)
        }
        #expect(side.cursor.warpLog.first?.p == CGPoint(x: -959, y: 0))
    }

    @Test func activationForAnotherEdgeOrDisplayIsIgnoredByTheEngine() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await UTRig.pair(dir: dir, vmStart: CGPoint(x: -700, y: 400), mbStart: CGPoint(x: -600, y: -700))
        defer { mb.engine.stop(); vm.engine.stop() }
        vm.engine.ucLogStarted()
        let ns = Self.tap(vm, 1599, 0, dy: -1)
        let now = DispatchTime.now().uptimeNanoseconds
        vm.engine.onUCLogEvent(Self.activation(on: ns, edge: "right"), receivedNs: now, continuousMinusAbsolute: 0)
        vm.engine.onUCLogEvent(Self.activation(on: ns, display: UUID(uuidString: "3C000000-0000-4000-8000-0000000000C1")!),
                               receivedNs: now, continuousMinusAbsolute: 0)
        vm.engine.onUCLogEvent(Self.activation(on: ns - 3_000_000_000), receivedNs: now, continuousMinusAbsolute: 0)
        let u = vm.engine.snapshot().ucLog
        #expect(u.ignored == 2 && u.clockErrors == 1 && u.matched == 0)
    }
}
