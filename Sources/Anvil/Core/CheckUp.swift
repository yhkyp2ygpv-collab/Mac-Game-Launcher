import Foundation
import Darwin

/// Anvil looking over everything it depends on, and putting right what it safely can —
/// with or without a connection.
///
/// The Doctor (GameDoctor) reads each game's sessions; this reads the rest: whether every
/// Epic game can start offline, whether the sign-in is there, whether every container's saves
/// have a recent copy, whether the engines are as they were sealed, whether anything Anvil
/// started is still running with nothing to show for it, and the Mac itself — Rosetta, room
/// on the disk. It runs by itself when Anvil starts and whenever it is opened. What it fixes by
/// itself is only what can't hurt: a copy of saves, an offline start made ready (legendary's
/// offline answer, which reaches nothing), a stale file of Anvil's own. Anything that stops a
/// program or needs the player stays a button.
@MainActor
final class CheckUp: ObservableObject {
    static let shared = CheckUp()

    struct Item: Identifiable, Hashable {
        enum State: Int { case problem = 0, fixed, advice, ok }
        var id: String
        var state: State
        var title: String
        var detail: String
        var action: Action?
    }

    enum Action: String, Hashable {
        case epicSignIn
        case stopLeftovers
        case showEngines
        case testOffline

        var label: String {
            switch self {
            case .epicSignIn: "Sign In to Epic…"
            case .stopLeftovers: "Stop Them"
            case .showEngines: "Show Engines"
            case .testOffline: "Test Them Offline"
            }
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var running = false
    @Published private(set) var checkedAt: Date?
    /// Problems still open, for the sidebar.
    var attention: Int { items.filter { $0.state == .problem }.count }

    /// Wine servers from Anvil's engines with no game of Anvil's behind them, found by the
    /// last check: prefix → that server's own program.
    private var leftovers: [String: URL] = [:]

    private init() {}

    /// Guardian, between games: the check-up again every three hours while Anvil is open and no game is
    /// running — a disk filling up, an engine changed, a sign-in that ran out, a program left behind — so
    /// what's wrong is found before the next game, not by it. Started once, by Autopilot at launch.
    private var watching = false
    func watchWhileOpen(every hours: Double = 3) {
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(hours * 3600))
                guard Launcher.shared.sessions.isEmpty else { continue }
                AnvilLog.write("guardian: the check-up again — Anvil open, no game running, \(Int(hours)) hours on")
                await run()
            }
        }
    }

    // MARK: Running the checks

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false; checkedAt = Date() }
        var out: [Item] = []
        out += macChecks()
        out += gameFileChecks()
        out += await epicChecks()
        out += offlineChecks()
        out += await saveChecks()
        out += await engineChecks()
        out += leftoverChecks()
        out += sessionChecks()
        tidyOfflineFlags()
        warmKeepRunning()
        items = out.sorted { ($0.state.rawValue, $0.title) < ($1.state.rawValue, $1.title) }
        let summary = items.filter { $0.state != .ok }.map { "\($0.state):\($0.id)" }
        AnvilLog.write("check-up: \(items.filter { $0.state == .ok }.count) fine"
                       + (summary.isEmpty ? "" : " [" + summary.joined(separator: ", ") + "]"))
    }

    // MARK: The Mac

    private func macChecks() -> [Item] {
        var out: [Item] = []
        let intelOnly = RuntimeManager.shared.runtimes.contains { $0.isUsable && SystemInfo.needsRosetta($0.wine64) }
        if intelOnly && !SystemInfo.rosettaWorks() {
            out.append(Item(id: "rosetta", state: .problem, title: "Rosetta isn't installed",
                            detail: "Anvil's engines are Intel programs, which Apple silicon runs through Rosetta. Install it from Terminal with: softwareupdate --install-rosetta --agree-to-license"))
        }
        if let free = SaveGuard.freeSpace(at: RuntimeManager.support) {
            if free < SaveGuard.launchMinimum {
                out.append(Item(id: "disk", state: .problem, title: "The disk is almost full",
                                detail: "Only \(SaveGuard.sizeText(free)) free. Games won't start below 1 GB, so no save is written onto a full disk. Empty the Trash or move large files off this Mac."))
            } else if free < 5 * 1_073_741_824 {
                out.append(Item(id: "disk", state: .advice, title: "Little room on the disk",
                                detail: "\(SaveGuard.sizeText(free)) free. Games, their updates and their saves need room; free some space soon."))
            } else {
                out.append(Item(id: "disk", state: .ok, title: "Room on the disk", detail: "\(SaveGuard.sizeText(free)) free."))
            }
        }
        return out
    }

    private func gameFileChecks() -> [Item] {
        let missing = Library.shared.games.filter { !$0.exists }.map(\.title)
        guard !missing.isEmpty else {
            return [Item(id: "games", state: .ok, title: "Every game's program is where it was",
                         detail: "\(Library.shared.games.count) game\(Library.shared.games.count == 1 ? "" : "s").")]
        }
        return [Item(id: "games", state: .problem, title: "\(missing.count == 1 ? "A game's" : "\(missing.count) games'") program can't be found",
                     detail: "\(missing.joined(separator: ", ")): moved, renamed or uninstalled. Point the game at its program again from its settings, or install it again.")]
    }

    // MARK: Epic

    private func epicChecks() async -> [Item] {
        var out: [Item] = []
        let games = Library.shared.games.filter { $0.epicSignIn }
        let links = games.compactMap { g in EpicLink.find(for: g).map { (g, $0) } }
        guard !links.isEmpty else { return out }

        func signedIn(_ link: EpicLink) -> Bool {
            link.launcher == "Anvil" ? EpicAccount.isSignedIn
                : FileManager.default.fileExists(atPath: link.configDir.appendingPathComponent("user.json").path)
        }
        let unsigned = links.filter { !signedIn($0.1) }
        if unsigned.isEmpty {
            out.append(Item(id: "epic-sign-in", state: .ok, title: "Signed in to Epic",
                            detail: "Through \(Set(links.map(\.1.launcher)).sorted().joined(separator: " and "))."))
        } else {
            out.append(Item(id: "epic-sign-in", state: .problem, title: "Epic isn't signed in",
                            detail: "\(unsigned.map(\.0.title).joined(separator: ", ")) start without your Epic account until it is, so saves tied to the account and DLC don't appear. Sign in once, while online; after that games start offline as well.",
                            action: .epicSignIn))
        }

        // Every Epic game ready to start offline, from Anvil's sealed copy. Made here when it
        // is missing: legendary's offline answer reaches nothing, so this works offline too.
        var ready: [String] = [], made: [String] = [], notYet: [String] = []
        for (game, link) in links {
            if EpicOfflineStart.arguments(appName: link.appName) != nil { ready.append(game.title); continue }
            guard signedIn(link), !Launcher.shared.isBusy(game),
                  let container = Library.shared.container(id: game.containerID),
                  let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) ?? RuntimeManager.shared.defaultRuntime else {
                notYet.append(game.title); continue
            }
            if let args = try? await link.signInArguments(wine: runtime.wine64, offline: true, timeout: 20) {
                EpicOfflineStart.remember(args, appName: link.appName)
            }
            if EpicOfflineStart.arguments(appName: link.appName) != nil {
                made.append(game.title)
                AnvilLog.write("check-up: \(game.title) made ready to start offline")
            } else {
                notYet.append(game.title)
            }
        }
        if !made.isEmpty {
            out.append(Item(id: "epic-offline", state: .fixed, title: "Made ready to start offline",
                            detail: "\(made.joined(separator: ", ")) can now start with no connection, as your account, with your saves."))
        }
        if !notYet.isEmpty {
            out.append(Item(id: "epic-offline-missing", state: .advice, title: "Not ready to start offline yet",
                            detail: "\(notYet.joined(separator: ", ")): sign in to Epic, or play once online, and Anvil keeps what an offline start needs."))
        } else if made.isEmpty {
            out.append(Item(id: "epic-offline", state: .ok, title: "Every Epic game's offline start is ready",
                            detail: "\(ready.joined(separator: ", ")) start with no connection as your account, so they find your saves. Whether each then plays offline is the game's own — see Offline."))
        }
        return out
    }

    // MARK: Offline

    /// Every game, by how it does with no connection: plays, needs internet to start, not known
    /// yet — with Offline Tests to find out while there's a connection — and Steam's readiness
    /// for its own Offline Mode.
    private func offlineChecks() -> [Item] {
        var out: [Item] = []
        let games = Library.shared.games.filter { !AutoStart.isStoreApp($0) && $0.exists }
        let plays = games.filter { $0.offlineRecord?.playedOffline == true }
        let needs = games.filter(OfflineStarts.needsConnection)
        let unclear = games.filter { g in
            guard let t = g.offlineRecord?.test else { return false }
            return t.verdict == .unclear && !t.confirmedByPlayer && !plays.contains(g) && !needs.contains(g)
        }
        let untested = OfflineTest.untested(games).filter { !unclear.contains($0) }
        if !plays.isEmpty {
            out.append(Item(id: "offline-plays", state: .ok, title: "Play\(plays.count == 1 ? "s" : "") offline",
                            detail: plays.map(\.title).joined(separator: ", ") + " — started with no connection here, or in an Offline Test, and got going."))
        }
        if !needs.isEmpty {
            out.append(Item(id: "offline-needs", state: .advice, title: "Need\(needs.count == 1 ? "s" : "") internet to start",
                            detail: needs.map(\.title).joined(separator: ", ") + ": sign\(needs.count == 1 ? "s" : "") in to \(needs.count == 1 ? "its" : "their") store as \(needs.count == 1 ? "it starts" : "they start") and wait\(needs.count == 1 ? "s" : "") until \(needs.count == 1 ? "it" : "they") can. Auto start starts \(needs.count == 1 ? "it" : "them") online whenever there's a connection, and with none waits and starts \(needs.count == 1 ? "it" : "them") once it's back. Once past the loading screen, \(needs.count == 1 ? "it plays" : "they play") on offline."))
        }
        if !unclear.isEmpty {
            out.append(Item(id: "offline-unclear", state: .advice, title: "Offline Test couldn't tell",
                            detail: unclear.map(\.title).joined(separator: ", ") + ": look at the picture on \(unclear.count == 1 ? "its" : "each") page and say whether it got going."))
        }
        if !untested.isEmpty {
            let busy = OfflineTest.shared.run != nil
            out.append(Item(id: "offline-untested", state: .advice, title: "Not tested offline yet",
                            detail: untested.map(\.title).joined(separator: ", ") + ": an Offline Test starts \(untested.count == 1 ? "it" : "each") as with no connection, its own connections held back while the Mac stays online, watches it for about a minute, closes it and says whether it plays offline. One at a time; nothing else should be running."
                                + (busy ? " A test is running now." : ""),
                            action: busy || !Launcher.shared.sessions.isEmpty ? nil : .testOffline))
        }
        // Steam: its own Offline Mode, which needs a remembered sign-in and games up to date.
        for container in SteamSupport.shared.containers {
            guard let remembered = SteamSupport.rememberedSignIn(in: container) else { continue }
            let notReady = SteamSupport.installedGames(in: container).filter { !$0.ready }.map(\.name)
            if !remembered {
                out.append(Item(id: "steam-offline-\(container.id)", state: .advice, title: "Steam can't start offline yet",
                                detail: "Steam in “\(container.name)” has no sign-in it remembers. Sign in once with “Remember me” ticked, while online; then Steam can start in its Offline Mode, and its games with it."))
            } else if !notReady.isEmpty {
                out.append(Item(id: "steam-offline-\(container.id)", state: .advice, title: "Steam games waiting for an update",
                                detail: notReady.joined(separator: ", ") + ": Steam won't start a game offline until its update or download finishes. Open Steam while online and let it finish."))
            } else {
                out.append(Item(id: "steam-offline-\(container.id)", state: .ok, title: "Steam is ready to start offline",
                                detail: "In “\(container.name)”: signed in with “Remember me”\(SteamSupport.installedGames(in: container).isEmpty ? "" : ", every game up to date"). With no connection Steam offers its Offline Mode as it starts."))
            }
        }
        return out
    }

    // MARK: Saves

    private func saveChecks() async -> [Item] {
        let week: TimeInterval = 7 * 86_400
        var copied: [String] = [], failed: [String] = [], fine = 0
        for container in Library.shared.containers where !Library.shared.games(in: container).isEmpty {
            if Launcher.shared.sessions.contains(where: { $0.container.id == container.id }) { fine += 1; continue }
            let id = container.id, name = container.name, prefix = container.prefixURL
            let names = SaveGuard.gameNames(in: container)
            let last = await Task.detached(priority: .utility) { SaveGuard.list(for: id).first?.date }.value
            if let last, Date().timeIntervalSince(last) < week { fine += 1; continue }
            let outcome = await Task.detached(priority: .utility) {
                SaveGuard.backUp(prefix: prefix, containerID: id, containerName: name, reason: "Check-up", games: names)
            }.value
            switch outcome {
            case .made: copied.append(name)
            case .failed: failed.append(name)
            default: fine += 1
            }
        }
        var out: [Item] = []
        if !copied.isEmpty {
            out.append(Item(id: "saves-copied", state: .fixed, title: "Saves copied",
                            detail: "\(copied.joined(separator: ", ")) had no copy of their saves from the last week; there is one now, in Save Backups."))
        }
        if !failed.isEmpty {
            out.append(Item(id: "saves-failed", state: .problem, title: "Saves couldn't be copied",
                            detail: "\(failed.joined(separator: ", ")): the copy didn't finish — usually a full disk. Each game's saves are still copied before it starts."))
        }
        if copied.isEmpty && failed.isEmpty {
            out.append(Item(id: "saves", state: .ok, title: "Every container's saves have a recent copy",
                            detail: "Copied before every game and kept for a month, in Save Backups."))
        }
        return out
    }

    // MARK: Engines

    private func engineChecks() async -> [Item] {
        let managed = RuntimeManager.shared.runtimes.filter { $0.isManaged && $0.isUsable }
        guard !managed.isEmpty else { return [] }
        var changed: [String] = []
        for r in managed {
            let root = r.root, id = r.id
            let verdict = await Task.detached(priority: .utility) { EngineSeal.check(root: root, id: id, full: false) }.value
            if case .changed = verdict { changed.append(r.displayName) }
        }
        if changed.isEmpty {
            return [Item(id: "engines", state: .ok, title: "Every engine is as it was sealed",
                         detail: managed.map(\.displayName).joined(separator: ", ") + ".")]
        }
        return [Item(id: "engines", state: .problem, title: "\(changed.joined(separator: ", ")) changed since it was sealed",
                     detail: "Files in it differ from when Anvil installed it, so games won't start on it. Install it again from Engines; games and saves aren't touched.",
                     action: .showEngines)]
    }

    // MARK: Programs left running

    private func leftoverChecks() -> [Item] {
        leftovers = [:]
        let inUse = Set(Launcher.shared.sessions.map { $0.container.prefixURL.standardizedFileURL.path })
        let steam = Set(Library.shared.containers.filter { SteamSupport.shared.clientRunning(in: $0) }.map { $0.prefixURL.standardizedFileURL.path })
        guard Launcher.shared.launching == nil else { return [] }
        for server in Self.anvilWineServers() {
            guard let prefix = server.prefix else { continue }
            let path = URL(fileURLWithPath: prefix).standardizedFileURL.path
            if inUse.contains(path) || steam.contains(path) { continue }
            leftovers[path] = server.program
        }
        guard !leftovers.isEmpty else { return [] }
        let names = leftovers.keys.map { p in Library.shared.containers.first { $0.prefixURL.standardizedFileURL.path == p }?.name ?? URL(fileURLWithPath: p).lastPathComponent }
        return [Item(id: "leftovers", state: .problem, title: "Windows programs still running with no game",
                     detail: "In \(names.sorted().joined(separator: ", ")): left from a game Anvil no longer has open. They take memory and can keep the next start from working. Stopping them asks Wine to close everything there properly.",
                     action: .stopLeftovers)]
    }

    struct WineServer { var pid: pid_t; var program: URL; var prefix: String? }

    /// Wine servers running from Anvil's own engines, with the prefix each serves.
    nonisolated static func anvilWineServers(under root: URL = RuntimeManager.support) -> [WineServer] {
        let support = root.standardizedFileURL.path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [WineServer] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            guard path.hasPrefix(support), (path as NSString).lastPathComponent == "wineserver" else { continue }
            out.append(WineServer(pid: pid, program: URL(fileURLWithPath: path), prefix: environment(of: pid)["WINEPREFIX"]))
        }
        return out
    }

    /// Another process's environment, for one of this user's own (KERN_PROCARGS2).
    nonisolated static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > 4 else { return [:] }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && data[i] != 0 { i += 1 }        // the program's path
        while i < size && data[i] == 0 { i += 1 }        // its padding
        var strings: [String] = []
        var start = i
        while i < size {
            if data[i] == 0 {
                if i > start { strings.append(String(decoding: data[start..<i], as: UTF8.self)) }
                start = i + 1
            }
            i += 1
        }
        var env: [String: String] = [:]
        for entry in strings.dropFirst(Int(argc)) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    /// Ask each leftover prefix's own Wine server to close everything in it.
    func stopLeftovers() async {
        let found = leftovers
        for (prefix, program) in found {
            await Task.detached(priority: .userInitiated) {
                let p = Process()
                p.executableURL = program
                p.arguments = ["-k"]
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = prefix
                env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }.value
            AnvilLog.write("check-up: stopped what was left running in \(prefix)")
        }
        await run()
    }

    // MARK: Games' last sessions

    private func sessionChecks() -> [Item] {
        let open = Library.shared.games.compactMap { g -> (String, Int)? in
            guard let r = Autopilot.shared.report(for: g), r.problems > 0 else { return nil }
            return (g.title, r.problems)
        }
        guard !open.isEmpty else {
            return [Item(id: "sessions", state: .ok, title: "Every game's last session checked out",
                         detail: "Anvil reads each session when it ends and puts right what it safely can.")]
        }
        return [Item(id: "sessions", state: .advice, title: "Something to look at from the last sessions",
                     detail: open.map { "\($0.0): \($0.1) thing\($0.1 == 1 ? "" : "s")" }.joined(separator: "; ") + " — on each game's Overview.")]
    }

    // MARK: Quiet upkeep

    /// Offline-session files left by a session that didn't end through Anvil.
    private func tidyOfflineFlags() {
        let dir = RuntimeManager.support.appendingPathComponent("Cache/Offline")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let running = Set(Launcher.shared.sessions.map { $0.container.id.uuidString })
        for name in names where !running.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Read each game's program for its keep-running switch now, so its first start doesn't.
    private func warmKeepRunning() {
        let exes = Library.shared.games.filter(\.exists).map(\.executableURL)
        Task.detached(priority: .background) { for exe in exes { _ = KeepRunning.supportedSwitch(for: exe) } }
    }
}
