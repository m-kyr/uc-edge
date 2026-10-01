import ApplicationServices
import CoreGraphics
import Foundation
import UCEdgeCore

/// `UCEdge selftest`: read-only checks. Never warps, never posts events, never creates a tap,
/// never prompts for permissions, never prints key material.
enum SelfTest {
    static func run(configPath: String) -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failures += 1 }
        }
        func info(_ label: String, _ detail: String) { print("INFO  \(label): \(detail)") }

        print("UCEdge \(UCEdgeVersion.string) selftest")
        let bundle = Bundle.main.bundleIdentifier ?? "(no bundle: bare binary)"
        info("identity", bundle)
        check(AXIsProcessTrusted(), "accessibility (warp)")
        check(CGPreflightListenEventAccess(), "input monitoring (event tap)")

        guard let loaded = CLI.loadConfig(configPath) else {
            check(false, "config", expandTilde(configPath))
            return 1
        }
        let validated = loaded.validated()
        let config = validated.config
        check(validated.errors.isEmpty, "config", "\(expandTilde(configPath)) name=\(config.name) side=\(config.side.rawValue)"
              + (validated.errors.isEmpty ? "" : " ERRORS: " + validated.errors.joined(separator: "; ")))
        validated.warnings.forEach { info("config warning", $0) }

        let wanted = config.edgeDisplayUUIDs
        let found = Displays.resolve(wanted)
        check(!wanted.isEmpty && found.count == wanted.count, "edge displays",
              "\(found.count)/\(wanted.count) found " + found.map { "\($0.uuid.uuidString.prefix(8))=\(rect($0.bounds))" }.joined(separator: " "))
        if found.count == wanted.count, !found.isEmpty {
            let g = EdgeGeometry(side: config.side, displays: found.map(\.bounds))
            info("geometry", String(format: "edgeY %.1f span [%.1f, %.1f]", g.edgeY, g.spanMin, g.spanMax))
        }
        info("all displays", Displays.activeDisplays().map { "\($0.uuid.uuidString.prefix(8))=\(rect($0.bounds))" }.joined(separator: " "))

        let keyPath = expandTilde(config.keyPath)
        let perms = (try? FileManager.default.attributesOfItem(atPath: keyPath)[.posixPermissions] as? Int) ?? nil
        let keyOK = WireKey.load(path: keyPath) != nil
        check(keyOK, "key", keyOK ? "\(keyPath) valid (32 bytes)" : "\(keyPath) missing or not exactly 64 hex chars")
        if let perms { check(WireKey.fileIsPrivate(path: keyPath), "key mode", String(format: "%o", perms)) }

        info("host UUID", UCArrangement.hostUUID() ?? "unknown")
        let plist = config.ucPlistPath.map(expandTilde) ?? UCArrangement.defaultPlistPath()
        if let plist {
            do {
                let a = try UCArrangement.load(path: plist)
                check(true, "UC arrangement", "\(a.links.count) link(s) in head entry")
                let local = Set(wanted.map(\.uuidString))
                for l in a.links {
                    let touches = local.contains(l.displayA.uppercased()) || local.contains(l.displayB.uppercased())
                    info("  link", String(format: "edge=%d %@ frac %.4f <-> %@ frac %.4f%@", l.edgeCode,
                                          String(l.displayA.prefix(8)), l.fracA, String(l.displayB.prefix(8)), l.fracB,
                                          touches ? "  (local edge)" : ""))
                }
            } catch {
                check(false, "UC arrangement", "\(plist): \(error) (\(config.deadStrip.fallbackZone.map { "fallback zone [\($0.minX), \($0.maxX)] would be used" } ?? "no fallback zone configured: the dead strip stays off"))")
            }
        } else {
            check(false, "UC arrangement", "no com.apple.universalcontrol.*.plist in ~/Library/Preferences/ByHost")
        }

        let port = UInt16(exactly: config.peerPort ?? config.port) ?? 0
        check(port != 0, "peer port", "\(config.peerPort ?? config.port)")
        for host in config.peerHosts {
            let (addrs, err) = PeerAddressBook.lookup(host: host, port: port)
            check(!addrs.isEmpty, "peer DNS \(host)", addrs.isEmpty ? (err ?? "no addresses") : addrs.map(\.description).joined(separator: " "))
        }

        print(failures == 0 ? "selftest: all checks passed" : "selftest: \(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }

    private static func rect(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
