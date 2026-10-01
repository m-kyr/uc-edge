import CoreGraphics
import Foundation
import UCEdgeCore

/// Edge geometry, UC's arrangement zone and status.
extension Engine {
    func refreshGeometry() {
        let wanted = config.edgeDisplayUUIDs
        let found = env.edgeDisplays()
        let all = env.allDisplays()
        let missing = wanted.filter { w in !found.contains { $0.uuid == w } }
        // A partial edge would map to the wrong span: stay off until every display is back.
        let g = EdgeGeometry(side: config.side, displays: missing.isEmpty ? found.map(\.bounds) : [])
        lock.withLock {
            let changed = g != geometry
            geometry = g
            displayBounds = all
            localEdge = missing.isEmpty
                ? found.map { LocalEdgeDisplay(uuid: $0.uuid.uuidString, minX: Double($0.bounds.minX), width: Double($0.bounds.width)) }
                : []
            status.geometry = .init(side: config.side.rawValue, edgeY: g.edgeY, spanMin: g.spanMin, spanMax: g.spanMax,
                                    displaysFound: found.map(\.uuid.uuidString),
                                    displaysMissing: missing.map(\.uuidString))
            if changed {
                log.log(String(format: "geometry side=%@ edgeY=%.1f span=[%.1f, %.1f] displays=%d missing=%d",
                               config.side.rawValue, g.edgeY, g.spanMin, g.spanMax, found.count, missing.count))
                recomputeZoneLocked()
            }
        }
    }

    /// Re-reads UC's plist when its path or mtime changed (read-only).
    func refreshArrangement() {
        let path = config.ucPlistPath.map(expandTilde) ?? env.ucPlistPath()
        let mtime = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        let stamp = "\(path ?? "-")|\(mtime?.timeIntervalSince1970 ?? 0)"
        guard lock.withLock({ stamp != arrangementStamp }) else { return }
        let result: Result<UCArrangement, UCArrangementError>
        if let path {
            do { result = .success(try UCArrangement.load(path: path)) } catch { result = .failure(error) }
        } else {
            result = .failure(.notFound)
        }
        lock.withLock {
            arrangementStamp = stamp
            arrangement = result
            recomputeZoneLocked()
        }
    }

    func recomputeZoneLocked() {
        // nil when no fallback zone is configured: UC's zone stays unknown (see latchZoneLocked).
        let fallback = config.deadStrip.fallbackZone
        var a = StatusSnapshot.Arrangement()
        switch arrangement {
        case .failure(let e)?:
            zone = fallback
            a.source = "fallback"
            a.note = "parse: \(e)"
        case nil:
            zone = fallback
            a.source = "fallback"
        case .success(let arr)?:
            if let hello = peerHello, !localEdge.isEmpty {
                switch arr.zone(local: localEdge, peer: hello.displays) {
                case let .zone(minX, maxX) where minX.isFinite && maxX.isFinite:
                    zone = (minX, maxX)
                    a.source = "parsed"
                case .zone:
                    zone = fallback
                    a.source = "fallback"
                    a.note = "non-finite zone"
                case .linkMissing:
                    zone = nil                        // nothing crosses; never redirect or latch
                    a.source = "parsed"
                    a.ucLinkMissing = true
                }
            } else {
                zone = fallback
                a.source = "waitingForPeer"
            }
        }
        a.zoneMinX = zone?.minX
        a.zoneMaxX = zone?.maxX
        status.arrangement = a
        let summary = "source=\(a.source) zone=\(zone.map { String(format: "[%.1f, %.1f]", $0.minX, $0.maxX) } ?? "none") linkMissing=\(a.ucLinkMissing)"
            + (a.note.map { " \($0)" } ?? "")
        if summary != lastZoneLog {
            lastZoneLog = summary
            log.log((a.ucLinkMissing ? "WARNING UC has no link between the local edge and the peer's edge; " : "") + "arrangement \(summary)")
        }
    }

    func snapshot() -> StatusSnapshot {
        let ax = env.accessibilityTrusted(), listen = env.listenEventAccess()
        let book = lock.withLock { peers }
        let address = book?.preferred?.description
        let learned = book?.isLearned ?? false
        return lock.withLock {
            let t = max(lastT, monotonicMs())
            status.updatedAt = Date()
            status.permissions.accessibility = ax
            status.permissions.listenEvents = listen
            status.peer.alive = peerAliveLocked(t)
            status.peer.lastPacketAgeMs = lastAuthT.map { t - $0 }
            status.ucLog.lastLineAgeMs = ucLogLastLineT.map { t - $0 }
            status.counters.deferred = detector.deferredCount
            status.counters.deferredFallbacks = detector.deferredFallbackCount
            status.peer.address = address
            status.peer.addressLearned = learned
            return status
        }
    }

    func writeStatus() {
        StatusFile.write(snapshot(), to: config.statusPath)
    }
}
