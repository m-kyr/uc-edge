import Foundation

/// What the menu bar app (UCEdgeMenu) shows. Pure: the app gathers the inputs (status.json,
/// whether the helper's LaunchAgent is loaded, the clock) and renders the result.

/// A lenient reading of the helper's status.json: every field is optional and a field of the
/// wrong type is treated as missing, so an older or newer helper never breaks the menu.
public struct StatusView: Decodable, Sendable, Equatable {
    public struct Permissions: Decodable, Sendable, Equatable {
        public var accessibility: Bool?, listenEvents: Bool?, tapActive: Bool?, pollingFallback: Bool?
        public init(accessibility: Bool? = nil, listenEvents: Bool? = nil, tapActive: Bool? = nil, pollingFallback: Bool? = nil) {
            self.accessibility = accessibility; self.listenEvents = listenEvents
            self.tapActive = tapActive; self.pollingFallback = pollingFallback
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            accessibility = c.lenient(.accessibility); listenEvents = c.lenient(.listenEvents)
            tapActive = c.lenient(.tapActive); pollingFallback = c.lenient(.pollingFallback)
        }
        enum Keys: String, CodingKey { case accessibility, listenEvents, tapActive, pollingFallback }
    }
    public struct Peer: Decodable, Sendable, Equatable {
        public var alive: Bool?, rttMs: Double?, sideConflict: Bool?, version: String?, axTrusted: Bool?
        public init(alive: Bool? = nil, rttMs: Double? = nil, sideConflict: Bool? = nil, version: String? = nil, axTrusted: Bool? = nil) {
            self.alive = alive; self.rttMs = rttMs; self.sideConflict = sideConflict
            self.version = version; self.axTrusted = axTrusted
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            alive = c.lenient(.alive); rttMs = c.lenient(.rttMs); sideConflict = c.lenient(.sideConflict)
            version = c.lenient(.version); axTrusted = c.lenient(.axTrusted)
        }
        enum Keys: String, CodingKey { case alive, rttMs, sideConflict, version, axTrusted }
    }
    public struct Geometry: Decodable, Sendable, Equatable {
        public var displaysMissing: [String]?
        public init(displaysMissing: [String]? = nil) { self.displaysMissing = displaysMissing }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            displaysMissing = c.lenient(.displaysMissing)
        }
        enum Keys: String, CodingKey { case displaysMissing }
    }
    public struct Arrangement: Decodable, Sendable, Equatable {
        public var ucLinkMissing: Bool?
        public init(ucLinkMissing: Bool? = nil) { self.ucLinkMissing = ucLinkMissing }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            ucLinkMissing = c.lenient(.ucLinkMissing)
        }
        enum Keys: String, CodingKey { case ucLinkMissing }
    }
    public struct UCLog: Decodable, Sendable, Equatable {
        public var state: String?
        public init(state: String? = nil) { self.state = state }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            state = c.lenient(.state)
        }
        enum Keys: String, CodingKey { case state }
    }
    public struct Counters: Decodable, Sendable, Equatable {
        public var immediate: Int?, late: Int?, deadStripRedirects: Int?
        public init(immediate: Int? = nil, late: Int? = nil, deadStripRedirects: Int? = nil) {
            self.immediate = immediate; self.late = late; self.deadStripRedirects = deadStripRedirects
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            immediate = c.lenient(.immediate); late = c.lenient(.late); deadStripRedirects = c.lenient(.deadStripRedirects)
        }
        enum Keys: String, CodingKey { case immediate, late, deadStripRedirects }
    }

    public var version: String?
    public var pid: Int?
    public var startedAt: Date?
    public var updatedAt: Date?
    public var keyMissing: Bool?
    public var keyInsecure: Bool?
    public var configErrors: [String]?
    public var warpFailing: Bool?
    public var netError: String?
    public var permissions: Permissions?
    public var peer: Peer?
    public var geometry: Geometry?
    public var arrangement: Arrangement?
    public var correctionsEnabled: Bool?
    public var ucLog: UCLog?
    public var counters: Counters?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = c.lenient(.version)
        pid = c.lenient(.pid)
        startedAt = c.lenient(.startedAt)
        updatedAt = c.lenient(.updatedAt)
        keyMissing = c.lenient(.keyMissing)
        keyInsecure = c.lenient(.keyInsecure)
        configErrors = c.lenient(.configErrors)
        warpFailing = c.lenient(.warpFailing)
        netError = c.lenient(.netError)
        permissions = c.lenient(.permissions)
        peer = c.lenient(.peer)
        geometry = c.lenient(.geometry)
        arrangement = c.lenient(.arrangement)
        correctionsEnabled = c.lenient(.correctionsEnabled)
        ucLog = c.lenient(.ucLog)
        counters = c.lenient(.counters)
    }

    enum Keys: String, CodingKey {
        case version, pid, startedAt, updatedAt, keyMissing, keyInsecure, configErrors, warpFailing, netError
        case permissions, peer, geometry, arrangement, correctionsEnabled, ucLog, counters
    }

    /// Decodes status.json the way the helper writes it (ISO 8601 dates, "nan"/"inf" strings).
    public static func decode(_ data: Data) throws -> StatusView {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try dec.decode(StatusView.self, from: data)
    }
}

