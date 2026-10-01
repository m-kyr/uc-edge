import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

/// Regression tests for the v1.3.1 findings (F1–F6), adapted from the auditor's proofs.
@Suite struct AuditV131CoreTests {
    static func vmPeer(_ source: CrossSource, _ active: Bool, _ t: Double) -> PeerEdgeState {
        PeerEdgeState(x: 500, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, receivedAt: t, crossX: source == .uc ? 480 : 500,
                      crossSource: source, peerUCLogActive: active)
    }

    /// MacBook detector with a frozen cursor since t = 0.
    func mbDetector() -> LandingDetector {
        let d = LandingDetector()
        _ = d.onSample(t: 0, p: CGPoint(x: -600, y: -700), buttonsDown: false, geometry: UTDesk.macbook, peer: nil)
        return d
    }

    // MARK: F1

    @Test func f1OneTickSkewNeverWrapsTheOffset() {
        #expect(UCLogClock.sampleOffset(absolute: 1001, continuous: 1000) == 0)
        #expect(UCLogClock.sampleOffset(absolute: 1000, continuous: 1000) == 0)
        #expect(UCLogClock.sampleOffset(absolute: 1000, continuous: 5000) == 4000)
        // Live: read in the new order, 5000 times.
        for _ in 0..<5000 {
            let a = mach_absolute_time()
            let off = UCLogClock.sampleOffset(absolute: a, continuous: mach_continuous_time())
            #expect(off < UInt64(Int64.max))
        }
    }

    // MARK: F2: wait briefly for UC's crossX, then fall back to the model's

    @Test func f2ModelCrossXWaitsThenCorrects() throws {
        let d = mbDetector()
        let g = UTDesk.macbook
        let peer = Self.vmPeer(.model, true, 995)
        #expect(d.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: peer) == nil, "deferred")
        #expect(d.onSample(t: 1020, p: .zero, buttonsDown: false, geometry: g, peer: peer) == nil, "still waiting at 20 ms")
        let c = try #require(d.onSample(t: 1025, p: .zero, buttonsDown: false, geometry: g, peer: peer))
        #expect(c.source == .model && c.kind == .late && c.landing == .zero)
        #expect(c.target == CGPoint(x: -880, y: -2))
        #expect(d.deferredCount == 1 && d.deferredFallbackCount == 1)
    }

