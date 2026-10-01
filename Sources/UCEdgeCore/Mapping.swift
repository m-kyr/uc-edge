/// Physical mapping: the fraction along the peer's span equals the fraction along ours (SPEC §1).
/// The result is clamped to [localSpanMin, localSpanMax]. A degenerate peer span maps to the
/// local midpoint; callers should treat such peers as invalid and not correct at all.
public func physicalMap(peerX: Double, peerSpanMin: Double, peerSpanMax: Double,
                        localSpanMin: Double, localSpanMax: Double) -> Double {
    let peerW = peerSpanMax - peerSpanMin
    let lo = min(localSpanMin, localSpanMax), hi = max(localSpanMin, localSpanMax)
    guard peerW.isFinite, abs(peerW) > 1e-9, peerX.isFinite else { return (lo + hi) / 2 }
    let v = localSpanMin + (peerX - peerSpanMin) / peerW * (localSpanMax - localSpanMin)
    return min(max(v, lo), hi)
}
