import ApplicationServices
import CoreGraphics
import Foundation
import UCEdgeCore

setvbuf(stdout, nil, _IOLBF, 0)
exit(CLI.main(Array(CommandLine.arguments.dropFirst())))

enum CLI {
    static let usage = """
    usage: UCEdge [run | status | version | selftest] [--config PATH]
      run       run the helper (launchd starts it with `run`)
      (no arguments, e.g. opened by double-click) contact the config's peerHosts so macOS asks for
                Local Network access in this user account, then quit
      status    print a summary of the running helper's status.json
      version   print the version
      selftest  read-only checks: permissions, displays, key, UC arrangement, peer DNS
    """

    static func main(_ args: [String]) -> Int32 {
        var rest = args
        var configPath = Config.defaultPath
        if let i = rest.firstIndex(of: "--config"), i + 1 < rest.count {
            configPath = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
        }
        if rest.isEmpty || rest.first?.hasPrefix("-psn_") == true { return lanPrompt(configPath: configPath) }
        switch rest.first! {
        case "run": return run(configPath: configPath)
        case "status": return status(configPath: configPath)
        case "version", "--version", "-v":
            print("UCEdge \(UCEdgeVersion.string)")
            return 0
        case "selftest": return SelfTest.run(configPath: configPath)
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
    }

    /// Opened by hand (no arguments): touch the LAN so macOS shows its Local Network prompt for
    /// this user account, then quit. On a Mac with two user accounts macOS checks both accounts'
    /// Local Network decisions, so each account has to allow UCEdge once. Sends a few junk
    /// datagrams (rejected by the peer's helper) to the configured peerHosts; does nothing else.
    static func lanPrompt(configPath: String) -> Int32 {
        let config = (try? Config.load(path: configPath)) ?? Config()
        guard !config.peerHosts.isEmpty else {
            print("no peerHosts in \(configPath): nothing to contact, so macOS has nothing to ask about")
            return 1
        }
        let port = String(config.peerPort ?? config.port)
        let payload = Array("uc-edge lan prompt".utf8)
        for _ in 0..<10 {
            for host in config.peerHosts {
                var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, port, &hints, &res) == 0, let first = res else { continue }
                var ai: UnsafeMutablePointer<addrinfo>? = first
                while let a = ai {
                    let fd = socket(a.pointee.ai_family, SOCK_DGRAM, 0)
                    if fd >= 0 {
                        _ = sendto(fd, payload, payload.count, 0, a.pointee.ai_addr, a.pointee.ai_addrlen)
                        close(fd)
                    }
                    ai = a.pointee.ai_next
                }
                freeaddrinfo(first)
            }
            sleep(2)
        }
        return 0
    }

    static func loadConfig(_ path: String) -> Config? {
        do { return try Config.load(path: path) } catch {
            FileHandle.standardError.write(Data("cannot load config \(path): \(error)\n".utf8))
            return nil
        }
    }

    static func status(configPath: String) -> Int32 {
        let path = (try? Config.load(path: configPath))?.statusPath ?? Config().statusPath
        do {
            print(StatusFile.summary(try StatusFile.read(from: path)))
            return 0
        } catch {
            print("no status at \(expandTilde(path)) (\(error.localizedDescription)); is the helper running?")
            return 1
        }
    }

    static func run(configPath: String) -> Int32 {
        guard let loaded = loadConfig(configPath) else {
            // launchd would restart us immediately; wait so a missing config doesn't spin.
            sleep(60)
            return 78
        }
        let check = loaded.validated()
        let config = check.config
        let log = Logger(path: config.logPath)
        log.log("UCEdge \(UCEdgeVersion.string) starting, config \(expandTilde(configPath))")
        if LaunchdLog.trim() { log.log("trimmed \(LaunchdLog.path) to its last 64 KB") }
        check.warnings.forEach { log.log("config warning: \($0)") }
        guard check.errors.isEmpty else {
            check.errors.forEach { log.log("config ERROR: \($0)") }
            var s = StatusSnapshot()
            s.name = config.name
            s.configErrors = check.errors
            s.configWarnings = check.warnings
            StatusFile.write(s, to: config.statusPath)
            log.flush()
            sleep(60)
            return 78
        }

        let key = waitForKey(config: config, log: log)
        let env = EngineEnvironment(
            cursor: CGCursorSystem(),
            edgeDisplays: { Displays.resolve(config.edgeDisplayUUIDs) },
            accessibilityTrusted: { AXIsProcessTrusted() },
            listenEventAccess: { CGPreflightListenEventAccess() },
            ucPlistPath: { UCArrangement.defaultPlistPath() },
            allDisplays: { Displays.activeDisplays().map(\.bounds) })
        let engine = Engine(config: config, key: key, env: env, log: log, configWarnings: check.warnings)
        let box = SupervisorBox()
        let supervisor = TapSupervisor(engine: engine, log: log) { [weak engine] in
            EventTapThread(
                handler: { p, dx, dy, buttons, ns in engine?.onTapEvent(p: p, dx: dx, dy: dy, buttonsDown: buttons, eventNs: ns) },
                onNote: { log.log($0) },
                onLost: { box.value?.tapLost() })
        }
        box.value = supervisor
        let tapOK = supervisor.startTap()
        do {
            try engine.start(tapActive: tapOK)
        } catch {
            log.log("FATAL cannot start: \(error)")
            log.flush()
            sleep(10)
            return 71
        }
        supervisor.startTimer()
        var ucLog: UCLogStream?
        if config.ucLogAssist.enabled {
            let orphans = UCLogStream.killOrphans()
            if !orphans.isEmpty { log.log("uclog: killed \(orphans.count) orphaned log stream child(ren) from an earlier run") }
            UCLogStream.installExitCleanup()
            ucLog = UCLogStream(engine: engine, log: log)
            ucLog?.start()
        }
        let stream = ucLog
        engine.onFatal = { _ in
            stream?.stop()
            exit(1)
        }
        // launchd stops the job with SIGTERM: take the `log stream` child down with us.
        let signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log.log("signal \(sig): stopping")
                stream?.stop()
                supervisor.stop()
                engine.stop()
                exit(0)
            }
            src.resume()
            return src
        }
        Displays.observeReconfiguration { engine.displaysChanged() }
        withExtendedLifetime((engine, supervisor, stream, signalSources)) { CFRunLoopRun() }
        return 0
    }

    /// Without a usable key nothing is sent or corrected. Stay alive (so launchd doesn't spin)
    /// and re-check every 10 s. Never logs key material.
    static func waitForKey(config: Config, log: Logger) -> WireKey {
        var warned = ""
        while true {
            let path = expandTilde(config.keyPath)
            let key = WireKey.load(path: path)
            let isPrivate = WireKey.fileIsPrivate(path: path)
            if let key, isPrivate { return key }
            let problem = key == nil ? "missing or not exactly 64 hex characters" : "readable by group or others (chmod 600)"
            if warned != problem {
                log.log("WARNING key at \(config.keyPath) is \(problem); not correcting until it is fixed")
                warned = problem
            }
            var s = StatusSnapshot()
            s.name = config.name
            s.keyMissing = key == nil
            s.keyInsecure = key != nil && !isPrivate
            s.permissions.accessibility = AXIsProcessTrusted()
            s.permissions.listenEvents = CGPreflightListenEventAccess()
            StatusFile.write(s, to: config.statusPath)
            sleep(10)
        }
    }
}
