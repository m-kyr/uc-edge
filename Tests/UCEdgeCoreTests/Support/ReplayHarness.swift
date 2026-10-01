import CoreGraphics
import Foundation
import UCEdgeCore

/// An EDGE packet as the receiver's detector sees it.
struct SynthPacket: Sendable {
    var sendT: Double       // source trace time
    var arriveT: Double     // receiver trace time
    var x: Double
    var d: Double
    var pushing: Bool
    var spanMin: Double
    var spanMax: Double
    /// The x UC crossed at, latched by the sender (§5.2 v1.1); nil until latched.
    var crossX: Double? = nil
    /// Send-to-arrival latency, as the receiver estimates it from the sender's clock (§12 v1.2).
    var lagMs: Double? = nil

    /// §5.3 v1.1: only a latched packet is "at edge", and targets map crossX.
    var isLatched: Bool { crossX.map(\.isFinite) ?? false }

    /// `episodeStart`: arrival of the first packet after a > 150 ms gap (§12 v1.2); nil = rule off.
    func peerState(episodeStart: Double? = nil) -> PeerEdgeState {
        PeerEdgeState(x: x, d: d, pushing: pushing, spanMin: spanMin, spanMax: spanMax, receivedAt: arriveT, crossX: crossX,
                      episodeStart: episodeStart, senderLagMs: lagMs)
    }
}

/// Independent model of the §5.2 crossX latch (latchrules.py rule "d+"): UC logs "Entering" on
/// the first event inside its 1 pt hot zone and "Activating" on the next event whose delta points
/// into the edge; its exit x is that event's x (all 7 s2 crossings). v1.2 (§12): one latch per edge
/// visit, so after the hold expires it stays spent until the cursor leaves the edge or events pause.
/// Written from the spec and the logs, to cross-check the builder's `CrossLatch`.
struct LatchModel {
    let side: EdgeSide
    let edgeY: Double
    let zone: (min: Double, max: Double)
    private var armed = false
    private var spent = false
    private(set) var crossX: Double?
    private var latchT = 0.0
    private var prevT = -Double.infinity

    init(side: EdgeSide, edgeY: Double, zone: (min: Double, max: Double)) {
        self.side = side
        self.edgeY = edgeY
        self.zone = zone
    }

    mutating func onEvent(t: Double, p: CGPoint, dy: Double) -> Double? {
        let s = side == .top ? Double(p.y) - edgeY : edgeY - Double(p.y)
        let push = side == .top ? dy < 0 : dy > 0
        let gap = t - prevT > 100
        let onEdge = s >= -1 && s < 1
        if gap || !onEdge { spent = false }            // left the edge, or a pause: a new visit
        if gap || s > 30 || s < -1 {
            armed = false
            crossX = nil
        } else if crossX != nil && t - latchT > 150 {
            armed = false
            crossX = nil
            spent = onEdge
        }
        if crossX == nil && !spent {
            if armed && push {
                crossX = Double(p.x)
                latchT = t
            } else if !armed && s >= -1 && s < 1 && Double(p.x) >= zone.min && Double(p.x) <= zone.max {
                armed = true
            }
        }
        prevT = t
        return crossX
    }
}

/// SPEC §5.2 v1.1 sender, re-implemented from the spec: an EDGE packet on every tap event that is at
/// the edge (-1 <= s <= 1.5) or latched, with x within span +- 1. Duplicate sends are left out
/// (the wire drops equal seq). The latch comes from the builder's `CrossLatch` or from `LatchModel`.
struct SpecSender: Sendable {
    enum Latch: Sendable { case builder, model }

    let side: EdgeSide
    let geometry: EdgeGeometry
    let span: (min: Double, max: Double)
    /// §5.2: §7's zone on the side with a dead strip (V-Mind), else [spanMin - 1, spanMax + 1].
    let zone: (min: Double, max: Double)
    var atEdgePt = 1.5

    static let vmind = SpecSender(side: .top, geometry: Desk.vmind, span: Desk.vmindSpan, zone: (-961, 1600))
    static let macbook = SpecSender(side: .bottom, geometry: Desk.macbook, span: Desk.macbookSpan, zone: (-2561, 1))

    func signedDist(_ p: CGPoint) -> Double { side == .top ? Double(p.y) - geometry.edgeY : geometry.edgeY - Double(p.y) }

    /// crossX after each tap event, from the chosen latch.
    func latched(_ taps: [TraceSample], by latch: Latch) -> [Double?] {
        switch latch {
        case .builder:
            let l = CrossLatch()
            return taps.map { l.onEvent(t: $0.t, p: $0.p, dy: $0.dy, geometry: geometry, zoneMin: zone.min, zoneMax: zone.max) }
        case .model:
            var m = LatchModel(side: side, edgeY: geometry.edgeY, zone: zone)
            return taps.map { m.onEvent(t: $0.t, p: $0.p, dy: $0.dy) }
        }
    }

