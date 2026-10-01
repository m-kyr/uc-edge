import ApplicationServices
import CoreGraphics
import Foundation
import UCEdgeCore

/// The engine's only window onto the real cursor. Tests substitute a fake.
protocol CursorSystem: AnyObject, Sendable {
    func location() -> CGPoint?
    func buttonsDown() -> Bool
    /// Warps and re-associates the mouse; returns the CGError raw value (0 = success).
    func warp(to p: CGPoint) -> Int32
}

/// Monotonic milliseconds (does not advance during sleep).
func monotonicMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

final class CGCursorSystem: CursorSystem, @unchecked Sendable {
    func location() -> CGPoint? { CGEvent(source: nil)?.location }

    func buttonsDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
    }

    func warp(to p: CGPoint) -> Int32 {
        let err = CGWarpMouseCursorPosition(p)
        // Lifts the ~250 ms local-event suppression that follows a warp.
        CGAssociateMouseAndMouseCursorPosition(1)
        return err.rawValue
    }
}

/// An event source the tap supervisor can start, check and throw away.
protocol EventTapping: AnyObject {
    /// Creates the tap and its thread; false when it can't be created (no Input Monitoring).
    func start() -> Bool
    /// Re-enables a disabled tap if possible; returns whether the tap is working.
    func heal() -> Bool
    func invalidate()
}

/// Listen-only session event tap on its own thread and CFRunLoop (SPEC §4).
final class EventTapThread: EventTapping, @unchecked Sendable {
    /// `timestampNs`: the event's own CGEvent.timestamp (uptime ns), for matching UC's log lines.
    typealias Handler = (_ p: CGPoint, _ dx: Double, _ dy: Double, _ buttonsDown: Bool, _ timestampNs: UInt64) -> Void

    private let handler: Handler
    private let onNote: (String) -> Void
    private let onLost: () -> Void
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var running = false
    private var buttons = Set<Int64>()

    /// `onLost` is called when the tap's run loop returns (the tap went away).
    init(handler: @escaping Handler, onNote: @escaping (String) -> Void, onLost: @escaping () -> Void) {
        self.handler = handler
        self.onNote = onNote
        self.onLost = onLost
    }

    func start() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: eventTapCallback, userInfo: me) else {
            return false
        }
        lock.withLock {
            tap = port
            running = true
        }
        let thread = Thread { [self] in
            guard let port = lock.withLock({ tap }) else { return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            lock.withLock { runLoop = CFRunLoopGetCurrent() }
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
            let wasRunning = lock.withLock { () -> Bool in
                defer { running = false }
                return running
            }
            if wasRunning { onLost() }          // not stopped by invalidate(): the tap died
        }
        thread.name = "uc-edge.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func heal() -> Bool {
        guard let port = lock.withLock({ running ? tap : nil }), CFMachPortIsValid(port) else { return false }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
            onNote("event tap was disabled; re-enabled")
        }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func invalidate() {
        let (port, rl) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            running = false
            defer { tap = nil; runLoop = nil }
            return (tap, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl { CFRunLoopStop(rl) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            onNote("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "userInput")")
            return
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttons.insert(event.getIntegerValueField(.mouseEventButtonNumber))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttons.remove(event.getIntegerValueField(.mouseEventButtonNumber))
        default:
            break
        }
        let dragging = type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
        if type == .mouseMoved { buttons.removeAll() }   // a plain move means nothing is held
        // Integer deltas, as in the recordings the latch model was validated on (v1.2).
        handler(event.location, Double(event.getIntegerValueField(.mouseEventDeltaX)),
                Double(event.getIntegerValueField(.mouseEventDeltaY)), dragging || !buttons.isEmpty, event.timestamp)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<EventTapThread>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

/// Keeps an event tap alive (SPEC §4, §12): re-enables a disabled tap, and recreates a lost
/// one or retries a failed one with exponential backoff (1 s doubling to 60 s), reset once the
/// tap has stayed healthy for 60 s. While there is no tap the engine polls instead.
final class TapSupervisor: @unchecked Sendable {
    static let minBackoffSec = 1.0, maxBackoffSec = 60.0, healthyResetSec = 60.0

    private let makeTap: () -> EventTapping
    private weak var engine: Engine?
    private let log: Logger
    private let now: () -> Double
    private let queue = DispatchQueue(label: "uc-edge.tap-supervisor", qos: .utility)
    private var tap: EventTapping?
    private var timer: DispatchSourceTimer?
    private var warnedFailure = false
    private(set) var backoffSec = TapSupervisor.minBackoffSec
    private var nextAttemptAt = -Double.infinity
    private var healthySince: Double?
    /// Tap creations attempted (tests).
    private(set) var attempts = 0

    /// `now` is in seconds (monotonic); tests inject a clock.
    init(engine: Engine, log: Logger, now: @escaping () -> Double = { monotonicMs() / 1000 },
         makeTap: @escaping () -> EventTapping) {
        self.engine = engine
        self.log = log
        self.now = now
        self.makeTap = makeTap
    }

    /// First attempt, synchronously; returns whether a tap is running.
    @discardableResult
    func startTap() -> Bool { queue.sync { attemptLocked(at: now()) } }

    /// Supervision runs once a second (a cheap tapIsEnabled check).
    func startTimer(tickSec: Double = 1) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickSec, repeating: tickSec, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tickLocked() }
        t.resume()
        timer = t
    }

    /// Called when the tap reports that its run loop ended.
    func tapLost() { queue.async { [weak self] in self?.tickLocked() } }

    /// Runs one supervision step now (tests).
    func check() { queue.sync { tickLocked() } }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            tap?.invalidate()
            tap = nil
        }
    }

    private func tickLocked() {
        let t = now()
        if let tap {
            if tap.heal() {
                if let since = healthySince {
                    if t - since >= Self.healthyResetSec { backoffSec = Self.minBackoffSec }
                } else {
                    healthySince = t
                }
                return
            }
            log.log("WARNING event tap lost; recreating it in \(Int(backoffSec)) s")
            tap.invalidate()
            self.tap = nil
            healthySince = nil
            engine?.setTapActive(false)
            scheduleRetryLocked(from: t)
            return
        }
        if t >= nextAttemptAt { _ = attemptLocked(at: t) }
    }

    private func scheduleRetryLocked(from t: Double) {
        nextAttemptAt = t + backoffSec
        backoffSec = min(backoffSec * 2, Self.maxBackoffSec)
    }

    private func attemptLocked(at t: Double) -> Bool {
        attempts += 1
        let candidate = makeTap()
        guard candidate.start() else {
            if !warnedFailure {
                log.log("WARNING event tap unavailable (Input Monitoring?): polling at 250 Hz, dead strip off; retrying with backoff")
                warnedFailure = true
            }
            engine?.setTapActive(false)
            scheduleRetryLocked(from: t)
            return false
        }
        if warnedFailure { log.log("event tap created") }
        warnedFailure = false
        tap = candidate
        healthySince = t
        engine?.setTapActive(true)
        return true
    }
}

