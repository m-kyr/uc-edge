import CoreGraphics

public enum EdgeSide: String, Codable, Sendable { case top, bottom }

/// The local shared edge, derived from the live bounds of the configured edge displays (SPEC §5.1).
public struct EdgeGeometry: Sendable, Equatable {
    public let side: EdgeSide
    public let displays: [CGRect]
    public let edgeY: Double
    public let spanMin: Double
    public let spanMax: Double

    public init(side: EdgeSide, displays: [CGRect]) {
        self.side = side
        self.displays = displays
        spanMin = displays.map { Double($0.minX) }.min() ?? 0
        spanMax = displays.map { Double($0.maxX) }.max() ?? 0
        switch side {
        case .top: edgeY = displays.map { Double($0.minY) }.min() ?? 0
        case .bottom: edgeY = displays.map { Double($0.maxY) }.max() ?? 0
        }
    }

    /// True when there is at least one display with a non-empty span.
    public var isValid: Bool { !displays.isEmpty && spanMax - spanMin > 1 }

    /// Signed distance from the edge, positive towards the inside of the edge displays.
    public func signedDist(_ p: CGPoint) -> Double {
        switch side {
        case .top: return Double(p.y) - edgeY
        case .bottom: return edgeY - Double(p.y)
        }
    }

    /// Distance from the edge, clamped at 0 when the point is on or beyond the edge.
    public func distToEdge(_ p: CGPoint) -> Double { max(0, signedDist(p)) }

    public func inSpan(_ x: Double, slack: Double = 1) -> Bool {
        x >= spanMin - slack && x <= spanMax + slack
    }

    /// Closed landing strip. A point more than 1 pt *beyond* the edge (e.g. deep into the
    /// MacBook's built-in display below display 3) is not in the strip even though its
    /// clamped distance is 0; the corner (0, 0) still is.
    public func inLandingStrip(_ p: CGPoint, stripPt: Double) -> Bool {
        let s = signedDist(p)
        return s <= stripPt && s >= -1 && inSpan(Double(p.x))
    }

    /// At the edge: within `atEdgePt` inside it, at most 1 pt beyond it, and within the span.
    public func isAtEdge(_ p: CGPoint, atEdgePt: Double) -> Bool {
        let s = signedDist(p)
        return s <= atEdgePt && s >= -1 && inSpan(Double(p.x))
    }

    /// Closed containment: a point on any display's border counts as on it.
    public func isOnEdgeDisplay(_ p: CGPoint) -> Bool {
        displays.contains { r in
            p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
        }
    }

    /// Clamp a correction target (SPEC §5.1 v1.1): x into [spanMin, spanMax − 0.5]; y at least
    /// `insetPt` inside the edge line (outside UC's 1 pt hot zone, so a slide right after the
    /// landing can't bounce back) and at most `stripPt` from it; then onto an edge display.
    public func clampTarget(x: Double, currentY: Double, stripPt: Double, insetPt: Double = 2) -> CGPoint {
        let cx = min(max(x, spanMin), spanMax - 0.5)
        let inset = max(insetPt, 0), depth = max(stripPt, inset)
        let cy: Double
        switch side {
        case .top: cy = min(max(currentY, edgeY + inset), edgeY + depth)
        case .bottom: cy = max(min(currentY, edgeY - inset), edgeY - depth)
        }
        let p = CGPoint(x: cx, y: cy)
        if displays.isEmpty || displays.contains(where: { Self.strictlyContains($0, p) }) { return p }
        return snapToNearestDisplay(p, inset: inset)
    }

    private static func strictlyContains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }

    private func snapToNearestDisplay(_ p: CGPoint, inset: Double) -> CGPoint {
        var best = p
        var bestD = Double.infinity
        let lo = side == .top ? inset : 0, hi = side == .bottom ? max(inset, 1) : 1
        for r in displays {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 0.5),
                            y: min(max(p.y, r.minY + lo), r.maxY - hi))
            let d = Double(hypot(q.x - p.x, q.y - p.y))
            if d < bestD { bestD = d; best = q }
        }
        return best
    }
}
