import CoreGraphics
import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

/// A fake cursor that returns a stale position to the network thread (to catch M1).
final class UTThreadAwareCursor: CursorSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var pos: CGPoint
    private var warps: [(t: Double, p: CGPoint)] = []
    let staleForNetThread: CGPoint?

    init(_ p: CGPoint, staleForNetThread: CGPoint? = nil) {
        pos = p
        self.staleForNetThread = staleForNetThread
    }
    var position: CGPoint {
        get { lock.withLock { pos } }
        set { lock.withLock { pos = newValue } }
    }
    var warpLog: [(t: Double, p: CGPoint)] { lock.withLock { warps } }
    func location() -> CGPoint? {
        if let s = staleForNetThread, Thread.current.name == "uc-edge.net" { return s }
        return position
    }
    func buttonsDown() -> Bool { false }
    func warp(to p: CGPoint) -> Int32 {
        lock.withLock { pos = p; warps.append((monotonicMs(), p)) }
        return 0
    }
}

/// Engines on loopback, plus a raw authenticated sender standing in for a peer.
enum UTRig {
    static let d3 = UUID(uuidString: "8A000000-0000-4000-8000-0000000000A1")!
    static let d4 = UUID(uuidString: "E5000000-0000-4000-8000-0000000000B1")!
    static let d5 = UUID(uuidString: "8D000000-0000-4000-8000-0000000000B2")!
    static let key = WireKey(hex: String(repeating: "5a", count: 32))!
    static let mbDisplays = [ResolvedDisplay(uuid: d3, id: 3, bounds: UTDesk.display3)]
    static let vmDisplays = [ResolvedDisplay(uuid: d4, id: 4, bounds: UTDesk.monitor4),
                             ResolvedDisplay(uuid: d5, id: 5, bounds: UTDesk.monitor5)]

    struct Side { let engine: Engine; let cursor: UTThreadAwareCursor; let socket: UDPSocket }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-rig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func side(macbook: Bool, cursor: UTThreadAwareCursor, socket: UDPSocket? = nil, peerPort: UInt16, dir: URL,
                     deadStrip: Bool = false, resolve: PeerAddressBook.Lookup? = nil) throws -> Side {
        let sock = try socket ?? UDPSocket(port: 0)
        var c = Config()
        c.name = macbook ? "macbook" : "vmind"
        c.side = macbook ? .bottom : .top
        c.edgeDisplays = (macbook ? mbDisplays : vmDisplays).map(\.uuid.uuidString)
        c.peerHosts = ["127.0.0.1"]
        c.port = Int(sock.port)
        c.peerPort = Int(peerPort)
        c.logPath = dir.appendingPathComponent("\(c.name).log").path
        c.statusPath = dir.appendingPathComponent("\(c.name)-status.json").path
        c.ucPlistPath = dir.appendingPathComponent("absent.plist").path
        c.deadStrip.enabled = deadStrip
        if deadStrip {
            // The plist is absent: UC's zone on V-Mind's desk (SPEC §2), configured as the fallback.
            c.deadStrip.zoneMinXFallback = -961
            c.deadStrip.zoneMaxXFallback = 1600
        }
        let displays = macbook ? mbDisplays : vmDisplays
        var env = EngineEnvironment(cursor: cursor, edgeDisplays: { displays }, accessibilityTrusted: { true },
                                    listenEventAccess: { true }, ucPlistPath: { nil })
        if let resolve { env.resolve = resolve }
        return Side(engine: Engine(config: c, key: key, env: env, log: Logger(path: c.logPath)), cursor: cursor, socket: sock)
    }

    /// A MacBook engine (tap mode) whose peer is a raw socket the test drives.
    static func macbookWithRawPeer(dir: URL, cursor: UTThreadAwareCursor) throws -> (Side, UTRawPeer) {
        let raw = try UTRawPeer()
        let mb = try side(macbook: true, cursor: cursor, peerPort: raw.socket.port, dir: dir)
        try mb.engine.start(tapActive: true, socket: mb.socket)
        return (mb, raw)
    }