/// Lets a tap's "lost" callback reach the supervisor that owns the tap.
final class SupervisorBox: @unchecked Sendable {
    weak var value: TapSupervisor?
}

/// Samples the cursor at 1 kHz while the engine is armed; otherwise blocks on a semaphore
/// (signalled by packet arrival) with a timeout, so idle CPU stays near zero. In fallback
/// mode (no tap) it polls at 250 Hz and turns position *changes* into synthetic events.
final class Poller: @unchecked Sendable {
    let wake = DispatchSemaphore(value: 0)
    private let cursor: CursorSystem
    private weak var engine: Engine?
    private let idleWaitMs: Double
    private let lock = NSLock()
    private var running = true
    private var fallback: Bool
    private var lastFallbackPos: CGPoint?

    init(cursor: CursorSystem, engine: Engine, idleWaitMs: Double, fallback: Bool) {
        self.cursor = cursor
        self.engine = engine
        self.idleWaitMs = idleWaitMs
        self.fallback = fallback
    }

    func start() {
        let t = Thread { [self] in loop() }
        t.name = "uc-edge.poll"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        lock.withLock { running = false }
        wake.signal()
    }

    func setFallback(_ on: Bool) {
        lock.withLock { fallback = on }
        wake.signal()
    }

    private var state: (running: Bool, fallback: Bool) { lock.withLock { (running, fallback) } }

    private func loop() {
        var wasArmed = false
        while let engine {
            let (isRunning, fallback) = state
            guard isRunning else { return }
            let armed = engine.isArmed()
            if armed || fallback {
                if let p = cursor.location() {
                    let buttons = cursor.buttonsDown()
                    if fallback, let prev = lastFallbackPos, p != prev {
                        lastFallbackPos = p
                        engine.onTapEvent(p: p, dx: Double(p.x - prev.x), dy: Double(p.y - prev.y),
                                          buttonsDown: buttons, synthetic: true)
                    } else {
                        // Unchanged positions only feed the detector's clock, never the latch (C1).
                        lastFallbackPos = p
                        engine.onPollSample(p: p, buttonsDown: buttons)
                    }
                }
                Self.sleep(ms: armed ? 1 : 4)
                wasArmed = armed
            } else if wasArmed {
                // Drop wake-ups that piled up while armed, then re-check: the packet handler
                // updates state before signalling, so nothing that should arm us is lost.
                while wake.wait(timeout: .now()) == .success {}
                wasArmed = false
            } else {
                _ = wake.wait(timeout: .now() + .milliseconds(Int(idleWaitMs)))
            }
        }
    }

    private static func sleep(ms: Double) {
        var ts = timespec(tv_sec: 0, tv_nsec: Int(ms * 1_000_000))
        nanosleep(&ts, nil)
    }
}
