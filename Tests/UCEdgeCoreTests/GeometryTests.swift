import CoreGraphics
import Testing
@testable import UCEdgeCore

/// The two real configurations (SPEC §1).
enum UTDesk {
    static let monitor4 = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    static let monitor5 = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
    static let display3 = CGRect(x: -2560, y: -1440, width: 2560, height: 1440)
    static let vmind = EdgeGeometry(side: .top, displays: [monitor4, monitor5])
    static let macbook = EdgeGeometry(side: .bottom, displays: [display3])
}

@Suite struct GeometryTests {
    @Test func spansAndEdgeY() {
        #expect(UTDesk.vmind.spanMin == -1600)
        #expect(UTDesk.vmind.spanMax == 1600)
        #expect(UTDesk.vmind.edgeY == 0)
        #expect(UTDesk.macbook.spanMin == -2560)
        #expect(UTDesk.macbook.spanMax == 0)
        #expect(UTDesk.macbook.edgeY == 0)
    }

    @Test func distToEdgeIsInwardAndClamped() {
        #expect(UTDesk.vmind.distToEdge(CGPoint(x: 100, y: 12)) == 12)
        #expect(UTDesk.macbook.distToEdge(CGPoint(x: -100, y: -12)) == 12)
        #expect(UTDesk.macbook.distToEdge(CGPoint(x: -100, y: -0.02)) == 0.02)
        // (0, 0) is on the MacBook's edge line: distance 0.
        #expect(UTDesk.macbook.distToEdge(CGPoint(x: 0, y: 0)) == 0)
        // Beyond the edge clamps at 0.
        #expect(UTDesk.macbook.distToEdge(CGPoint(x: -100, y: 5)) == 0)
    }

    @Test(arguments: [
        (-1600.0, -2560.0), (0.0, -1280.0), (1600.0, 0.0), (-800.0, -1920.0),
    ])
    func physicalMapVMindToMacBook(vm: Double, mb: Double) {
        let x = physicalMap(peerX: vm, peerSpanMin: -1600, peerSpanMax: 1600, localSpanMin: -2560, localSpanMax: 0)
        #expect(abs(x - mb) < 1e-9)
        let back = physicalMap(peerX: mb, peerSpanMin: -2560, peerSpanMax: 0, localSpanMin: -1600, localSpanMax: 1600)
        #expect(abs(back - vm) < 1e-9)
    }

    @Test func physicalMapClampsAndHandlesDegenerateSpans() {
        #expect(physicalMap(peerX: 5000, peerSpanMin: -1600, peerSpanMax: 1600, localSpanMin: -2560, localSpanMax: 0) == 0)
        #expect(physicalMap(peerX: -5000, peerSpanMin: -1600, peerSpanMax: 1600, localSpanMin: -2560, localSpanMax: 0) == -2560)
        let mid = physicalMap(peerX: 3, peerSpanMin: 7, peerSpanMax: 7, localSpanMin: -2560, localSpanMax: 0)
        #expect(mid == -1280)
    }

    @Test func landingStripIsClosed() {
        let mb = UTDesk.macbook
        #expect(mb.inLandingStrip(CGPoint(x: 0, y: 0), stripPt: 30))
        #expect(mb.inLandingStrip(CGPoint(x: -1599, y: -0.02), stripPt: 30))
        #expect(mb.inLandingStrip(CGPoint(x: -2561, y: -30), stripPt: 30))
        #expect(mb.inLandingStrip(CGPoint(x: 1, y: -1), stripPt: 30))
        #expect(!mb.inLandingStrip(CGPoint(x: 1.5, y: -1), stripPt: 30))
        #expect(!mb.inLandingStrip(CGPoint(x: -1000, y: -30.5), stripPt: 30))
        let vm = UTDesk.vmind
        #expect(vm.inLandingStrip(CGPoint(x: -1600, y: 0), stripPt: 30))
        #expect(vm.inLandingStrip(CGPoint(x: 1600, y: 30), stripPt: 30))
        #expect(!vm.inLandingStrip(CGPoint(x: 0, y: 31), stripPt: 30))
    }

    @Test func landingStripExcludesPointsDeepBeyondTheEdge() {
        // Display 1's left column on the MacBook is "beyond" display 3's bottom edge.
        #expect(!UTDesk.macbook.inLandingStrip(CGPoint(x: 0, y: 500), stripPt: 30))
        #expect(UTDesk.macbook.inLandingStrip(CGPoint(x: 0, y: 1), stripPt: 30))
    }

    @Test func clampTargetKeepsTargetsOnEdgeDisplaysAndInset() {
        let mb = UTDesk.macbook
        #expect(mb.clampTarget(x: 0, currentY: 0, stripPt: 30) == CGPoint(x: -0.5, y: -2))
        #expect(mb.clampTarget(x: -1280, currentY: -12, stripPt: 30) == CGPoint(x: -1280, y: -12))
        #expect(mb.clampTarget(x: -1280, currentY: -1, stripPt: 30) == CGPoint(x: -1280, y: -2))
        #expect(mb.clampTarget(x: -1280, currentY: -80, stripPt: 30) == CGPoint(x: -1280, y: -30))
        #expect(mb.clampTarget(x: -9999, currentY: 400, stripPt: 30) == CGPoint(x: -2560, y: -2))
        let vm = UTDesk.vmind
        #expect(vm.clampTarget(x: 2000, currentY: 50, stripPt: 30) == CGPoint(x: 1599.5, y: 30))
        #expect(vm.clampTarget(x: -1600, currentY: 0, stripPt: 30) == CGPoint(x: -1600, y: 2))
        #expect(vm.clampTarget(x: 12, currentY: -4, stripPt: 30) == CGPoint(x: 12, y: 2))
        #expect(vm.clampTarget(x: 12, currentY: 0, stripPt: 30, insetPt: 5) == CGPoint(x: 12, y: 5))
        for x in stride(from: -3000.0, through: 3000, by: 250) {
            for y in [-50.0, -1, 0, 0.5, 12, 400] {
                let p = mb.clampTarget(x: x, currentY: y, stripPt: 30)
                #expect(UTDesk.display3.contains(p), "MacBook target \(p) off display 3")
                #expect(mb.signedDist(p) >= 2, "MacBook target \(p) inside UC's hot zone")
                let q = vm.clampTarget(x: x, currentY: y, stripPt: 30)
                #expect(UTDesk.monitor4.contains(q) || UTDesk.monitor5.contains(q), "V-Mind target \(q) off 4/5")
                #expect(vm.signedDist(q) >= 2, "V-Mind target \(q) inside UC's hot zone")
            }
        }
    }

    @Test func clampTargetSnapsIntoGapsBetweenDisplays() {
        // Two displays with a gap and different heights: the result must land on one of them.
        let g = EdgeGeometry(side: .top, displays: [CGRect(x: 0, y: 0, width: 100, height: 100),
                                                    CGRect(x: 200, y: 0, width: 100, height: 100)])
        let p = g.clampTarget(x: 150, currentY: 10, stripPt: 30)
        #expect(g.displays.contains { $0.contains(p) })
    }
}
