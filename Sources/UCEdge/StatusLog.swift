import CoreGraphics
import Foundation
import UCEdgeCore

/// Append-only log with size rotation (2 MB, keeps `.1` and `.2`). Writes happen on a
/// background queue so callers never block on disk.
final class Logger: @unchecked Sendable {
    static let maxBytes: UInt64 = 2 * 1024 * 1024
    static let keep = 2

    private let path: String?
    private let echo: Bool
    private let queue = DispatchQueue(label: "uc-edge.log", qos: .utility)
    /// Only touched on `queue`.
    var handle: FileHandle?
    private var size: UInt64 = 0
    /// Lines dropped because a write failed (disk full, I/O error, …).
    private(set) var droppedLines = 0
    private let stampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    /// `path` nil = no file; `echo` also writes to stderr (launchd.log when run by launchd).
    init(path: String?, echo: Bool = false) {
        self.path = path.map(expandTilde)
        self.echo = echo
    }

    func log(_ message: String) {
        let line = "\(Date().formatted(stampFormat)) \(message)\n"
        queue.async { [self] in write(line) }
    }

    /// Blocks until queued lines are written.
    func flush() { queue.sync {} }

    /// Runs `body` on the logger's queue (tests use it to swap the handle).
    func onQueue(_ body: (Logger) -> Void) { queue.sync { body(self) } }

    /// Never throws or aborts: a failed write drops the line and reopens the file next time.
    private func write(_ line: String) {
        let data = Data(line.utf8)
        if echo { try? FileHandle.standardError.write(contentsOf: data) }
        guard let path else { return }
        if handle == nil { open(path) }
        guard let h = handle else { droppedLines += 1; return }
        do {
            try h.write(contentsOf: data)
        } catch {
            droppedLines += 1
            try? h.close()
            handle = nil
            return
        }
        size += UInt64(data.count)
        if size >= Self.maxBytes { rotate(path) }
    }

    private func open(_ path: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate(_ path: String) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(path).\(Self.keep)")
        for i in stride(from: Self.keep - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(path).\(i)", toPath: "\(path).\(i + 1)")
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        open(path)
    }
}

/// Counts events per key and logs at most once per `intervalSec` per key.
struct RateLimitedCounter {
    private(set) var counts: [String: Int] = [:]
    private var lastLogged: [String: Double] = [:]
    var intervalSec = 10.0

    /// Returns the count to report when this occurrence should be logged.
    mutating func hit(_ key: String, now: Double) -> Int? {
        counts[key, default: 0] += 1
        if let last = lastLogged[key], now - last < intervalSec * 1000 { return nil }
        lastLogged[key] = now
        return counts[key]
    }
}

struct PointJSON: Codable, Equatable, Sendable {
    var x: Double, y: Double
    init(_ p: CGPoint) { x = (Double(p.x) * 100).rounded() / 100; y = (Double(p.y) * 100).rounded() / 100 }
    var text: String { String(format: "(%.1f, %.1f)", x, y) }
}

struct CorrectionRecord: Codable, Equatable, Sendable {
    var at: Date
    var kind: String
    /// Where the peer's crossX came from: "uc" (UC's log) or "model" (the sender's latch).
    var crossSource: String
    var landing: PointJSON
    var target: PointJSON
    var peerX: Double
    var peerAgeMs: Double
    var latencyUs: Double
    var warped: Bool
    var note: String?
}

/// Everything `UCEdge status` shows. Written to status.json.
struct StatusSnapshot: Codable, Sendable {
    struct Permissions: Codable, Sendable {
        var accessibility = false, listenEvents = false, tapActive = false, pollingFallback = false
    }
    struct Peer: Codable, Sendable {
        var alive = false
        var lastPacketAgeMs: Double?
        var rttMs: Double?
        /// Peer wall clock − ours (NTP-style, from HELLO/HELLO_ACK with RTT < 50 ms).
        var clockOffsetMs: Double?
        var sideConflict = false
        var address: String?
        var addressLearned = false
        var version: String?
        var axTrusted: Bool?
        var edgeDisplays: [EdgeDisplayInfo] = []
    }
    struct Geometry: Codable, Sendable {
        var side: String = ""
        var edgeY = 0.0, spanMin = 0.0, spanMax = 0.0
        var displaysFound: [String] = []
        var displaysMissing: [String] = []
    }
    struct Arrangement: Codable, Sendable {
        var source = "fallback"           // parsed | fallback | waitingForPeer
        var zoneMinX: Double?, zoneMaxX: Double?
        var ucLinkMissing = false
        var note: String?
    }
    struct UCLog: Codable, Sendable {
        var state = "disabled"                 // running | restarting | stopped | disabled
        var active = false                     // what our HELLO advertises
        var linesParsed = 0
        var lastLineAgeMs: Double?
        var clockErrors = 0
        var activations = 0, matched = 0, unmatched = 0, ignored = 0
        /// v1.3.1: lines delivered later than `maxLagMs`, matches for an earlier edge visit,
        /// and over-long output dropped by the reader.
        var lateLines = 0, staleVisit = 0, overflows = 0
        var restarts = 0
        var peerActive = false
    }
    struct Counters: Codable, Sendable {
        var immediate = 0, late = 0, snapback = 0
        var skippedButtons = 0, skippedSmall = 0, warpFailures = 0, deadStripRedirects = 0
        var packetsSent = 0, packetsReceived = 0, sendErrors = 0, duplicates = 0
        var recvErrors = 0, episodeRejects = 0
        /// crossX sent from UC's log vs from the model latch (sender side).
        var ucCross = 0, modelCross = 0
        /// Receiver: landings held for a UC-sourced crossX, and those that fell back to the model's.
        var deferred = 0, deferredFallbacks = 0
        /// v1.4: re-warps after UC positioned the cursor absolutely over our correction.
        var overrideRewarps = 0
        var rejects: [String: Int] = [:]
    }

