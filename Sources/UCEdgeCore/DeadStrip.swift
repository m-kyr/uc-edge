import CoreGraphics

/// v1.4: a run of pinned pushes of at least 100 ms that did not fire, for tuning.
public struct DeadStripNearMiss: Sendable, Equatable {
    public var durationMs: Double, sum: Double, spread: Double, ratio: Double
    /// short | weak | sideways | wide | button | cooldown
    public var reason: String
    public var description: String {
        String(format: "%.0f ms, Σ|dy| %.1f, spread %.1f, dy/dx %.2f: %@", durationMs, sum, spread, ratio, reason)
    }
}

public struct DeadStripParams: Sendable, Codable, Equatable {
    public var enabled = false, pushThresholdPt = 12.0, minPushMs = 180.0, maxGapMs = 100.0
    public var cooldownMs = 1500.0, virtualXValidMs = 1000.0
    /// v1.2: a run whose x spread exceeds this is a slide along the menu bar, not a push.
    public var maxSpreadPt = 30.0
    /// v1.2: a push must be mostly vertical: Σ|dy| ≥ this × Σ|dx| over the run.
    public var minDyDxRatio = 1.5
    /// UC's covered x range on the local edge while UC's own zone is unknown: its arrangement
    /// can't be parsed, or the peer hasn't said hello yet (SPEC §7). Layout-specific, so there is
    /// no default: unset (nil), the dead strip stays off and the latch uses the whole span until
    /// UC's zone is known. Set both or neither.
    public var zoneMinXFallback: Double?, zoneMaxXFallback: Double?
    public init() {}

    /// The configured fallback zone, if both ends are set and form a range.
    public var fallbackZone: (minX: Double, maxX: Double)? {
        guard let lo = zoneMinXFallback, let hi = zoneMaxXFallback, lo.isFinite, hi.isFinite, lo < hi else { return nil }
        return (lo, hi)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeadStripParams()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        pushThresholdPt = try c.decodeIfPresent(Double.self, forKey: .pushThresholdPt) ?? d.pushThresholdPt
        minPushMs = try c.decodeIfPresent(Double.self, forKey: .minPushMs) ?? d.minPushMs
        maxGapMs = try c.decodeIfPresent(Double.self, forKey: .maxGapMs) ?? d.maxGapMs
        cooldownMs = try c.decodeIfPresent(Double.self, forKey: .cooldownMs) ?? d.cooldownMs
        virtualXValidMs = try c.decodeIfPresent(Double.self, forKey: .virtualXValidMs) ?? d.virtualXValidMs
        maxSpreadPt = try c.decodeIfPresent(Double.self, forKey: .maxSpreadPt) ?? d.maxSpreadPt
        minDyDxRatio = try c.decodeIfPresent(Double.self, forKey: .minDyDxRatio) ?? d.minDyDxRatio
        zoneMinXFallback = try c.decodeIfPresent(Double.self, forKey: .zoneMinXFallback)
        zoneMaxXFallback = try c.decodeIfPresent(Double.self, forKey: .zoneMaxXFallback)
    }
}

/// Detects a deliberate, sustained push into the part of the local edge UC does not cover
/// (SPEC §6 v1.1). Not thread-safe; the caller serializes.
public final class DeadStripDetector {
    public let params: DeadStripParams

    /// The current run of pinned pushes in the dead part, with its x extent and |dx| total.
    private struct Run {
        var start: Double, last: Double, sum: Double
        var minX: Double, maxX: Double, lastX: Double, sumDx: Double
    }
    private var run: Run? {
        didSet { if let old = oldValue, run == nil || run?.start != old.start { endRun(old) } }
    }
    private var cooldownFrom = -Double.infinity
    private var fired = false
    private var lastBlock: String?
    /// Near-misses so far, and the latest one.
    public private(set) var nearMissCount = 0
    public private(set) var lastNearMiss: DeadStripNearMiss?
    private var redirect: (t: Double, x: Double, to: CGPoint)?
    /// The same redirect, for the UC log path, which the model latch must not consume first.
    private var redirectForUC: (t: Double, x: Double, to: CGPoint)?

    /// Pinned means exactly at the edge (SPEC §6: d ≤ 0.5).
    public static let pinnedPt = 0.5

    public init(params: DeadStripParams) {
        self.params = params
    }

