import Foundation
import UCEdgeCore

/// Receive loop, packet handling, HELLO / HELLO_ACK, clock offset and DNS.
extension Engine {
    /// Never ends silently (v1.2): errors are logged and retried after `recvBackoffMs`; after
    /// `recvMaxErrors` in a row the process exits so launchd restarts it. Returns on `.closed`.
    func runReceiveLoop(_ next: () -> ReceiveResult) {
        var rx = WireReceiver(key: key)
        var consecutive = 0
        while true {
            switch next() {
            case .closed:
                return
            case .error(let e):
                consecutive += 1
                let msg = "recv: \(String(cString: strerror(e)))"
                let first = lock.withLock { () -> Bool in
                    status.counters.recvErrors += 1
                    status.netError = msg
                    return rejectLog.hit("recv", now: tick()) != nil
                }
                if consecutive >= recvMaxErrors {
                    log.log("FATAL \(consecutive) receive errors in a row (\(msg)); exiting so launchd restarts UCEdge")
                    writeStatus()
                    log.flush()
                    onFatal(msg)
                    return
                }
                if first { log.log("receive error \(msg) (\(consecutive) in a row); retrying every \(Int(recvBackoffMs)) ms") }
                usleep(useconds_t(max(0, recvBackoffMs) * 1000))
            case let .datagram(data, from):
                if consecutive > 0 {
                    lock.withLock { if status.netError?.hasPrefix("recv") == true { status.netError = nil } }
                }
                consecutive = 0
                do {
                    handle(try rx.accept(data, nowWallMs: currentWallMs()), from: from)
                } catch {
                    noteReject(error, from: from)
                }
            }
        }
    }

    func handle(_ packet: Packet, from: SocketAddress) {
        let (book, net) = lock.withLock { (peers, sender) }
        book?.learn(from)
        switch packet.body {
        case .edge(let e):
            let buttons = env.cursor.buttonsDown()
            let nowWall = currentWallMs()
            let (action, notes, p): (Action?, [String], Poller?) = lock.withLock {
                let t = tick()
                lastAuthT = t
                status.counters.packetsReceived += 1
                if lastEdgePacketT.map({ t - $0 > 150 }) ?? true {
                    episodeStart = t
                    episodeUCCross = nil
                }
                lastEdgePacketT = t
                let lag = clock.senderLag(wallMs: packet.wallMs, nowWallMs: nowWall)
                // v1.3.1: prefer a UC-sourced crossX for the whole episode; a model one may still be
                // used after the detector's short wait (ucWaitMs) when UC's doesn't come.
                if e.crossSource == .uc, let cx = e.crossX { episodeUCCross = cx }
                // No crossX: the sender's hold has reset, so a later crossing in this unbroken
                // episode must not reuse the earlier UC x (v1.4, G1).
                if e.crossX == nil { episodeUCCross = nil }
                let (crossX, source) = episodeUCCross.map { ($0, CrossSource.uc) } ?? (e.crossX, e.crossSource)
                let st = PeerEdgeState(x: e.x, d: e.d, pushing: e.pushing, spanMin: e.spanMin, spanMax: e.spanMax,
                                       receivedAt: t, crossX: crossX, episodeStart: episodeStart,
                                       senderLagMs: lag.lagMs, senderSlackMs: lag.slackMs,
                                       crossSource: source, peerUCLogActive: peerHello?.ucLogActive ?? false)
                peer = st
                // The late path uses the detector's own last sample, read under this lock, not a
                // cursor location read on this thread (which can predate the landing).
                guard config.corrections.enabled, let current = detector.lastPosition,
                      let c = detector.onPeerUpdate(t: t, peer: st, current: current, buttonsDown: buttons, geometry: geometry)
                else { return (nil, detectorNotesLocked(), poller) }
                detector.didWarp(t: t, to: c.target)
                return (.correct(c, t: t, peerAgeMs: 0, stillMs: detector.lastStillMs, source: c.source),
                        detectorNotesLocked(), poller)
            }
            p?.wake.signal()
            notes.forEach(log.log)
            if let action { perform(action) }

        case .hello(let h):
            let needRTT: Bool = lock.withLock {
                lastAuthT = tick()
                status.counters.packetsReceived += 1
                acceptHelloLocked(h)
                return status.peer.rttMs == nil
            }
            net?.send(.helloAck(helloPayload(echo: packet.wallMs)), to: from)
            // First contact (e.g. the peer just started): measure RTT now, not at the next heartbeat.
            if needRTT { net?.send(.hello(helloPayload()), to: from) }

        case .helloAck(let h):
            // Peer-supplied timestamps: Double arithmetic only, never trapping Int64 math (C4).
            let now = currentWallMs()
            let rtt = h.echoWallMs.map { Double(now) - Double($0) }
            lock.withLock {
                lastAuthT = tick()
                status.counters.packetsReceived += 1
                if let rtt, rtt >= 0, rtt <= 10_000 { status.peer.rttMs = rtt }
                if let echo = h.echoWallMs {
                    clock.add(sentWallMs: echo, peerWallMs: packet.wallMs, receivedWallMs: now)
                    status.peer.clockOffsetMs = clock.offsetMs
                }
                acceptHelloLocked(h)
            }
        }
    }

