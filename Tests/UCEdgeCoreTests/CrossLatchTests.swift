import CoreGraphics
import Testing
@testable import UCEdgeCore

@Suite struct CrossLatchTests {
    static let vmZone = (min: -961.0, max: 1600.0)

    /// Feeds one V-Mind event (top edge; dy < 0 pushes).
    @discardableResult
    static func vm(_ l: CrossLatch, _ t: Double, _ x: Double, _ y: Double, dy: Double) -> Double? {
        l.onEvent(t: t, p: CGPoint(x: x, y: y), dy: dy, geometry: UTDesk.vmind, zoneMin: vmZone.min, zoneMax: vmZone.max)
    }

    @Test func enteringEventNeverLatchesTheNextPushDoes() {
        let l = CrossLatch()
        #expect(Self.vm(l, 0, 115.06, 0, dy: -149) == nil, "Entering: arms only")
        #expect(l.isArmed)
        #expect(Self.vm(l, 16, 177.10, 0, dy: -85) == 177.10, "Activating: the next push latches its x")
        // Tail events keep the latched x.
        #expect(Self.vm(l, 33, 308.65, 0, dy: -149) == 177.10)
        #expect(Self.vm(l, 49, 373.39, 4, dy: -62) == 177.10)
    }

    @Test func approachDoesNotArmUntilWithinOnePoint() {
        let l = CrossLatch()
        #expect(Self.vm(l, 0, -955, 21.3, dy: -30) == nil)
        #expect(!l.isArmed)
        #expect(Self.vm(l, 16, -950.82, 0.99, dy: -30) == nil)
        #expect(l.isArmed)
        #expect(Self.vm(l, 33, -948.46, 0, dy: -20) == -948.46)
    }

    @Test func nonPushEventsKeepItArmedWithoutLatching() {
        let l = CrossLatch()
        Self.vm(l, 0, 1578.61, 0, dy: -3)
        #expect(Self.vm(l, 16, 1578.07, 0.95, dy: 0) == nil)
        #expect(Self.vm(l, 32, 1560, 12, dy: 5) == nil, "moving away does not reset it")
        #expect(l.isArmed)
        #expect(Self.vm(l, 48, 1474.58, 10, dy: -11) == 1474.58)
    }

    @Test func gapOver100msResets() {
        let l = CrossLatch()
        Self.vm(l, 0, 0, 0, dy: -5)
        #expect(Self.vm(l, 101, 3, 0, dy: -5) == nil, "gap resets, and this event re-arms")
        #expect(l.isArmed)
        #expect(Self.vm(l, 117, 4, 0, dy: -5) == 4)
        // A latched value is dropped by a gap too.
        #expect(Self.vm(l, 218, 5, 0, dy: -5) == nil)
    }

    @Test func tooDeepResets() {
        let l = CrossLatch()
        Self.vm(l, 0, 0, 0, dy: -5)
        #expect(Self.vm(l, 16, 0, 30, dy: 3) == nil)
        #expect(l.isArmed, "exactly 30 is still armed")
        #expect(Self.vm(l, 32, 0, 30.5, dy: 3) == nil)
        #expect(!l.isArmed)
        #expect(Self.vm(l, 48, 0, 5, dy: -5) == nil, "not re-armed from 5 pt")
    }

    @Test func beyondTheEdgeResets() {
        // MacBook bottom edge: y > +1 is display 1, below display 3's edge line.
        let l = CrossLatch()
        func mb(_ t: Double, _ x: Double, _ y: Double, dy: Double) -> Double? {
            l.onEvent(t: t, p: CGPoint(x: x, y: y), dy: dy, geometry: UTDesk.macbook,
                      zoneMin: UTDesk.macbook.spanMin - 1, zoneMax: UTDesk.macbook.spanMax + 1)
        }
        #expect(mb(0, -100, -0.02, dy: 30) == nil)
        #expect(l.isArmed)
        #expect(mb(16, -1, 1.5, dy: 30) == nil)
        #expect(!l.isArmed)
        #expect(mb(32, -1600.84, -0.02, dy: 110) == nil)
        #expect(mb(48, -1600.84, -0.02, dy: 30) == -1600.84)
    }

