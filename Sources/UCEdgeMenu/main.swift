import AppKit
import Foundation
import UCEdgeCore

// UCEdge Menu: a menu bar icon that shows the helper's status and can pause, resume or quit it.
// It only reads status.json and runs launchctl for the job local.uc-edge; it needs no
// permissions and never talks to the helper or the network.
//
//   UCEdgeMenu                 run the menu bar app (launchd starts it at login)
//   UCEdgeMenu --print         print what the menu would show, once, and exit
//   UCEdgeMenu --pause/--resume  the menu's Pause / Resume, from a shell
//   UCEdgeMenu --displays      list the displays' full UUIDs and bounds (for edgeDisplays)
//   ... [--config PATH]        helper config to read (default ~/.config/uc-edge/config.json)

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
var configPath = Config.defaultPath
if let i = args.firstIndex(of: "--config"), i + 1 < args.count {
    configPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

if args.contains("--print") {
    let source = StatusSource(configPath: configPath)
    print(source.model(resumedAt: nil).text)
    exit(0)
}
if args.contains("--displays") {
    print(DisplayList.text())
    exit(0)
}
// The menu's own Pause / Resume, for scripts and SSH.
if args.contains("--pause") {
    let ok = HelperControl.pause()
    print(ok ? "paused (local.uc-edge unloaded until --resume or the next login)" : "error: local.uc-edge is still loaded")
    exit(ok ? 0 : 1)
}
if args.contains("--resume") {
    let ok = HelperControl.resume()
    print(ok ? "resumed (local.uc-edge loaded)" : "error: could not load \(HelperControl.plistPath)")
    exit(ok ? 0 : 1)
}
if let unknown = args.first(where: { !$0.hasPrefix("-psn_") }) {
    FileHandle.standardError.write(Data("usage: UCEdgeMenu [--print | --pause | --resume | --displays] [--config PATH]  (unknown: \(unknown))\n".utf8))
    exit(64)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = StatusController(source: StatusSource(configPath: configPath))
    withExtendedLifetime(controller) {
        app.run()
    }
}