    func acceptHelloLocked(_ h: HelloPayload) {
        let changed = peerHello?.displays != h.displays || peerHello?.version != h.version || peerHello?.side != h.side
        peerHello = h
        status.peer.version = h.version
        status.peer.axTrusted = h.axTrusted
        status.peer.edgeDisplays = h.displays
        status.peer.sideConflict = h.side == config.side
        status.ucLog.peerActive = h.ucLogActive
        if changed {
            log.log("peer hello version=\(h.version) side=\(h.side.rawValue) displays=\(h.displays.map { "\($0.uuid.uuidString.prefix(8))@\($0.minX)+\($0.width)" }) ax=\(h.axTrusted)")
            if h.side == config.side {
                log.log("WARNING the peer's shared edge is also \(h.side.rawValue); check both configs")
            }
            recomputeZoneLocked()
        }
    }

    func helloPayload(echo: Int64? = nil) -> HelloPayload {
        let displays = lock.withLock {
            localEdge.compactMap { d in UUID(uuidString: d.uuid).map { EdgeDisplayInfo(uuid: $0, minX: d.minX, width: d.width) } }
        }
        let ucActive = lock.withLock { ucLogActiveLocked() }
        return HelloPayload(version: UCEdgeVersion.string, side: config.side, displays: displays,
                            axTrusted: env.accessibilityTrusted(), ucLogActive: ucActive, echoWallMs: echo)
    }

    func sendHello() {
        let net = lock.withLock { () -> NetSender? in
            _ = tick()
            return sender
        }
        net?.send(.hello(helloPayload()))
    }

    /// Blocking (getaddrinfo): only ever called on `dnsQueue`.
    func resolvePeers() {
        guard let book = lock.withLock({ peers }) else { return }
        let err = book.resolve()
        lock.withLock {
            if let err {
                status.netError = "resolve: \(err)"
            } else if status.netError?.hasPrefix("resolve") == true {
                status.netError = nil
            }
        }
        if let err, !book.isLearned { log.log("resolve failed: \(err)") }
    }

    func noteSentLocked() {
        status.counters.packetsSent += 1
        if status.netError?.hasPrefix("send") == true { status.netError = nil }
    }

    func noteSendError(_ err: Int32, _ dst: SocketAddress?) {
        let msg = "send \(dst?.description ?? "(no address)"): \(String(cString: strerror(err)))"
        let shouldLog: Int? = lock.withLock {
            status.counters.sendErrors += 1
            status.netError = msg
            return rejectLog.hit("send:\(err)", now: tick())
        }
        if let n = shouldLog { log.log("net error \(msg) (count \(n))") }
    }

    func noteReject(_ error: Error, from: SocketAddress) {
        if error as? WireError == .duplicate {
            lock.withLock { status.counters.duplicates += 1 }
            return
        }
        let reason = (error as? WireError)?.rawValue ?? "other"
        let shouldLog: Int? = lock.withLock {
            status.counters.rejects[reason, default: 0] += 1
            return rejectLog.hit("reject:\(reason)", now: tick())
        }
        if let n = shouldLog { log.log("reject reason=\(reason) from=\(from) count=\(n)") }
    }
}
