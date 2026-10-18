import AppKit
import Foundation

/// Auto start: how Play starts a game that needs internet to start (OfflineStarts).
///
/// Such a game signs in to its store at every start and waits on its loading screen until it
/// can. LEGO Star Wars' Epic edition did on every one of its starts with no connection here
/// (1–10 October), however Anvil started it; a start from Steam's library is the same start,
/// through Anvil. Online it gets past it in about 20 seconds, and plays on if the connection
/// drops later. So:
///
/// - Online — the store answering — it starts at once, online: the start that works, with its
///   saves, Epic sign-in, FSR and everything else, even with Offline Mode on.
/// - Connected, but its store doesn't answer yet (a VPN still connecting, a network that wants
///   its sign-in page first): it waits until it does, instead of starting into its loading screen.
/// - No connection: another copy of the same game in the library that starts offline — its
///   Steam edition, in Steam's own Offline Mode — starts instead. With none, it waits, and
///   starts by itself as soon as the connection is back.
///
/// A game that starts offline, or hasn't been started offline here yet, starts as it always has.
/// Nothing here signs a game in or gets around its store's sign-in.
@MainActor
final class AutoStart: ObservableObject {
    static let shared = AutoStart()

    struct Waiting: Identifiable, Equatable {
        let id = UUID()
        let gameID: UUID
        let title: String
        let since: Date
        var reason: Reason
    }

    enum Reason: Equatable {
        case noConnection
        /// Connected, but the store the game signs in to doesn't answer.
        case storeUnreachable(String)

        var text: String {
            switch self {
            case .noConnection: "This Mac has no internet connection."
            case .storeUnreachable(let store): "Connected, but \(store) doesn't answer yet — a VPN still connecting, or a network that wants its sign-in page first."
            }
        }
    }

    enum Plan: Equatable {
        /// As it is: online, or a game that starts offline.
        case start
        /// Another copy of the same game, which starts offline.
        case startInstead(UUID)
        case wait(Reason)
    }

    /// The game being waited for, shown over Anvil's window with a way out.
    @Published private(set) var waiting: Waiting?
    /// The game whose page is open (a sheet): the panel is shown there rather than behind it.
    @Published var sheetGameID: UUID?

    /// Waited this long, it isn't started after all: a start long after Play would surprise.
    static let longestWait: TimeInterval = 30 * 60

    private var startWaiting: ((Game) -> Void)?
    private var watcher: Task<Void, Never>?

    // MARK: Deciding

    /// What Play does, from the game's record and the connection. `storeReachable` is nil when
    /// it wasn't looked at: no connection, or a game that doesn't sign in to a store at start.
    nonisolated static func plan(for game: Game, in games: [Game], networkUp: Bool, storeReachable: Bool?) -> Plan {
        guard OfflineStarts.needsConnection(game) else { return .start }
        if networkUp {
            if storeReachable == false { return .wait(.storeUnreachable(storeName(of: game))) }
            return .start
        }
        if let other = otherCopy(of: game, in: games) { return .startInstead(other.id) }
        return .wait(.noConnection)
    }

    /// Another copy of the same game in the library that starts offline: from another store, or
    /// installed again elsewhere. One that has played offline here first, then a Steam copy.
    nonisolated static func otherCopy(of game: Game, in games: [Game]) -> Game? {
        let key = titleKey(game.title)
        guard !key.isEmpty else { return nil }
        let copies = games.filter { other in
            other.id != game.id && titleKey(other.title) == key && !isStoreApp(other)
                && !OfflineStarts.needsConnection(other) && other.exists
        }
        func rank(_ g: Game) -> Int { (g.offlineRecord?.playedOffline == true ? 0 : 2) + (g.steamAppID != nil ? 0 : 1) }
        return copies.min { rank($0) < rank($1) }
    }

