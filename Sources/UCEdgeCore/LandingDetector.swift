import CoreGraphics

/// Last EDGE packet decoded from the peer (SPEC §5.3).
public struct PeerEdgeState: Sendable, Equatable {
    public var x: Double; public var d: Double; public var pushing: Bool
    public var spanMin: Double; public var spanMax: Double
    public var receivedAt: Double          // local monotonic ms
    public var crossX: Double?             // latched UC exit x (§5.2); nil = not latched
    /// v1.2: local arrival time of the first EDGE packet after a > 150 ms gap. nil = rule off.
    public var episodeStart: Double?
    /// v1.2: estimated send-to-arrival latency from the sender's timestamp (nil = unknown), and
    /// the slack allowed on top of `freshMs` for that estimate.
    public var senderLagMs: Double?
    public var senderSlackMs: Double
    /// v1.3.1: where `crossX` came from, and whether the peer advertises its UC log assist (then a
    /// model crossX waits up to `ucWaitMs` for a UC-sourced one).
    public var crossSource: CrossSource
    public var peerUCLogActive: Bool
    public init(x: Double, d: Double, pushing: Bool, spanMin: Double, spanMax: Double, receivedAt: Double,
                crossX: Double? = nil, episodeStart: Double? = nil, senderLagMs: Double? = nil,
                senderSlackMs: Double = 50, crossSource: CrossSource = .model, peerUCLogActive: Bool = false) {
        self.x = x; self.d = d; self.pushing = pushing
        self.spanMin = spanMin; self.spanMax = spanMax; self.receivedAt = receivedAt
        self.crossX = crossX; self.episodeStart = episodeStart
        self.senderLagMs = senderLagMs; self.senderSlackMs = senderSlackMs
        self.crossSource = crossSource; self.peerUCLogActive = peerUCLogActive
    }

    /// A model crossX from a peer whose log assist may still deliver UC's exact one.
    func shouldWaitForUC(params: DetectorParams) -> Bool {
        crossSource == .model && peerUCLogActive && params.ucWaitMs > 0
    }

    /// A span we can map from: finite and wider than 1 pt.
    public var hasValidSpan: Bool {
        spanMin.isFinite && spanMax.isFinite && spanMax - spanMin > 1
    }

    /// v1.1: fresh and latched. The latch, not `d`, is the at-edge signal: tail packets can be
    /// several pt from the edge.
    /// v1.2: also fresh by the sender's own clock, so a packet delayed in flight can't look new.
    public func isFreshAtEdge(now: Double, params: DetectorParams) -> Bool {
        guard let cx = crossX, cx.isFinite, hasValidSpan else { return false }
        let arrivalAge = now - receivedAt
        guard arrivalAge <= params.freshMs else { return false }
        if let lag = senderLagMs {
            guard lag.isFinite, arrivalAge + lag <= params.freshMs + senderSlackMs else { return false }
        }
        return true
    }

    /// v1.2: a landing is only plausible if the local cursor sat still for the whole peer episode.
    func episodeAllows(landingT: Double, still: Double, slackMs: Double) -> Bool {
        guard let es = episodeStart else { return true }
        return still >= (landingT - es) - slackMs
    }
}

