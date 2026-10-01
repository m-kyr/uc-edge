import CoreGraphics
import Foundation

// UC log assist (SPEC §13): the pure parts. The `log stream` child lives in the system layer.

/// One "Hot Zone: Entering/Activating: <edge>:<device>:<display UUID>…" line from UniversalControl.
public struct UCLogEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case entering, activating }
    public var kind: Kind
    /// "top", "bottom", "left" or "right".
    public var edge: String
    public var device: String
    public var displayUUID: String
    /// mach_continuous_time ticks (includes sleep).
    public var machTimestamp: UInt64

    public init(kind: Kind, edge: String, device: String, displayUUID: String, machTimestamp: UInt64) {
        self.kind = kind; self.edge = edge; self.device = device
        self.displayUUID = displayUUID; self.machTimestamp = machTimestamp
    }
}

public enum UCLogParser {
    private struct Line: Decodable {
        let eventMessage: String?
        let machTimestamp: UInt64?
    }

    /// One line of `log stream --style ndjson`. nil for the text header, other messages, or junk.
    public static func parse(ndjsonLine line: String) -> UCLogEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"),
              let l = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8)),
              let message = l.eventMessage, let mach = l.machTimestamp else { return nil }
        return parse(message: message, machTimestamp: mach)
    }

    /// The message part: "Hot Zone: Activating: top:31000000:8A000000-…" (Entering adds ":[…]:guarded=…").
    public static func parse(message: String, machTimestamp: UInt64) -> UCLogEvent? {
        let kind: UCLogEvent.Kind
        let rest: Substring
        if message.hasPrefix("Hot Zone: Activating: ") {
            kind = .activating
            rest = message.dropFirst("Hot Zone: Activating: ".count)
        } else if message.hasPrefix("Hot Zone: Entering: ") {
            kind = .entering
            rest = message.dropFirst("Hot Zone: Entering: ".count)
        } else {
            return nil
        }
        let parts = rest.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, ["top", "bottom", "left", "right"].contains(String(parts[0])),
              UUID(uuidString: String(parts[2])) != nil else { return nil }
        return UCLogEvent(kind: kind, edge: String(parts[0]), device: String(parts[1]),
                          displayUUID: String(parts[2]).uppercased(), machTimestamp: machTimestamp)
    }
}

/// Converts UC's mach_continuous_time timestamps to uptime nanoseconds (CGEvent.timestamp's
/// domain): `ns = (mach − (continuous − absolute)) × numer / denom`, the offset sampled at receipt.
public struct UCLogClock: Sendable, Equatable {
    public var numer: UInt32, denom: UInt32
    /// Sanity bounds: a converted time outside [now − 2 s, now + 5 ms] is a clock error.
    public static let sanityLagNs: Int64 = 2_000_000_000
    public static let maxLeadNs: Int64 = 5_000_000
    /// v1.3.1 (F3): a line delivered later than this is too late to use (default; configurable).
    public static let maxLagNs: Int64 = 100_000_000

    public init(numer: UInt32, denom: UInt32) {
        self.numer = max(numer, 1); self.denom = max(denom, 1)
    }

    /// `continuousMinusAbsolute` in ticks. nil when the value doesn't fit.
    public func uptimeNs(machContinuous: UInt64, continuousMinusAbsolute: UInt64) -> UInt64? {
        guard machContinuous >= continuousMinusAbsolute else { return nil }
        let ticks = machContinuous - continuousMinusAbsolute
        let (hi, lo) = ticks.multipliedFullWidth(by: UInt64(numer))
        guard hi < UInt64(denom) else { return nil }
        return UInt64(denom).dividingFullWidth((hi, lo)).quotient
    }

    /// Ticks for an uptime (tests and fakes).
    public func ticks(uptimeNs: UInt64) -> UInt64 {
        let (hi, lo) = uptimeNs.multipliedFullWidth(by: UInt64(denom))
        guard hi < UInt64(numer) else { return .max }
        return UInt64(numer).dividingFullWidth((hi, lo)).quotient
    }

