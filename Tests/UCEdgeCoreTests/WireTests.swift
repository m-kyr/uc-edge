import Foundation
import Testing
@testable import UCEdgeCore

@Suite struct WireTests {
    static let key = WireKey(hex: String(repeating: "0123456789abcdef", count: 4))!
    static let otherKey = WireKey(hex: String(repeating: "fedcba9876543210", count: 4))!
    static let now: Int64 = 1_790_000_000_000

    static let edge = PacketBody.edge(EdgePayload(x: -947.66, d: 0, pushing: true, spanMin: -1600, spanMax: 1600))
    static let hello = HelloPayload(
        version: "1.0.0", side: .bottom,
        displays: [EdgeDisplayInfo(uuid: UUID(uuidString: "8A000000-0000-4000-8000-0000000000A1")!, minX: -2560, width: 2560)],
        axTrusted: true)

    func packet(_ body: PacketBody = edge, sender: UInt64 = 42, seq: UInt64 = 1, wall: Int64 = now) -> Packet {
        Packet(senderId: sender, seq: seq, wallMs: wall, body: body)
    }

    @Test func roundTripAllTypes() throws {
        var ack = Self.hello
        ack.echoWallMs = Self.now - 7
        for body in [Self.edge, .hello(Self.hello), .helloAck(ack)] {
            let p = packet(body)
            let data = Wire.encode(p, key: Self.key)
            #expect(try Wire.decodeAuthenticated(data, key: Self.key) == p)
        }
        #expect(Wire.encode(packet(), key: Self.key).count == Wire.headerSize + Wire.edgeBodySize + Wire.macSize)
    }

    @Test func crossXRoundTripsAsNaNOrValue() throws {
        for cross in [nil, -948.46, 0.0] as [Double?] {
            let p = packet(.edge(EdgePayload(x: 12, d: 0.5, pushing: false, spanMin: -1600, spanMax: 1600, crossX: cross)))
            let back = try Wire.decodeAuthenticated(Wire.encode(p, key: Self.key), key: Self.key)
            #expect(back == p)
        }
        #expect(Wire.edgeBodySize == 42)
    }

    @Test func v13FieldsRoundTripAndOldPeersAreRejected() throws {
        let e = packet(.edge(EdgePayload(x: 1, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: 539.41, crossSource: .uc)))
        #expect(try Wire.decodeAuthenticated(Wire.encode(e, key: Self.key), key: Self.key) == e)
        var h = Self.hello
        h.ucLogActive = true
        let hp = packet(.hello(h))
        #expect(try Wire.decodeAuthenticated(Wire.encode(hp, key: Self.key), key: Self.key) == hp)
        // A 1.2 peer ("UCE1") is rejected cleanly, not misparsed.
        var old = [UInt8](Wire.encode(e, key: Self.key))
        old[3] = UInt8(ascii: "1")
        #expect(throws: WireError.badMagic) { try Wire.decodeAuthenticated(Data(old), key: Self.key) }
        // An unknown crossSource is a bad body (re-signed so the MAC is valid).
        var w = ByteWriter()
        w.bytes(Array(Wire.encode(e, key: Self.key).dropLast(Wire.macSize + 1)))
        w.u8(7)
        w.bytes(Array(Wire.mac(w.data, key: Self.key)))
        #expect(throws: WireError.badBody) { try Wire.decodeAuthenticated(w.data, key: Self.key) }
    }