    /// `toReceiverMs` converts source trace time to receiver trace time; `delayMs` is the network.
    func packets(from taps: [TraceSample], toReceiverMs: Double, delayMs: Double, latch: Latch = .builder) -> [SynthPacket] {
        zip(taps, latched(taps, by: latch)).compactMap { e, crossX in
            let s = signedDist(e.p)
            let atEdge = s >= -1 && s <= atEdgePt
            guard atEdge || crossX != nil, e.p.x >= span.min - 1, e.p.x <= span.max + 1 else { return nil }
            let push = side == .top ? e.dy < 0 : e.dy > 0
            return SynthPacket(sendT: e.t, arriveT: e.t + toReceiverMs + delayMs, x: e.p.x, d: max(0, s),
                               pushing: atEdge && push, spanMin: span.min, spanMax: span.max, crossX: crossX, lagMs: delayMs)
        }
    }
}

struct ReplayedCorrection: Sendable, CustomStringConvertible {
    let t: Double
    let correction: Correction
    let viaPeerUpdate: Bool
    let fromEcho: Bool

    var description: String {
        let c = correction
        return String(format: "%@ t=%.1f landing=(%.2f,%.2f) target=(%.2f,%.2f) peerX=%.2f%@%@",
                      c.kind.rawValue, t, c.landing.x, c.landing.y, c.target.x, c.target.y, c.peerX,
                      viaPeerUpdate ? " [onPeerUpdate]" : "", fromEcho ? " [on own-warp echo]" : "")
    }
}

/// Drives a `LandingDetector` the way the engine would (SPEC §4, §5.5) over a recorded trace.
///
/// After each correction it plays the engine's part: `didWarp`, then the poller's view of the
/// warped cursor (the echo), then the rest of the trace offset in x by (target - UC landing), because
/// our warp sticks (fact 4). Only x: the 2 pt y inset is absorbed as soon as the user pushes into
/// the edge, and a y offset would keep replayed pinned pushes off the edge. That counterfactual path is only kept while it stays on a real
/// screen: once it would leave them, the recording diverged (e.g. the user went on to leave by
/// the side link at x = 0), so the replay falls back to the recorded positions. The offset also
/// ends at the next UC landing on this Mac (`shiftResets`, plus the s1 recorder's own WARPs).
///
/// With `episodeRule` on, each packet carries `episodeStart` the way the engine derives it (§12 v1.2).
func replayReceiver(samples: [TraceSample], packets: [SynthPacket], geometry: EdgeGeometry,
                    screens: [CGRect], shiftResets: [Double], episodeRule: Bool = true,
                    params: DetectorParams = .init()) -> [ReplayedCorrection] {
    enum Ev { case sample(TraceSample), packet(SynthPacket) }
    var evs: [(t: Double, order: Int, ev: Ev)] = []
    evs.reserveCapacity(samples.count + packets.count)
    for s in samples { evs.append((s.t, 1, .sample(s))) }
    for p in packets { evs.append((p.arriveT, 0, .packet(p))) }   // a packet at the same ms is seen first
    evs = evs.enumerated().sorted { ($0.element.t, $0.element.order, $0.offset) < ($1.element.t, $1.element.order, $1.offset) }
        .map(\.element)

    let detector = LandingDetector(params: params)
    let resets = shiftResets.sorted()
    var nextReset = 0
    var shift = CGVector.zero
    var raw: CGPoint?
    var buttons = false
    var peer: PeerEdgeState?
    var lastArrival = -Double.infinity
    var episodeStart = -Double.infinity
    var out: [ReplayedCorrection] = []

    func located(_ r: CGPoint) -> CGPoint { CGPoint(x: r.x + shift.dx, y: r.y + shift.dy) }

    for (i, e) in evs.enumerated() {
        var got: Correction?
        var viaPeer = false
        switch e.ev {
        case .packet(let pk):
            if pk.arriveT - lastArrival > 150 { episodeStart = pk.arriveT }
            lastArrival = pk.arriveT
            let st = pk.peerState(episodeStart: episodeRule ? episodeStart : nil)
            peer = st
            guard let r = raw else { continue }
            got = detector.onPeerUpdate(t: pk.arriveT, peer: st, current: located(r), buttonsDown: buttons, geometry: geometry)
            viaPeer = true
        case .sample(let s):
            while nextReset < resets.count && s.t >= resets[nextReset] - 0.001 {
                shift = .zero
                nextReset += 1
            }
            // Edge-inclusive: shifted recorded points sit exactly on a border (e.g. y = 0 under display 3).
            let q = located(s.p)
            if shift != .zero && !screens.contains(where: { q.x >= $0.minX && q.x <= $0.maxX && q.y >= $0.minY && q.y <= $0.maxY }) {
                shift = .zero
            }
            raw = s.p
            buttons = s.buttonsDown
            got = detector.onSample(t: s.t, p: located(s.p), buttonsDown: buttons, geometry: geometry, peer: peer)
        }
        guard let c = got, let r = raw else { continue }
        out.append(ReplayedCorrection(t: e.t, correction: c, viaPeerUpdate: viaPeer, fromEcho: false))

        // The engine never warps to a non-finite point or with a button down (§5.5).
        guard c.target.x.isFinite, c.target.y.isFinite, !buttons else { continue }
        detector.didWarp(t: e.t, to: c.target)
        shift = CGVector(dx: c.target.x - r.x, dy: 0)
        let nextT = i + 1 < evs.count ? evs[i + 1].t : e.t + 1
        let echoT = e.t + min(0.5, max(0, nextT - e.t) / 2)
        if let echo = detector.onSample(t: echoT, p: c.target, buttonsDown: buttons, geometry: geometry, peer: peer) {
            out.append(ReplayedCorrection(t: echoT, correction: echo, viaPeerUpdate: false, fromEcho: true))
        }
    }
    return out
}

