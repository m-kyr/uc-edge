import Foundation

/// One link of UC's arrangement: frac is measured along each display's shared edge from its minX.
public struct UCLink: Sendable, Equatable {
    public var timestamp: Double
    public var edgeCode: Int
    public var deviceA: String, displayA: String
    public var deviceB: String, displayB: String
    public var fracA: Double, fracB: Double

    public func joins(_ a: String, _ b: String) -> Bool {
        (Self.same(displayA, a) && Self.same(displayB, b)) || (Self.same(displayA, b) && Self.same(displayB, a))
    }

    /// (frac on `display`, frac on the other display) when `display` is one of the two ends.
    public func fracs(localDisplay display: String) -> (local: Double, peer: Double)? {
        if Self.same(displayA, display) { return (fracA, fracB) }
        if Self.same(displayB, display) { return (fracB, fracA) }
        return nil
    }

    static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
}

public enum UCArrangementError: Error, Sendable, Equatable {
    case notFound, unreadable, noConfiguration, badInnerPlist, noHead, badLink
}

/// Best-effort, read-only parser of UC's ByHost plist (SPEC §7).
public struct UCArrangement: Sendable, Equatable {
    public var links: [UCLink]

    public init(links: [UCLink]) { self.links = links }

    /// Parses the outer ByHost plist bytes (the file content).
    public static func parse(fileData: Data) throws(UCArrangementError) -> UCArrangement {
        guard let outer = try? PropertyListSerialization.propertyList(from: fileData, format: nil) as? [String: Any]
        else { throw .unreadable }
        guard let conf = outer["Configuration"] as? Data else { throw .noConfiguration }
        return try parse(configuration: conf)
    }

    /// Parses the `Configuration` bytes: a bplist dict {vers, head, heap, refs}.
    public static func parse(configuration: Data) throws(UCArrangementError) -> UCArrangement {
        guard let dict = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
              let heap = dict["heap"] as? [Any] else { throw .badInnerPlist }
        guard let head = dict["head"] as? Data else { throw .noHead }
        guard let entry = heap.lazy.compactMap({ $0 as? [Any] }).first(where: { ($0.first as? Data) == head })
        else { throw .noHead }
        var links: [UCLink] = []
        for raw in entry.dropFirst(5) {
            guard let l = raw as? [Any], l.count >= 8,
                  let dispA = l[3] as? String, let dispB = l[5] as? String,
                  let fa = number(l[6]), let fb = number(l[7]) else { throw .badLink }
            links.append(UCLink(timestamp: number(l[0]) ?? 0, edgeCode: Int(number(l[1]) ?? -1),
                                deviceA: l[2] as? String ?? "", displayA: dispA,
                                deviceB: l[4] as? String ?? "", displayB: dispB,
                                fracA: fa / 65535, fracB: fb / 65535))
        }
        return UCArrangement(links: links)
    }

    /// This host's `com.apple.universalcontrol.<host UUID>.plist` in `~/Library/Preferences/ByHost`,
    /// or the only such file when there is exactly one (v1.2).
    public static func defaultPlistPath(home: String = NSHomeDirectory(), hostUUID: String? = hostUUID()) -> String? {
        let dir = home + "/Library/Preferences/ByHost"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let matches = names.filter { $0.hasPrefix("com.apple.universalcontrol.") && $0.hasSuffix(".plist") }
        if let h = hostUUID, let mine = matches.first(where: { UCLink.same($0, "com.apple.universalcontrol.\(h).plist") }) {
            return dir + "/" + mine
        }
        return matches.count == 1 ? dir + "/" + matches[0] : nil
    }

    /// The host UUID that names ByHost preference files.
    public static func hostUUID() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        guard gethostuuid(&bytes, &wait) == 0 else { return nil }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    public static func load(path: String) throws(UCArrangementError) -> UCArrangement {
        guard FileManager.default.fileExists(atPath: path) else { throw .notFound }
        guard let data = FileManager.default.contents(atPath: path) else { throw .unreadable }
        return try parse(fileData: data)
    }

    private static func number(_ v: Any) -> Double? {
        (v as? NSNumber)?.doubleValue
    }
}

/// A local edge display as the zone computation needs it.
public struct LocalEdgeDisplay: Sendable, Equatable {
    public var uuid: String, minX: Double, width: Double
    public init(uuid: String, minX: Double, width: Double) { self.uuid = uuid; self.minX = minX; self.width = width }
}

public enum UCZone: Sendable, Equatable {
    /// The x range of the local edge that UC covers.
    case zone(minX: Double, maxX: Double)
    /// The arrangement parsed, but no link joins a local edge display to a peer edge display.
    case linkMissing
}

extension UCArrangement {
    /// SPEC §7: link point = local.minX + fracLocal·local.width; zoneMinX = linkPoint − fracPeer·peer.width.
    public func zone(local: [LocalEdgeDisplay], peer: [EdgeDisplayInfo]) -> UCZone {
        for link in links.sorted(by: { $0.timestamp > $1.timestamp }) {
            for l in local {
                guard let f = link.fracs(localDisplay: l.uuid) else { continue }
                let otherUUID = UCLink.same(link.displayA, l.uuid) ? link.displayB : link.displayA
                guard let p = peer.first(where: { UCLink.same($0.uuid.uuidString, otherUUID) }) else { continue }
                let linkPoint = l.minX + f.local * l.width
                let zoneMin = linkPoint - f.peer * p.width
                return .zone(minX: zoneMin, maxX: zoneMin + p.width)
            }
        }
        return .linkMissing
    }
}