    @Test func nonFiniteEdgeValuesAreRejected() {
        let bad: [EdgePayload] = [
            EdgePayload(x: .nan, d: 0, pushing: true, spanMin: -1600, spanMax: 1600),
            EdgePayload(x: 0, d: .infinity, pushing: true, spanMin: -1600, spanMax: 1600),
            EdgePayload(x: 0, d: 0, pushing: true, spanMin: -.infinity, spanMax: 1600),
            EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: .nan),
            EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: .infinity),
            EdgePayload(x: 0, d: 0, pushing: true, spanMin: -1600, spanMax: 1600, crossX: -.infinity),
        ]
        for e in bad {
            let data = Wire.encode(packet(.edge(e)), key: Self.key)
            #expect(throws: WireError.badBody) { try Wire.decodeAuthenticated(data, key: Self.key) }
        }
    }

    @Test func everyTamperedByteIsRejected() {
        let data = Wire.encode(packet(.hello(Self.hello)), key: Self.key)
        for i in 0..<data.count {
            var bad = data
            bad[i] ^= 0x01
            #expect(throws: WireError.self) { try Wire.decodeAuthenticated(bad, key: Self.key) }
        }
        var truncated = data
        truncated.removeLast()
        #expect(throws: WireError.self) { try Wire.decodeAuthenticated(truncated, key: Self.key) }
        #expect(throws: WireError.short) { try Wire.decodeAuthenticated(Data([1, 2, 3]), key: Self.key) }
    }

    @Test func wrongKeyIsRejected() {
        let data = Wire.encode(packet(), key: Self.key)
        #expect(throws: WireError.badMAC) { try Wire.decodeAuthenticated(data, key: Self.otherKey) }
    }

    @Test func replayedSeqIsRejected() throws {
        var rx = WireReceiver(key: Self.key)
        let a = Wire.encode(packet(seq: 5), key: Self.key)
        _ = try rx.accept(a, nowWallMs: Self.now)
        #expect(throws: WireError.duplicate) { try rx.accept(a, nowWallMs: Self.now) }
        #expect(throws: WireError.replay) { try rx.accept(Wire.encode(packet(seq: 4), key: Self.key), nowWallMs: Self.now) }
        _ = try rx.accept(Wire.encode(packet(seq: 6), key: Self.key), nowWallMs: Self.now)
    }

    @Test func staleWallClockIsRejected() throws {
        var rx = WireReceiver(key: Self.key)
        #expect(throws: WireError.staleClock) {
            try rx.accept(Wire.encode(packet(seq: 1, wall: Self.now - 10_001), key: Self.key), nowWallMs: Self.now)
        }
        #expect(throws: WireError.staleClock) {
            try rx.accept(Wire.encode(packet(seq: 2, wall: Self.now + 10_001), key: Self.key), nowWallMs: Self.now)
        }
        #expect(throws: WireError.staleClock) {
            try rx.accept(Wire.encode(packet(seq: 3, wall: .min), key: Self.key), nowWallMs: Self.now)
        }
        _ = try rx.accept(Wire.encode(packet(seq: 4, wall: Self.now - 10_000), key: Self.key), nowWallMs: Self.now)
    }

    @Test func newSenderIdIsAccepted() throws {
        var rx = WireReceiver(key: Self.key)
        _ = try rx.accept(Wire.encode(packet(sender: 1, seq: 100), key: Self.key), nowWallMs: Self.now)
        // A restarted peer has a new senderId and starts its seq again.
        let p = try rx.accept(Wire.encode(packet(sender: 2, seq: 1), key: Self.key), nowWallMs: Self.now)
        #expect(p.senderId == 2)
    }

    @Test func senderTableKeepsEightMostRecent() throws {
        var f = ReplayFilter()
        for id in UInt64(1)...8 { try f.check(packet(sender: id, seq: 10), nowWallMs: Self.now) }
        try f.check(packet(sender: 1, seq: 11), nowWallMs: Self.now)          // 1 is now most recent
        try f.check(packet(sender: 9, seq: 1), nowWallMs: Self.now)           // evicts 2
        #expect(throws: WireError.duplicate) { try f.check(packet(sender: 1, seq: 11), nowWallMs: Self.now) }
        #expect(throws: WireError.replay) { try f.check(packet(sender: 3, seq: 9), nowWallMs: Self.now) }
        try f.check(packet(sender: 2, seq: 1), nowWallMs: Self.now)           // forgotten, so accepted again
    }

    @Test func senderSeqIsStrictlyIncreasing() {
        var s = WireSender(senderId: 7)
        let a = s.packet(Self.edge, wallMs: 1), b = s.packet(Self.edge, wallMs: 1)
        #expect(a.senderId == 7 && b.seq == a.seq + 1)
    }

    @Test func keyParsingAndRedaction() {
        #expect(WireKey(hex: "abc") == nil)
        #expect(WireKey(hex: String(repeating: "zz", count: 32)) == nil)
        #expect(WireKey(hex: String(repeating: "ab", count: 32) + "\n") != nil)
        let text = "\(Self.key) \(String(reflecting: Self.key))"
        #expect(!text.contains("0123"))
        #expect(text.contains("redacted"))
    }
}
