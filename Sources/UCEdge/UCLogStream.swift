import Darwin
import Foundation
import UCEdgeCore

/// The running child's pid, readable from signal handlers and atexit (F4).
nonisolated(unsafe) private var ucLogChildPidForCleanup: pid_t = 0

/// Supervises `/usr/bin/log stream` for UC's Hot Zone lines (SPEC §13.2.1): restarts it with
/// backoff (1 s doubling to 60 s, reset after a 60 s run), kills it on shutdown, and hands each
/// line to the engine with the clock offset sampled at receipt.
final class UCLogStream: @unchecked Sendable {
    static let predicate = #"process == "UniversalControl" AND (eventMessage BEGINSWITH "Hot Zone: Activating" OR eventMessage BEGINSWITH "Hot Zone: Entering")"#
    static let minBackoffSec = 1.0, maxBackoffSec = 60.0, healthyResetSec = 60.0
    /// A partial line longer than this is dropped (F6).
    static let maxLineBytes = 64 * 1024

    private weak var engine: Engine?
    private let log: Logger
    let predicate: String
    private let queue = DispatchQueue(label: "uc-edge.uclog", qos: .utility)
    private var process: Process?
    private var stopping = false
    private var backoffSec = UCLogStream.minBackoffSec
    private var startedAt = 0.0

    init(engine: Engine, log: Logger, predicate: String = UCLogStream.predicate) {
        self.engine = engine
        self.log = log
        self.predicate = predicate
    }

    /// The running child's pid (0 = none).
    var childPid: pid_t { queue.sync { process?.processIdentifier ?? 0 } }

    func start() { queue.async { [self] in launchLocked() } }

    func stop() {
        queue.sync {
            stopping = true
            if let p = process, p.isRunning { p.terminate() }
            process = nil
            ucLogChildPidForCleanup = 0
        }
    }

    private func launchLocked() {
        guard !stopping, process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = Array(UCLogOrphan.argv(predicate: predicate).dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            queue.async { [weak self] in self?.exitedLocked(proc) }
        }
        do {
            try p.run()
        } catch {
            log.log("uclog: cannot start /usr/bin/log: \(error)")
            engine?.ucLogStopped(restarting: true)
            scheduleRestartLocked()
            return
        }
        process = p
        ucLogChildPidForCleanup = p.processIdentifier
        startedAt = monotonicMs() / 1000
        engine?.ucLogStarted()
        // Captures `out` so the pipe (which owns the descriptor) outlives the reader.
        let reader = Thread { [weak self, out] in self?.readLines(out.fileHandleForReading.fileDescriptor) }
        reader.name = "uc-edge.uclog"
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    private func exitedLocked(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        ucLogChildPidForCleanup = 0
        guard !stopping else { engine?.ucLogStopped(restarting: false); return }
        if monotonicMs() / 1000 - startedAt >= Self.healthyResetSec { backoffSec = Self.minBackoffSec }
        log.log("uclog: log stream exited (status \(proc.terminationStatus)); restarting in \(Int(backoffSec)) s")
        engine?.ucLogStopped(restarting: true)
        scheduleRestartLocked()
    }

    private func scheduleRestartLocked() {
        let delay = backoffSec
        backoffSec = min(backoffSec * 2, Self.maxBackoffSec)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launchLocked() }
    }

    /// Reads newline-separated ndjson until EOF (the child exited or was killed).
    private func readLines(_ fd: Int32) {
        var splitter = LineSplitter(maxBytes: Self.maxLineBytes)
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            // Sample the clocks as close to receipt as possible: absolute first, then continuous (F1).
            let absolute = mach_absolute_time()
            let continuousMinusAbsolute = UCLogClock.sampleOffset(absolute: absolute, continuous: mach_continuous_time())
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let overflowsBefore = splitter.overflows
            for line in splitter.append(buf[0..<n]) {
                engine?.onUCLogLine(line, receivedNs: nowNs, continuousMinusAbsolute: continuousMinusAbsolute)
            }
            if splitter.overflows != overflowsBefore { engine?.ucLogOverflow() }
        }
    }
}

extension UCLogClock {
    /// This machine's mach timebase.
    static var local: UCLogClock {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return UCLogClock(numer: tb.numer, denom: tb.denom)
    }
}

extension UCLogStream {
    /// Kills the child on exit paths other than a clean stop: `exit()` (atexit) and crashes
    /// (SIGSEGV & co.). SIGTERM/SIGINT/SIGHUP are handled in `run`. A SIGKILL can't be caught:
    /// `killOrphans` cleans up at the next start.
    static func installExitCleanup() {
        atexit {
            if ucLogChildPidForCleanup > 0 { kill(ucLogChildPidForCleanup, SIGTERM) }
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                if ucLogChildPidForCleanup > 0 { kill(ucLogChildPidForCleanup, SIGTERM) }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// Kills `log stream` processes left by earlier instances: our uid, ppid 1, and exactly our
    /// command line (`predicate`). Never touches any other process. Returns the pids signalled.
    @discardableResult
    static func killOrphans(predicate: String = UCLogStream.predicate) -> [pid_t] {
        let myUID = getuid()
        var killed: [pid_t] = []
        for (pid, ppid, uid) in processes(ofUID: myUID) where ppid == 1 {
            guard let argv = arguments(of: pid),
                  UCLogOrphan.isOrphan(argv: argv, ppid: ppid, uid: uid, myUID: myUID, predicate: predicate) else { continue }
            if kill(pid, SIGTERM) == 0 { killed.append(pid) }
        }
        return killed
    }

    private static func processes(ofUID uid: uid_t) -> [(pid_t, Int32, UInt32)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map {
            ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid, $0.kp_eproc.e_ucred.cr_uid)
        }
    }

    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 1 << 20 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return UCLogOrphan.parseProcArgs2(Array(buf.prefix(size)))
    }
}
