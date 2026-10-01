import CoreGraphics
import Foundation
import Testing
import UCEdgeCore

/// SPEC §13 UC log assist: crossX = x of the latest at-edge tap event at or before UC's
/// "Hot Zone: Activating" line. Checked on s3 (exact CGEvent and log timestamps) and on s2 (UC log
/// wall ms mapped with groundtruth.py's alignment). Validation numbers: Support/ucassist.py.
@Suite("Trace replay: UC log assist")
struct TraceReplayUCLogTests {
    static let windowNs = 100e6

    // MARK: - Independent model

    @Test("model: s3 V-Mind top crossings give UC's x exactly (539.41, 1313.00)")
    func modelS3VMind() throws {
        let s3 = try UCLogTrace.load("s3-vmind-uclog.txt")
        let events = s3.taps.map { (t: $0.eventNs, p: $0.p) }
        let acts = s3.activations.filter { $0.edge == "top" && $0.display == UCLogTrace.macbookDisplay3 }
        #expect(acts.count == 2)
        var got: [Double] = []
        for a in acts {
            // V-Mind had not slept: continuous == uptime.
            let x = try #require(UCAssistModel.crossX(events: events, at: a.line.continuousNs, side: .top, edgeY: 0, window: Self.windowNs))
            let uc = try #require(s3.ucExitX(after: a.line, edge: "top", display: a.display))
            #expect(abs(x - uc) < 0.005, "Activating \(a.line.wall): matched \(x), UC used \(uc)")
            got.append(x)
        }
        #expect(got == [539.41, 1313.00])
    }

    @Test("model: s3 MacBook bottom crossing with the derived continuous offset")
    func modelS3MacBook() throws {
        let s3 = try UCLogTrace.load("s3-macbook-uclog.txt")
        let offset = try #require(s3.derivedContinuousOffsetNs())
        #expect(abs(offset / 1e9 - 12_711.19) < 0.01, "derived offset \(offset / 1e9) s")
        let events = s3.taps.map { (t: $0.eventNs, p: $0.p) }
        let acts = s3.activations.filter { $0.edge == "bottom" }
        #expect(acts.count == 1)
        for a in acts {
            let x = try #require(UCAssistModel.crossX(events: events, at: a.line.continuousNs - offset, side: .bottom, edgeY: 0, window: Self.windowNs))
            let uc = try #require(s3.ucExitX(after: a.line, edge: "bottom", display: a.display))
            #expect(abs(x - uc) < 0.005 && abs(x - -199.09) < 0.005, "matched \(x), UC used \(uc)")
        }
    }

    @Test("model: s2, every top/bottom crossing's Activating time gives UC's x")
    func modelS2() throws {
        let gt = try TraceKit.loadGroundTruth()
        let vm = try TraceKit.loadTrace("s2-vmind.txt").taps, mb = try TraceKit.loadTrace("s2-macbook.txt").taps
        for c in gt.crossings where c.direction == "up" || c.direction == "down" {
            let up = c.direction == "up"
            let at = try #require(c.activatingSourceT), exitX = try #require(c.exitX)
            let events = (up ? vm : mb).map { (t: $0.t, p: $0.p) }
            let x = UCAssistModel.crossX(events: events, at: at, side: up ? .top : .bottom, edgeY: 0, window: 100)
            #expect(x == exitX, "\(c.id): matched \(String(describing: x)), UC used \(exitX)")
        }
    }

    // MARK: - Implementation (UCEdgeCore v1.3)

    static let clock = UCLogClock(numer: 125, denom: 3)
    static let vmindDisplays = [UCLogTrace.vmindMonitor5, UCLogTrace.vmindMonitor4].compactMap(UUID.init(uuidString:))
    static let macbookDisplays = [UCLogTrace.macbookDisplay3].compactMap(UUID.init(uuidString:))

