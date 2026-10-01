import CryptoKit
import Foundation

// Wire protocol (SPEC §8). All multi-byte fields are little-endian.
//
// header  : "UCE2" | type u8 | senderId u64 | seq u64 | wallMs i64          (29 B)
// EDGE    : x f64 | d f64 | pushing u8 | spanMin f64 | spanMax f64 | crossX f64 (NaN = none)
//           | crossSource u8                                                  (42 B)
// HELLO   : version (u8 len + UTF-8) | side u8 | count u8 | count × (UUID 16 B | minX f64 | width f64)
//           | axTrusted u8 | ucLogActive u8 [| echoWallMs i64, HELLO_ACK only]
// v1.3 changed the magic from "UCE1" so a 1.2 peer and a 1.3 peer reject each other (badMagic).
// trailer : HMAC-SHA256(everything before it), first 16 bytes

public enum PacketType: UInt8, Sendable { case hello = 1, edge = 2, helloAck = 3 }

/// Where a crossX came from (§13): the sender's model latch, or UC's own "Activating" log line.
public enum CrossSource: UInt8, Sendable, Codable { case model = 0, uc = 1 }

public struct EdgePayload: Sendable, Equatable {
    public var x: Double, d: Double, pushing: Bool, spanMin: Double, spanMax: Double
    /// Latched UC exit x (§5.2); nil = not latched (NaN on the wire).
    public var crossX: Double?
    public var crossSource: CrossSource
    public init(x: Double, d: Double, pushing: Bool, spanMin: Double, spanMax: Double, crossX: Double? = nil,
                crossSource: CrossSource = .model) {
        self.x = x; self.d = d; self.pushing = pushing; self.spanMin = spanMin; self.spanMax = spanMax
        self.crossX = crossX; self.crossSource = crossSource
    }
}

/// One edge display as advertised in HELLO: its UUID and horizontal extent.
public struct EdgeDisplayInfo: Sendable, Equatable, Codable {
    public var uuid: UUID, minX: Double, width: Double
    public init(uuid: UUID, minX: Double, width: Double) { self.uuid = uuid; self.minX = minX; self.width = width }
}

public struct HelloPayload: Sendable, Equatable {
    public var version: String, side: EdgeSide, displays: [EdgeDisplayInfo], axTrusted: Bool
    /// The sender's UC log assist is delivering (§13.2.2): prefer its `crossSource = uc` packets.
    public var ucLogActive: Bool
    public var echoWallMs: Int64?          // HELLO_ACK only
    public init(version: String, side: EdgeSide, displays: [EdgeDisplayInfo], axTrusted: Bool,
                ucLogActive: Bool = false, echoWallMs: Int64? = nil) {
        self.version = version; self.side = side; self.displays = displays
        self.axTrusted = axTrusted; self.ucLogActive = ucLogActive; self.echoWallMs = echoWallMs
    }
}

public enum PacketBody: Sendable, Equatable {
    case hello(HelloPayload), edge(EdgePayload), helloAck(HelloPayload)
    public var type: PacketType {
        switch self { case .hello: .hello; case .edge: .edge; case .helloAck: .helloAck }
    }
}

public struct Packet: Sendable, Equatable {
    public var senderId: UInt64, seq: UInt64, wallMs: Int64, body: PacketBody
    public init(senderId: UInt64, seq: UInt64, wallMs: Int64, body: PacketBody) {
        self.senderId = senderId; self.seq = seq; self.wallMs = wallMs; self.body = body
    }
}

public enum WireError: String, Error, Sendable, CaseIterable {
    case short, badMagic, badType, badBody, badMAC, staleClock, replay
    /// seq equal to the last one seen: our own duplicate copy of an at-edge packet (§5.2)
    /// whose original arrived. Rejected like a replay, but expected and not worth logging.
    case duplicate
}