    @Test func f2UCPacketWithinTheWaitWins() throws {
        let d = mbDetector()
        let g = UTDesk.macbook
        _ = d.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: Self.vmPeer(.model, true, 995))
        let c = try #require(d.onPeerUpdate(t: 1010, peer: Self.vmPeer(.uc, true, 1010), current: .zero,
                                            buttonsDown: false, geometry: g))
        #expect(c.source == .uc && c.peerX == 480)
        #expect(d.onSample(t: 1030, p: .zero, buttonsDown: false, geometry: g, peer: Self.vmPeer(.model, true, 995)) == nil,
                "no second correction")
    }

    @Test func f2NeitherMeansNoWarp() {
        let d = mbDetector()
        let g = UTDesk.macbook
        #expect(d.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil)
        for t in stride(from: 1001.0, through: 1200, by: 1) {
            #expect(d.onSample(t: t, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil)
        }
    }

    @Test func f2InactivePeerAssistCorrectsWithTheModelAtOnce() throws {
        let d = mbDetector()
        let c = try #require(d.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: UTDesk.macbook,
                                        peer: Self.vmPeer(.model, false, 995)))
        #expect(c.kind == .immediate && c.source == .model)
    }

    @Test func f2LateModelPacketWaitsUntilTheLandingPlus25() throws {
        let d = mbDetector()
        let g = UTDesk.macbook
        #expect(d.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil)
        #expect(d.onPeerUpdate(t: 1010, peer: Self.vmPeer(.model, true, 1010), current: .zero, buttonsDown: false, geometry: g) == nil)
        let c = try #require(d.onSample(t: 1025, p: .zero, buttonsDown: false, geometry: g, peer: nil))
        #expect(c.source == .model)
        // After the wait, a late model packet corrects at once.
        let d2 = mbDetector()
        #expect(d2.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil)
        #expect(d2.onPeerUpdate(t: 1030, peer: Self.vmPeer(.model, true, 1030), current: .zero, buttonsDown: false, geometry: g)?.source == .model)
    }

    @Test func f2DeferredCorrectionPassesTheUsualChecksAtFireTime() {
        let g = UTDesk.macbook
        // A button goes down during the wait.
        let d1 = mbDetector()
        _ = d1.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: Self.vmPeer(.model, true, 995))
        #expect(d1.onSample(t: 1026, p: .zero, buttonsDown: true, geometry: g, peer: nil) == nil)
        #expect(d1.onSample(t: 1027, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil, "dropped, not retried")
        // The cursor left the edge displays during the wait.
        let d2 = mbDetector()
        _ = d2.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: Self.vmPeer(.model, true, 995))
        #expect(d2.onSample(t: 1026, p: CGPoint(x: 30, y: 40), buttonsDown: false, geometry: g, peer: nil) == nil)
        // The episode rule still applies.
        let d3 = mbDetector()
        var p = Self.vmPeer(.model, true, 995)
        p.episodeStart = 0
        _ = d3.onSample(t: 900, p: CGPoint(x: -600, y: -690), buttonsDown: false, geometry: g, peer: nil)
        #expect(d3.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: p) == nil)
        #expect(d3.onSample(t: 1026, p: .zero, buttonsDown: false, geometry: g, peer: nil) == nil)
        // The cursor delta since the landing is kept.
        let d4 = mbDetector()
        _ = d4.onSample(t: 1000, p: .zero, buttonsDown: false, geometry: g, peer: Self.vmPeer(.model, true, 995))
        let c = d4.onSample(t: 1026, p: CGPoint(x: -4, y: -9), buttonsDown: false, geometry: g, peer: nil)
        #expect(c?.target == CGPoint(x: -884, y: -9))
    }

    // MARK: F3: late lines and edge visits

    @Test func f3LagLimitAndEdgeVisits() {
        let now: UInt64 = 10_000_000_000
        #expect(UCLogClock.lagIsAcceptable(eventNs: now - 100_000_000, nowNs: now))
        #expect(!UCLogClock.lagIsAcceptable(eventNs: now - 100_000_001, nowNs: now))
        #expect(!UCLogClock.lagIsAcceptable(eventNs: now - 800_000_000, nowNs: now), "the auditor's 0.8 s late line")
        var v = UCEdgeVisit()
        v.onEvent(t: 0, ns: 1_000, s: 0)
        v.onEvent(t: 16, ns: 2_000, s: 0)
        #expect(v.contains(ns: 1_000))
        v.onEvent(t: 40, ns: 3_000, s: 50)                              // left the edge
        #expect(!v.contains(ns: 1_000))
        v.onEvent(t: 60, ns: 4_000, s: 0)                               // a new visit
        #expect(!v.contains(ns: 2_000) && v.contains(ns: 4_000))
        v.onEvent(t: 200, ns: 5_000, s: 0)                              // gap > 100 ms: new visit
        #expect(!v.contains(ns: 4_000) && v.contains(ns: 5_000))
    }

    // MARK: F4: orphans

    @Test func f4ProcArgsParsingAndOrphanMatch() {
        let pred = UCLogStream.predicate
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(6).littleEndian) { buf.append(contentsOf: $0) }
        buf += Array("/usr/bin/log".utf8) + [0, 0, 0, 0]
        for a in UCLogOrphan.argv(predicate: pred) { buf += Array(a.utf8) + [0] }
        buf += Array("HOME=/Users/x".utf8) + [0]
        let argv = UCLogOrphan.parseProcArgs2(buf)
        #expect(argv == UCLogOrphan.argv(predicate: pred))
        #expect(UCLogOrphan.isOrphan(argv: argv ?? [], ppid: 1, uid: 501, myUID: 501, predicate: pred))
        #expect(!UCLogOrphan.isOrphan(argv: argv ?? [], ppid: 77, uid: 501, myUID: 501, predicate: pred), "still has a parent")
        #expect(!UCLogOrphan.isOrphan(argv: argv ?? [], ppid: 1, uid: 0, myUID: 501, predicate: pred), "another user's")
        #expect(!UCLogOrphan.isOrphan(argv: ["/usr/bin/log", "stream", "--style", "ndjson"], ppid: 1, uid: 501, myUID: 501, predicate: pred))
        #expect(!UCLogOrphan.isOrphan(argv: ["/usr/bin/log", "show", "--predicate", pred], ppid: 1, uid: 501, myUID: 501, predicate: pred))
        #expect(UCLogOrphan.parseProcArgs2([1, 0]) == nil)
    }

    // MARK: F6

    @Test func f6LineSplitterCapsAPartialLine() {
        var s = LineSplitter(maxBytes: 16)
        #expect(s.append(Array("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(s.append(Array(":2}\n".utf8)) == ["{\"b\":2}"])
        #expect(s.append([UInt8](repeating: 0x41, count: 20)).isEmpty)
        #expect(s.overflows == 1)
        #expect(s.append(Array("ok\n".utf8)) == ["ok"], "recovers after dropping the junk")
    }
}