    /// Two engines on loopback that have heard each other.
    static func pair(dir: URL, vmTap: Bool = true, vmStart: CGPoint, mbStart: CGPoint,
                     vmDeadStrip: Bool = false) async throws -> (mb: Side, vm: Side) {
        let mbSock = try UDPSocket(port: 0), vmSock = try UDPSocket(port: 0)
        let mb = try side(macbook: true, cursor: UTThreadAwareCursor(mbStart), socket: mbSock, peerPort: vmSock.port, dir: dir)
        let vm = try side(macbook: false, cursor: UTThreadAwareCursor(vmStart), socket: vmSock, peerPort: mbSock.port,
                          dir: dir, deadStrip: vmDeadStrip)
        try mb.engine.start(tapActive: true, socket: mbSock)
        try vm.engine.start(tapActive: vmTap, socket: vmSock)
        let deadline = monotonicMs() + 3000
        while monotonicMs() < deadline && !(mb.engine.snapshot().peer.alive && vm.engine.snapshot().peer.alive) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return (mb, vm)
    }

    static func ms(_ n: Double) async { try? await Task.sleep(nanoseconds: UInt64(n * 1_000_000)) }

    static func vmToMb(_ x: Double) -> Double {
        physicalMap(peerX: x, peerSpanMin: -1600, peerSpanMax: 1600, localSpanMin: -2560, localSpanMax: 0)
    }
}

/// An authenticated sender that is not an engine.
final class UTRawPeer: @unchecked Sendable {
    let socket: UDPSocket
    private var wire = WireSender()
    init() throws { socket = try UDPSocket(port: 0) }

    func send(_ body: PacketBody, wallMs: Int64 = currentWallMs(), to port: UInt16) {
        let data = Wire.encode(wire.packet(body, wallMs: wallMs), key: UTRig.key)
        if let dst = PeerAddressBook.lookup(host: "127.0.0.1", port: port).0.first { _ = socket.send(data, to: dst) }
    }

    /// A latched V-Mind EDGE packet.
    func vmEdge(crossX: Double, wallMs: Int64 = currentWallMs(), to port: UInt16) {
        send(.edge(EdgePayload(x: crossX, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: crossX)),
             wallMs: wallMs, to: port)
    }
}

final class UTFakeTap: EventTapping {
    var startOK: Bool
    var healthy = true
    var starts = 0, invalidations = 0
    init(startOK: Bool) { self.startOK = startOK }
    func start() -> Bool { starts += 1; return startOK }
    func heal() -> Bool { healthy }
    func invalidate() { invalidations += 1 }
}

@Suite(.serialized) struct AuditEngineRegressionTests {

    // MARK: C1(a): a frozen cursor in polling fallback sends nothing

