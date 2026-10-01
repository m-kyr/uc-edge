import CoreGraphics
import Foundation
import UCEdgeCore

/// What the engine needs from the machine. The app wires CoreGraphics in; tests use fakes.
struct EngineEnvironment: Sendable {
    var cursor: CursorSystem
    /// Live bounds of the configured edge displays that are attached.
    var edgeDisplays: @Sendable () -> [ResolvedDisplay]
    var accessibilityTrusted: @Sendable () -> Bool
    var listenEventAccess: @Sendable () -> Bool
    /// UC's ByHost plist, or nil when there is none.
    var ucPlistPath: @Sendable () -> String?
    /// Name resolution (blocking; runs on the engine's DNS queue).
    var resolve: PeerAddressBook.Lookup = PeerAddressBook.lookup
    /// Bounds of every local display (the override guard's clamping check); empty = edge displays.
    var allDisplays: @Sendable () -> [CGRect] = { [] }
}

/// Wires the Core logic to the system. One lock guards the detectors and all engine state,
/// including the network plumbing; CoreGraphics calls (buttons, warp) and network I/O happen
/// outside it. Split over Engine.swift, Engine+Net.swift and Engine+Edge.swift.
final class Engine: @unchecked Sendable {
    let config: Config
    let env: EngineEnvironment
    let log: Logger
    let key: WireKey

    enum Action {
        case correct(Correction, t: Double, peerAgeMs: Double, stillMs: Double, source: CrossSource)
        case redirect(to: CGPoint, from: CGPoint, t: Double)
    }

    // MARK: state guarded by `lock`
    let lock = NSLock()
    var detector: LandingDetector
    var deadStrip: DeadStripDetector
    let latch = CrossLatch()
    /// Original x replacing the current latch after a dead-strip redirect (§6 v1.2).
    var latchOverride: Double?
    /// UC log assist (§13): recent tap events, and the UC-sourced crossX held for tail packets.
    let matcher = UCCrossMatcher()
    var ucHold = UCCrossHold()
    var ucVisit = UCEdgeVisit()
    var ucClock = UCLogClock.local
    var ucLogRunning = false
    var ucLogParsedSinceStart = 0
    var ucLogLastLineT: Double?
    var ucLogLastMatchT: Double?
    var ucLogAdvertised = false
    /// The peer's UC-sourced crossX in its current episode: preferred over later model ones.
    var episodeUCCross: Double?
    /// Activating lines are matched this long after receipt, so the tap callback for the
    /// activating event is surely in the buffer (v1.3.1, F5).
    var ucMatchDelayMs = 3.0
    let ucMatchQueue = DispatchQueue(label: "uc-edge.ucmatch", qos: .userInteractive)
    var clockRef: (wallMs: Double, upMs: Double)?
    var geometry = EdgeGeometry(side: .top, displays: [])
    var localEdge: [LocalEdgeDisplay] = []
    var peer: PeerEdgeState?
    var peerHello: HelloPayload?
    var lastAuthT: Double?
    var lastEdgePacketT: Double?
    var episodeStart: Double?
    var clock = ClockOffsetEstimator()
    var zone: (minX: Double, maxX: Double)?
    var lastEventPinned = false
    var lastSkipCount = 0
    var lastEpisodeRejects = 0
    var lastNearMissCount = 0
    var displayBounds: [CGRect] = []
    var lastT = 0.0
    var status = StatusSnapshot()
    var rejectLog = RateLimitedCounter()
    var arrangement: Result<UCArrangement, UCArrangementError>?
    var arrangementStamp: String?
    var lastZoneLog: String?
    var socket: UDPSocket?
    var sender: NetSender?
    var peers: PeerAddressBook?
    var poller: Poller?
    var timers: [DispatchSourceTimer] = []

    let timerQueue = DispatchQueue(label: "uc-edge.timers", qos: .utility)
    let dnsQueue = DispatchQueue(label: "uc-edge.dns", qos: .utility)

    // MARK: receive-loop policy (tests shorten it)
    var recvBackoffMs = 100.0
    var recvMaxErrors = 50
    var onFatal: @Sendable (String) -> Void = { _ in exit(1) }

