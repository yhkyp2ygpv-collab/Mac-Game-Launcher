import AppKit
import SwiftUI

/// Starting a game from anywhere but its tile: the menu bar, the Dock menu, the Game
/// menu, a shortcut app in Applications, or an anvil:// link. Every one of them goes
/// through here, so they all behave exactly like pressing Play.
@MainActor
enum QuickLaunch {

    /// anvil://play/<game id> — what a shortcut app opens.
    static func url(for game: Game) -> URL {
        URL(string: "anvil://play/\(game.id.uuidString)")!
    }

    /// Games in quick-launch order: most recently played first, then the rest by title.
    static func recentGames(limit: Int = .max) -> [Game] {
        let games = Library.shared.games.sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        return Array(games.prefix(limit))
    }

    /// The game played most recently, for "Play Last Game".
    static var lastPlayed: Game? {
        Library.shared.games.filter { $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! }
    }

    /// Play, or bring the game forward if it is already running.
    static func play(_ game: Game) {
        let launcher = Launcher.shared
        if let running = launcher.session(for: game) {
            GameFocus.handOff(to: game, startedAt: running.startedAt)
            return
        }
        guard game.exists else {
            report("\(game.title) can't start", "Its executable is no longer at \(game.executablePath). If the game was moved or reinstalled, use Sync in the library, or open its settings and add it again.")
            return
        }
        guard engine(for: game) != nil else {
            report("\(game.title) can't start", "Its container or Wine engine is missing. Open Anvil and choose a container for it in its settings.")
            return
        }
        AnvilLog.write("quick launch: \(game.title)")
        // Online, offline, or once the connection is back — or another copy of it (AutoStart).
        AutoStart.shared.play(game) { start($0) }
    }

    /// A game's container and Wine engine, when both are there.
    static func engine(for game: Game) -> (container: Container, runtime: Runtime)? {
        guard let container = Library.shared.container(id: game.containerID),
              let runtime = RuntimeManager.shared.runtime(id: container.runtimeID)
                ?? RuntimeManager.shared.defaultRuntime else { return nil }
        return (container, runtime)
    }

    /// Start it now.
    private static func start(_ game: Game) {
        let launcher = Launcher.shared
        guard let engine = engine(for: game) else {
            report("\(game.title) can't start", "Its container or Wine engine is missing. Open Anvil and choose a container for it in its settings.")
            return
        }
        Task {
            do { try await launcher.prepareAndLaunch(game: game, container: engine.container, runtime: engine.runtime) }
            catch Launcher.LaunchError.alreadyStarting {
                AnvilLog.write("  quick launch ignored: another game is starting")
            } catch {
                report("\(game.title) didn't start", error.localizedDescription)
            }
        }
    }

    static func play(gameID: UUID) {
        guard let game = Library.shared.games.first(where: { $0.id == gameID }) else {
            report("That game isn't in Anvil any more",
                   "The shortcut or link you opened points to a game that has been removed from Anvil's library. Add the game again, then make a new shortcut from its settings.")
            return
        }
        play(game)
    }

    /// Handle an anvil:// link. Returns false for one Anvil does not understand.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "anvil" else { return false }
        // anvil://play/<id>: the host is the verb and the path holds the id.
        let verb = (url.host ?? "").lowercased()
        let argument = url.pathComponents.first { $0 != "/" } ?? ""
        switch verb {
        case "play":
            guard let id = UUID(uuidString: argument) else { return false }
            play(gameID: id)
            return true
        // anvil://add-to-steam/<id>: the game into Steam's library, as its page's Add to Steam's
        // Library does — Play in Steam then starts it through Anvil, offline as well for a game
        // that plays offline. Only once the player says yes: a link never changes Steam by itself.
        case "add-to-steam":
            guard let id = UUID(uuidString: argument), let game = Library.shared.games.first(where: { $0.id == id }) else { return false }
            NSApp.unhide(nil)
            NSApp.activate()
            let ask = NSAlert()
            ask.messageText = "Add \(game.title) to Steam's library?"
            ask.informativeText = "Play in Steam will start it through Anvil. Steam closes for a moment while it's added. You can take it out again in Settings › Steam."
            ask.addButton(withTitle: "Add to Steam")
            ask.addButton(withTitle: "Cancel")
            guard ask.runModal() == .alertFirstButtonReturn else {
                AnvilLog.write("steam: adding \(game.title) from a link — not wanted")
                return true
            }
            Task {
                do { _ = try await SteamShortcuts.add(game) }
                catch { report("\(game.title) wasn't added to Steam", error.localizedDescription) }
            }
            return true
        // anvil://offline-test/<id>, or /all: an Offline Test, as from the game's page or the Check-Up.
        case "offline-test":
            showMainWindow()
            if argument.lowercased() == "all" {
                OfflineTest.shared.testAll()
            } else if let id = UUID(uuidString: argument), let game = Library.shared.games.first(where: { $0.id == id }) {
                OfflineTest.shared.test(game)
            } else {
                return false
            }
            return true
        case "open", "":
            showMainWindow()
            return true
        default:
            return false
        }
    }

    /// SwiftUI's way to reopen the main window once it has been closed, kept from the
    /// first view that had it: the Dock menu and anvil:// links have no view of their own.
    static var openWindowAction: OpenWindowAction?

    /// Bring Anvil's window forward, reopening it if it was closed.
    static func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate()
        if let openWindowAction {
            // For a single-window scene this brings the window forward if it is open.
            openWindowAction(id: "main")
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Say why a launch from outside the window did not happen. Anvil may be hidden
    /// behind a game or not showing a window at all, so it comes forward first.
    static func report(_ title: String, _ message: String) {
        AnvilLog.write("quick launch: \(title) — \(message)")
        NSApp.unhide(nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