    /// Replays an s3 recording through UCLogParser, UCLogFilter, UCLogClock and UCCrossMatcher in the
    /// order the engine sees things: taps and log lines by receive time.
    func implementationMatches(_ s3: UCLogTrace, side: EdgeSide, peerDisplays: [UUID], offsetNs: Double)
        -> (activations: Int, matches: [(line: UCLogTrace.Line, x: Double?, sane: Bool)]) {
        enum Item { case tap(UCLogTrace.Tap), line(UCLogTrace.Line) }
        let items = (s3.taps.map { ($0.rxNs, Item.tap($0)) } + s3.lines.map { ($0.rxNs, Item.line($0)) })
            .enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        let matcher = UCCrossMatcher()
        let offsetTicks = UInt64((offsetNs * 3 / 125).rounded())
        var activations = 0
        var out: [(line: UCLogTrace.Line, x: Double?, sane: Bool)] = []
        for item in items {
            switch item {
            case .tap(let e):
                let s = side == .top ? Double(e.p.y) : -Double(e.p.y)
                matcher.record(UCTapRecord(ns: UInt64(e.eventNs), x: e.p.x, y: e.p.y, s: s, dy: e.dy))
            case .line(let l):
                guard let ev = UCLogParser.parse(message: l.message, machTimestamp: l.machTicks), ev.kind == .activating else { continue }
                activations += 1
                guard UCLogFilter.accepts(ev, localSide: side, peerDisplays: peerDisplays),
                      let ns = Self.clock.uptimeNs(machContinuous: l.machTicks, continuousMinusAbsolute: offsetTicks) else { continue }
                out.append((l, matcher.match(activationNs: ns)?.x, UCLogClock.lagIsSane(eventNs: ns, nowNs: UInt64(l.rxNs))))
            }
        }
        return (activations, out)
    }

    @Test("implementation: s3 V-Mind gives 539.41 and 1313.00; the side-link Activating line is filtered out")
    func implS3VMind() throws {
        let s3 = try UCLogTrace.load("s3-vmind-uclog.txt")
        let r = implementationMatches(s3, side: .top, peerDisplays: Self.macbookDisplays, offsetNs: 0)
        #expect(r.activations == 3, "two top crossings and one right: side-link line")
        #expect(r.matches.map(\.x) == [539.41, 1313.00], "\(r.matches.map(\.x))")
        let sane = r.matches.filter { $0.sane }.count
        #expect(sane == r.matches.count, "receive lag within [-5 ms, 2 s]")
    }