@Suite(.serialized) struct AuditV131EngineTests {
    static let testPredicate = #"eventMessage == "uc-edge-orphan-test-7f3a2c""#

    static func activePair(dir: URL) async throws -> (mb: UTRig.Side, vm: UTRig.Side) {
        let (mb, vm) = try await UTRig.pair(dir: dir, vmStart: CGPoint(x: 300, y: 500), mbStart: CGPoint(x: -1000, y: -700))
        vm.engine.ucLogStarted()
        vm.engine.onUCLogEvent(UCLogEvent(kind: .entering, edge: "top", device: "d", displayUUID: UTRig.d3.uuidString,
                                          machTimestamp: UCLogClock.local.ticks(uptimeNs: DispatchTime.now().uptimeNanoseconds)),
                               receivedNs: DispatchTime.now().uptimeNanoseconds, continuousMinusAbsolute: 0)
        let deadline = monotonicMs() + 2000
        while monotonicMs() < deadline && !mb.engine.snapshot().ucLog.peerActive { await UTRig.ms(10) }
        return (mb, vm)
    }

    static func pushUp(_ vm: UTRig.Side) async -> UInt64 {
        _ = UCLogAssistEngineTests.tap(vm, 500, 40, dy: -30); await UTRig.ms(16)
        _ = UCLogAssistEngineTests.tap(vm, 500, 0.5, dy: -20); await UTRig.ms(16)
        return UCLogAssistEngineTests.tap(vm, 500, 0, dy: -3)
    }

