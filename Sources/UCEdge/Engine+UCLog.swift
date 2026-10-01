import CoreGraphics
import Foundation
import UCEdgeCore

/// UC log assist (SPEC §13.2.1, §13.4): UC's own "Activating" line fixes the exact crossX.
extension Engine {
    static let ucLogMatchMemoryMs = 24 * 60 * 60 * 1000.0

    /// Advertised in HELLO (v1.3.1): the child runs and has matched an Activating line in the
    /// last 24 h, or has parsed any line since it started. The peer only uses it to decide whether
    /// a short wait for our UC-sourced crossX is worthwhile.
    func ucLogActiveLocked() -> Bool {
        guard config.ucLogAssist.enabled, ucLogRunning else { return false }
        if ucLogParsedSinceStart > 0 { return true }
        return ucLogLastMatchT.map { max(lastT, monotonicMs()) - $0 <= Self.ucLogMatchMemoryMs } ?? false
    }

    func ucLogStarted() {
        lock.withLock {
            ucLogRunning = true
            ucLogParsedSinceStart = 0
            status.ucLog.state = "running"
        }
        log.log("uclog: log stream running")
        advertiseUCLogIfChanged()
    }

    func ucLogStopped(restarting: Bool) {
        lock.withLock {
            ucLogRunning = false
            status.ucLog.state = restarting ? "restarting" : "stopped"
            if restarting { status.ucLog.restarts += 1 }
        }
        advertiseUCLogIfChanged()
    }

    /// The reader dropped an over-long partial line (v1.3.1, F6).
    func ucLogOverflow() {
        lock.withLock { status.ucLog.overflows += 1 }
        log.log("uclog: dropped over 64 KB of output without a newline")
    }

    /// One line from `log stream --style ndjson`, with the clocks sampled at receipt.
    func onUCLogLine(_ line: String, receivedNs: UInt64, continuousMinusAbsolute: UInt64) {
        guard let event = UCLogParser.parse(ndjsonLine: line) else { return }
        onUCLogEvent(event, receivedNs: receivedNs, continuousMinusAbsolute: continuousMinusAbsolute)
    }

    /// Checks at receipt (clock, lag, side and display); the match itself runs `ucMatchDelayMs`
    /// later on `ucMatchQueue`.
    func onUCLogEvent(_ event: UCLogEvent, receivedNs: UInt64, continuousMinusAbsolute: UInt64) {
        // A "negative" offset (the two clocks read a tick apart on a Mac that never slept) is 0 (F1).
        let offset = continuousMinusAbsolute > UInt64(Int64.max) ? 0 : continuousMinusAbsolute
        var note: String?
        let accepted: UInt64? = lock.withLock {
            let t = tick()
            ucLogParsedSinceStart += 1
            ucLogLastLineT = t
            status.ucLog.linesParsed += 1
            guard event.kind == .activating else { return nil }
            status.ucLog.activations += 1
            guard let ns = ucClock.uptimeNs(machContinuous: event.machTimestamp, continuousMinusAbsolute: offset),
                  UCLogClock.lagIsSane(eventNs: ns, nowNs: receivedNs) else {
                status.ucLog.clockErrors += 1
                note = "uclog: clock error for \(event.edge) activation (ignored)"
                return nil
            }
            let maxLagNs = Int64(config.ucLogAssist.maxLagMs * 1_000_000)
            guard UCLogClock.lagIsAcceptable(eventNs: ns, nowNs: receivedNs, maxLagNs: maxLagNs) else {
                status.ucLog.lateLines += 1
                note = String(format: "uclog: activation delivered %.0f ms late (limit %.0f ms), ignored",
                              Double(Int64(bitPattern: receivedNs &- ns)) / 1e6, config.ucLogAssist.maxLagMs)
                return nil
            }
            guard UCLogFilter.accepts(event, localSide: config.side, peerDisplays: peerHello?.displays.map(\.uuid) ?? []) else {
                status.ucLog.ignored += 1
                return nil
            }
            return ns
        }
        if let note { log.log(note) }
        advertiseUCLogIfChanged()
        guard let ns = accepted else { return }
        ucMatchQueue.asyncAfter(deadline: .now() + .microseconds(Int(ucMatchDelayMs * 1000))) { [weak self] in
            self?.matchActivation(ns: ns, receivedNs: receivedNs)
        }
    }

    /// Matches an accepted Activating line to our at-edge event and sends the crossX at once.
    func matchActivation(ns: UInt64, receivedNs: UInt64) {
        var edge: EdgePayload?
        var note: String?
        let net: NetSender? = lock.withLock {
            let t = tick()
            guard let hit = matcher.match(activationNs: ns, atEdgePt: config.detector.atEdgePt) else {
                status.ucLog.unmatched += 1
                note = String(format: "uclog: activation with no at-edge event in the 100 ms before it (lag %.1f ms)",
                              Double(Int64(bitPattern: receivedNs &- ns)) / 1e6)
                return nil
            }
            // Never carry a crossX into a later edge visit (F3).
            guard ucVisit.contains(ns: hit.ns) else {
                status.ucLog.staleVisit += 1
                note = "uclog: activation for an earlier edge visit, ignored"
                return nil
            }
            status.ucLog.matched += 1
            status.counters.ucCross += 1
            ucLogLastMatchT = t
            // A dead-strip redirect makes UC activate at the redirect point: send the original x.
            let x = deadStrip.consumeRedirectForUC(t: t, latchX: hit.x) ?? hit.x
            ucHold.set(x, at: t)
            edge = edgePacketLocked(p: CGPoint(x: hit.x, y: hit.y), dy: hit.dy, moved: true, synthetic: false,
                                    crossX: x, source: .uc)
            note = String(format: "uccross x=%.2f lagMs=%.2f eventAgeMs=%.2f", x,
                          Double(Int64(bitPattern: receivedNs &- ns)) / 1e6, Double(ns - hit.ns) / 1e6)
            return sender
        }
        if let edge { net?.send(.edge(edge), duplicateAfterMs: config.duplicateDelayMs) }
        if let note { log.log(note) }
    }

    /// Sends a HELLO at once when what we advertise changes, so the peer switches promptly.
    func advertiseUCLogIfChanged() {
        let changed = lock.withLock { () -> Bool in
            let now = ucLogActiveLocked()
            status.ucLog.active = now
            defer { ucLogAdvertised = now }
            return now != ucLogAdvertised
        }
        if changed { sendHello() }
    }
}