    /// zone = the x range of the local shared edge that UC *does* cover (§7). Returns the redirect
    /// point to warp to when a deliberate push in the uncovered part is detected.
    public func onEvent(t: Double, p: CGPoint, dy: Double, prevWasPinned: Bool, buttonsDown: Bool,
                        geometry: EdgeGeometry, zoneMinX: Double, zoneMaxX: Double) -> CGPoint? {
        guard params.enabled, geometry.isValid, zoneMaxX > zoneMinX else { run = nil; return nil }
        let x = Double(p.x)
        let s = geometry.signedDist(p)
        let pinned = s <= Self.pinnedPt && s >= -1
        let deadLeft = x < zoneMinX && x >= geometry.spanMin - 1
        let deadRight = x > zoneMaxX && x <= geometry.spanMax + 1
        // Leaving the edge or the dead part ends the run.
        guard pinned, deadLeft || deadRight else { run = nil; return nil }
        if let r = run, t - r.last > params.maxGapMs { run = nil }
        if var r = run {
            // Horizontal motion while pinned (pushes or pauses) counts against the run.
            r.sumDx += abs(x - r.lastX)
            r.lastX = x
            r.minX = min(r.minX, x)
            r.maxX = max(r.maxX, x)
            run = r
            // A slide along the menu bar: restart the run from here.
            if r.maxX - r.minX > params.maxSpreadPt { run = nil }
        }

        let intoEdge = geometry.side == .top ? dy < 0 : dy > 0
        guard prevWasPinned, intoEdge else { return nil }       // arrival or a pause: no push
        var r = run ?? Run(start: t, last: t, sum: 0, minX: x, maxX: x, lastX: x, sumDx: 0)
        r.last = t
        r.sum += abs(dy)
        run = r

        if t - r.start < params.minPushMs { lastBlock = "short"; return nil }
        if r.sum < params.pushThresholdPt { lastBlock = "weak"; return nil }
        if r.sum < params.minDyDxRatio * r.sumDx { lastBlock = "sideways"; return nil }
        if buttonsDown { lastBlock = "button"; return nil }
        if t - cooldownFrom < params.cooldownMs { lastBlock = "cooldown"; return nil }
        fired = true
        run = nil
        cooldownFrom = t
        let rx = deadLeft ? zoneMinX + 2 : zoneMaxX - 2
        let clampedX = min(max(rx, geometry.spanMin), geometry.spanMax - 0.5)
        // A bottom edge's edgeY belongs to the display below; stay 1 pt inside.
        let ry = geometry.side == .top ? geometry.edgeY : geometry.edgeY - 1
        let to = CGPoint(x: clampedX, y: ry)
        redirect = (t, x, to)
        redirectForUC = (t, x, to)
        return to
    }

    /// A run that ended without firing after ≥ 100 ms is a near-miss (logged by the engine).
    private func endRun(_ r: Run) {
        defer { fired = false; lastBlock = nil }
        guard !fired, r.last - r.start >= 100 else { return }
        let spread = r.maxX - r.minX
        let reason = spread > params.maxSpreadPt ? "wide" : (lastBlock ?? "short")
        lastNearMiss = DeadStripNearMiss(durationMs: r.last - r.start, sum: r.sum, spread: spread,
                                         ratio: r.sumDx > 0 ? r.sum / r.sumDx : .infinity, reason: reason)
        nearMissCount += 1
    }

    /// Original x of the last redirect while it is still valid.
    public func virtualX(at t: Double) -> Double? {
        guard let r = redirect, t - r.t <= params.virtualXValidMs, t >= r.t else { return nil }
        return r.x
    }

    /// v1.2: the sender calls this once per new latch. Returns the original x to send instead
    /// of `latchX` only for the first latch after a redirect, within `windowMs` of it, and only if
    /// the latch is within `tolerancePt` of the redirect point. The redirect is consumed either way.
    public func consumeRedirect(latchT: Double, latchX: Double, windowMs: Double = 300,
                                tolerancePt: Double = 5) -> Double? {
        guard let r = redirect else { return nil }
        redirect = nil
        guard latchT >= r.t, latchT - r.t <= windowMs, abs(latchX - Double(r.to.x)) <= tolerancePt else { return nil }
        return r.x
    }

    /// §13.2.1: for a UC Activating matched at `latchX` (time `t`), the redirect's original x
    /// if the redirect happened within `windowMs` and the match is within `tolerancePt` of the
    /// redirect point. Consumed on use.
    public func consumeRedirectForUC(t: Double, latchX: Double, windowMs: Double = 1000,
                                     tolerancePt: Double = 5) -> Double? {
        guard let r = redirectForUC, t >= r.t, t - r.t <= windowMs,
              abs(latchX - Double(r.to.x)) <= tolerancePt else { return nil }
        redirectForUC = nil
        return r.x
    }

    /// Stop reporting the virtual x.
    public func clearRedirect() {
        redirect = nil
        redirectForUC = nil
    }
}