    @Test func latchExpires150msAfterLatchTAndStaysSpentUntilTheCursorLeaves() {
        let l = CrossLatch()
        Self.vm(l, 0, 0, 0, dy: -5)
        #expect(Self.vm(l, 20, 1, 0, dy: -5) == 1)
        #expect(Self.vm(l, 100, 30, 0, dy: -5) == 1)
        #expect(Self.vm(l, 170, 40, 0, dy: -5) == 1, "exactly 150 ms after latchT")
        #expect(Self.vm(l, 171, 41, 0, dy: -5) == nil, "expired")
        #expect(l.isSpent && !l.isArmed)
        #expect(Self.vm(l, 187, 42, 0, dy: -5) == nil, "v1.2: no second latch in the same edge visit")
        #expect(Self.vm(l, 204, 43, 0, dy: -5) == nil)
        #expect(Self.vm(l, 220, 44, 3, dy: 2) == nil, "leaves the edge")
        #expect(!l.isSpent)
        #expect(Self.vm(l, 237, 45, 0, dy: -5) == nil, "back at the edge: arms")
        #expect(Self.vm(l, 254, 46, 0, dy: -5) == 46)
    }

    @Test func spentLatchReArmsAfterAGap() {
        let l = CrossLatch()
        Self.vm(l, 0, 0, 0, dy: -5)
        Self.vm(l, 16, 1, 0, dy: -5)
        #expect(Self.vm(l, 100, 2, 0, dy: -5) == 1)
        #expect(Self.vm(l, 167, 2, 0, dy: -5) == nil)
        #expect(l.isSpent)
        #expect(Self.vm(l, 268, 3, 0, dy: -5) == nil, "a 101 ms gap is a new visit: arms")
        #expect(Self.vm(l, 284, 4, 0, dy: -5) == 4)
    }

    @Test func armingNeedsTheZoneLatchingDoesNot() {
        let l = CrossLatch()
        #expect(Self.vm(l, 0, -1200, 0, dy: -5) == nil)
        #expect(!l.isArmed, "dead strip: outside UC's zone")
        #expect(Self.vm(l, 16, -1190, 0, dy: -5) == nil)
        #expect(Self.vm(l, 32, -961, 0, dy: -5) == nil)
        #expect(l.isArmed, "zone edge is inclusive")
        #expect(Self.vm(l, 48, -975, 0, dy: -5) == -975, "once armed, UC latches even outside the zone")
    }

    @Test func pushDirectionFollowsTheSide() {
        let l = CrossLatch()
        func mb(_ t: Double, dy: Double) -> Double? {
            l.onEvent(t: t, p: CGPoint(x: -500, y: -0.02), dy: dy, geometry: UTDesk.macbook, zoneMin: -2561, zoneMax: 1)
        }
        #expect(mb(0, dy: 5) == nil)
        #expect(mb(16, dy: -5) == nil, "dy < 0 moves away from a bottom edge")
        #expect(mb(32, dy: 5) == -500)
    }

    @Test func resetClearsEverything() {
        let l = CrossLatch()
        Self.vm(l, 0, 0, 0, dy: -5)
        Self.vm(l, 16, 1, 0, dy: -5)
        l.reset()
        #expect(l.crossX == nil && !l.isArmed)
        #expect(Self.vm(l, 32, 2, 0, dy: -5) == nil)
    }

    @Test func invalidGeometryNeverLatches() {
        let l = CrossLatch()
        let g = EdgeGeometry(side: .top, displays: [])
        for i in 0..<5 {
            #expect(l.onEvent(t: Double(i) * 16, p: .zero, dy: -5, geometry: g, zoneMin: -10, zoneMax: 10) == nil)
        }
    }
}
