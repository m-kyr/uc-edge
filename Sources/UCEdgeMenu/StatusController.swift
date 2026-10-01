import AppKit
import Foundation
import UCEdgeCore

/// Reads the helper's config and status.json and builds the menu model. May run launchctl, so
/// the app calls it off the main thread.
struct StatusSource: Sendable {
    let configPath: String

    var config: Config { (try? Config.load(path: configPath)) ?? Config() }

    func model(resumedAt: Date?) -> MenuModel {
        let loadedConfig = Result { try Config.load(path: configPath) }
        let cfg = (try? loadedConfig.get()) ?? Config()
        var configProblem: String?
        if case .failure(let error) = loadedConfig {
            configProblem = MenuModel.configProblem(path: configPath, error: error)
        }
        let configData = try? Data(contentsOf: URL(fileURLWithPath: expandTilde(configPath)))
        let status = (try? Data(contentsOf: URL(fileURLWithPath: expandTilde(cfg.statusPath))))
            .flatMap { try? StatusView.decode($0) }
        let now = Date()
        // A fresh status file from a live process means the helper is running; ask launchctl
        // otherwise (right after a pause the file is still fresh but its process is gone).
        let fresh = status?.updatedAt.map { now.timeIntervalSince($0) <= 15 } ?? false
        let alive = status?.pid.map { $0 > 0 && kill(pid_t(clamping: $0), 0) == 0 }
        let loaded = (fresh && alive == true) || HelperControl.isLoaded()
        return MenuModel.make(MenuInputs(
            status: status, helperLoaded: loaded, helperInstalled: HelperControl.isInstalled, now: now,
            peerName: MenuModel.peerName(configJSON: configData, peerHosts: cfg.peerHosts), resumedAt: resumedAt,
            statusProcessAlive: alive, configProblem: configProblem))
    }
}

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let source: StatusSource
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    /// Status reads and launchctl run here, never on the main thread.
    private let queue = DispatchQueue(label: "local.uc-edge.menu.refresh", qos: .utility)
    private var timer: Timer?
    /// Set when the menu (re)starts the helper, and at launch (login starts both at once).
    private var resumedAt: Date? = Date()
    private var busy = false
    private var refreshing = false
    /// Bumped by every action, so a refresh started before it is dropped.
    private var generation = 0
    private var isOpen = false
    private var current: MenuModel?
    /// A failed Pause / Resume / Quit, shown in the menu until the next action or state change.
    private var actionError: String?

    init(source: StatusSource) {
        self.source = source
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageOnly
        item.button?.title = "UC"
        rebuildMenu(nil)
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Recomputes the model on `queue` and applies it on the main thread.
    func refresh() {
        guard !busy, !refreshing else { return }
        refreshing = true
        let source = source, resumedAt = resumedAt, generation = generation
        queue.async {
            let m = source.model(resumedAt: resumedAt)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    guard generation == self.generation, !self.busy else { return }
                    if m.state != .starting, self.resumedAt == resumedAt { self.resumedAt = nil }
                    self.apply(m)
                }
            }
        }
    }

    private func apply(_ m: MenuModel) {
        guard m != current else { return }
        if let old = current, old.state != m.state { actionError = nil }
        current = m
        updateIcon(m)
        if !isOpen { rebuildMenu(m) }
    }

    /// Shows the latest model (at most one refresh old); no launchctl here, so opening never waits.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(current)
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    private func updateIcon(_ m: MenuModel) {
        guard let button = item.button else { return }
        let image = m.symbolNames.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: m.headline) }
            .first
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "UC" : ""
        button.appearsDisabled = m.dimmed
        button.toolTip = ([m.headline] + (m.reason.map { [$0] } ?? [])).joined(separator: "\n")
    }

    private func rebuildMenu(_ model: MenuModel?) {
        menu.removeAllItems()
        guard let m = model else {
            menu.addItem(info("UCEdge: checking…"))
            menu.addItem(.separator())
            menu.addItem(action("Open Log", #selector(openLog), subtitle: nil))
            return
        }
        let head = info(m.headline)
        head.attributedTitle = NSAttributedString(string: m.headline,
                                                  attributes: [.font: NSFont.menuFont(ofSize: 0).bold()])
        menu.addItem(head)
        if let r = m.reason { menu.addItem(info(r)) }
        for line in m.lines { menu.addItem(info(line)) }
        if let e = actionError { menu.addItem(info(e)) }
        menu.addItem(.separator())

        if busy {
            menu.addItem(info("Working…"))
        } else if m.canResume {
            menu.addItem(action("Resume UCEdge", #selector(resumeHelper), subtitle: nil))
        } else if m.canPause {
            menu.addItem(action("Pause UCEdge", #selector(pauseHelper),
                                subtitle: "Until you resume or log in again"))
        }
        menu.addItem(action("Open Log", #selector(openLog), subtitle: nil))
        menu.addItem(.separator())
        let quit = action("Quit UCEdge", #selector(quitAll), subtitle: "Starts again at your next login")
        quit.toolTip = "Stops UCEdge on this Mac and closes this menu. Both start again at your next login."
        quit.isEnabled = !busy
        menu.addItem(quit)
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, subtitle: String?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        if let subtitle {
            if #available(macOS 14.4, *) { i.subtitle = subtitle } else { i.toolTip = subtitle }
        }
        return i
    }

    // MARK: actions (launchctl runs off the main thread; the menu shows "Working…")

    private func runBusy(_ work: @escaping @Sendable () -> Bool, then: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !busy else { return }
        busy = true
        generation += 1
        actionError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    then(ok)
                    if !self.isOpen { self.rebuildMenu(self.current) }
                    self.refresh()
                }
            }
        }
    }

    @objc private func pauseHelper() {
        runBusy({ HelperControl.pause() }) { [weak self] ok in
            self?.resumedAt = nil
            if !ok { self?.actionError = "Couldn't pause: local.uc-edge is still loaded" }
        }
    }

    @objc private func resumeHelper() {
        runBusy({ HelperControl.resume() }) { [weak self] ok in
            self?.resumedAt = ok ? Date() : nil
            if !ok { self?.actionError = "Couldn't resume: launchctl bootstrap failed" }
        }
    }

    @objc private func openLog() {
        let path = expandTilde(source.config.logPath)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            // Console shows a live tail; fall back to the default app for .log files.
            let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
            if FileManager.default.fileExists(atPath: console.path) {
                NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Stops the helper, then exits 0: launchd's KeepAlive {SuccessfulExit: false} leaves the
    /// menu quit until the next login, when both LaunchAgents are loaded again. If the helper
    /// can't be stopped, the menu stays (quitting it would leave UCEdge running with no menu).
    @objc private func quitAll() {
        runBusy({ HelperControl.pause() }) { [weak self] ok in
            if ok { NSApp.terminate(nil) } else { self?.actionError = "Couldn't stop UCEdge, so the menu stays open" }
        }
    }
}

private extension NSFont {
    func bold() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