    init(config: Config, key: WireKey, env: EngineEnvironment, log: Logger, configWarnings: [String] = []) {
        self.config = config
        self.key = key
        self.env = env
        self.log = log
        detector = LandingDetector(params: config.detector)
        deadStrip = DeadStripDetector(params: config.deadStrip)
        status.name = config.name
        status.deadStripEnabled = config.deadStrip.enabled
        status.correctionsEnabled = config.corrections.enabled
        status.ucLog.state = config.ucLogAssist.enabled ? "stopped" : "disabled"
        status.configWarnings = configWarnings
    }

    // MARK: lifecycle

    /// Binds the socket (unless one is given), starts the receive thread, poller and timers.
    func start(tapActive: Bool, socket given: UDPSocket? = nil) throws {
        guard let port = UInt16(exactly: config.port), port > 0,
              let peerPort = UInt16(exactly: config.peerPort ?? config.port), peerPort > 0 else {
            throw NetError.badPort(config.peerPort ?? config.port)
        }
        let sock = try given ?? UDPSocket(port: port)
        let book = PeerAddressBook(hosts: config.peerHosts, port: peerPort, lookup: env.resolve)
        let net = NetSender(socket: sock, key: key, peers: book,
                            onSent: { [weak self] in
                                guard let self else { return }
                                lock.withLock { noteSentLocked() }
                            },
                            onError: { [weak self] err, dst in self?.noteSendError(err, dst) })
        let p = Poller(cursor: env.cursor, engine: self, idleWaitMs: config.idleWaitMs, fallback: !tapActive)
        lock.withLock {
            socket = sock
            peers = book
            sender = net
            poller = p
            status.permissions.tapActive = tapActive
            status.permissions.pollingFallback = !tapActive
        }
        refreshGeometry()
        refreshArrangement()
        dnsQueue.async { [self] in
            resolvePeers()
            sendHello()
        }
        p.start()

        let rx = Thread { [self] in runReceiveLoop { sock.receive() } }
        rx.name = "uc-edge.net"
        rx.qualityOfService = .userInteractive
        rx.start()

        schedule(every: config.heartbeatSec) { [weak self] in self?.sendHello() }
        schedule(every: 10) { [weak self] in self?.refreshGeometry(); self?.refreshArrangement() }
        schedule(every: 5) { [weak self] in self?.writeStatus() }
        schedule(every: 30) { [weak self] in
            guard let self else { return }
            dnsQueue.async { [weak self] in self?.resolvePeers() }
        }
        log.log("start \(UCEdgeVersion.string) name=\(config.name) side=\(config.side.rawValue) port=\(sock.port) "
                + "peers=\(config.peerHosts) senderId=\(String(format: "%016llx", net.senderId)) tap=\(tapActive)")
    }

    func stop() {
        let (p, s) = lock.withLock { () -> (Poller?, UDPSocket?) in
            timers.forEach { $0.cancel() }
            timers.removeAll()
            return (poller, socket)
        }
        p?.stop()
        s?.shutdownAndClose()
        writeStatus()
        log.flush()
    }

    /// The tap supervisor reports whether a tap is running; without one the poller takes over.
    func setTapActive(_ active: Bool) {
        let (changed, p) = lock.withLock { () -> (Bool, Poller?) in
            let changed = status.permissions.tapActive != active || status.permissions.pollingFallback == active
            status.permissions.tapActive = active
            status.permissions.pollingFallback = !active
            if changed { latch.reset() }
            return (changed, poller)
        }
        p?.setFallback(!active)
        if changed { log.log(active ? "event tap active" : "polling fallback active (no event tap)") }
    }

    func displaysChanged() {
        timerQueue.async { [self] in
            refreshGeometry()
            refreshArrangement()
        }
    }

    // MARK: input paths

