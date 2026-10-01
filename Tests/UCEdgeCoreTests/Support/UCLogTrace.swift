import CoreGraphics
import Foundation
import UCEdgeCore

/// An s3 recording (`testdata/s3-*-uclog.txt`): tap events with their CGEvent timestamps, and
/// UniversalControl's own log lines with mach_continuous_time stamps. Parsed independently of the
/// implementation's UC-log code, so the replay can check it.
struct UCLogTrace: Sendable {
    struct Tap: Sendable {
        var rxNs: Double          // uptime ns when the tap callback ran
        var eventNs: Double       // CGEvent.timestamp, uptime ns
        var type: Int
        var p: CGPoint
        var dx: Double
        var dy: Double
    }
    struct Line: Sendable {
        var rxNs: Double          // uptime ns when the recorder read the line
        var machTicks: UInt64     // mach_continuous_time ticks
        var wall: String
        var message: String
        /// Continuous-domain ns (timebase 125/3 on Apple silicon).
        var continuousNs: Double { Double(machTicks) * 125 / 3 }
    }

    var taps: [Tap]
    var positions: [(ns: Double, p: CGPoint)]
    var lines: [Line]

    static func load(_ name: String) throws -> UCLogTrace {
        let text = try String(contentsOf: TraceKit.root.appendingPathComponent("testdata/\(name)"), encoding: .utf8)
        var taps: [Tap] = [], positions: [(ns: Double, p: CGPoint)] = [], lines: [Line] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("TAP ") {
                let f = line.split(separator: " ")
                guard f.count >= 7, let rx = value(f[1], "rx="), let ev = value(f[2], "evts="), let type = Int(f[3].dropFirst()),
                      let p = point(f[4]), let dx = value(f[5], "dx="), let dy = value(f[6], "dy=") else { continue }
                taps.append(Tap(rxNs: rx, eventNs: ev, type: type, p: p, dx: dx, dy: dy))
            } else if line.hasPrefix("POS ") {
                let f = line.split(separator: " ")
                guard f.count >= 3, let ns = value(f[1], "ns="), let p = point(f[2]) else { continue }
                positions.append((ns, p))
            } else if line.hasPrefix("UCLOG "), let msgRange = line.range(of: " msg=") {
                let f = line[..<msgRange.lowerBound].split(separator: " ")
                guard f.count >= 5, let rx = value(f[1], "rx="), f[2].hasPrefix("mach="), let mach = UInt64(f[2].dropFirst(5)) else { continue }
                lines.append(Line(rxNs: rx, machTicks: mach, wall: String(f[4]), message: String(line[msgRange.upperBound...])))
            }
        }
        return UCLogTrace(taps: taps, positions: positions, lines: lines)
    }

    private static func value(_ field: Substring, _ key: String) -> Double? {
        field.hasPrefix(key) ? Double(field.dropFirst(key.count)) : nil
    }

    private static func point(_ field: Substring) -> CGPoint? {
        let xy = field.dropFirst().dropLast().split(separator: ",")
        guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// "Hot Zone: Activating: <edge>:<device>:<display UUID>" lines.
    var activations: [(line: Line, edge: String, display: String)] {
        lines.compactMap { l in
            guard l.message.hasPrefix("Hot Zone: Activating: ") else { return nil }
            let f = l.message.dropFirst("Hot Zone: Activating: ".count).split(separator: ":")
            return f.count >= 3 ? (l, String(f[0]), String(f[2])) : nil
        }
    }

    /// The x UC used, from the first "Target Ready: edge=<edge>, offset=" after `line`.
    func ucExitX(after line: Line, edge: String, display: String) -> Double? {
        guard let ready = lines.first(where: { $0.machTicks > line.machTicks && $0.message.contains("Target Ready: edge=\(edge),") }),
              let r = ready.message.range(of: "offset="),
              let offset = Double(ready.message[r.upperBound...].prefix { $0 != "," }) else { return nil }
        switch edge {
        case "top": return 961 * offset - 961                     // SPEC §2
        case "bottom" where display == UCLogTrace.vmindMonitor5: return 961 * offset - 2560
        default: return offset                                  // bottom:<4> logs raw x
        }
    }

    /// The MacBook recording did not store its continuous - uptime offset (~12 711 s): UC's
    /// "Warp Location" lines against the poller's landing jumps (the poller trails the warp by < 1 ms),
    /// raised to the bound set by the log's receive times (a line can't be read before it's written).
    func derivedContinuousOffsetNs() -> Double? {
        let warps = lines.filter { $0.message.hasPrefix("Warp Location") }
        let fromLandings: [Double] = warps.compactMap { w in
            guard let i = positions.indices.first(where: { i in
                i > 0 && abs(positions[i].ns - w.rxNs) <= 10e6
                    && abs(positions[i].p.x - positions[i - 1].p.x) + abs(positions[i].p.y - positions[i - 1].p.y) > 20
            }) else { return nil }
            return w.continuousNs - positions[i].ns
        }
        guard !fromLandings.isEmpty else { return nil }
        let median = fromLandings.sorted()[fromLandings.count / 2]
        let lagBound = lines.map { $0.continuousNs - $0.rxNs }.max()! + 0.24e6
        return max(median, lagBound)
    }

    static let vmindMonitor5 = "8D000000-0000-4000-8000-0000000000B2"
    static let vmindMonitor4 = "E5000000-0000-4000-8000-0000000000B1"
    static let macbookDisplay3 = "8A000000-0000-4000-8000-0000000000A1"
}

/// Independent model of the SPEC §13 match: crossX is the x of the latest local tap event at the
/// edge (-1 <= s <= 1.5) with timestamp <= the Activating line's time, at most `window` before it.
/// Units are the caller's (ns for s3, ms for s2).
enum UCAssistModel {
    static func crossX(events: [(t: Double, p: CGPoint)], at t: Double, side: EdgeSide, edgeY: Double, window: Double) -> Double? {
        events.last { e in
            let s = side == .top ? Double(e.p.y) - edgeY : edgeY - Double(e.p.y)
            return e.t <= t && t - e.t <= window && s >= -1 && s <= 1.5
        }.map { Double($0.p.x) }
    }
}