    @Test func c1FallbackFrozenCursorKeepsThePeerQuiet() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await UTRig.pair(dir: dir, vmTap: false, vmStart: CGPoint(x: -500, y: 0),
                                            mbStart: CGPoint(x: -1000, y: -10))
        defer { mb.engine.stop(); vm.engine.stop() }
        #expect(mb.engine.snapshot().peer.alive)
        #expect(vm.engine.snapshot().permissions.pollingFallback)
        await UTRig.ms(600)
        let edgeBefore = mb.engine.lock.withLock { mb.engine.lastEdgePacketT }
        await UTRig.ms(1000)
        let edgeAfter = mb.engine.lock.withLock { mb.engine.lastEdgePacketT }
        #expect(edgeBefore == edgeAfter, "no EDGE packets from a frozen V-Mind")
        #expect(!mb.engine.isArmed())
        // The MacBook user works near display 3's bottom: nothing may warp.
        var y = -10.0
        for i in 0..<3 {
            y -= 2
            let p = CGPoint(x: -1000 + Double(i) * 10, y: y)
            mb.cursor.position = p
            mb.engine.onTapEvent(p: p, dx: 10, dy: -2, buttonsDown: false)
            await UTRig.ms(300)
        }
        #expect(mb.cursor.warpLog.isEmpty)
    }

    // MARK: C1(c) / M7: the tap is supervised

    @Test func c1TapSupervisorRetriesAndRecreates() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir)
        let taps = [UTFakeTap(startOK: false), UTFakeTap(startOK: true), UTFakeTap(startOK: true)]
        var next = 0
        let clock = UTClock()
        let sup = TapSupervisor(engine: side.engine, log: Logger(path: nil), now: { clock.now }) {
            defer { next = min(next + 1, taps.count - 1) }
            return taps[next]
        }
        #expect(!sup.startTap())
        #expect(side.engine.snapshot().permissions.pollingFallback)
        clock.now = 1
        sup.check()                                                      // the first retry, after 1 s
        #expect(side.engine.snapshot().permissions.tapActive)
        #expect(taps[1].starts == 1)
        sup.check()                                                      // healthy: nothing happens
        #expect(taps[2].starts == 0)
        taps[1].healthy = false                                          // disabled for good / run loop ended
        sup.check()
        #expect(taps[1].invalidations == 1)
        #expect(side.engine.snapshot().permissions.pollingFallback)
        clock.now = 5                                                    // after the (2 s) backoff
        sup.check()
        #expect(taps[2].starts == 1)
        #expect(side.engine.snapshot().permissions.tapActive)
        sup.stop()
        side.socket.shutdownAndClose()
    }

    // MARK: C2: a dead-strip virtualX can't leak into a later crossing

    @Test func c2VirtualXDoesNotLeakIntoALaterCrossing() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, vm) = try await UTRig.pair(dir: dir, vmStart: CGPoint(x: -1599, y: 40),
                                            mbStart: CGPoint(x: -1000, y: -700), vmDeadStrip: true)
        defer { mb.engine.stop(); vm.engine.stop() }
        mb.engine.onPollSample(p: mb.cursor.position, buttonsDown: false)
        // Deliberate dead-strip push at x = -1599 (pinned at y = 0).
        var p = CGPoint(x: -1599, y: 0)
        vm.cursor.position = p
        vm.engine.onTapEvent(p: p, dx: 0, dy: -40, buttonsDown: false)
        for _ in 0..<20 {
            await UTRig.ms(16)
            p = vm.cursor.position
            if p.x > -1000 { break }
            vm.engine.onTapEvent(p: p, dx: 0, dy: -2, buttonsDown: false)
        }
        #expect(vm.cursor.warpLog.first != nil, "redirect happened")
        // No crossing; the user moves away and ~400 ms later goes up at x = 1000.
        for (x, y) in [(-900.0, 60.0), (-300.0, 200.0), (400.0, 300.0), (900.0, 150.0)] {
            await UTRig.ms(80)
            p = CGPoint(x: x, y: y); vm.cursor.position = p
            vm.engine.onTapEvent(p: p, dx: 100, dy: 10, buttonsDown: false)
        }
        for (y, dy) in [(20.0, -30.0), (0.5, -19.0), (0.0, -3.0), (0.0, -2.0)] {
            await UTRig.ms(16)
            p = CGPoint(x: 1000, y: y); vm.cursor.position = p
            vm.engine.onTapEvent(p: p, dx: 0, dy: dy, buttonsDown: false)
        }
        let land = monotonicMs()
        mb.cursor.position = .zero
        await UTRig.ms(100)
        let w = try #require(mb.cursor.warpLog.first { $0.t >= land })
        #expect(abs(Double(w.p.x) - UTRig.vmToMb(1000)) < 1, "target \(w.p) must come from the new latch, not virtualX")
    }

    // MARK: dead strip with no fallback zone (UC's zone unknown): off, and the latch uses the span

    @Test(arguments: [false, true]) func deadStripFallbackZone(configured: Bool) async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = try UTRawPeer()
        var side = try UTRig.side(macbook: false, cursor: UTThreadAwareCursor(CGPoint(x: -1500, y: 40)),
                                  peerPort: raw.socket.port, dir: dir, deadStrip: true)
        if !configured {
            var c = side.engine.config
            c.deadStrip.zoneMinXFallback = nil
            c.deadStrip.zoneMaxXFallback = nil
            side = UTRig.Side(engine: Engine(config: c, key: UTRig.key, env: side.engine.env, log: side.engine.log),
                              cursor: side.cursor, socket: side.socket)
        }
        try side.engine.start(tapActive: true, socket: side.socket)
        defer { side.engine.stop(); raw.socket.shutdownAndClose() }
        raw.send(.hello(HelloPayload(version: "1.4.0", side: .bottom,
                                     displays: [EdgeDisplayInfo(uuid: UTRig.d3, minX: -2560, width: 2560)], axTrusted: true)),
                 to: side.socket.port)
        await UTRig.ms(100)
        #expect(side.engine.snapshot().peer.alive)
        #expect(side.engine.snapshot().arrangement.zoneMinX == (configured ? -961 : nil))
        // A firm push at x = -1500, in the dead part of the configured zone.
        let p = CGPoint(x: -1500, y: 0)
        side.cursor.position = p
        side.engine.onTapEvent(p: p, dx: 0, dy: -40, buttonsDown: false)
        for _ in 0..<20 {
            await UTRig.ms(16)
            side.engine.onTapEvent(p: p, dx: 0, dy: -2, buttonsDown: false)
        }
        if configured {
            #expect(!side.cursor.warpLog.isEmpty, "redirected into the configured zone")
        } else {
            #expect(side.cursor.warpLog.isEmpty, "no redirect while UC's zone is unknown")
            #expect(side.engine.snapshot().counters.modelCross >= 1, "the latch arms anywhere on the span")
        }
    }

    // MARK: C4: hostile HELLO_ACK timestamps can't crash the engine

    @Test func c4HelloAckEchoOverflowDoesNotCrash() async {
        await #expect(processExitsWith: .success) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-c4-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (mb, raw) = try! UTRig.macbookWithRawPeer(dir: dir, cursor: UTThreadAwareCursor(CGPoint(x: -600, y: -700)))
            for echo in [Int64.min, Int64.max, 0] {
                let h = HelloPayload(version: "x", side: .top, displays: [], axTrusted: true, echoWallMs: echo)
                raw.send(.helloAck(h), wallMs: currentWallMs(), to: mb.socket.port)
            }
            usleep(500_000)
            let s = mb.engine.snapshot()
            exit(s.counters.packetsReceived == 3 && s.peer.rttMs == nil && s.peer.clockOffsetMs == nil ? 0 : 2)
        }
    }

    // MARK: M1: the late path uses the detector's own last sample

    @Test func m1LateTargetIgnoresStaleCursorReads() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let frozen = CGPoint(x: -600, y: -700)
        let cursor = UTThreadAwareCursor(frozen, staleForNetThread: frozen)
        let (mb, raw) = try UTRig.macbookWithRawPeer(dir: dir, cursor: cursor)
        defer { mb.engine.stop(); raw.socket.shutdownAndClose() }
        mb.engine.onPollSample(p: frozen, buttonsDown: false)
        await UTRig.ms(100)
        cursor.position = .zero                                  // UC lands the cursor at (0, 0)
        mb.engine.onPollSample(p: .zero, buttonsDown: false)     // pending: no peer packet yet
        raw.vmEdge(crossX: 0, to: mb.socket.port)
        await UTRig.ms(100)
        let w = try #require(cursor.warpLog.first)
        #expect(w.p == CGPoint(x: -1280, y: -2), "stale net-thread read would give x = -1880")
    }

    // MARK: M2: the receive loop survives errors, and exits cleanly when they persist

    @Test func m2ReceiveErrorsAreRetriedAndCounted() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir)
        defer { side.socket.shutdownAndClose() }
        side.engine.recvBackoffMs = 1
        var w = WireSender()
        let hello = Wire.encode(w.packet(.hello(HelloPayload(version: "x", side: .top, displays: [], axTrusted: true)),
                                         wallMs: currentWallMs()), key: UTRig.key)
        let from = try #require(PeerAddressBook.lookup(host: "127.0.0.1", port: 9).0.first)
        var script: [ReceiveResult] = [.error(EBADF), .error(EIO), .error(EBADF), .datagram(hello, from), .closed]
        side.engine.runReceiveLoop { script.removeFirst() }
        let s = side.engine.snapshot()
        #expect(s.counters.recvErrors == 3)
        #expect(s.counters.packetsReceived == 1)
        #expect(s.netError == nil, "cleared once a datagram arrived")
        side.engine.log.flush()
        let log = try String(contentsOfFile: side.engine.config.logPath, encoding: .utf8)
        #expect(log.contains("receive error"))
    }

    @Test func m2PersistentReceiveErrorsEndTheProcess() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir)
        defer { side.socket.shutdownAndClose() }
        side.engine.recvBackoffMs = 0
        side.engine.recvMaxErrors = 5
        let fatal = UTCounter()
        side.engine.onFatal = { _ in fatal.add() }
        var calls = 0
        side.engine.runReceiveLoop { calls += 1; return calls < 100 ? .error(EBADF) : .closed }
        #expect(fatal.value == 1)
        #expect(calls == 5)
        #expect(side.engine.snapshot().counters.recvErrors == 5)
    }

    // MARK: M3: a failed log write drops the line, never aborts

    @Test func m3LogWriteErrorDropsTheLine() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("uc.log").path
        let log = Logger(path: path)
        log.log("one")
        log.flush()
        // A handle that can't write (read-only): the old FileHandle.write(_:) raised an ObjC exception.
        log.onQueue { $0.handle = FileHandle(forReadingAtPath: path) }
        log.log("two")
        log.log("three")
        log.flush()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("one") && !text.contains("two") && text.contains("three"))
        log.onQueue { #expect($0.droppedLines == 1) }
    }

    @Test func m3StatusWithNonFiniteValuesStillWrites() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = StatusSnapshot()
        s.peer.rttMs = .nan
        s.peer.clockOffsetMs = .infinity
        let path = dir.appendingPathComponent("status.json").path
        StatusFile.write(s, to: path)
        let back = try StatusFile.read(from: path)
        #expect(back.peer.rttMs?.isNaN == true)
    }

    // MARK: M5: an EDGE packet delayed in flight is not fresh

    @Test func m5DelayedPacketDoesNotCorrect() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let frozen = CGPoint(x: -600, y: -700)
        let cursor = UTThreadAwareCursor(frozen)
        let (mb, raw) = try UTRig.macbookWithRawPeer(dir: dir, cursor: cursor)
        defer { mb.engine.stop(); raw.socket.shutdownAndClose() }
        mb.engine.onPollSample(p: frozen, buttonsDown: false)
        await UTRig.ms(100)
        raw.vmEdge(crossX: 0, wallMs: currentWallMs() - 2000, to: mb.socket.port)   // sent 2 s ago
        await UTRig.ms(20)
        cursor.position = .zero
        mb.engine.onPollSample(p: .zero, buttonsDown: false)
        raw.vmEdge(crossX: 0, wallMs: currentWallMs() - 2000, to: mb.socket.port)
        await UTRig.ms(100)
        #expect(cursor.warpLog.isEmpty)
        #expect(mb.engine.snapshot().counters.packetsReceived == 2, "authentic, just old")
    }

    // MARK: M6: slow DNS never blocks the timer queue

    @Test func m6SlowResolverDoesNotBlockTimers() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: true, cursor: UTThreadAwareCursor(.zero), peerPort: 9, dir: dir,
                                  resolve: { _, _ in Thread.sleep(forTimeInterval: 1.5); return ([], "slow") })
        try side.engine.start(tapActive: true, socket: side.socket)
        defer { side.engine.stop() }
        await UTRig.ms(50)
        let t0 = monotonicMs()
        side.engine.timerQueue.sync {}
        side.engine.refreshGeometry()
        #expect(monotonicMs() - t0 < 200)
    }

    // MARK: minor

    @Test func tapEventsDuringStartAreSafe() throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let side = try UTRig.side(macbook: false, cursor: UTThreadAwareCursor(CGPoint(x: 10, y: 0)), peerPort: 9, dir: dir)
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            for i in 0..<5000 {
                side.engine.onTapEvent(p: CGPoint(x: Double(i % 50), y: 0), dx: 1, dy: -1, buttonsDown: false)
            }
            done.signal()
        }
        t.start()
        try side.engine.start(tapActive: true, socket: side.socket)
        done.wait()
        side.engine.stop()
    }

    @Test func peerHelloOnTheSameSideIsFlagged() async throws {
        let dir = try UTRig.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (mb, raw) = try UTRig.macbookWithRawPeer(dir: dir, cursor: UTThreadAwareCursor(.zero))
        defer { mb.engine.stop(); raw.socket.shutdownAndClose() }
        raw.send(.hello(HelloPayload(version: "x", side: .bottom, displays: [], axTrusted: true)), to: mb.socket.port)
        await UTRig.ms(100)
        #expect(mb.engine.snapshot().peer.sideConflict)
    }
}

final class UTClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 0.0
    var now: Double {
        get { lock.withLock { t } }
        set { lock.withLock { t = newValue } }
    }
}

final class UTCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
