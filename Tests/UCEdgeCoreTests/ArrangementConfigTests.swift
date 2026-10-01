import Foundation
import Testing
@testable import UCEdgeCore

@Suite struct ArrangementTests {
    static let d1 = "3C000000-0000-4000-8000-0000000000C1"
    static let d3 = "8A000000-0000-4000-8000-0000000000A1"
    static let d4 = "E5000000-0000-4000-8000-0000000000B1"
    static let d5 = "8D000000-0000-4000-8000-0000000000B2"
    static let vmindEdge = [LocalEdgeDisplay(uuid: d4, minX: 0, width: 1600),
                            LocalEdgeDisplay(uuid: d5, minX: -1600, width: 1600)]
    static let macbookEdge = [EdgeDisplayInfo(uuid: UUID(uuidString: d3)!, minX: -2560, width: 2560)]

    /// Builds a ByHost file shaped like UC's: {Configuration: bplist{vers, head, heap, refs}}.
    static func byHostFile(links: [[Any]]) throws -> Data {
        let head = Data(repeating: 0xAB, count: 32), old = Data(repeating: 0x01, count: 32)
        let headEntry: [Any] = [head, 812403391637, 1, old, links.count] + links
        let oldEntry: [Any] = [old, 812400000000, 1, Data(count: 32), 0]
        let inner: [String: Any] = ["vers": 3, "head": head, "heap": [oldEntry, headEntry], "refs": [String: Any]()]
        let conf = try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
        return try PropertyListSerialization.data(fromPropertyList: ["Configuration": conf, "DisableMagicEdges": false],
                                                  format: .binary, options: 0)
    }

    static var todaysLinks: [[Any]] { [
        [812403391637, 1, "dev-mbp", d1, "dev-vmind", d4, 24655, 32767],
        [812403391637, 2, "dev-mbp", d3, "dev-vmind", d4, 45055, 32767],
    ] }

    @Test func parsesHeadLinksAndComputesZone() throws {
        let a = try UCArrangement.parse(fileData: Self.byHostFile(links: Self.todaysLinks))
        #expect(a.links.count == 2)
        #expect(abs(a.links[1].fracA - 0.6875) < 1e-3)
        guard case let .zone(minX, maxX) = a.zone(local: Self.vmindEdge, peer: Self.macbookEdge) else {
            Issue.record("expected a zone"); return
        }
        #expect(abs(minX - (-960)) < 0.1)
        #expect(abs(maxX - 1600) < 0.1)
    }

    @Test func zoneFromTheMacBookSide() throws {
        let a = try UCArrangement.parse(fileData: Self.byHostFile(links: Self.todaysLinks))
        let local = [LocalEdgeDisplay(uuid: Self.d3, minX: -2560, width: 2560)]
        let peer = [EdgeDisplayInfo(uuid: UUID(uuidString: Self.d4)!, minX: 0, width: 1600),
                    EdgeDisplayInfo(uuid: UUID(uuidString: Self.d5)!, minX: -1600, width: 1600)]
        guard case let .zone(minX, maxX) = a.zone(local: local, peer: peer) else {
            Issue.record("expected a zone"); return
        }
        // 4's midpoint sits under 3's x = 1760 from 3's left: −2560 + 1760 − 800.
        #expect(abs(minX - (-1600)) < 0.1)
        #expect(abs(maxX - 0) < 0.1)
    }

    @Test func missingTopLinkIsReported() throws {
        let a = try UCArrangement.parse(fileData: Self.byHostFile(links: [Self.todaysLinks[0]]))
        #expect(a.zone(local: Self.vmindEdge, peer: Self.macbookEdge) == .linkMissing)
    }

    @Test func garbageThrows() {
        #expect(throws: UCArrangementError.self) { try UCArrangement.parse(fileData: Data("nope".utf8)) }
        #expect(throws: UCArrangementError.self) { try UCArrangement.parse(configuration: Data([0, 1, 2])) }
        #expect(throws: UCArrangementError.notFound) { try UCArrangement.load(path: "/nonexistent/uc.plist") }
    }

