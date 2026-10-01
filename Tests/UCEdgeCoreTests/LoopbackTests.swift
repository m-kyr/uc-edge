import CoreGraphics
import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

/// A cursor that only exists in memory: no CoreGraphics calls, no warps, no events.
final class UTFakeCursor: CursorSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var pos: CGPoint
    private var warps: [(t: Double, p: CGPoint)] = []

    init(_ p: CGPoint) { pos = p }

    var position: CGPoint {
        get { lock.withLock { pos } }
        set { lock.withLock { pos = newValue } }
    }
    var warpLog: [(t: Double, p: CGPoint)] { lock.withLock { warps } }

    func location() -> CGPoint? { position }
    func buttonsDown() -> Bool { false }
    func warp(to p: CGPoint) -> Int32 {
        lock.withLock {
            pos = p
            warps.append((monotonicMs(), p))
        }
        return 0
    }
}

/// Two engines (MacBook and V-Mind roles) talking real UDP over 127.0.0.1 (SPEC §10.5).
@Suite(.serialized) struct LoopbackTests {
    static let d3 = UUID(uuidString: "8A000000-0000-4000-8000-0000000000A1")!
    static let d4 = UUID(uuidString: "E5000000-0000-4000-8000-0000000000B1")!
    static let d5 = UUID(uuidString: "8D000000-0000-4000-8000-0000000000B2")!
    static let key = WireKey(hex: String(repeating: "5a", count: 32))!

    struct Side {
        let engine: Engine
        let cursor: UTFakeCursor
        let socket: UDPSocket
    }

    static func makeSide(name: String, side: EdgeSide, displays: [ResolvedDisplay], start: CGPoint,
                         socket: UDPSocket, peerPort: UInt16, dir: URL) -> Side {
        var c = Config()
        c.name = name
        c.side = side
        c.edgeDisplays = displays.map(\.uuid.uuidString)
        c.peerHosts = ["127.0.0.1"]
        c.port = Int(socket.port)
        c.peerPort = Int(peerPort)
        c.logPath = dir.appendingPathComponent("\(name).log").path
        c.statusPath = dir.appendingPathComponent("\(name)-status.json").path
        c.ucPlistPath = dir.appendingPathComponent("absent.plist").path
        let cursor = UTFakeCursor(start)
        let env = EngineEnvironment(cursor: cursor, edgeDisplays: { displays },
                                    accessibilityTrusted: { true }, listenEventAccess: { true }, ucPlistPath: { nil })
        let engine = Engine(config: c, key: key, env: env, log: Logger(path: c.logPath))
        return Side(engine: engine, cursor: cursor, socket: socket)
    }

