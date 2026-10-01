import CoreGraphics
import Foundation
import Testing
import UCEdgeCore

/// SPEC §10 item 4: replay the recorded sessions through the detectors. The receivers run with the
/// v1.2 peer-episode rule on (§12): each packet carries episodeStart as the engine derives it.
/// Ground truth (crossings, alignment) comes from Support/groundtruth.py -> Support/s2-crossings.json.
@Suite("Trace replay")
struct TraceReplayTests {
    /// A correction belongs to a crossing if it happens between the UC landing sample and the end
    /// of the late window.
    static func window(_ landingT: Double, params: DetectorParams = .init()) -> ClosedRange<Double> {
        (landingT - 0.6)...(landingT + params.lateWindowMs + 1)
    }

    // MARK: - s2, MacBook receives upward crossings

    /// 2 ms is the real one-way LAN latency (RTT ~5 ms), 5 ms the spec's replay delay; from ~20 ms the
    /// late path takes over. Before crossX, 0-3 ms put U3 105 pt off (post-crossing tail packets won
    /// the race) and 20-40 ms put D2 19 pt and U3 50 pt off (see latchrules.py).
    static let delays: [Double] = [0, 2, 5, 10, 20, 30, 40]

    @Test("s2: MacBook corrects each upward crossing once, nothing else", arguments: delays)
    func s2MacBookReceiver(delayMs: Double) throws {
        let gt = try TraceKit.loadGroundTruth()
        let mb = try TraceKit.loadTrace("s2-macbook.txt")
        let vm = try TraceKit.loadTrace("s2-vmind.txt")
        let packets = SpecSender.vmind.packets(from: vm.taps, toReceiverMs: gt.alignment.vmindToMacbookMs, delayMs: delayMs)
        let arrivals = gt.crossings.filter { $0.direction == "up" || $0.direction == "side-up" }
        let got = replayReceiver(samples: mb.samples, packets: packets, geometry: Desk.macbook,
                                 screens: Desk.macbookScreens, shiftResets: arrivals.map(\.landingT))
        try checkReceiver(side: "MacBook", delayMs: delayMs, got: got,
                          expected: gt.crossings.filter { $0.direction == "up" },
                          packets: packets, samples: mb.samples, geometry: Desk.macbook,
                          peerSpan: Desk.vmindSpan, localSpan: Desk.macbookSpan)
    }

    // MARK: - s2, V-Mind receives downward crossings

    @Test("s2: V-Mind corrects each downward crossing once, nothing else", arguments: delays)
    func s2VMindReceiver(delayMs: Double) throws {
        let gt = try TraceKit.loadGroundTruth()
        let mb = try TraceKit.loadTrace("s2-macbook.txt")
        let vm = try TraceKit.loadTrace("s2-vmind.txt")
        let packets = SpecSender.macbook.packets(from: mb.taps, toReceiverMs: -gt.alignment.vmindToMacbookMs, delayMs: delayMs)
        let arrivals = gt.crossings.filter { $0.direction == "down" || $0.direction == "side-down" }
        let got = replayReceiver(samples: vm.samples, packets: packets, geometry: Desk.vmind,
                                 screens: Desk.vmindScreens, shiftResets: arrivals.map(\.landingT))
        // S3 (side link from the MacBook's (0,0) corner) lands at V-Mind (1599, 0) right after
        // MacBook packets at d = 0, x = 0.74. They never latch (no push into the bottom edge),
        // so the V-Mind must leave that landing alone.
        try checkReceiver(side: "V-Mind", delayMs: delayMs, got: got,
                          expected: gt.crossings.filter { $0.direction == "down" },
                          packets: packets, samples: vm.samples, geometry: Desk.vmind,
                          peerSpan: Desk.macbookSpan, localSpan: Desk.vmindSpan)
    }