/// The shared 32-byte key. Its description never reveals key material.
public struct WireKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let key: SymmetricKey

    public init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        key = SymmetricKey(data: bytes)
    }

    /// Exactly 64 hex digits, optionally followed by one newline. Nothing else is accepted.
    public init?(hex: String) {
        var chars = Array(hex.utf8)
        if chars.last == UInt8(ascii: "\n") { chars.removeLast() }
        guard chars.count == 64 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var out = Data(capacity: 32)
        for i in stride(from: 0, to: 64, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        self.init(bytes: out)
    }

    /// Reads a key file. Returns nil when the file is missing or malformed; never logs content.
    public static func load(path: String) -> WireKey? {
        guard let data = FileManager.default.contents(atPath: path),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return WireKey(hex: s)
    }

    /// v1.2: the key file must not be readable or writable by group or others.
    public static func fileIsPrivate(path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? Int else { return false }
        return mode & 0o077 == 0
    }

    public var description: String { "WireKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum Wire {
    public static let magic: [UInt8] = Array("UCE2".utf8)
    public static let headerSize = 29
    public static let macSize = 16
    public static let edgeBodySize = 42

    public static func encode(_ p: Packet, key: WireKey) -> Data {
        var w = ByteWriter()
        w.bytes(magic)
        w.u8(p.body.type.rawValue)
        w.u64(p.senderId)
        w.u64(p.seq)
        w.i64(p.wallMs)
        switch p.body {
        case .edge(let e):
            w.f64(e.x); w.f64(e.d); w.u8(e.pushing ? 1 : 0); w.f64(e.spanMin); w.f64(e.spanMax)
            w.f64(e.crossX ?? .nan)
            w.u8(e.crossSource.rawValue)
        case .hello(let h):
            writeHello(h, ack: false, into: &w)
        case .helloAck(let h):
            writeHello(h, ack: true, into: &w)
        }
        w.bytes(Array(mac(w.data, key: key)))
        return w.data
    }

    /// Checks 1 (length, magic) and 2 (HMAC), then parses. Clock and replay checks are
    /// `ReplayFilter`'s job, so a decoder alone can be used by tests and tools.
    public static func decodeAuthenticated(_ data: Data, key: WireKey) throws(WireError) -> Packet {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize + macSize else { throw .short }
        guard Array(bytes[0..<4]) == magic else { throw .badMagic }
        let signed = bytes[0..<(bytes.count - macSize)]
        let expected = mac(Data(signed), key: key)
        guard constantTimeEqual(Array(expected), Array(bytes[(bytes.count - macSize)...])) else { throw .badMAC }

        var r = ByteReader(bytes: Array(signed))
        _ = try r.bytes(4)
        guard let type = PacketType(rawValue: try r.u8()) else { throw .badType }
        let senderId = try r.u64(), seq = try r.u64(), wallMs = try r.i64()
        let body: PacketBody
        switch type {
        case .edge:
            let x = try r.f64(), d = try r.f64(), pushing = try r.u8() != 0
            let lo = try r.f64(), hi = try r.f64(), cross = try r.f64()
            guard x.isFinite, d.isFinite, lo.isFinite, hi.isFinite, cross.isFinite || cross.isNaN,
                  let source = CrossSource(rawValue: try r.u8()) else { throw .badBody }
            body = .edge(EdgePayload(x: x, d: d, pushing: pushing, spanMin: lo, spanMax: hi,
                                     crossX: cross.isNaN ? nil : cross, crossSource: source))
        case .hello:
            body = .hello(try readHello(&r, ack: false))
        case .helloAck:
            body = .helloAck(try readHello(&r, ack: true))
        }
        guard r.atEnd else { throw .badBody }
        return Packet(senderId: senderId, seq: seq, wallMs: wallMs, body: body)
    }

    static func mac(_ data: Data, key: WireKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key.key)).prefix(macSize)
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private static func writeHello(_ h: HelloPayload, ack: Bool, into w: inout ByteWriter) {
        let v = Array(h.version.utf8.prefix(255))
        w.u8(UInt8(v.count)); w.bytes(v)
        w.u8(h.side == .top ? 0 : 1)
        let ds = h.displays.prefix(255)
        w.u8(UInt8(ds.count))
        for d in ds {
            let u = d.uuid.uuid
            w.bytes([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
            w.f64(d.minX); w.f64(d.width)
        }
        w.u8(h.axTrusted ? 1 : 0)
        w.u8(h.ucLogActive ? 1 : 0)
        if ack { w.i64(h.echoWallMs ?? 0) }
    }

    private static func readHello(_ r: inout ByteReader, ack: Bool) throws(WireError) -> HelloPayload {
        let vlen = Int(try r.u8())
        guard let version = String(bytes: try r.bytes(vlen), encoding: .utf8) else { throw .badBody }
        let sideRaw = try r.u8()
        guard sideRaw <= 1 else { throw .badBody }
        let count = Int(try r.u8())
        var displays: [EdgeDisplayInfo] = []
        for _ in 0..<count {
            let b = try r.bytes(16)
            let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            let minX = try r.f64(), width = try r.f64()
            guard minX.isFinite, width.isFinite, width > 0 else { throw .badBody }
            displays.append(EdgeDisplayInfo(uuid: uuid, minX: minX, width: width))
        }
        let ax = try r.u8() != 0
        let ucLog = try r.u8() != 0
        let echo: Int64? = ack ? try r.i64() : nil
        return HelloPayload(version: version, side: sideRaw == 0 ? .top : .bottom,
                            displays: displays, axTrusted: ax, ucLogActive: ucLog, echoWallMs: echo)
    }
}

/// Receive checks 3 and 4 (SPEC §8): wall-clock sanity and a strictly increasing seq per
/// sender, remembering at most `maxSenders` senders (least recently used is dropped).
public struct ReplayFilter: Sendable {
    public let maxSkewMs: Int64
    public let maxSenders: Int
    private var senders: [(id: UInt64, seq: UInt64)] = []   // most recently used last

    public init(maxSkewMs: Int64 = 10_000, maxSenders: Int = 8) {
        self.maxSkewMs = maxSkewMs; self.maxSenders = maxSenders
    }

    public mutating func check(_ p: Packet, nowWallMs: Int64) throws(WireError) {
        let skew = nowWallMs.subtractingReportingOverflow(p.wallMs)
        guard !skew.overflow, skew.partialValue.magnitude <= UInt64(maxSkewMs) else { throw .staleClock }
        if let i = senders.firstIndex(where: { $0.id == p.senderId }) {
            guard p.seq != senders[i].seq else { throw .duplicate }
            guard p.seq > senders[i].seq else { throw .replay }
            senders.remove(at: i)
        } else if senders.count >= maxSenders {
            senders.removeFirst()
        }
        senders.append((p.senderId, p.seq))
    }
}

/// Decode + all four receive checks, in SPEC order.
public struct WireReceiver: Sendable {
    public let key: WireKey
    public var replay = ReplayFilter()
    public init(key: WireKey) { self.key = key }

    public mutating func accept(_ data: Data, nowWallMs: Int64) throws(WireError) -> Packet {
        let p = try Wire.decodeAuthenticated(data, key: key)
        try replay.check(p, nowWallMs: nowWallMs)
        return p
    }
}

/// Stamps outgoing packets with this process's sender id and a strictly increasing seq.
public struct WireSender: Sendable {
    public let senderId: UInt64
    public private(set) var seq: UInt64 = 0
    public init(senderId: UInt64 = UInt64.random(in: 1...UInt64.max)) { self.senderId = senderId }

    public mutating func packet(_ body: PacketBody, wallMs: Int64) -> Packet {
        seq += 1
        return Packet(senderId: senderId, seq: seq, wallMs: wallMs, body: body)
    }
}

public func currentWallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

struct ByteWriter {
    var data = Data()
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos = 0
    var atEnd: Bool { pos == bytes.count }

    mutating func bytes(_ n: Int) throws(WireError) -> [UInt8] {
        guard n >= 0, pos + n <= bytes.count else { throw .badBody }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }
    mutating func u8() throws(WireError) -> UInt8 { try bytes(1)[0] }
    mutating func u64() throws(WireError) -> UInt64 {
        let b = try bytes(8)
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[i]) }
        return v
    }
    mutating func i64() throws(WireError) -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f64() throws(WireError) -> Double { Double(bitPattern: try u64()) }
}