    var version = UCEdgeVersion.string
    var name = ""
    var pid = Int(ProcessInfo.processInfo.processIdentifier)
    var startedAt = Date()
    var updatedAt = Date()
    var keyMissing = false
    var keyInsecure = false
    var configErrors: [String] = []
    var configWarnings: [String] = []
    var warpFailing = false
    var netError: String?
    var permissions = Permissions()
    var peer = Peer()
    var geometry = Geometry()
    var arrangement = Arrangement()
    var deadStripEnabled = false
    var deadStripLastNearMiss: String?
    var correctionsEnabled = true
    var ucLog = UCLog()
    var counters = Counters()
    var lastCorrections: [CorrectionRecord] = []
}

enum StatusFile {
    static func write(_ s: StatusSnapshot, to path: String) {
        let p = expandTilde(path)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        // Never let one odd value stop status updates.
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    static func read(from path: String) throws -> StatusSnapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try dec.decode(StatusSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: expandTilde(path))))
    }

    /// Human summary for `UCEdge status`.
    static func summary(_ s: StatusSnapshot, now: Date = Date()) -> String {
        func yn(_ b: Bool) -> String { b ? "yes" : "NO" }
        func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "-" }
        let age = now.timeIntervalSince(s.updatedAt)
        var out: [String] = []
        out.append("UCEdge \(s.version) [\(s.name)] pid \(s.pid), up since \(s.startedAt.formatted(date: .omitted, time: .standard))"
                   + (age > 15 ? "  (status is \(Int(age)) s old: not running?)" : ""))
        var alerts: [String] = []
        if s.keyMissing { alerts.append("keyMissing") }
        if s.keyInsecure { alerts.append("keyInsecure (chmod 600 the key)") }
        if !s.configErrors.isEmpty { alerts.append("config errors: " + s.configErrors.joined(separator: "; ")) }
        if s.peer.sideConflict { alerts.append("peer uses the same edge side as us") }
        if s.warpFailing { alerts.append("warpFailing") }
        if s.arrangement.ucLinkMissing { alerts.append("ucLinkMissing") }
        if s.permissions.pollingFallback { alerts.append("tap unavailable: polling fallback") }
        if let e = s.netError { alerts.append("netError: \(e)") }
        if !alerts.isEmpty { out.append("ALERTS: " + alerts.joined(separator: ", ")) }
        let p = s.permissions
        out.append("permissions: accessibility \(yn(p.accessibility)), input monitoring \(yn(p.listenEvents)), tap \(p.tapActive ? "active" : "inactive")")
        let pe = s.peer
        out.append("peer: \(pe.alive ? "alive" : "NOT alive"), rtt \(f(pe.rttMs)) ms, clock offset \(f(pe.clockOffsetMs)) ms, last packet \(f(pe.lastPacketAgeMs, 0)) ms ago, "
                   + "address \(pe.address ?? "-")\(pe.addressLearned ? " (learned)" : " (dns)")"
                   + (pe.version.map { ", v\($0)" } ?? "") + (pe.axTrusted == false ? ", peer lacks Accessibility" : ""))
        let g = s.geometry
        out.append("geometry: side \(g.side), edgeY \(f(g.edgeY)), span [\(f(g.spanMin)), \(f(g.spanMax))], "
                   + "displays \(g.displaysFound.count) found" + (g.displaysMissing.isEmpty ? "" : ", MISSING \(g.displaysMissing.joined(separator: " "))"))
        let a = s.arrangement
        out.append("arrangement: \(a.source), zone [\(f(a.zoneMinX)), \(f(a.zoneMaxX))], linkMissing \(a.ucLinkMissing)"
                   + (a.note.map { " (\($0))" } ?? "") + ", dead strip \(s.deadStripEnabled ? "on" : "off")")
        let c = s.counters
        let u = s.ucLog
        out.append("uc log: \(u.state)\(u.active ? " (active)" : ""), lines \(u.linesParsed), last \(f(u.lastLineAgeMs, 0)) ms ago, "
                   + "activations \(u.activations) (matched \(u.matched), unmatched \(u.unmatched), ignored \(u.ignored), "
                   + "late \(u.lateLines), stale visit \(u.staleVisit)), "
                   + "clock errors \(u.clockErrors), restarts \(u.restarts); peer's \(u.peerActive ? "active" : "inactive")")
        out.append("corrections \(s.correctionsEnabled ? "enabled" : "DISABLED (this Mac only sends)"); crossX sent: uc \(s.counters.ucCross), model \(s.counters.modelCross)")
        if let m = s.deadStripLastNearMiss { out.append("dead strip last near-miss: \(m)") }
        out.append("counters: immediate \(c.immediate), late \(c.late), snapback \(c.snapback), override \(c.overrideRewarps), deadStrip \(c.deadStripRedirects), "
                   + "skipped(button) \(c.skippedButtons), skipped(<2pt) \(c.skippedSmall), warpFail \(c.warpFailures)")
        let rejects = c.rejects.isEmpty ? "0" : c.rejects.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        out.append("packets: sent \(c.packetsSent), received \(c.packetsReceived), duplicates \(c.duplicates), "
                   + "sendErrors \(c.sendErrors), recvErrors \(c.recvErrors), rejects \(rejects), episode rejects \(c.episodeRejects)")
        if !s.configWarnings.isEmpty { out.append("config warnings: " + s.configWarnings.joined(separator: "; ")) }
        out.append("last corrections (\(s.lastCorrections.count)):")
        for r in s.lastCorrections.suffix(10).reversed() {
            out.append("  \(r.at.formatted(date: .omitted, time: .standard)) \(r.kind.padding(toLength: 9, withPad: " ", startingAt: 0)) [\(r.crossSource)] "
                       + "landing \(r.landing.text) -> target \(r.target.text) peerX \(f(r.peerX)) "
                       + "age \(f(r.peerAgeMs, 0)) ms latency \(f(r.latencyUs, 0)) us" + (r.warped ? "" : " [not warped: \(r.note ?? "?")]"))
        }
        return out.joined(separator: "\n")
    }
}

enum UCEdgeVersion {
    static let string = "1.4.0"
}

/// launchd's stdout/stderr file (the LaunchAgent plist points it here). It is not rotated by
/// launchd, so it is trimmed at startup (v1.2.1).
enum LaunchdLog {
    static let path = "~/Library/Logs/UCEdge/launchd.log"

    /// Over `maxBytes`: keep the last `keepBytes`, from a line start. Truncates in place, so the
    /// append-mode descriptors launchd gave us keep working. Returns whether it trimmed.
    @discardableResult
    static func trim(path: String = LaunchdLog.path, maxBytes: UInt64 = 1 << 20, keepBytes: Int = 64 << 10) -> Bool {
        let p = expandTilde(path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.uint64Value,
              size > maxBytes, let h = FileHandle(forUpdatingAtPath: p) else { return false }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: size - UInt64(min(keepBytes, Int(size))))
            var tail = try h.readToEnd() ?? Data()
            if let nl = tail.firstIndex(of: 0x0A) { tail = Data(tail[tail.index(after: nl)...]) }
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: tail)
            return true
        } catch {
            return false
        }
    }
}