extension KeyedDecodingContainer {
    /// Missing, null or of the wrong type: nil.
    fileprivate func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

public enum MenuState: String, Sendable, Equatable {
    case working, starting, waiting, paused, attention, notRunning, notInstalled
}

public struct MenuInputs: Sendable {
    /// nil: status.json missing or unreadable.
    public var status: StatusView?
    /// The helper's LaunchAgent (local.uc-edge) is loaded in this login session.
    public var helperLoaded: Bool
    /// Its plist exists in ~/Library/LaunchAgents.
    public var helperInstalled: Bool
    public var now: Date
    public var peerName: String
    /// The menu just started the helper (or itself started, at login): a stale status is
    /// "starting", not "not responding".
    public var resumedAt: Date?
    /// Whether the process that wrote status.json (its `pid`) still runs; nil = unknown. A
    /// status from an exited process is never fresh, however recent.
    public var statusProcessAlive: Bool?
    /// The helper's config is missing or unreadable (the helper then waits 60 s and exits 78
    /// without writing status).
    public var configProblem: String?
    public var staleAfterSec: Double
    public var timeZone: TimeZone
    public var locale: Locale

    public init(status: StatusView?, helperLoaded: Bool, helperInstalled: Bool = true, now: Date, peerName: String,
                resumedAt: Date? = nil, statusProcessAlive: Bool? = nil, configProblem: String? = nil,
                staleAfterSec: Double = 15, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.status = status; self.helperLoaded = helperLoaded; self.helperInstalled = helperInstalled
        self.now = now; self.peerName = peerName; self.resumedAt = resumedAt
        self.statusProcessAlive = statusProcessAlive; self.configProblem = configProblem
        self.staleAfterSec = staleAfterSec; self.timeZone = timeZone; self.locale = locale
    }
}

public struct MenuModel: Sendable, Equatable {
    public var state: MenuState
    public var headline: String
    /// Why it needs attention or isn't running.
    public var reason: String?
    /// Further read-only lines (peer, counts, notes).
    public var lines: [String]
    /// Pause is offered while the helper is loaded, Resume while it isn't (and is installed).
    public var canPause: Bool
    public var canResume: Bool