public struct DetectorParams: Sendable, Codable, Equatable {
    public var stripPt = 30.0, minStillMs = 30.0, freshMs = 300.0, lateWindowMs = 150.0
    public var cooldownMs = 400.0, guardMs = 250.0, atEdgePt = 1.5
    /// A change less than this after a still position at our own edge is our exit's tail (§5.4).
    public var exitTailMs = 75.0
    /// Targets sit at least this far inside the edge line, outside UC's 1 pt hot zone (§5.1).
    public var targetInsetPt = 2.0
    /// Corrections that would move x by less than this are skipped (§5.1).
    public var minCorrectionPt = 2.0
    /// Episode rule slack (§12): our own exit tail can run ~100 ms into the peer's episode.
    public var episodeSlackMs = 120.0
    /// v1.3.1 (F2): how long a landing with only a model crossX waits for a UC-sourced one when the
    /// peer advertises its UC log assist.
    public var ucWaitMs = 25.0
    /// v1.4 (§14.2.1): re-warp when UC positions the cursor absolutely after our correction.
    public var overrideGuard = true
    public var overrideGuardMs = 300.0, overrideMismatchPt = 20.0, overrideMaxRewarps = 2.0
    /// v1.4 deviation: an override must also carry the cursor back toward UC's landing by at least
    /// this fraction of the correction (the MacBook's first event after a handoff also reports a
    /// garbage delta, but its position is relative to our warp and must not re-warp).
    public var overrideBackFraction = 0.25
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectorParams()
        stripPt = try c.decodeIfPresent(Double.self, forKey: .stripPt) ?? d.stripPt
        minStillMs = try c.decodeIfPresent(Double.self, forKey: .minStillMs) ?? d.minStillMs
        freshMs = try c.decodeIfPresent(Double.self, forKey: .freshMs) ?? d.freshMs
        lateWindowMs = try c.decodeIfPresent(Double.self, forKey: .lateWindowMs) ?? d.lateWindowMs
        cooldownMs = try c.decodeIfPresent(Double.self, forKey: .cooldownMs) ?? d.cooldownMs
        guardMs = try c.decodeIfPresent(Double.self, forKey: .guardMs) ?? d.guardMs
        atEdgePt = try c.decodeIfPresent(Double.self, forKey: .atEdgePt) ?? d.atEdgePt
        exitTailMs = try c.decodeIfPresent(Double.self, forKey: .exitTailMs) ?? d.exitTailMs
        targetInsetPt = try c.decodeIfPresent(Double.self, forKey: .targetInsetPt) ?? d.targetInsetPt
        minCorrectionPt = try c.decodeIfPresent(Double.self, forKey: .minCorrectionPt) ?? d.minCorrectionPt
        episodeSlackMs = try c.decodeIfPresent(Double.self, forKey: .episodeSlackMs) ?? d.episodeSlackMs
        ucWaitMs = try c.decodeIfPresent(Double.self, forKey: .ucWaitMs) ?? d.ucWaitMs
        overrideGuard = try c.decodeIfPresent(Bool.self, forKey: .overrideGuard) ?? d.overrideGuard
        overrideGuardMs = try c.decodeIfPresent(Double.self, forKey: .overrideGuardMs) ?? d.overrideGuardMs
        overrideMismatchPt = try c.decodeIfPresent(Double.self, forKey: .overrideMismatchPt) ?? d.overrideMismatchPt
        overrideMaxRewarps = try c.decodeIfPresent(Double.self, forKey: .overrideMaxRewarps) ?? d.overrideMaxRewarps
        overrideBackFraction = try c.decodeIfPresent(Double.self, forKey: .overrideBackFraction) ?? d.overrideBackFraction
    }
}

public enum CorrectionKind: String, Sendable, Codable {
    case immediate, late, snapback
    /// v1.4: a re-warp after UC positioned the cursor absolutely, undoing our correction.
    case override
}

public struct Correction: Sendable, Equatable {
    public let kind: CorrectionKind
    public let target: CGPoint
    public let landing: CGPoint           // where UC put the cursor (pending.p for late)
    public let peerX: Double              // the peer x that was mapped: its latched crossX
    /// Where that crossX came from (v1.3.1).
    public let source: CrossSource
    public init(kind: CorrectionKind, target: CGPoint, landing: CGPoint, peerX: Double, source: CrossSource = .model) {
        self.kind = kind; self.target = target; self.landing = landing; self.peerX = peerX; self.source = source
    }
}

/// The correction state machine (SPEC §5.4). Not thread-safe; the caller serializes.
public final class LandingDetector {
    public let params: DetectorParams
    /// v1.2.1: only a jump this large can be a tail-suppressed landing (UC's landing, not a tail move).
    public static let tailJumpPt = 40.0
    /// v1.2: the exit-tail exemption needs a pushing packet at most this old.
    public static let pushingFreshMs = 50.0
    /// v1.2: a snap-back is a jump of more than this from the previous sample.
    public static let snapbackJumpPt = 10.0

    /// A landing waiting for a peer packet (late path), for UC's crossX (`deferUntil`, v1.3.1), or
    /// flagged `tail` (only a pushing packet may resolve it).
    private struct Pending {
        var t: Double, p: CGPoint, still: Double, tail: Bool
        var deferUntil: Double?
        var model: PeerEdgeState?
    }

