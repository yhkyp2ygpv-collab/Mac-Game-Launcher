import AppKit

/// The parts of being a Mac app that SwiftUI's scenes do not cover: anvil:// links from
/// shortcut apps, the Dock icon's menu, and quitting while a game is still running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered before launch finishes, so a link that started Anvil is not lost.
        // Handled here rather than through SwiftUI's onOpenURL, which opens a new
        // window for every link.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Housekeeping.atLaunch()
        GameReady.shared.install()
        GameFocus.watchActivation()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        AnvilLog.write("link: \(url.absoluteString)")
        if !QuickLaunch.handle(url) {
            QuickLaunch.report("Anvil can't open that link", url.absoluteString)
        }
    }

    // MARK: Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        // Items say for themselves whether they can be chosen.
        menu.autoenablesItems = false
        let launcher = Launcher.shared
        for session in launcher.sessions {
            menu.addItem(.sectionHeader(title: session.game.title))
            let closing = launcher.closing.contains(session.id)
            let game = session.game
            menu.addItem(ActionItem(closing ? "Closing…" : "Quit Game", enabled: !closing) { launcher.quit(game) })
            menu.addItem(ActionItem("Force Quit Game") { launcher.forceQuit(game) })
            menu.addItem(.separator())
        }
        let games = QuickLaunch.recentGames(limit: 8).filter { !launcher.isRunning($0) }
        if !games.isEmpty {
            menu.addItem(.sectionHeader(title: "Play"))
            for game in games {
                menu.addItem(ActionItem(game.title, enabled: game.exists) { QuickLaunch.play(game) })
            }
        }
        return menu
    }

    // MARK: Quitting with a game running

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let launcher = Launcher.shared
        guard !launcher.sessions.isEmpty else { return .terminateNow }
        let titles = launcher.sessions.map(\.game.title)
        // A logout, restart or shutdown carries a reason; that is not the moment to
        // ask anything, only to close the games properly.
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        if !systemQuit {
            NSApp.unhide(nil)
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = titles.count == 1 ? "\(titles[0]) is still running"
                                                  : "\(titles.count) games are still running"
            alert.informativeText = "Anvil closes \(titles.count == 1 ? "it" : "them") first, the way Quit Game does — the game gets to save, its play time is recorded, and Wine shuts its container down cleanly."
            alert.addButton(withTitle: titles.count == 1 ? "Quit Game and Anvil" : "Quit Games and Anvil")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        AnvilLog.write("quitting Anvil: closing \(titles.joined(separator: ", ")) first")
        launcher.quitAll()
        Task { @MainActor in
            // Quit escalates to a force quit on its own; this only bounds the wait.
            let deadline = Date().addingTimeInterval(50)
            while !Launcher.shared.sessions.isEmpty && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { MainActor.assumeIsolated { run() } }
}