    /// Waits (polling) for the first warp at or after `since`.
    static func firstWarp(_ c: UTFakeCursor, since: Double, timeoutMs: Double = 500) async -> (t: Double, p: CGPoint)? {
        let deadline = monotonicMs() + timeoutMs
        while monotonicMs() < deadline {
            if let w = c.warpLog.first(where: { $0.t >= since }) { return w }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }

    /// Feeds tap events every 16 ms, moving the fake cursor along.
    static func push(_ s: Side, _ path: [(Double, Double, Double)]) async {
        for (x, y, dy) in path {
            let p = CGPoint(x: x, y: y)
            s.cursor.position = p
            s.engine.onTapEvent(p: p, dx: 0, dy: dy, buttonsDown: false)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    static func dumpDiagnostics(_ sides: [Side]) {
        for side in sides {
            side.engine.log.flush()
            let s = side.engine.snapshot()
            print("[loopback \(side.engine.config.name)] armed=\(side.engine.isArmed()) peerAlive=\(s.peer.alive) "
                  + "counters=\(s.counters) warps=\(side.cursor.warpLog.map(\.p))")
            print((try? String(contentsOfFile: side.engine.config.logPath, encoding: .utf8)) ?? "(no log)")
        }
    }

    @Test func crossingsAreCorrectedOnTheReceiverWithin20ms() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sockMB = try UDPSocket(port: 0), sockVM = try UDPSocket(port: 0)
        let mb = Self.makeSide(name: "macbook", side: .bottom,
                               displays: [ResolvedDisplay(uuid: Self.d3, id: 3, bounds: UTDesk.display3)],
                               start: CGPoint(x: -600, y: -700), socket: sockMB, peerPort: sockVM.port, dir: dir)
        let vm = Self.makeSide(name: "vmind", side: .top,
                               displays: [ResolvedDisplay(uuid: Self.d4, id: 4, bounds: UTDesk.monitor4),
                                          ResolvedDisplay(uuid: Self.d5, id: 5, bounds: UTDesk.monitor5)],
                               start: CGPoint(x: -700, y: 400), socket: sockVM, peerPort: sockMB.port, dir: dir)
        try mb.engine.start(tapActive: true, socket: sockMB)
        try vm.engine.start(tapActive: true, socket: sockVM)
        defer { mb.engine.stop(); vm.engine.stop() }
        // Each Mac's tap saw its cursor's last position before the pointer left it.
        mb.engine.onTapEvent(p: mb.cursor.position, dx: 0, dy: 0, buttonsDown: false)
        vm.engine.onTapEvent(p: vm.cursor.position, dx: 0, dy: 0, buttonsDown: false)
        // HELLO / HELLO_ACK: wait for both sides to resolve and hear each other (a cold
        // getaddrinfo in a fresh test process can take longer than a fixed sleep).
        let deadline = monotonicMs() + 3000
        while monotonicMs() < deadline && !(mb.engine.snapshot().peer.alive && vm.engine.snapshot().peer.alive
                                              && mb.engine.snapshot().peer.rttMs != nil) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mb.engine.snapshot().peer.alive && vm.engine.snapshot().peer.alive)

        // Up: V-Mind arms at −950.82 (Entering), latches −948.46 (Activating), then a tail event
        // runs on to −940.41; UC lands the MacBook at (0, 0). The target must map the latch.
        await Self.push(vm, [(-955, 21.3, -30), (-950.82, 0, -30), (-948.46, 0, -20), (-940.41, 0, -46)])
        let landUp = monotonicMs()
        mb.cursor.position = CGPoint(x: 0, y: 0)
        guard let up = await Self.firstWarp(mb.cursor, since: landUp) else {
            Self.dumpDiagnostics([mb, vm])
            Issue.record("no correction on the MacBook for the upward crossing")
            return
        }
        let expectedUpX = physicalMap(peerX: -948.46, peerSpanMin: -1600, peerSpanMax: 1600, localSpanMin: -2560, localSpanMax: 0)
        #expect(abs(Double(up.p.x) - expectedUpX) < 0.01)
        #expect(up.p.y == -2, "2 pt inset")
        #expect(up.t - landUp <= 20, "correction took \(up.t - landUp) ms")

        // Down: after a while on the MacBook, it pushes into its bottom edge; UC lands V-Mind at (−1, 0).
        try await Task.sleep(nanoseconds: 600_000_000)
        await Self.push(mb, [(-1599.53, -146.45, 160), (-1600.84, -14.72, 132), (-1600.84, -0.02, 110),
                             (-1600.84, -0.02, 30), (-1603.2, -0.02, 20)])
        let landDown = monotonicMs()
        vm.cursor.position = CGPoint(x: -1, y: 0)
        guard let down = await Self.firstWarp(vm.cursor, since: landDown) else {
            Self.dumpDiagnostics([mb, vm])
            Issue.record("no correction on V-Mind for the downward crossing")
            return
        }
        #expect(abs(Double(down.p.x) - (-401.05)) < 0.01)
        #expect(down.p.y == 2, "2 pt inset")
        #expect(down.t - landDown <= 20, "correction took \(down.t - landDown) ms")

        // Exactly one correction per crossing, and none on the exiting side.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(mb.cursor.warpLog.count == 1)
        #expect(vm.cursor.warpLog.count == 1)

        let s = mb.engine.snapshot()
        #expect(s.peer.alive)
        #expect(s.peer.rttMs != nil)
        #expect(s.peer.edgeDisplays.map(\.uuid) == [Self.d4, Self.d5])
        #expect(s.counters.immediate == 1)
        #expect(s.lastCorrections.first?.kind == "immediate")
        // At-edge packets arrive twice; the copy is a silent duplicate, not a reject.
        #expect(s.counters.duplicates >= 1)
        #expect(s.counters.rejects.isEmpty)
        #expect(vm.engine.snapshot().counters.immediate == 1)

        for side in [mb, vm] {
            side.engine.log.flush()
            let text = try String(contentsOfFile: side.engine.config.logPath, encoding: .utf8)
            let lines = text.split(separator: "\n").filter { $0.contains("correct kind=") }
            #expect(lines.count == 1)
            #expect(lines.first?.contains("kind=immediate") == true && lines.first?.contains("latency=") == true)
            print("[loopback \(side.engine.config.name)] \(lines.first ?? "")")
        }
    }

    @Test func unauthenticatedPacketsAreCountedAndIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-edge-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sock = try UDPSocket(port: 0), other = try UDPSocket(port: 0)
        let side = Self.makeSide(name: "macbook", side: .bottom,
                                 displays: [ResolvedDisplay(uuid: Self.d3, id: 3, bounds: UTDesk.display3)],
                                 start: CGPoint(x: -600, y: -700), socket: sock, peerPort: other.port, dir: dir)
        try side.engine.start(tapActive: true, socket: sock)
        defer { side.engine.stop(); other.shutdownAndClose() }

        let wrongKey = WireKey(hex: String(repeating: "a5", count: 32))!
        let forged = Wire.encode(Packet(senderId: 9, seq: 1, wallMs: currentWallMs(),
                                        body: .edge(EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600))),
                                 key: wrongKey)
        let dst = try #require(PeerAddressBook.lookup(host: "127.0.0.1", port: sock.port).0.first)
        #expect(other.send(forged, to: dst) == 0)
        #expect(other.send(Data("hello".utf8), to: dst) == 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let s = side.engine.snapshot()
        #expect(s.counters.rejects["badMAC"] == 1)
        #expect(s.counters.rejects["short"] == 1)
        #expect(s.counters.packetsReceived == 0)
        #expect(!s.peer.alive)
    }
}