/// What SPEC §5.4 v1.1 says the detector must do at one UC landing, computed from the packet list.
struct SpecExpectation: Sendable, CustomStringConvertible {
    let kind: CorrectionKind
    let peerX: Double
    let targetX: Double
    let at: Double

    var description: String { String(format: "%@ at t=%.1f peerX=%.2f targetX=%.2f", kind.rawValue, at, peerX, targetX) }

    static func at(landingT: Double, landing: CGPoint, packets: [SynthPacket], samples: [TraceSample],
                   peerSpan: (min: Double, max: Double), localSpan: (min: Double, max: Double),
                   params: DetectorParams = .init()) -> SpecExpectation? {
        let arrived = packets.filter { $0.arriveT <= landingT }.max { $0.arriveT < $1.arriveT }
        if let p = arrived, let cx = p.crossX, p.isLatched, landingT - p.arriveT <= params.freshMs {
            let x = Desk.clampTargetX(Desk.map(cx, from: peerSpan, to: localSpan), span: localSpan)
            return SpecExpectation(kind: .immediate, peerX: cx, targetX: x, at: landingT)
        }
        let late = packets.filter { $0.arriveT > landingT && $0.arriveT - landingT <= params.lateWindowMs && $0.isLatched }
            .min { $0.arriveT < $1.arriveT }
        guard let p = late, let cx = p.crossX else { return nil }
        let current = samples.last { $0.t <= p.arriveT }?.p ?? landing
        let x = Desk.clampTargetX(Desk.map(cx, from: peerSpan, to: localSpan) + (current.x - landing.x), span: localSpan)
        return SpecExpectation(kind: .late, peerX: cx, targetX: x, at: p.arriveT)
    }
}

/// §13 sender with the UC log assist on: crossX comes only from UC's "Hot Zone: Activating" lines
/// (source trace ms), through the implementation's `UCCrossMatcher` and `UCCrossHold`. A packet goes out
/// as soon as the line is read (`logLagMs` after it), and tail packets keep the held crossX. With the
/// peer's assist active, model-latched crossX is unusable, so packets carry only the UC-sourced value.
extension SpecSender {
    func ucLogPackets(from taps: [TraceSample], activations: [Double], logLagMs: Double,
                      toReceiverMs: Double, delayMs: Double) -> (packets: [SynthPacket], matched: [Double: Double]) {
        let matcher = UCCrossMatcher()
        var hold = UCCrossHold()
        var out: [SynthPacket] = []
        var matched: [Double: Double] = [:]
        var pending = activations.sorted()
        var last: TraceSample?
        let ns = { (ms: Double) in UInt64((ms + 1_000_000) * 1e6) }   // trace ms -> positive "uptime ns"

        func emit(_ e: TraceSample, at t: Double, crossX: Double?) {
            let s = signedDist(e.p)
            let atEdge = s >= -1 && s <= atEdgePt
            guard atEdge || crossX != nil, e.p.x >= span.min - 1, e.p.x <= span.max + 1 else { return }
            let push = side == .top ? e.dy < 0 : e.dy > 0
            out.append(SynthPacket(sendT: t, arriveT: t + toReceiverMs + delayMs, x: e.p.x, d: max(0, s), pushing: atEdge && push,
                                   spanMin: span.min, spanMax: span.max, crossX: crossX, lagMs: delayMs))
        }
        func readLines(until t: Double) {
            while let a = pending.first, a + logLagMs <= t {
                pending.removeFirst()
                guard let rec = matcher.match(activationNs: ns(a)), let e = last else { continue }
                matched[a] = rec.x
                hold.set(rec.x, at: a + logLagMs)
                emit(e, at: a + logLagMs, crossX: rec.x)        // sent at once on the log line
            }
        }
        for e in taps {
            readLines(until: e.t)
            let s = signedDist(e.p)
            matcher.record(UCTapRecord(ns: ns(e.t), x: e.p.x, y: e.p.y, s: s, dy: e.dy))
            last = e
            emit(e, at: e.t, crossX: hold.onEvent(t: e.t, s: s))
        }
        readLines(until: .infinity)
        return (out, matched)
    }
}