    @Test func f1WrappedOffsetIsNotAClockError() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: false, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir)
        defer { side.socket.shutdownAndClose() }
        for _ in 0..<500 {
            let now = DispatchTime.now().uptimeNanoseconds
            let ev = UCLogEvent(kind: .activating, edge: "top", device: "x", displayUUID: UTRig.d3.uuidString,
                                machTimestamp: UCLogClock.local.ticks(uptimeNs: now - 1_000_000))
            // One tick of skew between the two clock reads, as the old reader order produced.
            side.engine.onUCLogEvent(ev, receivedNs: now, continuousMinusAbsolute: 0 &- 1)
        }
        #expect(side.engine.snapshot().ucLog.clockErrors == 0)
    }

    @Test func f2UCPathMissStillGetsTheModelCorrection() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await Self.activePair(dir: dir)
        defer { mb.engine.stop(); vm.engine.stop() }
        #expect(mb.engine.snapshot().ucLog.peerActive)
        mb.engine.onTapEvent(p: mb.cursor.position, dx: 0, dy: 0, buttonsDown: false)
        await UTRig.ms(300)
        _ = await Self.pushUp(vm)                                         // model latch; no UC line arrives
        await UTRig.ms(5)
        let land = monotonicMs()
        mb.cursor.position = .zero
        await UTRig.ms(120)
        let w = try #require(mb.cursor.warpLog.first { $0.t >= land })
        #expect(abs(Double(w.p.x) - UTRig.vmToMb(500)) < 0.01)
        #expect(w.t - land <= 40, "model correction after the 25 ms wait: \(w.t - land) ms")
        #expect(mb.engine.snapshot().lastCorrections.last?.crossSource == "model")
    }

    @Test func f2UCLineTenMsAfterTheLandingWins() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await Self.activePair(dir: dir)
        defer { mb.engine.stop(); vm.engine.stop() }
        mb.engine.onTapEvent(p: mb.cursor.position, dx: 0, dy: 0, buttonsDown: false)
        await UTRig.ms(300)
        _ = UCLogAssistEngineTests.tap(vm, 490, 40, dy: -30); await UTRig.ms(16)
        let activatedOn = UCLogAssistEngineTests.tap(vm, 495, 0.5, dy: -20); await UTRig.ms(16)
        _ = UCLogAssistEngineTests.tap(vm, 500, 0, dy: -3)                // the model latch would say 500
        await UTRig.ms(5)
        let land = monotonicMs()
        mb.cursor.position = .zero
        await UTRig.ms(8)
        vm.engine.onUCLogEvent(UCLogAssistEngineTests.activation(on: activatedOn),
                               receivedNs: DispatchTime.now().uptimeNanoseconds, continuousMinusAbsolute: 0)
        await UTRig.ms(100)
        let w = try #require(mb.cursor.warpLog.first { $0.t >= land })
        #expect(abs(Double(w.p.x) - UTRig.vmToMb(495)) < 0.01, "UC's x wins over the model's 500")
        #expect(mb.engine.snapshot().lastCorrections.last?.crossSource == "uc")
    }

    @Test func f3LateActivatingLineIsRejectedAndNothingWarps() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await Self.activePair(dir: dir)
        defer { mb.engine.stop(); vm.engine.stop() }
        let ns = await Self.pushUp(vm)
        await UTRig.ms(20)
        let land = monotonicMs()
        mb.cursor.position = .zero                                       // corrected (model) at +25 ms
        await UTRig.ms(300)
        for (x, y) in [(-20.0, -8.0), (-45.0, -14.0)] {                  // the user moves on
            mb.cursor.position = CGPoint(x: x, y: y)
            mb.engine.onTapEvent(p: CGPoint(x: x, y: y), dx: -20, dy: -6, buttonsDown: false)
            await UTRig.ms(16)
        }
        await UTRig.ms(450)
        vm.engine.onUCLogEvent(UCLogAssistEngineTests.activation(on: ns),     // ~0.8 s late
                               receivedNs: DispatchTime.now().uptimeNanoseconds, continuousMinusAbsolute: 0)
        await UTRig.ms(60)
        let p = CGPoint(x: -70, y: -16)
        mb.cursor.position = p
        mb.engine.onTapEvent(p: p, dx: -25, dy: -2, buttonsDown: false)
        await UTRig.ms(30)
        #expect(vm.engine.snapshot().ucLog.lateLines == 1 && vm.engine.snapshot().ucLog.matched == 0)
        #expect(mb.cursor.warpLog.filter { $0.t >= land + 500 }.isEmpty, "no delayed warp")
    }

    @Test func f3ActivationFromAnEarlierVisitIsIgnored() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await UTRig.pair(dir: dir, vmStart: CGPoint(x: 300, y: 500), mbStart: CGPoint(x: -1000, y: -700))
        defer { mb.engine.stop(); vm.engine.stop() }
        vm.engine.ucMatchDelayMs = 0
        let old = UCLogAssistEngineTests.tap(vm, 500, 0, dy: -3)
        await UTRig.ms(16)
        _ = UCLogAssistEngineTests.tap(vm, 500, 60, dy: 30)                // leaves the edge
        await UTRig.ms(16)
        _ = UCLogAssistEngineTests.tap(vm, 520, 0, dy: -40)                // a new visit
        // UC's line for the old visit's event (5 ms after it) arrives only now, ~35 ms later.
        vm.engine.onUCLogEvent(UCLogAssistEngineTests.activation(on: old, afterNs: 5_000_000),
                               receivedNs: DispatchTime.now().uptimeNanoseconds, continuousMinusAbsolute: 0)
        await UTRig.ms(20)
        let u = vm.engine.snapshot().ucLog
        #expect(u.staleVisit == 1 && u.matched == 0, "\(u)")
    }

    @Test func f5LineBeforeItsTapCallbackStillMatches() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await UTRig.pair(dir: dir, vmStart: CGPoint(x: 300, y: 500), mbStart: CGPoint(x: -1000, y: -700))
        defer { mb.engine.stop(); vm.engine.stop() }
        vm.engine.ucLogStarted()
        _ = UCLogAssistEngineTests.tap(vm, 700, 20, dy: -30)
        await UTRig.ms(16)
        // The activating event happened now, but its tap callback runs 1 ms after UC's log line.
        let eventNs = DispatchTime.now().uptimeNanoseconds
        vm.engine.onUCLogEvent(UCLogAssistEngineTests.activation(on: eventNs, afterNs: 200_000),
                               receivedNs: eventNs + 400_000, continuousMinusAbsolute: 0)
        await UTRig.ms(1)
        vm.cursor.position = CGPoint(x: 702, y: 0)
        vm.engine.onTapEvent(p: CGPoint(x: 702, y: 0), dx: 0, dy: -20, buttonsDown: false, eventNs: eventNs)
        await UTRig.ms(20)
        #expect(vm.engine.snapshot().ucLog.matched == 1)
    }

    @Test func f6StatusLineAgeAndNoPollingWithCorrectionsOff() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = try UTRawPeer()
        let base = try UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: raw.socket.port, dir: dir)
        var c = base.engine.config
        c.corrections.enabled = false
        let e = Engine(config: c, key: UTRig.key, env: base.engine.env, log: base.engine.log)
        try e.start(tapActive: true, socket: base.socket)
        defer { e.stop(); raw.socket.shutdownAndClose() }
        raw.send(.edge(EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: 0, crossSource: .uc)),
                 to: base.socket.port)
        await UTRig.ms(50)
        #expect(e.snapshot().counters.packetsReceived == 1)
        #expect(!e.isArmed(), "corrections off: never arm the 1 kHz poller")
        e.ucLogStarted()
        e.onUCLogLine(#"{"eventMessage":"Hot Zone: Entering: top:31000000:8A000000-0000-4000-8000-0000000000A1:[x]","machTimestamp":1}"#,
                      receivedNs: DispatchTime.now().uptimeNanoseconds, continuousMinusAbsolute: 0)
        await UTRig.ms(30)
        let age = try #require(e.snapshot().ucLog.lastLineAgeMs)
        #expect(age >= 25 && age < 1000)
    }

    // MARK: F4: the child never outlives us

    /// `log stream` processes of this test with exactly `predicate`: (pid, ppid).
    static func logChildren(predicate: String) -> [(pid: pid_t, ppid: pid_t)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { l in
            let f = l.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]), f[2].hasPrefix("/usr/bin/log stream"),
                  f[2].contains("uc-edge-orphan-test-7f3a2c") else { return nil }
            return (pid, ppid)
        }
    }

    @Test func f4OrphansFromAnEarlierRunAreKilledAndNothingElse() async throws {
        // An orphan: started from a shell that exits at once, so launchd adopts it (ppid 1).
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "/usr/bin/log stream --style ndjson --predicate '\(Self.testPredicate)' >/dev/null 2>&1 &"]
        try sh.run()
        sh.waitUntilExit()
        // And a child we still own, with the same command line: must survive.
        let own = Process()
        own.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        own.arguments = Array(UCLogOrphan.argv(predicate: Self.testPredicate).dropFirst())
        own.standardOutput = FileHandle.nullDevice
        try own.run()
        defer { own.terminate() }
        var orphans: [pid_t] = []
        for _ in 0..<50 where orphans.isEmpty {
            await UTRig.ms(50)
            orphans = Self.logChildren(predicate: Self.testPredicate).filter { $0.ppid == 1 }.map(\.pid)
        }
        #expect(orphans.count == 1)
        let killed = UCLogStream.killOrphans(predicate: Self.testPredicate)
        #expect(killed == orphans)
        await UTRig.ms(300)
        let left = Self.logChildren(predicate: Self.testPredicate)
        #expect(left.map(\.pid) == [own.processIdentifier], "only our own child is left")
        #expect(UCLogStream.killOrphans(predicate: "no such predicate").isEmpty)
    }

    @Test func f4ExitKillsTheChild() async throws {
        await #expect(processExitsWith: .success) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-f4-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let side = try! UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir)
            UCLogStream.installExitCleanup()
            let stream = UCLogStream(engine: side.engine, log: side.engine.log,
                                     predicate: #"eventMessage == "uc-edge-orphan-test-7f3a2c""#)
            stream.start()
            for _ in 0..<100 where stream.childPid == 0 { usleep(20_000) }
            exit(stream.childPid > 0 ? 0 : 3)                            // atexit must take the child down
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let left = Self.logChildren(predicate: Self.testPredicate)
        _ = UCLogStream.killOrphans(predicate: Self.testPredicate)        // never leak one, even on failure
        #expect(left.isEmpty, "\(left)")
    }
}