    /// A title as it compares across stores: letters and digits only, without ® and ™.
    nonisolated static func titleKey(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    nonisolated static func isStoreApp(_ game: Game) -> Bool {
        let exe = game.executableURL.lastPathComponent.lowercased()
        return exe == "steam.exe" || exe == "epicgameslauncher.exe"
    }

    /// Whether Play signs the game in to Epic, so Epic answering is what an online start needs.
    nonisolated static func signsInToEpic(_ game: Game) -> Bool {
        game.epicSignIn && (game.epicAppName != nil || game.offlineRecord?.viaEpic == true)
    }

    nonisolated static func storeName(of game: Game) -> String {
        signsInToEpic(game) ? "Epic" : game.steamAppID != nil ? "Steam" : "its store"
    }

    /// What Auto start does with the game right now, for its page.
    nonisolated static func summary(for game: Game, in games: [Game], networkUp: Bool) -> String? {
        guard OfflineStarts.needsConnection(game) else { return nil }
        if networkUp {
            return "Online now, so Play starts it online at once — the start that gets past its loading screen — even with Offline Mode on. If \(storeName(of: game)) doesn't answer yet, Anvil waits until it does."
        }
        if let other = otherCopy(of: game, in: games) {
            return "No internet now, so Play starts your other copy, “\(other.title)”\(other.steamAppID != nil ? " from Steam" : ""), which starts offline. Its saves are its own."
        }
        return "No internet now, so Play waits and starts it by itself as soon as the connection is back — with its saves, FSR and everything else as usual."
    }

    // MARK: Playing

    /// Play, the Auto start way. `start` starts the game it's given now — this one, or another
    /// copy of it — and may be called later, once a connection is back.
    func play(_ game: Game, start: @escaping (Game) -> Void) {
        if Launcher.shared.session(for: game) != nil { start(game); return }
        if waiting?.gameID == game.id { QuickLaunch.showMainWindow(); return }
        if let w = waiting {
            AnvilLog.write("auto start: \(w.title) — no longer waited for: \(game.title) started instead")
            stopWaiting()
        }
        guard OfflineStarts.needsConnection(game) else { start(game); return }
        Task {
            let networkUp = Connectivity.networkUpNow
            let reachable: Bool? = networkUp && Self.signsInToEpic(game)
                ? await Connectivity.reaches(Launcher.epicAccounts, timeout: 3) : nil
            let games = Library.shared.games
            switch Self.plan(for: game, in: games, networkUp: Connectivity.networkUpNow, storeReachable: reachable) {
            case .start:
                AnvilLog.write("auto start: \(game.title) needs internet to start — online, so started online")
                start(game)
            case .startInstead(let id):
                guard let other = games.first(where: { $0.id == id }) else { start(game); return }
                AnvilLog.write("auto start: \(game.title) needs internet to start and this Mac has none — started its other copy “\(other.title)” (\(other.executablePath)), which starts offline")
                Launcher.shared.note("\(game.title) needs internet to start, so its other copy — “\(other.title)”, which starts offline — was started instead. Its saves are its own.")
                start(other)
            case .wait(let reason):
                beginWaiting(for: game, reason: reason, start: start)
            }
        }
    }

    private func beginWaiting(for game: Game, reason: Reason, start: @escaping (Game) -> Void) {
        waiting = Waiting(gameID: game.id, title: game.title, since: Date(), reason: reason)
        startWaiting = start
        AnvilLog.write("auto start: \(game.title) needs internet to start — waiting to start it once \(reason == .noConnection ? "there's a connection" : "\(Self.storeName(of: game)) answers"): \(reason.text)")
        QuickLaunch.showMainWindow()
        let id = game.id
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, let w = self.waiting, w.gameID == id else { return }
                let waited = Date().timeIntervalSince(w.since)
                if waited > Self.longestWait {
                    AnvilLog.write("auto start: \(w.title) — no connection after \(Int(Self.longestWait / 60)) minutes; not started")
                    self.stopWaiting()
                    GameReady.shared.say("\(w.title) wasn't started",
                                         "There was no internet for \(Int(Self.longestWait / 60)) minutes. Press Play again once you're online.",
                                         id: "auto-start-\(id.uuidString)")
                    return
                }
                guard Connectivity.networkUpNow else {
                    if w.reason != .noConnection { self.waiting?.reason = .noConnection }
                    continue
                }
                let current = Library.shared.games.first { $0.id == id }
                if let current, Self.signsInToEpic(current),
                   !(await Connectivity.reaches(Launcher.epicAccounts, timeout: 3)) {
                    guard self.waiting?.gameID == id else { return }
                    self.waiting?.reason = .storeUnreachable(Self.storeName(of: current))
                    continue
                }
                guard self.waiting?.gameID == id, let current else { return }
                let start = self.startWaiting
                self.stopWaiting()
                AnvilLog.write("auto start: \(current.title) — online after \(Int(waited)) s of waiting; started online")
                GameReady.shared.say("Starting \(current.title)", "You're back online, so it's starting now.", id: "auto-start-\(id.uuidString)")
                start?(current)
                return
            }
        }
    }

    /// Start Offline Anyway: the game's offline start, as it would be with Auto start off.
    func startOfflineAnyway() {
        guard let w = waiting, let game = Library.shared.games.first(where: { $0.id == w.gameID }) else { stopWaiting(); return }
        let start = startWaiting
        stopWaiting()
        AnvilLog.write("auto start: \(w.title) — started offline anyway, from the wait")
        start?(game)
    }

    func cancel() {
        guard let w = waiting else { return }
        AnvilLog.write("auto start: \(w.title) — waiting cancelled after \(Int(Date().timeIntervalSince(w.since))) s")
        stopWaiting()
    }

    private func stopWaiting() {
        watcher?.cancel()
        watcher = nil
        waiting = nil
        startWaiting = nil
    }
}