    private func checkReceiver(side: String, delayMs: Double, got: [ReplayedCorrection],
                               expected: [GroundTruth.Crossing],
                               packets: [SynthPacket], samples: [TraceSample], geometry: EdgeGeometry,
                               peerSpan: (min: Double, max: Double), localSpan: (min: Double, max: Double)) throws {
        let tag = "\(side) receiver, +\(Int(delayMs)) ms"
        print("[\(tag)] \(got.count) corrections:\n  " + got.map(\.description).joined(separator: "\n  "))
        #expect(expected.count >= 3, "fixture should list the s2 crossings")

        for c in expected {
            let mine = got.filter { Self.window(c.landingT).contains($0.t) }
            #expect(mine.count == 1, "\(tag) \(c.id) @\(c.wall): want exactly 1 correction, got \(mine)")
            guard let r = mine.first else { continue }
            let t = r.correction.target
            let exitX = try #require(c.exitX), physical = try #require(c.expectedTargetX)

            #expect(abs(r.correction.landing.x - c.landingX) <= 0.01 && abs(r.correction.landing.y - c.landingY) <= 0.01,
                    "\(tag) \(c.id): landing should be UC's landing \(c.landing), got \(r.correction.landing)")
            #expect(geometry.displays.contains { $0.contains(t) }, "\(tag) \(c.id): target \(t) is not on an edge display")
            let inset = geometry.side == .top ? Double(t.y) - geometry.edgeY : geometry.edgeY - Double(t.y)
            #expect(inset >= 2 - 0.01 && inset <= 30.01, "\(tag) \(c.id): target \(t) must sit 2...30 pt inside the edge")

            // The exact §5.4 outcome for these packets (which path, which peer x).
            let spec = try #require(SpecExpectation.at(landingT: c.landingT, landing: c.landing, packets: packets, samples: samples,
                                                       peerSpan: peerSpan, localSpan: localSpan),
                                    "\(tag) \(c.id): no fresh at-edge packet near the landing; replay setup is wrong")
            #expect(r.correction.kind == spec.kind, "\(tag) \(c.id): expected \(spec), got \(r)")
            #expect(abs(r.correction.peerX - spec.peerX) <= 0.01, "\(tag) \(c.id): expected \(spec), got \(r)")
            #expect(abs(t.x - spec.targetX) <= 0.6, "\(tag) \(c.id): expected \(spec), got \(r)")

            // Physical truth: the x UC itself used to cross (SPEC §10: within 5 pt), at every latency.
            #expect(abs(t.x - physical) <= 5, "\(tag) \(c.id): target x \(t.x) vs physicalMap(exit x \(exitX)) = \(physical)")
        }

        let stray = got.filter { r in !expected.contains { Self.window($0.landingT).contains(r.t) } }
        #expect(stray.isEmpty, "\(tag): corrections outside any real crossing: \(stray)")
        #expect(!got.contains { $0.correction.kind == .snapback }, "\(tag): no snap-back in this data (our warps stick)")
    }

    // MARK: - s1, MacBook only: no false positives while working on the MacBook

    @Test("s1: corrections only at the six V-Mind exits", arguments: [false, true])
    func s1NoFalsePositives(busyPeerNotLatched: Bool) throws {
        let gt = try TraceKit.loadGroundTruth()
        let s1 = try TraceKit.loadTrace("s1-macbook-landtest.txt")
        let crossings = gt.s1.crossings
        #expect(crossings.count == 6)

        func pkt(_ t: Double, x: Double, d: Double, crossX: Double? = nil) -> SynthPacket {
            SynthPacket(sendT: t - 5, arriveT: t, x: x, d: d, pushing: d == 0, spanMin: -1600, spanMax: 1600, crossX: crossX, lagMs: 5)
        }
        // Around each exit, at ~60 Hz (v1.1 sends only at the edge or latched): the event that enters
        // UC's zone (arms the latch), UC's exit event ~16 ms before the landing (latches), and the tail.
        var packets = crossings.flatMap { c in
            [(-33.0, 0.0, -1.5, false), (-16, 0, 0, true), (1, 0, 1, true), (17, 3, 2, true)]
                .map { pkt(c.landingT + $0.0, x: c.specExitX + $0.2, d: $0.1, crossX: $0.3 ? c.specExitX : nil) }
        }
        if busyPeerNotLatched {
            // V-Mind pushing at its top edge all session without UC crossing (like the dead strip):
            // fresh at-edge packets that never latch, except around the real exits.
            let end = try #require(s1.samples.last).t
            for t in stride(from: 0.0, to: end, by: 16.7) where !crossings.contains(where: { abs($0.landingT - t) < 400 }) {
                packets.append(pkt(t, x: -1590, d: 0))
            }
        }
        packets.sort { $0.arriveT < $1.arriveT }

        let resets = crossings.map(\.landingT) + gt.s1.otherJumps.map(\.t) + s1.warpTimes
        let got = replayReceiver(samples: s1.samples, packets: packets, geometry: Desk.macbook,
                                 screens: Desk.macbookScreens, shiftResets: resets)
        print("[s1 busyPeerNotLatched=\(busyPeerNotLatched)] \(got.count) corrections:\n  " + got.map(\.description).joined(separator: "\n  "))

        for c in crossings {
            let mine = got.filter { Self.window(c.landingT).contains($0.t) }
            #expect(mine.count == 1, "s1 exit \(c.specExitX) @\(c.wall): want exactly 1 correction, got \(mine)")
            if let r = mine.first {
                #expect(r.correction.kind == .immediate, "s1 exit \(c.specExitX): \(r)")
                #expect(abs(r.correction.target.x - Desk.clampTargetX(c.expectedTargetX, span: Desk.macbookSpan)) <= 0.6,
                        "s1 exit \(c.specExitX): want x \(c.expectedTargetX), got \(r)")
            }
        }
        // The recorder's own WARPs move the cursor; ignore the ~300 ms after each.
        let stray = got.filter { r in
            !crossings.contains { Self.window($0.landingT).contains(r.t) } && !s1.warpTimes.contains { (($0)...($0 + 300)).contains(r.t) }
        }
        #expect(stray.isEmpty, "s1: corrections while working on the MacBook: \(stray)")
    }

    // MARK: - Dead strip on s2 V-Mind

    @Test("s2: dead-strip detector fires once, during the push burst")
    func deadStripS2() throws {
        let gt = try TraceKit.loadGroundTruth()
        let vm = try TraceKit.loadTrace("s2-vmind.txt")
        var params = DeadStripParams()
        params.enabled = true
        let det = DeadStripDetector(params: params)

        var redirects: [(t: Double, to: CGPoint, from: CGPoint)] = []
        var prevPinned = false
        for e in vm.taps {
            if let to = det.onEvent(t: e.t, p: e.p, dy: e.dy, prevWasPinned: prevPinned, buttonsDown: e.buttonsDown,
                                    geometry: Desk.vmind, zoneMinX: -961, zoneMaxX: 1600) {
                redirects.append((e.t, to, e.p))
                let vx = det.virtualX(at: e.t + 999)
                #expect(vx != nil && abs(vx! - e.p.x) <= 0.01, "virtualX should hold the original x \(e.p.x) for 1000 ms, got \(String(describing: vx))")
                #expect(det.virtualX(at: e.t + 1001) == nil, "virtualX must expire after virtualXValidMs")
            }
            prevPinned = e.p.y <= 0.5
        }
        print("[dead strip] redirects: \(redirects)")

        #expect(redirects.count == 1, "want exactly one redirect, got \(redirects)")
        if let r = redirects.first {
            #expect((139_600.0...141_300.0).contains(r.t), "redirect at \(r.t) is outside the push burst")
            // Sustained push only: >= 180 ms of pinned pushes (the old 24 pt/400 ms rule fired 34 ms in,
            // on arrival momentum). The agreed rule fires at 139852.2.
            #expect(r.t >= gt.deadStrip.startT + 180, "redirect at \(r.t) came before 180 ms of pushing")
            #expect(abs(r.to.x - gt.deadStrip.expectedRedirectX) <= 0.5 && abs(r.to.y) <= 0.5,
                    "redirect should be (zoneMinX + 2, edgeY) = (-959, 0), got \(r.to)")
            #expect(r.from.x < -961, "redirect must come from the dead part, came from \(r.from)")
        }
        // The trace has plenty of in-zone top-edge events (all the upward crossings), none may fire.
        #expect(vm.taps.filter { $0.p.y <= 0.5 && $0.p.x >= -961 }.count >= 15)
    }

    // MARK: - The crossX latch reproduces UC's exit x

    @Test("CrossLatch agrees with the independent latch model on every s2 tap event")
    func crossLatchMatchesModel() throws {
        for (name, trace, sender) in [("V-Mind", "s2-vmind.txt", SpecSender.vmind), ("MacBook", "s2-macbook.txt", SpecSender.macbook)] {
            let taps = try TraceKit.loadTrace(trace).taps
            let builder = sender.latched(taps, by: .builder), model = sender.latched(taps, by: .model)
            let diffs = taps.indices.filter { builder[$0] != model[$0] }
            #expect(diffs.isEmpty, "\(name): \(diffs.count) events differ, first at t=\(diffs.first.map { taps[$0].t } ?? 0): builder \(diffs.first.map { String(describing: builder[$0]) } ?? "") vs model \(diffs.first.map { String(describing: model[$0]) } ?? "")")
        }
    }

    @Test("sender latch: crossX = UC's exit x at every s2 crossing, stable through the tail",
          arguments: [SpecSender.Latch.builder, .model])
    func senderLatchMatchesUC(latch: SpecSender.Latch) throws {
        let gt = try TraceKit.loadGroundTruth()
        let vm = try TraceKit.loadTrace("s2-vmind.txt").taps, mb = try TraceKit.loadTrace("s2-macbook.txt").taps
        let fromVM = SpecSender.vmind.latched(vm, by: latch), fromMB = SpecSender.macbook.latched(mb, by: latch)
        for c in gt.crossings where c.direction == "up" || c.direction == "down" {
            let exitX = try #require(c.exitX), exitT = try #require(c.exitT)
            let (taps, crossX) = c.direction == "up" ? (vm, fromVM) : (mb, fromMB)
            let i = try #require(taps.firstIndex { abs($0.t - exitT) < 0.05 }, "\(c.id): no TAP at UC's exit event")
            #expect(crossX[i] == exitX, "\(c.id): latched \(String(describing: crossX[i])) at UC's exit event, UC used \(exitX)")
            // Nothing latched in the 150 ms before UC's exit event; the tail (up to ~100 ms) keeps UC's x.
            #expect(!taps.indices.contains { taps[$0].t < exitT && taps[$0].t > exitT - 150 && crossX[$0] != nil }, "\(c.id): latched too early")
            let tail = taps.indices.filter { taps[$0].t > exitT && taps[$0].t <= exitT + 150 }
            #expect(tail.allSatisfy { crossX[$0] == exitX }, "\(c.id): tail changed crossX: \(tail.map { crossX[$0] })")
        }
        // At the edge without crossing: the dead-strip push (outside UC's zone) and the menu-bar pass at
        // d = 1.16 (outside UC's 1 pt zone; UC logged no Entering either). Both send packets, unlatched.
        let quiet = SpecSender.vmind.packets(from: vm, toReceiverMs: 0, delayMs: 0, latch: latch)
            .filter { (135_000.0...135_200.0).contains($0.sendT) || (139_000.0...146_500.0).contains($0.sendT) }
        #expect(quiet.count > 50 && quiet.allSatisfy { $0.crossX == nil }, "V-Mind latched where UC did not cross")
    }

    // MARK: - The fixture still describes the recordings

    @Test("ground truth matches the traces and UC's offset formula")
    func groundTruthConsistency() throws {
        let gt = try TraceKit.loadGroundTruth()
        let mb = try TraceKit.loadTrace("s2-macbook.txt")
        let vm = try TraceKit.loadTrace("s2-vmind.txt")
        #expect(abs(gt.alignment.vmindToMacbookMs) < 1000)
        for c in gt.crossings {
            let up = c.direction.hasSuffix("up")
            let dest = up ? mb : vm
            #expect(dest.samples.contains { !$0.isTap && abs($0.t - c.landingT) < 0.05 && abs($0.p.x - c.landingX) < 0.01 && abs($0.p.y - c.landingY) < 0.01 },
                    "\(c.id): no landing sample at \(c.landingT)")
            guard let exitX = c.exitX, let exitT = c.exitT, let target = c.expectedTargetX else { continue }
            let src = up ? vm : mb
            #expect(src.taps.contains { abs($0.t - exitT) < 0.05 && abs($0.p.x - exitX) < 0.011 }, "\(c.id): no exit TAP")
            if up {
                // SPEC §2: V-Mind sends offset = (x + 961) / 961.
                let offset = try #require(c.ucOffset)
                #expect(abs((exitX + 961) / 961 - offset) < 0.0001, "\(c.id): exit x \(exitX) vs UC offset \(offset)")
                #expect(abs(target - Desk.map(exitX, from: Desk.vmindSpan, to: Desk.macbookSpan)) < 0.01)
            } else {
                #expect(abs(target - Desk.map(exitX, from: Desk.macbookSpan, to: Desk.vmindSpan)) < 0.01)
            }
        }
    }
}
