import Foundation

/// `~/.config/uc-edge/config.json`. Every field is optional in the file; missing ones take
/// the defaults below, so a config only needs what differs per machine.
public struct Config: Codable, Sendable, Equatable {
    /// Name used in logs and status ("vmind", "macbook").
    public var name = "uc-edge"
    public var side: EdgeSide = .top
    /// Display UUIDs of the local shared edge.
    public var edgeDisplays: [String] = []
    public var peerHosts: [String] = []
    public var port = 47591
    /// The peer's port when it differs from ours (tests); nil = `port`.
    public var peerPort: Int?
    /// Poll at 1 kHz while a peer EDGE packet is at most this old.
    public var armMs = 400.0
    /// How long the idle poller blocks between wake-ups.
    public var idleWaitMs = 250.0
    /// Delay of the duplicate copy of every EDGE packet.
    public var duplicateDelayMs = 4.0
    public var heartbeatSec = 2.0
    public var detector = DetectorParams()
    public var deadStrip = DeadStripParams()
    /// §13.2.4: false = never warp for landings (V-Mind: UC drives its pointer absolutely).
    public var corrections = Toggle(enabled: true)
    /// §13.2.1: read UC's own Activating log lines for the exact crossX.
    public var ucLogAssist = UCLogAssistConfig()
    public var keyPath = "~/.config/uc-edge/key"
    public var logPath = "~/Library/Logs/UCEdge/uc-edge.log"
    public var statusPath = "~/Library/Application Support/UCEdge/status.json"
    /// Override for UC's ByHost plist; nil = search `~/Library/Preferences/ByHost`.
    public var ucPlistPath: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        side = try c.decodeIfPresent(EdgeSide.self, forKey: .side) ?? d.side
        edgeDisplays = try c.decodeIfPresent([String].self, forKey: .edgeDisplays) ?? d.edgeDisplays
        peerHosts = try c.decodeIfPresent([String].self, forKey: .peerHosts) ?? d.peerHosts
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        peerPort = try c.decodeIfPresent(Int.self, forKey: .peerPort)
        armMs = try c.decodeIfPresent(Double.self, forKey: .armMs) ?? d.armMs
        idleWaitMs = try c.decodeIfPresent(Double.self, forKey: .idleWaitMs) ?? d.idleWaitMs
        duplicateDelayMs = try c.decodeIfPresent(Double.self, forKey: .duplicateDelayMs) ?? d.duplicateDelayMs
        heartbeatSec = try c.decodeIfPresent(Double.self, forKey: .heartbeatSec) ?? d.heartbeatSec
        detector = try c.decodeIfPresent(DetectorParams.self, forKey: .detector) ?? d.detector
        deadStrip = try c.decodeIfPresent(DeadStripParams.self, forKey: .deadStrip) ?? d.deadStrip
        corrections = try c.decodeIfPresent(Toggle.self, forKey: .corrections) ?? d.corrections
        ucLogAssist = try c.decodeIfPresent(UCLogAssistConfig.self, forKey: .ucLogAssist) ?? d.ucLogAssist
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? d.keyPath
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? d.logPath
        statusPath = try c.decodeIfPresent(String.self, forKey: .statusPath) ?? d.statusPath
        ucPlistPath = try c.decodeIfPresent(String.self, forKey: .ucPlistPath)
    }

    public static let defaultPath = "~/.config/uc-edge/config.json"

    public static func load(path: String = defaultPath) throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: expandTilde(path)))
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Edge display UUIDs, parsed. Malformed entries are dropped.
    public var edgeDisplayUUIDs: [UUID] { edgeDisplays.compactMap { UUID(uuidString: $0) } }
}

/// `ucLogAssist`: on/off, and how late a UC log line may arrive and still be used (v1.3.1, F3).
public struct UCLogAssistConfig: Codable, Sendable, Equatable {
    public var enabled = true
    public var maxLagMs = 100.0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxLagMs = try c.decodeIfPresent(Double.self, forKey: .maxLagMs) ?? 100
    }
}

/// `{ "enabled": bool }`; a missing `enabled` keeps the default.
public struct Toggle: Codable, Sendable, Equatable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// v1.2 config validation: structural problems are errors (refuse to run); out-of-range
/// numbers fall back to their defaults with a warning.
public struct ConfigCheck: Sendable, Equatable {
    public var config: Config
    public var errors: [String] = []
    public var warnings: [String] = []
}