    private var lastPos: CGPoint?
    private var lastChangeT = 0.0
    private var latestT = -Double.infinity
    private var pending: Pending?
    private var expectedWarp: (t: Double, p: CGPoint)?
    private var lastCorrection: (t: Double, target: CGPoint, landing: CGPoint, peerX: Double, source: CrossSource)?
    private var snapbackAvailable = false
    private var cooldownFrom = -Double.infinity
    /// v1.4: the position after the previous tap event, or our last warp target since.
    private var lastTapPos: CGPoint?
    /// v1.4: the correction the override guard protects (landing, shift Δ = target − landing).
    private var guarded: (t: Double, landing: CGPoint, delta: CGVector, peerX: Double, source: CrossSource, rewarps: Int)?
    /// Override re-warps so far.
    public private(set) var overrideRewarpCount = 0

    /// Stillness before the most recent position change, for logs.
    public private(set) var lastStillMs = 0.0
    /// Corrections skipped because they would move x by less than `minCorrectionPt`.
    public private(set) var skippedSmallCount = 0
    public private(set) var lastSkippedSmall: Correction?
    /// Landings rejected because the local cursor moved during the peer's episode.
    public private(set) var episodeRejectCount = 0
    /// Landings held for a UC-sourced crossX (v1.3.1), and how many then fell back to the model's.
    public private(set) var deferredCount = 0
    public private(set) var deferredFallbackCount = 0
    /// The last sampled local position (the engine uses it as the late path's `current`).
    public var lastPosition: CGPoint? { lastPos }

    public init(params: DetectorParams = .init()) {
        self.params = params
    }

    public func onSample(t: Double, p: CGPoint, buttonsDown: Bool,
                         geometry: EdgeGeometry, peer: PeerEdgeState?) -> Correction? {
        advance(to: t)
        // 1. Change detection.
        guard let prev = lastPos else {
            lastPos = p; lastChangeT = t
            return nil
        }
        let changed = abs(p.x - prev.x) > 0.01 || abs(p.y - prev.y) > 0.01
        var still = 0.0
        if changed {
            still = t - lastChangeT
            lastPos = p; lastChangeT = t
            lastStillMs = still
        }
        // A landing held for UC's crossX whose wait is over: correct with the model's (v1.3.1).
        if let c = fireDeferredIfDue(t: t, buttonsDown: buttonsDown, geometry: geometry) { return c }
        guard changed else { return nil }

        // 2. Own-warp echo.
        if let w = expectedWarp, Self.dist(p, w.p) <= 1.5 {
            expectedWarp = nil
            return nil
        }
        guard geometry.isValid else { return nil }

        // 3. Snap-back guard: UC puts the cursor back with a jump, the user doesn't.
        if snapbackAvailable, let c = lastCorrection, t - c.t <= params.guardMs,
           Self.dist(p, c.landing) <= 3, Self.dist(p, prev) > Self.snapbackJumpPt {
            guard !buttonsDown else { return nil }
            snapbackAvailable = false
            cooldownFrom = t
            let target = clamp(geometry, x: Double(c.target.x + (p.x - c.landing.x)),
                               y: Double(c.target.y + (p.y - c.landing.y)))
            return finish(Correction(kind: .snapback, target: target, landing: p, peerX: c.peerX, source: c.source),
                          currentX: Double(p.x), at: t)
        }

        // 4. Cooldown.
        if t - cooldownFrom < params.cooldownMs { return nil }

        // 5. Landing candidate.
        guard still >= params.minStillMs, !buttonsDown,
              geometry.inLandingStrip(p, stripPt: params.stripPt) else { return nil }
        let peerFresh = peer.map { $0.isFreshAtEdge(now: t, params: params) } ?? false
        // Exit tail: a change right after sitting at our own edge is our own exit's tail,
        // unless the peer is pushing into its edge right now (a genuine quick return).
        if still < params.exitTailMs && geometry.isAtEdge(prev, atEdgePt: params.atEdgePt) {
            let pushingNow = peerFresh && peer?.pushing == true && t - (peer?.receivedAt ?? -.infinity) <= Self.pushingFreshMs
            if !pushingNow {
                // Only UC's landing jump may wait for a pushing packet; a small tail move along
                // the edge never becomes pending (v1.2.1, N1).
                if Self.dist(p, prev) > Self.tailJumpPt { pending = Pending(t: t, p: p, still: still, tail: true) }
                return nil
            }
        }
        if let peer, peerFresh, let cx = peer.crossX {
            guard peer.episodeAllows(landingT: t, still: still, slackMs: params.episodeSlackMs) else {
                episodeRejectCount += 1
                return nil
            }
            if peer.shouldWaitForUC(params: params) {
                pending = Pending(t: t, p: p, still: still, tail: false, deferUntil: t + params.ucWaitMs, model: peer)
                deferredCount += 1
                return nil
            }
            let target = clamp(geometry, x: map(cx, peer, geometry), y: Double(p.y))
            return finish(Correction(kind: .immediate, target: target, landing: p, peerX: cx, source: peer.crossSource),
                          currentX: Double(p.x), at: t)
        }
        pending = Pending(t: t, p: p, still: still, tail: false)
        return nil
    }

