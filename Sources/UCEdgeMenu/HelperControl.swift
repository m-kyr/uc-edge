import Foundation

/// Starts and stops the helper's LaunchAgent (local.uc-edge) in this login session.
/// Pause = `launchctl bootout`: the job stays unloaded until Resume or the next login, when
/// launchd loads ~/Library/LaunchAgents again. Never touches any other job.
enum HelperControl {
    static let label = "local.uc-edge"
    static var domain: String { "gui/\(getuid())" }
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func isLoaded() -> Bool {
        launchctl(["print", "\(domain)/\(label)"]) == 0
    }

    /// Stops the helper. Returns true if it is no longer loaded.
    @discardableResult
    static func pause() -> Bool {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        for _ in 0..<20 where isLoaded() { usleep(100_000) }
        return !isLoaded()
    }

    /// Starts the helper again. Returns true once it is loaded.
    @discardableResult
    static func resume() -> Bool {
        guard isInstalled else { return false }
        // Right after a bootout, bootstrap can fail with EIO (5) for a moment: retry.
        for _ in 0..<10 {
            if launchctl(["bootstrap", domain, plistPath]) == 0 || isLoaded() { return true }
            usleep(500_000)
        }
        return isLoaded()
    }

    /// Runs /bin/launchctl quietly; returns its exit status (-1 if it could not run).
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