extension Config {
    public func validated() -> ConfigCheck {
        var check = ConfigCheck(config: self)
        if edgeDisplays.isEmpty { check.errors.append("edgeDisplays is empty") }
        for s in edgeDisplays where UUID(uuidString: s) == nil {
            check.errors.append("edgeDisplays: \"\(s)\" is not a UUID")
        }
        if !(1...65535).contains(port) { check.errors.append("port \(port) is not a UDP port") }
        if let p = peerPort, !(1...65535).contains(p) { check.errors.append("peerPort \(p) is not a UDP port") }
        if peerHosts.isEmpty { check.warnings.append("peerHosts is empty: only a peer that contacts us can be reached") }

        let d = Config()
        func bound(_ path: WritableKeyPath<Config, Double>, _ name: String, _ range: ClosedRange<Double>) {
            let v = check.config[keyPath: path]
            guard !range.contains(v) else { return }
            check.config[keyPath: path] = d[keyPath: path]
            check.warnings.append("\(name) = \(v) outside \(range.lowerBound)…\(range.upperBound); using \(d[keyPath: path])")
        }
        let ms: ClosedRange<Double> = 1...10_000
        bound(\.armMs, "armMs", ms)
        bound(\.idleWaitMs, "idleWaitMs", 10...10_000)
        bound(\.duplicateDelayMs, "duplicateDelayMs", 0...100)
        bound(\.heartbeatSec, "heartbeatSec", 0.5...60)
        bound(\.detector.stripPt, "detector.stripPt", 1...200)
        bound(\.detector.minStillMs, "detector.minStillMs", ms)
        bound(\.detector.freshMs, "detector.freshMs", ms)
        bound(\.detector.lateWindowMs, "detector.lateWindowMs", ms)
        bound(\.detector.cooldownMs, "detector.cooldownMs", ms)
        bound(\.detector.guardMs, "detector.guardMs", ms)
        bound(\.detector.atEdgePt, "detector.atEdgePt", 0.1...20)
        bound(\.detector.exitTailMs, "detector.exitTailMs", 0...10_000)
        bound(\.detector.targetInsetPt, "detector.targetInsetPt", 0...20)
        bound(\.detector.minCorrectionPt, "detector.minCorrectionPt", 0...100)
        bound(\.detector.episodeSlackMs, "detector.episodeSlackMs", 0...10_000)
        bound(\.detector.ucWaitMs, "detector.ucWaitMs", 0...150)
        bound(\.detector.overrideGuardMs, "detector.overrideGuardMs", 0...5000)
        bound(\.detector.overrideMismatchPt, "detector.overrideMismatchPt", 1...1000)
        bound(\.detector.overrideMaxRewarps, "detector.overrideMaxRewarps", 0...10)
        bound(\.detector.overrideBackFraction, "detector.overrideBackFraction", 0...1)
        bound(\.ucLogAssist.maxLagMs, "ucLogAssist.maxLagMs", 1...2000)
        bound(\.deadStrip.pushThresholdPt, "deadStrip.pushThresholdPt", 0.1...1000)
        bound(\.deadStrip.minPushMs, "deadStrip.minPushMs", ms)
        bound(\.deadStrip.maxGapMs, "deadStrip.maxGapMs", ms)
        bound(\.deadStrip.cooldownMs, "deadStrip.cooldownMs", 1...60_000)
        bound(\.deadStrip.virtualXValidMs, "deadStrip.virtualXValidMs", ms)
        bound(\.deadStrip.maxSpreadPt, "deadStrip.maxSpreadPt", 1...2000)
        bound(\.deadStrip.minDyDxRatio, "deadStrip.minDyDxRatio", 0...100)
        let lo = check.config.deadStrip.zoneMinXFallback, hi = check.config.deadStrip.zoneMaxXFallback
        if lo != nil || hi != nil {
            let coord: ClosedRange<Double> = -100_000...100_000
            let ok = check.config.deadStrip.fallbackZone.map { coord.contains($0.minX) && coord.contains($0.maxX) } ?? false
            if !ok {
                check.config.deadStrip.zoneMinXFallback = nil
                check.config.deadStrip.zoneMaxXFallback = nil
                check.warnings.append("deadStrip.zoneMinXFallback / zoneMaxXFallback = \(lo.map { "\($0)" } ?? "unset") / \(hi.map { "\($0)" } ?? "unset"): "
                                      + "need both, min < max, within ±100000; using no fallback zone")
            }
        }
        return check
    }
}