    /// 6. Late path: a pending landing is resolved by a peer packet that arrives just after it.
    /// v1.3.1: a UC-sourced packet resolves it at once; a model-sourced one from a peer whose log
    /// assist is active waits until `ucWaitMs` after the landing.
    public func onPeerUpdate(t: Double, peer: PeerEdgeState, current: CGPoint, buttonsDown: Bool,
                             geometry: EdgeGeometry) -> Correction? {
        advance(to: t)
        guard var pd = pending, t - pd.t <= params.lateWindowMs,
              peer.isFreshAtEdge(now: t, params: params), let cx = peer.crossX, !buttonsDown,
              !pd.tail || peer.pushing,
              geometry.isValid, geometry.isOnEdgeDisplay(current) else {
            return fireDeferredIfDue(t: t, buttonsDown: buttonsDown, geometry: geometry)
        }
        if peer.shouldWaitForUC(params: params) {
            let deadline = pd.deferUntil ?? (pd.t + params.ucWaitMs)
            if t < deadline {
                if pd.deferUntil == nil { deferredCount += 1 }
                pd.deferUntil = deadline
                pd.model = peer
                pending = pd
                return nil
            }
        }
        guard peer.episodeAllows(landingT: pd.t, still: pd.still, slackMs: params.episodeSlackMs) else {
            pending = nil
            episodeRejectCount += 1
            return nil
        }
        return lateCorrection(pd, crossX: cx, peer: peer, current: current, geometry: geometry, at: t)
    }

    public func didWarp(t: Double, to: CGPoint) {
        advance(to: t)
        expectedWarp = (t, to)
        lastTapPos = to
    }

    /// v1.4: a local **tap event** with its reported deltas (poller samples go to `onSample`).
    /// Runs the normal state machine, then the override guard: within `overrideGuardMs` of a
    /// correction, an event whose observed motion disagrees with its reported delta by more than
    /// `overrideMismatchPt` on an axis (not explained by a display boundary clamping it), and which
    /// carries the cursor back toward UC's landing, is UC positioning the cursor absolutely: re-warp
    /// to `p + Δ`. `displays` are all local displays (for the clamping check); default = the edge.
    public func onTapEvent(t: Double, p: CGPoint, dx: Double, dy: Double, buttonsDown: Bool,
                           geometry: EdgeGeometry, peer: PeerEdgeState?, displays: [CGRect]? = nil) -> Correction? {
        let prevTap = lastTapPos
        lastTapPos = p
        if let c = onSample(t: t, p: p, buttonsDown: buttonsDown, geometry: geometry, peer: peer) { return c }
        guard params.overrideGuard, !buttonsDown, geometry.isValid, let last = prevTap,
              var g = guarded, t - g.t <= params.overrideGuardMs, Double(g.rewarps) < params.overrideMaxRewarps else { return nil }
        let bounds = displays ?? geometry.displays
        let mx = abs(Double(p.x - last.x) - dx), my = abs(Double(p.y - last.y) - dy)
        let xOverride = mx > params.overrideMismatchPt && !Self.nearBoundary(Double(p.x), bounds.flatMap { [Double($0.minX), Double($0.maxX)] })
        let yOverride = my > params.overrideMismatchPt && !Self.nearBoundary(Double(p.y), bounds.flatMap { [Double($0.minY), Double($0.maxY)] })
        guard xOverride || yOverride else { return nil }
        let shift = hypot(g.delta.dx, g.delta.dy)
        guard Self.dist(p, g.landing) <= Self.dist(last, g.landing) - params.overrideBackFraction * shift else { return nil }
        let target = geometry.clampTarget(x: Double(p.x + g.delta.dx), currentY: Double(p.y + g.delta.dy),
                                          stripPt: .infinity, insetPt: params.targetInsetPt)
        g.rewarps += 1
        guarded = g
        overrideRewarpCount += 1
        return Correction(kind: .override, target: target, landing: p, peerX: g.peerX, source: g.source)
    }