    /// Every local tap event (tap thread). In polling fallback, every position change arrives
    /// here as a synthetic event with deltas derived from the previous sample. `eventNs` is the
    /// event's CGEvent.timestamp (uptime ns); nil = now.
    func onTapEvent(p: CGPoint, dx: Double, dy: Double, buttonsDown: Bool, synthetic: Bool = false, eventNs: UInt64? = nil) {
        let ns = eventNs ?? DispatchTime.now().uptimeNanoseconds
        var edge: EdgePayload?
        var action: Action?
        var notes: [String] = []
        let net: NetSender? = lock.withLock {
            let t = tick()
            action = synthetic ? sampleLocked(t: t, p: p, buttonsDown: buttonsDown)
                               : tapSampleLocked(t: t, p: p, dx: dx, dy: dy, buttonsDown: buttonsDown)
            if action == nil, !synthetic, let z = zone, peerAliveLocked(t),
               let r = deadStrip.onEvent(t: t, p: p, dy: dy, prevWasPinned: lastEventPinned, buttonsDown: buttonsDown,
                                         geometry: geometry, zoneMinX: z.minX, zoneMaxX: z.maxX) {
                detector.didWarp(t: t, to: r)
                action = .redirect(to: r, from: p, t: t)
            }
            if deadStrip.nearMissCount != lastNearMissCount, let m = deadStrip.lastNearMiss {
                lastNearMissCount = deadStrip.nearMissCount
                status.deadStripLastNearMiss = m.description
                if rejectLog.hit("deadstrip-nearmiss", now: t) != nil { notes.append("deadstrip near-miss: \(m.description)") }
            }
            let s = geometry.signedDist(p)
            lastEventPinned = s <= DeadStripDetector.pinnedPt && s >= -1
            matcher.record(UCTapRecord(ns: ns, x: Double(p.x), y: Double(p.y), s: s, dy: dy))
            ucVisit.onEvent(t: t, ns: ns, s: s)
            let ucX = ucHold.onEvent(t: t, s: s)
            let before = latch.crossX
            let crossX = latchLocked(t: t, p: p, dy: dy, synthetic: synthetic)
            if let cx = crossX, before == nil {
                status.counters.modelCross += 1
                // A new latch: the only one that may carry a dead-strip redirect's original x.
                latchOverride = deadStrip.consumeRedirect(latchT: t, latchX: cx)
            } else if crossX == nil {
                latchOverride = nil
            }
            // UC's own crossX (from its log) wins over the model latch for this edge visit.
            if let ucX {
                edge = edgePacketLocked(p: p, dy: dy, moved: true, synthetic: synthetic, crossX: ucX, source: .uc)
            } else {
                edge = edgePacketLocked(p: p, dy: dy, moved: true, synthetic: synthetic,
                                        crossX: crossX.map { latchOverride ?? $0 }, source: .model)
            }
            notes += detectorNotesLocked()
            return sender
        }
        if let edge { net?.send(.edge(edge), duplicateAfterMs: config.duplicateDelayMs) }
        notes.forEach(log.log)
        if let action { perform(action) }
    }

    /// A 1 kHz poller sample (poll thread).
    func onPollSample(p: CGPoint, buttonsDown: Bool) {
        let (action, notes) = lock.withLock { (sampleLocked(t: tick(), p: p, buttonsDown: buttonsDown), detectorNotesLocked()) }
        notes.forEach(log.log)
        if let action { perform(action) }
    }

    /// Armed: a fresh peer EDGE packet, a pending late landing, or the snap-back guard. Never
    /// with corrections off: nothing would come of the 1 kHz samples (v1.3.1, F6).
    func isArmed() -> Bool {
        guard config.corrections.enabled else { return false }
        return lock.withLock {
            let t = max(lastT, monotonicMs())
            if let peer, t - peer.receivedAt <= config.armMs { return true }
            return detector.isArmed(at: t)
        }
    }

    // MARK: locked helpers

    /// Monotonic now. Uptime stops during sleep, so a peer packet from before a sleep would
    /// look fresh after wake: when wall time ran ahead of uptime by > 2 s, drop all state.
    func tick() -> Double {
        let up = monotonicMs()
        let wall = Date().timeIntervalSince1970 * 1000
        if let r = clockRef, (wall - r.wallMs) - (up - r.upMs) > 2000 {
            peer = nil
            lastEdgePacketT = nil
            episodeStart = nil
            detector = LandingDetector(params: config.detector)
            deadStrip = DeadStripDetector(params: config.deadStrip)
            latch.reset()
            latchOverride = nil
            ucHold.reset()
            ucVisit = UCEdgeVisit()
            episodeUCCross = nil
            lastSkipCount = 0
            lastEpisodeRejects = 0
            log.log(String(format: "clock gap of %.0f ms (sleep?): peer and detector state reset", (wall - r.wallMs) - (up - r.upMs)))
        }
        clockRef = (wall, up)
        lastT = max(lastT, up)
        return lastT
    }

