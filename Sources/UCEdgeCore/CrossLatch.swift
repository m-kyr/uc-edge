import CoreGraphics

/// The sender's model of UC's hot zone (SPEC §5.2): arm on the first event within 1 pt of the
/// edge inside UC's zone ("Entering"), latch the x of the next event that pushes into the edge
/// ("Activating"). That latched x is exactly the x UC crosses at; later tail events keep it.
/// v1.2: one latch per edge visit. After a latch expires it cannot re-arm until the cursor
/// leaves the edge (s ≥ 1 or s < −1) or events pause for more than `maxGapMs`.
/// Not thread-safe; the caller serializes.
public final class CrossLatch {
    /// More than this between events resets the latch.
    public static let maxGapMs = 100.0
    /// Deeper than this inside the edge (or more than 1 pt beyond it) resets the latch.
    public static let maxDepthPt = 30.0
    /// A latch is dropped this long after it was set (tails end ≤ 100 ms after UC's exit event).
    public static let holdMs = 150.0

    public private(set) var isArmed = false
    public private(set) var crossX: Double?
    /// This edge visit already produced a latch that expired.
    public private(set) var isSpent = false
    private var latchT = 0.0
    private var prevT = -Double.infinity

    public init() {}

    /// zoneMin/zoneMax per §5.2. Returns the latched crossX after processing this event (nil = none).
    public func onEvent(t: Double, p: CGPoint, dy: Double, geometry: EdgeGeometry,
                        zoneMin: Double, zoneMax: Double) -> Double? {
        let s = geometry.signedDist(p)
        let gap = t - prevT > Self.maxGapMs
        let atEdge = s >= -1 && s < 1
        if gap || !atEdge || !geometry.isValid { isSpent = false }       // a new edge visit
        if gap || s > Self.maxDepthPt || s < -1 || !geometry.isValid {
            isArmed = false
            crossX = nil
        } else if crossX != nil && t - latchT > Self.holdMs {
            isArmed = false
            crossX = nil
            isSpent = atEdge
        }
        if crossX == nil && geometry.isValid && !isSpent {
            let push = geometry.side == .top ? dy < 0 : dy > 0
            let x = Double(p.x)
            if isArmed && push {
                crossX = x
                latchT = t
            } else if !isArmed && atEdge && x >= zoneMin && x <= zoneMax {
                isArmed = true
            }
        }
        prevT = t
        return crossX
    }

    public func reset() {
        isArmed = false
        crossX = nil
        isSpent = false
        prevT = -Double.infinity
    }
}