    @Test("implementation: s3 MacBook bottom crossing (derived offset) gives -199.09; the left: line is filtered out")
    func implS3MacBook() throws {
        let s3 = try UCLogTrace.load("s3-macbook-uclog.txt")
        let offset = try #require(s3.derivedContinuousOffsetNs())
        let r = implementationMatches(s3, side: .bottom, peerDisplays: Self.vmindDisplays, offsetNs: offset)
        #expect(r.activations == 2)
        #expect(r.matches.count == 1 && r.matches.first?.x == -199.09, "\(r.matches.map(\.x))")
        let sane = r.matches.filter { $0.sane }.count
        #expect(sane == r.matches.count, "receive lag within [-5 ms, 2 s]")
        #expect(implementationMatches(s3, side: .bottom, peerDisplays: Self.macbookDisplays, offsetNs: offset).matches.isEmpty,
                "an Activating line toward a foreign display is ignored")
    }

    @Test("implementation: UCCrossMatcher gives UC's x at every s2 top/bottom crossing")
    func implS2() throws {
        let gt = try TraceKit.loadGroundTruth()
        let vm = try TraceKit.loadTrace("s2-vmind.txt").taps, mb = try TraceKit.loadTrace("s2-macbook.txt").taps
        for c in gt.crossings where c.direction == "up" || c.direction == "down" {
            let up = c.direction == "up"
            let matcher = UCCrossMatcher()
            let at = try #require(c.activatingSourceT)
            for e in (up ? vm : mb) where e.t <= at + 50 {
                let s = up ? Double(e.p.y) : -Double(e.p.y)
                matcher.record(UCTapRecord(ns: UInt64((e.t + 1e6) * 1e6), x: e.p.x, y: e.p.y, s: s, dy: e.dy))
            }
            let x = matcher.match(activationNs: UInt64((at + 1e6) * 1e6))?.x
            #expect(x == c.exitX, "\(c.id): matched \(String(describing: x)), UC used \(String(describing: c.exitX))")
        }
    }

    // 0-40 ms network delay; the log line is read 1 ms after UC writes it (measured 0.3-2.5 ms).
    @Test("implementation: s2 MacBook replay with UC-sourced crossX: each upward crossing once, exact", arguments: TraceReplayTests.delays)
    func implS2Replay(delayMs: Double) throws {
        let gt = try TraceKit.loadGroundTruth()
        let mb = try TraceKit.loadTrace("s2-macbook.txt"), vm = try TraceKit.loadTrace("s2-vmind.txt")
        let ups = gt.crossings.filter { $0.direction == "up" }
        let (packets, matched) = SpecSender.vmind.ucLogPackets(from: vm.taps, activations: ups.compactMap(\.activatingSourceT), logLagMs: 1,
                                                                toReceiverMs: gt.alignment.vmindToMacbookMs, delayMs: delayMs)
        for c in ups { #expect(matched[c.activatingSourceT ?? 0] == c.exitX, "\(c.id): UC-sourced crossX \(String(describing: matched[c.activatingSourceT ?? 0]))") }
        let resets = gt.crossings.filter { $0.direction.hasSuffix("up") }.map(\.landingT)
        let got = replayReceiver(samples: mb.samples, packets: packets, geometry: Desk.macbook, screens: Desk.macbookScreens, shiftResets: resets)
        print("[UC log assist, MacBook receiver, +\(Int(delayMs)) ms] " + got.map(\.description).joined(separator: " | "))
        for c in ups {
            let mine = got.filter { TraceReplayTests.window(c.landingT).contains($0.t) }
            #expect(mine.count == 1, "\(c.id): \(mine)")
            if let r = mine.first, let want = c.expectedTargetX {
                #expect(abs(r.correction.target.x - want) <= 5 && r.correction.peerX == c.exitX, "\(c.id): \(r) want x \(want)")
            }
        }
        let stray = got.filter { r in !ups.contains { TraceReplayTests.window($0.landingT).contains(r.t) } }
        #expect(stray.isEmpty, "corrections outside the crossings: \(stray)")
    }

    // MARK: - Synthetic

    @Test("matcher: MacBook events 4 ms apart pick the right event around the Activating time")
    func matcher4ms() {
        let m = UCCrossMatcher()
        let base: UInt64 = 5_000_000_000
        // 40 events 4 ms apart sliding down onto the bottom edge; at the edge from event 20 on.
        var events: [(ns: UInt64, x: Double, y: Double)] = []
        for i in 0..<40 {
            let f = Double(i)
            events.append((base + UInt64(i) * 4_000_000, -700 - 3 * f, min(-0.02, -60 + 3 * f)))
        }
        for e in events { m.record(UCTapRecord(ns: e.ns, x: e.x, y: e.y, s: -e.y, dy: 3)) }
        let k = 30
        #expect(m.match(activationNs: events[k].ns + 500_000)?.x == events[k].x, "0.5 ms after event k")
        #expect(m.match(activationNs: events[k].ns)?.x == events[k].x, "at event k's timestamp (<=)")
        #expect(m.match(activationNs: events[k].ns - 1_000)?.x == events[k - 1].x, "1 us before event k: the one 4 ms earlier")
        #expect(m.match(activationNs: events[19].ns + 500_000) == nil, "no at-edge event yet (s = 3)")
        #expect(m.match(activationNs: events[39].ns + 100_000_001) == nil, "older than 100 ms")

        // A later event off the edge doesn't count: the latest at-edge one does.
        m.record(UCTapRecord(ns: events[39].ns + 4_000_000, x: -900, y: -5, s: 5, dy: -5))
        #expect(m.match(activationNs: events[39].ns + 4_500_000)?.x == events[39].x)
    }

    @Test("matcher keeps about 2 s of events")
    func matcherBuffer() {
        let m = UCCrossMatcher()
        for i in 0..<1000 { m.record(UCTapRecord(ns: UInt64(i) * 4_000_000, x: Double(i), y: 0, s: 0, dy: 1)) }  // 4 s
        #expect(m.count <= 502 && m.count >= 490, "\(m.count) events kept")
    }

    @Test("filter: only Activating lines for our shared edge toward the peer's edge displays")
    func filter() throws {
        let mbUUID = UCLogTrace.macbookDisplay3
        func accepts(_ msg: String, side: EdgeSide = .top, peer: [UUID] = Self.macbookDisplays) -> Bool {
            guard let e = UCLogParser.parse(message: msg, machTimestamp: 1) else { return false }
            return UCLogFilter.accepts(e, localSide: side, peerDisplays: peer)
        }
        #expect(accepts("Hot Zone: Activating: top:31000000:\(mbUUID)"))
        #expect(!accepts("Hot Zone: Activating: right:31000000:3C000000-0000-4000-8000-0000000000C1"), "side link")
        #expect(!accepts("Hot Zone: Activating: top:31000000:\(mbUUID)", side: .bottom), "not our edge")
        #expect(!accepts("Hot Zone: Activating: top:31000000:\(mbUUID)", peer: Self.vmindDisplays), "foreign display")
        #expect(!accepts("Hot Zone: Entering: top:31000000:\(mbUUID):[-961.0 0.0 1600.0 1.0]:guarded=false"), "Entering")
        #expect(UCLogParser.parse(message: "Hide cursor 552707", machTimestamp: 1) == nil)
    }

    @Test("clock: continuous ticks to uptime ns, and the receive-lag sanity bounds")
    func clock() throws {
        // s3 MacBook, UC's Activating line: 1729047132862 ticks, continuous - absolute ~ 12 711.1958 s.
        let offTicks: UInt64 = 305_068_700_000   // 12 711.195833 s at 125/3
        let ns = try #require(Self.clock.uptimeNs(machContinuous: 1_729_047_132_862, continuousMinusAbsolute: offTicks))
        let want = (1_729_047_132_862 - offTicks) * 125 / 3
        #expect(max(ns, want) - min(ns, want) <= 1, "\(ns) vs \(want)")
        #expect(Self.clock.uptimeNs(machContinuous: 10, continuousMinusAbsolute: 11) == nil, "offset larger than the stamp")
        let now: UInt64 = 10_000_000_000
        #expect(UCLogClock.lagIsSane(eventNs: now - 2_000_000_000, nowNs: now))
        #expect(!UCLogClock.lagIsSane(eventNs: now - 2_000_000_001, nowNs: now))
        #expect(UCLogClock.lagIsSane(eventNs: now + 5_000_000, nowNs: now))
        #expect(!UCLogClock.lagIsSane(eventNs: now + 5_000_001, nowNs: now))
    }

    @Test("hold: a UC-sourced crossX stays for the tail, with the latch's reset rules")
    func hold() {
        /// As in the engine: the activating tap event goes through onEvent before its log line sets the hold.
        func held(_ x: Double) -> UCCrossHold {
            var h = UCCrossHold()
            h.onEvent(t: -0.5, s: 0)
            h.set(x, at: 0)
            return h
        }
        var h = held(539.41)
        #expect(h.onEvent(t: 16, s: 0) == 539.41 && h.onEvent(t: 66, s: 8) == 539.41 && h.onEvent(t: 140, s: 0) == 539.41, "tail")
        #expect(h.onEvent(t: 151, s: 0) == nil, "150 ms after it was set")
        var g = held(1)
        #expect(g.onEvent(t: 10, s: 0) == 1)
        #expect(g.onEvent(t: 111, s: 0) == nil, "gap over 100 ms")
        var d = held(1)
        #expect(d.onEvent(t: 10, s: 31) == nil, "more than 30 pt from the edge")
        var b = held(1)
        #expect(b.onEvent(t: 10, s: -1.5) == nil, "beyond the edge")
    }

    @Test("receiver preference: with the peer's log assist active only UC-sourced crossX counts")
    func policy() {
        #expect(CrossSourcePolicy.usableCrossX(5, source: .uc, peerUCLogActive: true) == 5)
        #expect(CrossSourcePolicy.usableCrossX(5, source: .model, peerUCLogActive: true) == nil)
        #expect(CrossSourcePolicy.usableCrossX(5, source: .model, peerUCLogActive: false) == 5, "fallback to the v1.2 latch")
        #expect(CrossSourcePolicy.usableCrossX(nil, source: .uc, peerUCLogActive: true) == nil)
    }

    @Test("dead strip: a UC Activating at the redirect point is replaced by the original x, once, within 1 s and 5 pt")
    func deadStripUC() throws {
        func redirected() throws -> (DeadStripDetector, Double) {
            var p = DeadStripParams()
            p.enabled = true
            let det = DeadStripDetector(params: p)
            for i in 0..<30 {
                let t = Double(i) * 20
                if det.onEvent(t: t, p: CGPoint(x: -1590, y: 0), dy: -2, prevWasPinned: true, buttonsDown: false,
                               geometry: Desk.vmind, zoneMinX: -961, zoneMaxX: 1600) != nil { return (det, t) }
            }
            throw CancellationError()
        }
        let (a, t0) = try redirected()
        #expect(a.consumeRedirect(latchT: t0 + 40, latchX: -957) == -1590, "the model latch has its own copy")
        #expect(a.consumeRedirectForUC(t: t0 + 500, latchX: -957) == -1590)
        #expect(a.consumeRedirectForUC(t: t0 + 510, latchX: -957) == nil, "consumed")
        let (b, t1) = try redirected()
        #expect(b.consumeRedirectForUC(t: t1 + 1001, latchX: -957) == nil, "stale")
        let (c, t2) = try redirected()
        #expect(c.consumeRedirectForUC(t: t2 + 100, latchX: -900) == nil, "59 pt from the redirect point")
    }
}