    private static func nearBoundary(_ v: Double, _ edges: [Double]) -> Bool {
        edges.contains { abs(v - $0) <= 1 || abs(v - ($0 - 1)) <= 1 }
    }

    /// The engine decided not to warp (button down, warp error): no echo to expect and
    /// nothing to guard against. The cooldown still applies.
    public func didSkipWarp(t: Double) {
        advance(to: t)
        expectedWarp = nil
        snapbackAvailable = false
    }

    public var isArmed: Bool { isArmed(at: latestT) }

    public func isArmed(at t: Double) -> Bool {
        if let pd = pending, t - pd.t <= params.lateWindowMs { return true }
        if snapbackAvailable, let c = lastCorrection, t - c.t <= params.guardMs { return true }
        return false
    }

    /// Expires state without a sample.
    public func advance(to t: Double) {
        latestT = max(latestT, t)
        if let pd = pending, latestT - pd.t > params.lateWindowMs { pending = nil }
        if let w = expectedWarp, latestT - w.t > params.guardMs { expectedWarp = nil }
        if snapbackAvailable, let c = lastCorrection, latestT - c.t > params.guardMs { snapbackAvailable = false }
    }

    /// The UC wait of a deferred landing is over: correct with the model crossX, if the usual
    /// checks still pass (no button, still on an edge display, the episode rule). `current` is our
    /// own last sample; the cursor's movement since the landing is kept, as on the late path.
    private func fireDeferredIfDue(t: Double, buttonsDown: Bool, geometry: EdgeGeometry) -> Correction? {
        guard let pd = pending, let due = pd.deferUntil, t >= due, let model = pd.model, let cx = model.crossX else {
            return nil
        }
        pending = nil
        guard !buttonsDown, geometry.isValid, let current = lastPos, geometry.isOnEdgeDisplay(current),
              model.isFreshAtEdge(now: t, params: params) else { return nil }
        guard model.episodeAllows(landingT: pd.t, still: pd.still, slackMs: params.episodeSlackMs) else {
            episodeRejectCount += 1
            return nil
        }
        deferredFallbackCount += 1
        return lateCorrection(pd, crossX: cx, peer: model, current: current, geometry: geometry, at: t)
    }

    /// Keeps the user's vertical progress; only x is remapped, plus the movement since the landing.
    private func lateCorrection(_ pd: Pending, crossX cx: Double, peer: PeerEdgeState, current: CGPoint,
                                geometry: EdgeGeometry, at t: Double) -> Correction? {
        let target = geometry.clampTarget(x: map(cx, peer, geometry) + Double(current.x - pd.p.x),
                                          currentY: Double(current.y), stripPt: .infinity,
                                          insetPt: params.targetInsetPt)
        return finish(Correction(kind: .late, target: target, landing: pd.p, peerX: cx, source: peer.crossSource),
                      currentX: Double(current.x), at: t)
    }

    private func map(_ crossX: Double, _ peer: PeerEdgeState, _ g: EdgeGeometry) -> Double {
        physicalMap(peerX: crossX, peerSpanMin: peer.spanMin, peerSpanMax: peer.spanMax,
                    localSpanMin: g.spanMin, localSpanMax: g.spanMax)
    }

    private func clamp(_ g: EdgeGeometry, x: Double, y: Double) -> CGPoint {
        g.clampTarget(x: x, currentY: y, stripPt: params.stripPt, insetPt: params.targetInsetPt)
    }

    /// Records a correction, or handles it silently when it would move x by less than
    /// `minCorrectionPt`: pending is cleared and the cooldown starts either way.
    private func finish(_ c: Correction, currentX: Double, at t: Double) -> Correction? {
        pending = nil
        cooldownFrom = t
        if abs(Double(c.target.x) - currentX) < params.minCorrectionPt {
            snapbackAvailable = false
            skippedSmallCount += 1
            lastSkippedSmall = c
            return nil
        }
        lastCorrection = (t, c.target, c.landing, c.peerX, c.source)
        if c.kind != .snapback {
            guarded = (t, c.landing, CGVector(dx: c.target.x - c.landing.x, dy: c.target.y - c.landing.y), c.peerX, c.source, 0)
        }
        // A correction of a few points leaves the cursor "within 3 pt of the landing" by design;
        // a snap-back is only recognisable when we moved it clearly away.
        snapbackAvailable = c.kind != .snapback && Self.dist(c.target, c.landing) > 6
        return c
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }
}