    /// SF Symbol for the menu bar, with fallbacks for older systems.
    public var symbolNames: [String] {
        switch state {
        case .working: return ["cursorarrow.motionlines", "cursorarrow"]
        case .starting, .waiting: return ["cursorarrow", "circle.dashed"]
        case .paused: return ["pause.circle", "pause"]
        case .attention: return ["exclamationmark.triangle", "exclamationmark.circle"]
        case .notRunning, .notInstalled: return ["cursorarrow.slash", "xmark.circle"]
        }
    }
    /// Drawn dimmed (template image, "disabled" look) to read as inactive.
    public var dimmed: Bool { [.starting, .waiting, .paused, .notRunning, .notInstalled].contains(state) }

    public static func make(_ inp: MenuInputs) -> MenuModel {
        let peer = inp.peerName
        guard inp.helperInstalled || inp.helperLoaded else {
            return MenuModel(state: .notInstalled, headline: "UCEdge: Not installed",
                             reason: "No LaunchAgent at ~/Library/LaunchAgents/local.uc-edge.plist",
                             lines: [], canPause: false, canResume: false)
        }
        guard inp.helperLoaded else {
            return MenuModel(state: .paused, headline: "UCEdge: Paused", reason: nil,
                             lines: ["No corrections on either Mac until you resume (or log in again)"],
                             canPause: false, canResume: true)
        }
        let s = inp.status
        let age = s?.updatedAt.map { inp.now.timeIntervalSince($0) }
        let exited = s != nil && inp.statusProcessAlive == false
        let recent = age.map { $0 <= inp.staleAfterSec } ?? false
        let fresh = recent && !exited
        guard let s, fresh else {
            // No usable config: the helper waits 60 s and exits without writing status.
            if let p = inp.configProblem {
                return MenuModel(state: .attention, headline: "UCEdge: Needs attention", reason: p, lines: [],
                                 canPause: true, canResume: false)
            }
            // A config error makes the helper write status once, then exit after 60 s.
            if let e = s?.configErrors, !e.isEmpty {
                return MenuModel(state: .attention, headline: "UCEdge: Needs attention",
                                 reason: "Config error: " + e.joined(separator: "; "), lines: [],
                                 canPause: true, canResume: false)
            }
            // Just (re)started by the menu, or a recent status whose process has exited while the
            // job is loaded: launchd is starting the helper again.
            let justResumed = inp.resumedAt.map { inp.now.timeIntervalSince($0) <= inp.staleAfterSec } ?? false
            if justResumed || (exited && recent) {
                return MenuModel(state: .starting, headline: "UCEdge: Starting…", reason: nil, lines: [],
                                 canPause: true, canResume: false)
            }
            let why: String
            if s == nil { why = "No status from the helper" }
            else if let age { why = "Status is \(Self.duration(age)) old" }
            else { why = "Status has no timestamp" }
            return MenuModel(state: .notRunning, headline: "UCEdge: Not responding", reason: why,
                             lines: ["Open Log for details; Pause → Resume restarts it"], canPause: true, canResume: false)
        }

        // Faults on this Mac.
        var problems: [String] = []
        if let p = inp.configProblem { problems.append(p) }
        if s.keyMissing == true { problems.append("Shared key missing (~/.config/uc-edge/key)") }
        if s.keyInsecure == true { problems.append("Key file readable by others (chmod 600 it)") }
        if let e = s.configErrors, !e.isEmpty { problems.append("Config error: " + e.joined(separator: "; ")) }
        if s.permissions?.accessibility == false { problems.append("Needs Accessibility permission") }
        if s.peer?.sideConflict == true { problems.append("Both Macs are configured for the same edge side") }
        if s.warpFailing == true { problems.append("Moving the cursor keeps failing") }
        if let e = s.netError { problems.append("Network: \(e)") }

        var lines: [String] = []
        let alive = s.peer?.alive == true
        if alive {
            let rtt = s.peer?.rttMs.flatMap { $0.isFinite && $0 >= 0 && $0 < 100_000 ? $0 : nil }
            lines.append("\(peer): connected" + (rtt.map { " · \(Int($0.rounded())) ms" } ?? ""))
        } else {
            lines.append("\(peer): not connected (asleep, away, or paused)")
        }
        if s.correctionsEnabled == false {
            lines.append("Corrections off on this Mac (it only sends)")
        } else {
            let c = s.counters
            let fixed = (c?.immediate ?? 0) + (c?.late ?? 0)
            var line = "Fixed \(fixed) landing\(fixed == 1 ? "" : "s") on this Mac"
            if let started = s.startedAt { line += " since " + Self.since(started, now: inp.now, timeZone: inp.timeZone, locale: inp.locale) }
            if let n = c?.deadStripRedirects, n > 0 { line += " · \(n) corner nudge\(n == 1 ? "" : "s")" }
            lines.append(line)
        }
        switch s.ucLog?.state {
        case "running": lines.append("Exact crossing points: on")
        case "disabled": lines.append("Exact crossing points: off (config)")
        case nil: break
        default: lines.append("Exact crossing points: unavailable — using estimate")
        }
        // Notes: degraded but working.
        if s.permissions?.pollingFallback == true { lines.append("Event tap unavailable: polling instead (Input Monitoring?)") }
        if let m = s.geometry?.displaysMissing, !m.isEmpty {
            lines.append("Edge display\(m.count == 1 ? "" : "s") not connected: \(m.count)")
        }
        if s.arrangement?.ucLinkMissing == true { lines.append("Universal Control link to \(peer) not found in its settings") }
        if alive, s.peer?.axTrusted == false { lines.append("\(peer) lacks Accessibility permission") }

        if !problems.isEmpty {
            return MenuModel(state: .attention, headline: "UCEdge: Needs attention", reason: problems.joined(separator: " · "),
                             lines: lines, canPause: true, canResume: false)
        }
        if !alive {
            return MenuModel(state: .waiting, headline: "UCEdge: Waiting for \(peer)", reason: nil,
                             lines: lines, canPause: true, canResume: false)
        }
        return MenuModel(state: .working, headline: "UCEdge: Working", reason: nil, lines: lines,
                         canPause: true, canResume: false)
    }