    /// A tap event: the detector also sees its deltas (override guard, §14).
    func tapSampleLocked(t: Double, p: CGPoint, dx: Double, dy: Double, buttonsDown: Bool) -> Action? {
        guard config.corrections.enabled,
              let c = detector.onTapEvent(t: t, p: p, dx: dx, dy: dy, buttonsDown: buttonsDown, geometry: geometry,
                                          peer: peer, displays: displayBounds.isEmpty ? nil : displayBounds) else {
            return nil
        }
        detector.didWarp(t: t, to: c.target)
        return .correct(c, t: t, peerAgeMs: peer.map { t - $0.receivedAt } ?? -1, stillMs: detector.lastStillMs,
                        source: c.source)
    }

    func sampleLocked(t: Double, p: CGPoint, buttonsDown: Bool) -> Action? {
        // §13.2.4: with corrections off this Mac never warps for landings (no snap-back either).
        guard config.corrections.enabled,
              let c = detector.onSample(t: t, p: p, buttonsDown: buttonsDown, geometry: geometry, peer: peer) else {
            return nil
        }
        // Registered before the warp so a concurrent sample of the target is seen as our echo.
        detector.didWarp(t: t, to: c.target)
        return .correct(c, t: t, peerAgeMs: peer.map { t - $0.receivedAt } ?? -1, stillMs: detector.lastStillMs,
                        source: c.source)
    }

    /// The x range where the latch may arm (§5.2): UC's zone on a dead-strip side, else the span.
    func latchZoneLocked() -> (min: Double, max: Double) {
        let span = (geometry.spanMin - 1, geometry.spanMax + 1)
        guard config.deadStrip.enabled else { return span }
        if let z = zone { return (z.minX, z.maxX) }
        // ucLinkMissing: UC crosses nowhere, so never latch. Otherwise UC's zone is unknown and no
        // fallback zone is configured: latch on the whole span, as without the dead strip.
        return status.arrangement.ucLinkMissing ? (.infinity, -.infinity) : span
    }

    func latchLocked(t: Double, p: CGPoint, dy: Double, synthetic: Bool) -> Double? {
        let z = latchZoneLocked()
        guard synthetic else {
            return latch.onEvent(t: t, p: p, dy: dy, geometry: geometry, zoneMin: z.min, zoneMax: z.max)
        }
        // Polling fallback has no deltas: the second consecutive at-edge position change in the
        // zone latches. Only changes arrive here, so a frozen cursor can never latch (C1).
        let s = geometry.signedDist(p), x = Double(p.x)
        let edgeInZone = s >= -1 && s < 1 && x >= z.min && x <= z.max
        if !edgeInZone && latch.crossX == nil { latch.reset() }
        let pseudoDy: Double = edgeInZone ? (geometry.side == .top ? -1 : 1) : 0
        return latch.onEvent(t: t, p: p, dy: pseudoDy, geometry: geometry, zoneMin: z.min, zoneMax: z.max)
    }

    /// SPEC §5.2: send while at the edge or latched, within the span.
    func edgePacketLocked(p: CGPoint, dy: Double, moved: Bool, synthetic: Bool, crossX: Double?,
                          source: CrossSource) -> EdgePayload? {
        guard geometry.isValid, geometry.inSpan(Double(p.x)) else { return nil }
        let s = geometry.signedDist(p)
        // More than 1 pt beyond the edge is another display (e.g. the MacBook's built-in).
        let atEdge = s >= -1 && s <= config.detector.atEdgePt
        guard atEdge || crossX != nil else { return nil }
        let push = geometry.side == .top ? dy < 0 : dy > 0
        let pushing = atEdge && (synthetic ? moved : push)     // fallback: "at edge and moved"
        return EdgePayload(x: Double(p.x), d: max(0, s), pushing: pushing, spanMin: geometry.spanMin,
                           spanMax: geometry.spanMax, crossX: crossX, crossSource: crossX == nil ? .model : source)
    }