    /// Reads (never writes) the real UC plist when this machine has one. The layout check runs
    /// only where our own configs (gitignored config/local/) name the displays.
    @Test(.enabled(if: UCArrangement.defaultPlistPath() != nil))
    func realByHostFileHasTheTopLink() throws {
        let path = try #require(UCArrangement.defaultPlistPath())
        let a = try UCArrangement.load(path: path)
        let repo = ConfigTests.repo
        guard let lower = try? Config.load(path: repo.appendingPathComponent("config/local/vmind.json").path),
              let upper = try? Config.load(path: repo.appendingPathComponent("config/local/macbook.json").path),
              let d4 = lower.edgeDisplays.first, let d3 = upper.edgeDisplays.first else { return }
        let link = try #require(a.links.first { $0.joins(d3, d4) })
        let f3 = try #require(link.fracs(localDisplay: d3))
        #expect(abs(f3.local - 0.6875) < 1e-3)
        #expect(abs(f3.peer - 0.5) < 1e-3)
    }
}

@Suite struct ConfigTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func emptyConfigTakesDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(c == Config())
        #expect(c.port == 47591)
        #expect(c.detector == DetectorParams())
        #expect(!c.deadStrip.enabled)
    }

    /// The dead-strip fallback zone is layout-specific: no default, both ends or neither.
    @Test func deadStripFallbackZoneHasNoDefault() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"deadStrip": {"enabled": true}}"#.utf8))
        #expect(c.deadStrip.zoneMinXFallback == nil && c.deadStrip.zoneMaxXFallback == nil)
        #expect(c.deadStrip.fallbackZone == nil)
        let set = try JSONDecoder().decode(DeadStripParams.self, from: Data(#"{"zoneMinXFallback": -961, "zoneMaxXFallback": 1600}"#.utf8))
        #expect(set.fallbackZone?.minX == -961 && set.fallbackZone?.maxX == 1600)
        for bad in [#"{"zoneMinXFallback": -961}"#, #"{"zoneMaxXFallback": 1600}"#,
                    #"{"zoneMinXFallback": 1600, "zoneMaxXFallback": -961}"#,
                    #"{"zoneMinXFallback": -961, "zoneMaxXFallback": 200000}"#] {
            var c = Config()
            c.edgeDisplays = ["E5000000-0000-4000-8000-0000000000B1"]
            c.deadStrip = try JSONDecoder().decode(DeadStripParams.self, from: Data(bad.utf8))
            let check = c.validated()
            #expect(check.errors.isEmpty, "\(bad)")
            #expect(check.config.deadStrip.zoneMinXFallback == nil && check.config.deadStrip.zoneMaxXFallback == nil, "\(bad)")
            #expect(check.warnings.contains { $0.contains("using no fallback zone") }, "\(bad)")
        }
        var ok = Config()
        ok.edgeDisplays = ["E5000000-0000-4000-8000-0000000000B1"]
        ok.deadStrip = set
        #expect(ok.validated().config.deadStrip == set)
        #expect(!ok.validated().warnings.contains { $0.contains("Fallback") })
    }

    /// The published examples: they decode, carry the per-side settings that matter, and their
    /// placeholders are refused until real display UUIDs are filled in.
    @Test func lowerMacExample() throws {
        let c = try Config.load(path: Self.repo.appendingPathComponent("config/examples/lower-mac.json").path)
        #expect(c.side == .top)
        #expect(c.peerHosts == ["upper-mac.local"])
        #expect(c.deadStrip.enabled)
        #expect(c.corrections.enabled && c.ucLogAssist.enabled)
        #expect(c.detector.overrideGuard, "the lower Mac keeps the override guard (UC positions it absolutely)")
        #expect(c.validated().errors.contains { $0.contains("is not a UUID") })
    }

    @Test func upperMacExample() throws {
        let c = try Config.load(path: Self.repo.appendingPathComponent("config/examples/upper-mac.json").path)
        #expect(c.side == .bottom)
        #expect(c.peerHosts == ["lower-mac.local"])
        #expect(!c.deadStrip.enabled)
        #expect(c.corrections.enabled && c.ucLogAssist.enabled)
        #expect(!c.detector.overrideGuard, "audit v1.4: the guard can double-shift upper-Mac corrections")
        #expect(c.validated().errors.contains { $0.contains("is not a UUID") })
    }

    /// Our own configs live in the gitignored config/local/; check them when present.
    @Test func localConfigsWhenPresent() throws {
        for (file, side) in [("config/local/vmind.json", EdgeSide.top), ("config/local/macbook.json", .bottom)] {
            let path = Self.repo.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let c = try Config.load(path: path)
            #expect(c.side == side)
            #expect(c.validated().errors.isEmpty)
            #expect(c.detector.overrideGuard == (side == .top))
            if c.deadStrip.enabled {
                #expect(c.deadStrip.fallbackZone != nil, "\(file): our dead strip keeps an explicit fallback zone")
            }
        }
    }
}