    /// "1:52 PM" today, "Sep 30, 1:52 PM" otherwise (in the user's locale).
    static func since(_ d: Date, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        if cal.isDate(d, inSameDayAs: now) {
            f.dateStyle = .none
            f.timeStyle = .short
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMd jj:mm")
        }
        return f.string(from: d)
    }

    static func duration(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "?" }
        if sec < 120 { return "\(Int(sec.rounded())) s" }
        if sec < 7200 { return "\(Int((sec / 60).rounded())) min" }
        if sec < 172_800 { return "\(Int((sec / 3600).rounded())) h" }
        return "\(Int(min(sec / 86_400, 1e6).rounded())) days"
    }

    /// Display name of the other Mac: config.json's optional top-level "peerName" (the helper
    /// ignores keys it doesn't know), else the first peer host without ".local".
    public static func peerName(configJSON: Data?, peerHosts: [String]) -> String {
        if let data = configJSON,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["peerName"] as? String,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        if let host = peerHosts.first, !host.isEmpty {
            return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        }
        return "Other Mac"
    }

    /// Why the helper can't load its config at `path` (what `Config.load` threw).
    public static func configProblem(path: String, error: Error) -> String {
        if let e = error as? CocoaError, e.code == .fileReadNoSuchFile || e.code == .fileNoSuchFile {
            return "No config at \(path)"
        }
        if error is DecodingError { return "Config at \(path) is not valid JSON for UCEdge" }
        return "Config at \(path) can't be read: \(error.localizedDescription)"
    }

    /// Plain-text rendering (`UCEdgeMenu --print`).
    public var text: String {
        var out = [headline]
        if let reason { out.append("  " + reason) }
        out += lines.map { "  " + $0 }
        out.append("  [actions: \(canPause ? "Pause" : canResume ? "Resume" : "-"), Open Log, Quit]")
        return out.joined(separator: "\n")
    }
}