    /// Log lines for corrections the detector declined: too small, or the cursor moved during
    /// the peer's episode.
    func detectorNotesLocked() -> [String] {
        var notes: [String] = []
        if detector.skippedSmallCount != lastSkipCount, let c = detector.lastSkippedSmall {
            lastSkipCount = detector.skippedSmallCount
            status.counters.skippedSmall += 1
            notes.append(String(format: "skip kind=%@ landing=(%.1f,%.1f) target=(%.1f,%.1f) peerX=%.1f (< %.1f pt)",
                                c.kind.rawValue, c.landing.x, c.landing.y, c.target.x, c.target.y, c.peerX,
                                config.detector.minCorrectionPt))
        }
        if detector.episodeRejectCount != lastEpisodeRejects {
            lastEpisodeRejects = detector.episodeRejectCount
            status.counters.episodeRejects += 1
            notes.append(String(format: "reject landing: local cursor moved during the peer's episode (still %.0f ms)",
                                detector.lastStillMs))
        }
        return notes
    }

    func peerAliveLocked(_ t: Double) -> Bool {
        lastAuthT.map { t - $0 <= 10_000 } ?? false
    }

    // MARK: warping

    func perform(_ action: Action) {
        switch action {
        case let .correct(c, t, age, still, source):
            var note: String?
            var err: Int32 = 0
            if env.cursor.buttonsDown() {
                note = "button down"
            } else {
                err = env.cursor.warp(to: c.target)
                if err != 0 { note = "CGError \(err)" }
            }
            let latencyUs = (monotonicMs() - t) * 1000
            let warped = note == nil
            lock.withLock {
                if warped {
                    switch c.kind {
                    case .immediate: status.counters.immediate += 1
                    case .late: status.counters.late += 1
                    case .snapback: status.counters.snapback += 1
                    case .override: status.counters.overrideRewarps += 1
                    }
                    status.warpFailing = false
                } else {
                    detector.didSkipWarp(t: tick())
                    if err == 0 { status.counters.skippedButtons += 1 } else { status.counters.warpFailures += 1 }
                    if err == 1003 { status.warpFailing = true }
                }
                status.lastCorrections.append(CorrectionRecord(
                    at: Date(), kind: c.kind.rawValue, crossSource: source == .uc ? "uc" : "model",
                    landing: PointJSON(c.landing), target: PointJSON(c.target),
                    peerX: c.peerX, peerAgeMs: age, latencyUs: latencyUs, warped: warped, note: note))
                if status.lastCorrections.count > 10 { status.lastCorrections.removeFirst() }
            }
            if c.kind == .override {
                let n = lock.withLock { status.counters.overrideRewarps }
                log.log(String(format: "override rewarp n=%d p=(%.1f,%.1f) to=(%.1f,%.1f) latency=%.0fus",
                               n, c.landing.x, c.landing.y, c.target.x, c.target.y, latencyUs)
                        + (warped ? "" : " SKIPPED (\(note ?? ""))"))
            } else {
                log.log(String(format: "correct kind=%@ src=%@ landing=(%.1f,%.1f) target=(%.1f,%.1f) peerX=%.2f age=%.0fms still=%.0fms latency=%.0fus",
                               c.kind.rawValue, source == .uc ? "uc" : "model", c.landing.x, c.landing.y, c.target.x, c.target.y,
                               c.peerX, age, still, latencyUs)
                        + (warped ? "" : " SKIPPED (\(note ?? ""))"))
            }
            timerQueue.async { [weak self] in self?.writeStatus() }

        case let .redirect(r, from, t):
            var note: String?
            if env.cursor.buttonsDown() {
                note = "button down"
            } else {
                let err = env.cursor.warp(to: r)
                if err != 0 { note = "CGError \(err)" }
            }
            let latencyUs = (monotonicMs() - t) * 1000
            lock.withLock {
                if note == nil {
                    status.counters.deadStripRedirects += 1
                } else {
                    detector.didSkipWarp(t: tick())
                    deadStrip.clearRedirect()
                }
            }
            log.log(String(format: "deadstrip from=(%.1f,%.1f) to=(%.1f,%.1f) latency=%.0fus", from.x, from.y, r.x, r.y, latencyUs)
                    + (note.map { " SKIPPED (\($0))" } ?? ""))
        }
    }

    func schedule(every seconds: Double, _ body: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 100)))
        t.setEventHandler(handler: body)
        t.resume()
        lock.withLock { timers.append(t) }
    }
}
