/// NTP-style estimate of the peer's wall clock minus ours, from HELLO → HELLO_ACK exchanges
/// (SPEC §5.3 v1.2). Only low-RTT samples are used, smoothed. All arithmetic is in Double,
/// so no peer-supplied value can overflow.
public struct ClockOffsetEstimator: Sendable, Equatable {
    /// Samples with a round trip at least this long are ignored.
    public static let maxRTTMs = 50.0
    /// Slack on top of `freshMs` for the sender-age check, with and without an offset estimate.
    public static let slackWithOffsetMs = 50.0
    public static let slackWithoutOffsetMs = 500.0
    static let smoothing = 0.2
    /// A good sample this far from the estimate is a clock step: adopt it at once (v1.2.1, N3).
    public static let stepMs = 200.0

    /// Peer clock − our clock, in ms. nil until a usable sample arrived.
    public private(set) var offsetMs: Double?
    public private(set) var samples = 0

    public init() {}

    /// `sentWallMs`: our clock when we sent the HELLO (echoed back); `peerWallMs`: the peer's
    /// clock when it sent the ACK; `receivedWallMs`: our clock when the ACK arrived.
    /// Returns the round trip when the sample was used.
    @discardableResult
    public mutating func add(sentWallMs: Int64, peerWallMs: Int64, receivedWallMs: Int64) -> Double? {
        let t0 = Double(sentWallMs), t1 = Double(peerWallMs), t3 = Double(receivedWallMs)
        let rtt = t3 - t0
        guard rtt.isFinite, rtt >= 0, rtt < Self.maxRTTMs else { return nil }
        let sample = t1 - (t0 + t3) / 2
        guard sample.isFinite, abs(sample) < 86_400_000 else { return nil }
        if let o = offsetMs, abs(sample - o) <= Self.stepMs {
            offsetMs = o + Self.smoothing * (sample - o)
        } else {
            offsetMs = sample
        }
        samples += 1
        return rtt
    }

    /// How long ago (ms, our clock) a packet stamped `wallMs` by the peer was sent, and the
    /// slack to allow on top of `freshMs` for that estimate.
    public func senderLag(wallMs: Int64, nowWallMs: Int64) -> (lagMs: Double, slackMs: Double) {
        let raw = Double(nowWallMs) - Double(wallMs)
        guard let o = offsetMs else { return (raw, Self.slackWithoutOffsetMs) }
        return (raw + o, Self.slackWithOffsetMs)
    }
}