    /// The §13 sanity check on the receive lag (clock errors).
    public static func lagIsSane(eventNs: UInt64, nowNs: UInt64) -> Bool {
        let lag = Int64(bitPattern: nowNs &- eventNs)
        return lag >= -maxLeadNs && lag <= sanityLagNs
    }

    /// v1.3.1 (F3): only lines delivered within `maxLagNs` are used.
    public static func lagIsAcceptable(eventNs: UInt64, nowNs: UInt64, maxLagNs: Int64 = UCLogClock.maxLagNs) -> Bool {
        Int64(bitPattern: nowNs &- eventNs) <= maxLagNs
    }

    /// v1.3.1 (F1): sample the continuous − absolute offset. Read absolute first, then continuous,
    /// so on a Mac that never slept (true offset 0) a tick between the reads can't wrap it negative;
    /// a negative difference is clamped to 0.
    public static func sampleOffset(absolute: UInt64, continuous: UInt64) -> UInt64 {
        continuous >= absolute ? continuous - absolute : 0
    }
}

public enum UCLogFilter {
    /// An Activating line for our shared edge, toward one of the peer's edge displays.
    public static func accepts(_ e: UCLogEvent, localSide: EdgeSide, peerDisplays: [UUID]) -> Bool {
        e.kind == .activating && e.edge == localSide.rawValue
            && peerDisplays.contains { $0.uuidString.caseInsensitiveCompare(e.displayUUID) == .orderedSame }
    }
}

/// A local tap event as the matcher keeps it.
public struct UCTapRecord: Sendable, Equatable {
    public var ns: UInt64
    public var x: Double, y: Double, s: Double, dy: Double
    public init(ns: UInt64, x: Double, y: Double, s: Double, dy: Double) {
        self.ns = ns; self.x = x; self.y = y; self.s = s; self.dy = dy
    }
}

/// The last 2 s of local tap events, and the §13 match: the latest event at the edge with
/// `ns ≤ activation`, at most 100 ms before it. Not thread-safe.
public final class UCCrossMatcher {
    public static let keepNs: UInt64 = 2_000_000_000
    public static let maxAgeNs: UInt64 = 100_000_000
    private var events: [UCTapRecord] = []

    public init() {}

    public var count: Int { events.count }

    public func record(_ e: UCTapRecord) {
        if let last = events.last, e.ns < last.ns {
            // Out of order (rare): keep the buffer sorted.
            let i = events.firstIndex { $0.ns > e.ns } ?? events.endIndex
            events.insert(e, at: i)
        } else {
            events.append(e)
        }
        let newest = events.last?.ns ?? e.ns
        if let firstKeep = events.firstIndex(where: { newest - $0.ns <= Self.keepNs }), firstKeep > 0 {
            events.removeFirst(firstKeep)
        }
    }

    public func match(activationNs: UInt64, atEdgePt: Double = 1.5) -> UCTapRecord? {
        for e in events.reversed() where e.ns <= activationNs {
            guard activationNs - e.ns <= Self.maxAgeNs else { return nil }
            if e.s >= -1 && e.s <= atEdgePt { return e }
        }
        return nil
    }
}

/// Keeps a UC-sourced crossX for the tail packets of the same edge visit, with the latch's
/// reset rules (gap > 100 ms, s > 30 or s < −1, 150 ms after it was set). Not thread-safe.
public struct UCCrossHold: Sendable, Equatable {
    public private(set) var crossX: Double?
    private var setT = 0.0
    private var prevT = -Double.infinity

    public init() {}

    public mutating func set(_ x: Double, at t: Double) {
        crossX = x
        setT = t
    }

