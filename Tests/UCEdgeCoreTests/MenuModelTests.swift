import Foundation
import Testing
@testable import UCEdge
@testable import UCEdgeCore

@Suite struct MenuModelTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let gmt = TimeZone(identifier: "GMT")!

    /// A healthy status as the helper would report it.
    static func healthy() -> StatusView {
        var s = StatusView()
        s.version = "1.4.0"
        s.startedAt = now.addingTimeInterval(-3600)
        s.updatedAt = now.addingTimeInterval(-2)
        s.keyMissing = false
        s.keyInsecure = false
        s.configErrors = []
        s.warpFailing = false
        s.permissions = .init(accessibility: true, listenEvents: true, tapActive: true, pollingFallback: false)
        s.peer = .init(alive: true, rttMs: 4.6, sideConflict: false, version: "1.4.0", axTrusted: true)
        s.geometry = .init(displaysMissing: [])
        s.arrangement = .init(ucLinkMissing: false)
        s.correctionsEnabled = true
        s.ucLog = .init(state: "running")
        s.counters = .init(immediate: 27, late: 6, deadStripRedirects: 5)
        return s
    }

    static func model(_ s: StatusView?, loaded: Bool = true, installed: Bool = true, resumedAt: Date? = nil,
                      processAlive: Bool? = nil, configProblem: String? = nil) -> MenuModel {
        MenuModel.make(MenuInputs(status: s, helperLoaded: loaded, helperInstalled: installed, now: now,
                                  peerName: "MacBook", resumedAt: resumedAt, statusProcessAlive: processAlive,
                                  configProblem: configProblem, timeZone: gmt))
    }

    @Test func normal() {
        let m = Self.model(Self.healthy())
        #expect(m.state == .working)
        #expect(m.headline == "UCEdge: Working")
        #expect(m.reason == nil)
        #expect(m.lines.contains("MacBook: connected · 5 ms"))
        #expect(m.lines.contains { $0.hasPrefix("Fixed 33 landings on this Mac since ") && $0.hasSuffix(" · 5 corner nudges") })
        #expect(m.lines.contains("Exact crossing points: on"))
        #expect(m.canPause && !m.canResume)
        #expect(!m.dimmed)
    }

    @Test func sinceShowsTimeTodayAndDateOtherwise() {
        let us = Locale(identifier: "en_US")
        let started = Date(timeIntervalSince1970: 1_790_000_000 - 3600)  // same day in GMT
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(plain(MenuModel.since(started, now: Self.now, timeZone: Self.gmt, locale: us)) == "1:13 PM")
        let older = Self.now.addingTimeInterval(-3 * 86_400)
        let o = plain(MenuModel.since(older, now: Self.now, timeZone: Self.gmt, locale: us))
        #expect(o.hasPrefix("Sep 18") && o.hasSuffix("2:13 PM"), "\(o)")
    }

    @Test func staleFileWhileLoadedIsNotResponding() {
        var s = Self.healthy()
        s.updatedAt = Self.now.addingTimeInterval(-40)
        let m = Self.model(s)
        #expect(m.state == .notRunning)
        #expect(m.headline == "UCEdge: Not responding")
        #expect(m.reason == "Status is 40 s old")
        #expect(m.canPause)
    }

    @Test func staleRightAfterResumeIsStarting() {
        var s = Self.healthy()
        s.updatedAt = Self.now.addingTimeInterval(-600)
        #expect(Self.model(s, resumedAt: Self.now.addingTimeInterval(-3)).state == .starting)
        #expect(Self.model(s, resumedAt: Self.now.addingTimeInterval(-30)).state == .notRunning)
    }

    @Test func missingFile() {
        let m = Self.model(nil)
        #expect(m.state == .notRunning)
        #expect(m.reason == "No status from the helper")
        #expect(Self.model(nil, resumedAt: Self.now).state == .starting)
    }

    /// After a restart or crash the file is still recent, but its writer is gone: never "Working"
    /// on its stale data. While the job is loaded that is "Starting" until the file goes stale.
    @Test func recentStatusFromAnExitedProcessIsStartingNotWorking() {
        let m = Self.model(Self.healthy(), processAlive: false)
        #expect(m.state == .starting)
        #expect(m.canPause)
        var old = Self.healthy()
        old.updatedAt = Self.now.addingTimeInterval(-40)
        let stale = Self.model(old, processAlive: false)
        #expect(stale.state == .notRunning && stale.reason == "Status is 40 s old")
        #expect(Self.model(Self.healthy(), processAlive: true).state == .working)
        #expect(Self.model(Self.healthy(), loaded: false, processAlive: false).state == .paused)
    }

    /// With no usable config the helper writes no status: say why instead of "not responding".
    @Test func missingConfigNeedsAttention() {
        let why = "No config at ~/.config/uc-edge/config.json"
        for s in [nil, { var s = Self.healthy(); s.updatedAt = Self.now.addingTimeInterval(-3600); return s }()] as [StatusView?] {
            let m = Self.model(s, configProblem: why)
            #expect(m.state == .attention)
            #expect(m.reason == why)
            #expect(m.canPause)
        }
        // A running helper whose config has since gone: it won't start again.
        let running = Self.model(Self.healthy(), configProblem: why)
        #expect(running.state == .attention && running.reason == why)
        #expect(Self.model(nil, loaded: false, configProblem: why).state == .paused)
    }

    @Test func configProblemWording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ucedge-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("absent.json").path
        #expect(throws: (any Error).self) { try Config.load(path: missing) }
        do { _ = try Config.load(path: missing) } catch {
            #expect(MenuModel.configProblem(path: "~/x.json", error: error) == "No config at ~/x.json")
        }
        let bad = dir.appendingPathComponent("bad.json")
        try Data(#"{"port": "nope"}"#.utf8).write(to: bad)
        do { _ = try Config.load(path: bad.path); Issue.record("should not load") } catch {
            #expect(MenuModel.configProblem(path: "~/x.json", error: error) == "Config at ~/x.json is not valid JSON for UCEdge")
        }
    }

    @Test func pausedWinsOverAnyStatus() {
        for s in [Self.healthy(), nil] as [StatusView?] {
            let m = Self.model(s, loaded: false)
            #expect(m.state == .paused)
            #expect(m.canResume && !m.canPause)
            #expect(m.dimmed)
        }
    }

    @Test func notInstalled() {
        let m = Self.model(nil, loaded: false, installed: false)
        #expect(m.state == .notInstalled)
        #expect(!m.canResume && !m.canPause)
    }

    @Test func peerDownIsWaitingNotAProblem() {
        var s = Self.healthy()
        s.peer?.alive = false
        let m = Self.model(s)
        #expect(m.state == .waiting)
        #expect(m.headline == "UCEdge: Waiting for MacBook")
        #expect(m.lines.contains("MacBook: not connected (asleep, away, or paused)"))
        #expect(m.dimmed)
    }

    @Test func missingAccessibility() {
        var s = Self.healthy()
        s.permissions?.accessibility = false
        let m = Self.model(s)
        #expect(m.state == .attention)
        #expect(m.reason == "Needs Accessibility permission")
    }

    @Test func keyMissing() {
        var s = Self.healthy()
        s.keyMissing = true
        s.peer = .init(alive: false)
        let m = Self.model(s)
        #expect(m.state == .attention)  // a fault outranks "waiting"
        #expect(m.reason?.contains("Shared key missing") == true)
    }

    @Test func sideConflict() {
        var s = Self.healthy()
        s.peer?.sideConflict = true
        #expect(Self.model(s).state == .attention)
        #expect(Self.model(s).reason == "Both Macs are configured for the same edge side")
    }

    @Test func configErrorEvenWhenStale() {
        var s = StatusView()
        s.updatedAt = Self.now.addingTimeInterval(-50)
        s.configErrors = ["edgeDisplays is empty"]
        let m = Self.model(s)
        #expect(m.state == .attention)
        #expect(m.reason == "Config error: edgeDisplays is empty")
    }

    @Test func ucLogNotRunningIsANoteNotAProblem() {
        var s = Self.healthy()
        s.ucLog?.state = "restarting"
        let m = Self.model(s)
        #expect(m.state == .working)
        #expect(m.lines.contains("Exact crossing points: unavailable — using estimate"))
        s.ucLog?.state = "disabled"
        #expect(Self.model(s).lines.contains("Exact crossing points: off (config)"))
    }

    @Test func correctionsOffSaysSoInsteadOfCounting() {
        var s = Self.healthy()
        s.correctionsEnabled = false
        let m = Self.model(s)
        #expect(m.lines.contains("Corrections off on this Mac (it only sends)"))
        #expect(!m.lines.contains { $0.hasPrefix("Fixed") })
    }

    @Test func singularAndNoNudges() {
        var s = Self.healthy()
        s.counters = .init(immediate: 1, late: 0, deadStripRedirects: 0)
        let line = Self.model(s).lines.first { $0.hasPrefix("Fixed") }
        #expect(line?.hasPrefix("Fixed 1 landing on this Mac since ") == true)
        #expect(line?.contains("nudge") == false)
    }

    @Test func notesForDegradedStates() {
        var s = Self.healthy()
        s.permissions?.pollingFallback = true
        s.geometry?.displaysMissing = ["X"]
        s.arrangement?.ucLinkMissing = true
        s.peer?.axTrusted = false
        let m = Self.model(s)
        #expect(m.state == .working)
        #expect(m.lines.contains { $0.contains("polling") })
        #expect(m.lines.contains("Edge display not connected: 1"))
        #expect(m.lines.contains { $0.contains("Universal Control link") })
        #expect(m.lines.contains("MacBook lacks Accessibility permission"))
    }

    @Test func peerNameFromConfigOrHost() {
        let withName = Data(#"{"peerName": "MacBook", "peerHosts": ["m.local"]}"#.utf8)
        #expect(MenuModel.peerName(configJSON: withName, peerHosts: ["m.local"]) == "MacBook")
        #expect(MenuModel.peerName(configJSON: Data("{}".utf8), peerHosts: ["top-mac.local"]) == "top-mac")
        #expect(MenuModel.peerName(configJSON: Data(#"{"peerName": " "}"#.utf8), peerHosts: ["192.0.2.2"]) == "192.0.2.2")
        #expect(MenuModel.peerName(configJSON: nil, peerHosts: []) == "Other Mac")
    }

    @Test func helperConfigIgnoresPeerName() throws {
        let json = Data(#"{"peerName": "MacBook", "name": "x", "edgeDisplays": []}"#.utf8)
        let c = try JSONDecoder().decode(Config.self, from: json)
        #expect(c.name == "x")
    }

    /// The menu must read exactly what the helper writes (including NaN and odd values).
    @Test func readsTheHelpersOwnStatusFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ucedge-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = StatusSnapshot()
        s.peer.alive = true
        s.peer.rttMs = .nan
        s.counters.immediate = 3
        s.counters.late = 2
        s.counters.deadStripRedirects = 1
        s.ucLog.state = "running"
        s.permissions.accessibility = true
        let path = dir.appendingPathComponent("status.json").path
        StatusFile.write(s, to: path)
        let v = try StatusView.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(v.peer?.alive == true)
        #expect(v.peer?.rttMs?.isNaN == true)
        #expect(v.counters == .init(immediate: 3, late: 2, deadStripRedirects: 1))
        #expect(v.updatedAt != nil && v.startedAt != nil)
        #expect(v.pid == Int(ProcessInfo.processInfo.processIdentifier))
        let m = MenuModel.make(MenuInputs(status: v, helperLoaded: true, now: Date(), peerName: "MacBook"))
        #expect(m.state == .working)
        #expect(m.lines.first == "MacBook: connected")  // NaN rtt is not shown as a number
    }

    @Test func wrongTypesAreIgnoredNotFatal() throws {
        let json = Data(#"{"updatedAt": 12, "peer": {"alive": "yes", "rttMs": 3}, "counters": [], "keyMissing": false}"#.utf8)
        let v = try StatusView.decode(json)
        #expect(v.updatedAt == nil)
        #expect(v.peer?.alive == nil)
        #expect(v.peer?.rttMs == 3)
        #expect(v.counters == nil)
    }
}
