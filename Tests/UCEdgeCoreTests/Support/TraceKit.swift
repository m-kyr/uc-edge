import CoreGraphics
import Foundation
import UCEdgeCore

/// Recorded traces (`testdata/`) and the ground truth derived from them by `groundtruth.py`.
enum TraceKit {
    static let supportDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// Package root: the first ancestor of this file that has `testdata/`.
    static let root: URL = {
        var dir = supportDir
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("testdata").path) { return dir }
            dir.deleteLastPathComponent()
        }
        fatalError("testdata/ not found above \(supportDir.path)")
    }()

    static func loadTrace(_ name: String) throws -> Trace {
        try Trace.parse(String(contentsOf: root.appendingPathComponent("testdata/\(name)"), encoding: .utf8))
    }

    static func loadGroundTruth() throws -> GroundTruth {
        let data = try Data(contentsOf: supportDir.appendingPathComponent("s2-crossings.json"))
        return try JSONDecoder().decode(GroundTruth.self, from: data)
    }
}

/// One local observation: a 1 kHz poll line or a session event-tap line.
struct TraceSample: Sendable {
    var t: Double
    var p: CGPoint
    var buttonsDown: Bool
    var isTap: Bool
    var tapType: Int = 0      // CGEventType raw value (5 moved, 1/2 left down/up, 6 left dragged)
    var dx: Double = 0
    var dy: Double = 0
}

struct Trace: Sendable {
    /// Poll and TAP lines merged in time order.
    var samples: [TraceSample]
    /// `WARP` lines (s1 only): the recorder's own test warps.
    var warpTimes: [Double]

    var taps: [TraceSample] { samples.filter(\.isTap) }

    static func parse(_ text: String) -> Trace {
        var samples: [TraceSample] = []
        var warps: [Double] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 2, let t = Double(f[0]) else { continue }
            if f[1] == "WARP" {
                warps.append(t)
            } else if f[1] == "TAP", f.count == 6, f[2].hasPrefix("t"), let type = Int(f[2].dropFirst()) {
                let xy = f[3].dropFirst().dropLast().split(separator: ",")
                guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]),
                      let dx = Double(f[4].dropFirst(3)), let dy = Double(f[5].dropFirst(3)) else { continue }
                // Moved/up events mean no left button; down/dragged mean it is held.
                let down = type == 1 || type == 6
                samples.append(TraceSample(t: t, p: CGPoint(x: x, y: y), buttonsDown: down, isTap: true,
                                           tapType: type, dx: dx, dy: dy))
            } else if f.count == 5, f[3].hasPrefix("b"), let x = Double(f[1]), let y = Double(f[2]) {
                samples.append(TraceSample(t: t, p: CGPoint(x: x, y: y), buttonsDown: f[3] == "b1", isTap: false))
            }
        }
        // Lines are written as they happen, but a TAP line can precede an earlier poll line by ~1 ms.
        let order = samples.indices.sorted { (samples[$0].t, $0) < (samples[$1].t, $1) }
        return Trace(samples: order.map { samples[$0] }, warpTimes: warps)
    }
}

/// Decoded `s2-crossings.json`. All times are trace ms (MacBook trace for MacBook-side values,
/// V-Mind trace for V-Mind-side values); `vmindToMacbookMs` converts: t_macbook = t_vmind + k.
struct GroundTruth: Decodable, Sendable {
    struct Alignment: Decodable, Sendable {
        let vmindToMacbookMs: Double
        let estimatedErrorMs: Double
    }
    struct Crossing: Decodable, Sendable {
        let id: String
        let direction: String          // up | down | side-up | side-down
        let wall: String
        let landingT: Double           // destination trace time of UC's landing sample
        let landingX: Double
        let landingY: Double
        let ucOffset: Double?          // UC's logged "Target Ready ... offset"
        let activatingSourceT: Double? // UC's "Hot Zone: Activating" line, in source trace ms
        let exitX: Double?             // source x UC used (matches its logged offset)
        let exitT: Double?             // source trace time of the TAP event at exitX
        let exitXFrozen: Double?
        let expectedTargetX: Double?   // physicalMap(exitX) on the destination
        var landing: CGPoint { CGPoint(x: landingX, y: landingY) }
    }
    struct DeadStrip: Decodable, Sendable {
        let startT: Double
        let endT: Double
        let expectedRedirectX: Double
        let expectedFireT: Double?
    }
    struct S1Crossing: Decodable, Sendable {
        let wall: String
        let specExitX: Double
        let ucExitX: Double
        let landingT: Double
        let landingX: Double
        let landingY: Double
        let expectedTargetX: Double
    }
    struct Jump: Decodable, Sendable {
        let t: Double
        let x: Double
        let y: Double
    }
    struct S1: Decodable, Sendable {
        let crossings: [S1Crossing]
        let warpT: [Double]
        let otherJumps: [Jump]
    }

    let alignment: Alignment
    let crossings: [Crossing]
    let deadStrip: DeadStrip
    let s1: S1
}

/// The desk from SPEC §1, written out independently of the implementation.
enum Desk {
    static let macbookDisplay3 = CGRect(x: -2560, y: -1440, width: 2560, height: 1440)
    static let vmindMonitor5 = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
    static let vmindMonitor4 = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    static let macbook = EdgeGeometry(side: .bottom, displays: [macbookDisplay3])
    static let vmind = EdgeGeometry(side: .top, displays: [vmindMonitor5, vmindMonitor4])

    /// Every screen of each Mac (from the trace headers): where a simulated post-warp path can go.
    static let macbookScreens = [macbookDisplay3, CGRect(x: 0, y: -1440, width: 2560, height: 1440),
                                 CGRect(x: 0, y: 0, width: 2056, height: 1329)]
    static let vmindScreens = [vmindMonitor5, vmindMonitor4]

    static let vmindSpan = (min: -1600.0, max: 1600.0)
    static let macbookSpan = (min: -2560.0, max: 0.0)

    /// SPEC §1 physical mapping, clamped to the local span.
    static func map(_ x: Double, from: (min: Double, max: Double), to: (min: Double, max: Double)) -> Double {
        let v = to.min + (x - from.min) / (from.max - from.min) * (to.max - to.min)
        return Swift.min(Swift.max(v, to.min), to.max)
    }

    /// §5.1 target x clamp: [spanMin, spanMax - 0.5].
    static func clampTargetX(_ x: Double, span: (min: Double, max: Double)) -> Double {
        Swift.min(Swift.max(x, span.min), span.max - 0.5)
    }
}