    /// Call on every local event (t in ms, s = signed distance). Returns the held crossX.
    @discardableResult
    public mutating func onEvent(t: Double, s: Double) -> Double? {
        if t - prevT > CrossLatch.maxGapMs || s > CrossLatch.maxDepthPt || s < -1
            || (crossX != nil && t - setT > CrossLatch.holdMs) {
            crossX = nil
        }
        prevT = t
        return crossX
    }

    public mutating func reset() { crossX = nil; prevT = -.infinity }
}

/// The local cursor's current visit to the edge, with the latch's reset rules (gap > 100 ms,
/// s > 30, s < −1). v1.3.1 (F3): a UC activation only counts if its event belongs to this visit.
public struct UCEdgeVisit: Sendable, Equatable {
    public private(set) var startNs: UInt64?
    private var prevT = -Double.infinity

    public init() {}

    /// Call on every local event (t in ms, ns = its timestamp, s = signed distance).
    public mutating func onEvent(t: Double, ns: UInt64, s: Double) {
        let gap = t - prevT > CrossLatch.maxGapMs
        prevT = t
        if s > CrossLatch.maxDepthPt || s < -1 { startNs = nil; return }
        if gap || startNs == nil { startNs = ns }
    }

    /// The matched event is part of the current visit.
    public func contains(ns: UInt64) -> Bool {
        guard let start = startNs else { return false }
        return ns >= start
    }
}

/// v1.3 receiver gate: with the peer's log assist active, only UC-sourced crossX counts. Kept for
/// reference; v1.3.1 replaced it by the detector's `ucWaitMs` deferral (§13.4).
public enum CrossSourcePolicy {
    public static func usableCrossX(_ crossX: Double?, source: CrossSource, peerUCLogActive: Bool) -> Double? {
        guard let crossX else { return nil }
        return !peerUCLogActive || source == .uc ? crossX : nil
    }
}

/// v1.3.1 (F4): recognising orphaned `log stream` children of earlier UCEdge instances.
public enum UCLogOrphan {
    /// Exactly the command line UCEdge starts.
    public static func argv(predicate: String) -> [String] {
        ["/usr/bin/log", "stream", "--style", "ndjson", "--predicate", predicate]
    }

    /// An orphan to kill: our uid, reparented to launchd (ppid 1), and exactly our command line.
    public static func isOrphan(argv: [String], ppid: Int32, uid: UInt32, myUID: UInt32, predicate: String) -> Bool {
        ppid == 1 && uid == myUID && argv == Self.argv(predicate: predicate)
    }

    /// Parses a KERN_PROCARGS2 buffer: argc (Int32), the exec path, NUL padding, then argc strings.
    public static func parseProcArgs2(_ buf: [UInt8]) -> [String]? {
        guard buf.count >= 4 else { return nil }
        let argc = Int(Int32(littleEndian: buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc > 0, argc < 4096 else { return nil }
        var i = 4
        while i < buf.count && buf[i] != 0 { i += 1 }          // exec path
        while i < buf.count && buf[i] == 0 { i += 1 }          // padding
        var args: [String] = []
        while args.count < argc && i < buf.count {
            let start = i
            while i < buf.count && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.count == argc ? args : nil
    }
}

/// Splits a byte stream into newline-terminated lines, dropping a partial line that grows past
/// `maxBytes` (v1.3.1, F6). Not thread-safe.
public struct LineSplitter: Sendable {
    public let maxBytes: Int
    private var pending: [UInt8] = []
    public private(set) var overflows = 0

    public init(maxBytes: Int = 64 * 1024) { self.maxBytes = maxBytes }

    /// Complete lines contained in `bytes` (plus what was buffered before).
    public mutating func append(_ bytes: some Collection<UInt8>) -> [String] {
        pending.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        for i in pending.indices where pending[i] == 0x0A {
            lines.append(String(decoding: pending[start..<i], as: UTF8.self))
            start = i + 1
        }
        pending.removeFirst(start)
        if pending.count > maxBytes {
            pending.removeAll()
            overflows += 1
        }
        return lines
    }
}
