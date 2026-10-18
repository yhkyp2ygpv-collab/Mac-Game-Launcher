import Foundation

/// Persistence for containers and games, plus prefix lifecycle.
@MainActor
final class Library: ObservableObject {
    @Published var containers: [Container] = []
    @Published var games: [Game] = []
    @Published var busyMessage: String?
    @Published var lastError: String?

    static let shared = Library()

    private var storeURL: URL { RuntimeManager.support.appendingPathComponent("library.json") }
    /// Copies of library.json, at most one an hour, the newest twenty kept.
    nonisolated static var backupsDir: URL { RuntimeManager.support.appendingPathComponent("Library Backups", isDirectory: true) }
    /// Set when library.json is there but couldn't be read: nothing is written over it.
    private var readOnly = false
    /// Set by a removal the user asked for, the one way an empty library may be saved
    /// over one that has something in it.
    private var emptyingAllowed = false

    private init() { load() }

    // MARK: Persistence

    private struct Store: Codable { var containers: [Container]; var games: [Game] }

    func load() {
        let data: Data
        do { data = try Data(contentsOf: storeURL) } catch {
            if FileManager.default.fileExists(atPath: storeURL.path) {
                // There, but not readable just now. Saving anything over it would be how a
                // library is lost: leave it alone until Anvil is opened again.
                readOnly = true
                lastError = "Anvil couldn't read your library just now (\(error.localizedDescription)), so it won't save over it. Quit and open Anvil again."
                AnvilLog.write("library: library.json couldn't be read (\(error.localizedDescription)) — not saving over it this session")
                return
            }
            // Nothing to load. If an earlier build set a library aside as unreadable,
            // recover it now rather than presenting an empty library — the fault that
            // caused it is fixed, and the games in it are still installed.
            recoverQuarantinedLibrary()
            if games.isEmpty && containers.isEmpty { recoverFromBackup() }
            return
        }
        apply(data, from: storeURL)
        if games.isEmpty && containers.isEmpty && lastError != nil { recoverFromBackup() }
        ownLookToMedium()
    }

    /// 0.52, once, coming from 0.51 (which only ever ran on its maker's Mac): a game 0.51's Look Check put at its
    /// own look (Full) goes to Medium, which since 0.52 keeps its reflections and turns its water and heat
    /// distortion off — with it on, LEGO Star Wars' picture distorted under FSR 3 and Smooth Motion (15 October).
    /// Full is still one button away, in the Look Check and on the Graphics page.
    private func ownLookToMedium() {
        let defaults = UserDefaults.standard
        let done = "anvil.ownLookToMedium052"
        guard !readOnly, !defaults.bool(forKey: done), defaults.string(forKey: "anvil.lastSeenVersion") == "0.51.0" else { return }
        defaults.set(true, forKey: done)
        var changed = false
        for i in games.indices where games[i].graphicsTuning == .gameDefault && GameTuning.profile(for: games[i]) != nil {
            games[i].graphicsTuning = .medium
            changed = true
            AnvilLog.write("graphics: \(games[i].title) — from the game's own look to Medium: its reflections kept, its water and heat distortion off (they warped the picture under FSR 3 and Smooth Motion)")
        }
        if changed { save() }
    }

    /// The newest copy in Library Backups, when library.json is gone or held nothing readable.
    private func recoverFromBackup() {
        let fm = FileManager.default
        let copies = ((try? fm.contentsOfDirectory(at: Self.backupsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("library-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for copy in copies {
            guard let data = try? Data(contentsOf: copy),
                  let store = try? JSONDecoder().decode(Store.self, from: data),
                  !store.games.isEmpty || !store.containers.isEmpty else { continue }
            containers = store.containers
            games = store.games
            lastError = "Your library was missing, so Anvil brought back its copy from \(copy.deletingPathExtension().lastPathComponent.dropFirst(8)):00 — \(games.count) game\(games.count == 1 ? "" : "s")."
            AnvilLog.write("library: recovered \(games.count) games and \(containers.count) containers from \(copy.lastPathComponent)")
            save()
            return
        }
    }

    /// Decode a library file, keeping every record that survives.
    private func apply(_ data: Data, from url: URL) {
        // Fast path: a current-format file.
        if let store = try? JSONDecoder().decode(Store.self, from: data) {
            containers = store.containers
            games = store.games
            return
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Only a file that is not JSON at all is set aside. Anything that parses
            // gets salvaged below, however old it is.
            let backup = storeURL.deletingLastPathComponent()
                .appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            lastError = """
                Anvil couldn't read your library and has set it aside as \(backup.lastPathComponent) \
                rather than overwrite it. Your containers and games are still on disk.
                """
            return
        }

        let c = Migration.salvage(Container.self, from: root["containers"],
                                  default: Container(name: "", runtimeID: ""))
        let g = Migration.salvage(Game.self, from: root["games"],
                                  default: Game(title: "", executablePath: "", containerID: UUID()))
        containers = c.kept
        games = g.kept

        if c.lost + g.lost > 0 {
            lastError = "\(c.lost + g.lost) entr\(c.lost + g.lost == 1 ? "y" : "ies") in your library could not be read and were skipped. Everything else was kept."
        }
        // Write the repaired library back so the salvage only has to happen once.
        if !containers.isEmpty || !games.isEmpty { save() }
    }

    /// Bring back the newest library an earlier build quarantined.
    private func recoverQuarantinedLibrary() {
        let dir = storeURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        let quarantined = entries
            .filter { $0.lastPathComponent.hasPrefix("library-unreadable-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }

        for file in quarantined {
            guard let data = try? Data(contentsOf: file) else { continue }
            apply(data, from: file)
            if !games.isEmpty || !containers.isEmpty {
                lastError = "Recovered \(games.count) game\(games.count == 1 ? "" : "s") from a library an earlier version could not read."
                save()
                return
            }
        }
    }

    func save() {
        guard !readOnly else { return }
        let fm = FileManager.default
        // An empty library never replaces one with games in it, unless that is what the
        // user just did.
        if containers.isEmpty && games.isEmpty && !emptyingAllowed,
           let old = try? Data(contentsOf: storeURL), let held = try? JSONDecoder().decode(Store.self, from: old),
           !held.games.isEmpty || !held.containers.isEmpty {
            AnvilLog.write("library: not saving an empty library over one with \(held.games.count) games")
            return
        }
        emptyingAllowed = false
        let store = Store(containers: containers, games: games)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        keepCopy(of: storeURL)
        guard DiskCache.writeReplacing(data, to: storeURL, durable: true) else {
            if fm.fileExists(atPath: storeURL.path) { try? data.write(to: storeURL, options: .atomic) }
            else { try? data.write(to: storeURL) }
            return
        }
    }

    /// The library as it was, at most once an hour: what a bad save, a bug or a mistaken
    /// removal can be undone from. The newest twenty are kept.
    private func keepCopy(of url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH"
        let name = "library-\(f.string(from: Date())).json"
        let dest = Self.backupsDir.appendingPathComponent(name)
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: Self.backupsDir, withIntermediateDirectories: true)
        _ = SaveGuard.copy(url, to: dest)
        let copies = ((try? fm.contentsOfDirectory(atPath: Self.backupsDir.path)) ?? [])
            .filter { $0.hasPrefix("library-") }.sorted(by: >)
        for old in copies.dropFirst(20) { try? fm.removeItem(at: Self.backupsDir.appendingPathComponent(old)) }
    }

    func container(id: UUID) -> Container? { containers.first { $0.id == id } }

    func update(_ container: Container) {
        guard let idx = containers.firstIndex(where: { $0.id == container.id }) else { return }
        containers[idx] = container
        save()
    }

    func update(_ game: Game) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx] = game
        save()
    }

    func games(in container: Container) -> [Game] {
        games.filter { $0.containerID == container.id }
    }

    // MARK: Containers

    /// Create the prefix on disk. `wineboot` is run once to populate the registry and
    /// system DLLs; until it completes the prefix is not safe to launch into.
    @discardableResult
    func createContainer(named name: String, runtime: Runtime,
                         configure: (inout Container) -> Void = { _ in }) async -> Container? {
        var container = Container.performanceDefault(name: name, runtimeID: runtime.id)
        configure(&container)
        busyMessage = "Creating “\(name)” — initialising Windows environment…"
        defer { busyMessage = nil }

        do {
            try FileManager.default.createDirectory(at: container.prefixURL, withIntermediateDirectories: true)
            try await runWineboot(prefix: container.prefixURL, runtime: runtime)
            try? await applyWindowsVersion(container.windowsVersion, prefix: container.prefixURL, runtime: runtime)
            // Retina mode and DPI are registry keys, not environment variables. Anvil
            // set them as environment variables for a long time, which is why games
            // kept being handed a low-DPI display no matter what the UI said.
            _ = try? await Prefix.prepare(container: container, runtime: runtime)
            await configureControllers(in: container, runtime: runtime)
            containers.append(container)
            save()
            return container
        } catch {
            // Never leave a half-initialised prefix behind — that is exactly the state
            // that later reads as "corrupt game files".
            try? FileManager.default.removeItem(at: container.prefixURL)
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Store containers Anvil made that hold no games — the empty "Epic Games" containers
    /// 0.19.0 could make several of at once — go to the Trash. Only ones Anvil made for a
    /// store, never one the user made or one with anything in its library.
    func tidyEmptyStoreContainers() {
        let empty = containers.filter { c in
            c.storefront == "epic" && !games.contains { $0.containerID == c.id }
                && SaveGuard.items(in: c.driveC).isEmpty
        }
        for c in empty { deleteContainer(c) }
        if !empty.isEmpty {
            AnvilLog.write("library: \(empty.count) empty Epic container(s) made by mistake moved to the Trash")
        }
    }

    /// Remove a container and its games from the library. The prefix — with every save
    /// its games kept inside it — goes to the Trash rather than being erased, so a
    /// mistaken delete can still be undone from Finder.
    func deleteContainer(_ container: Container) {
        let fm = FileManager.default
        // Its saves first, somewhere the Trash being emptied doesn't reach.
        if fm.fileExists(atPath: container.prefixURL.path) {
            let saved = SaveGuard.backUp(prefix: container.prefixURL, containerID: container.id,
                                         containerName: container.name, reason: "Before “\(container.name)” was deleted", force: true,
                                         games: SaveGuard.gameNames(in: container))
            AnvilLog.write("container delete: \(saved.logLine)")
        }
        for game in games where game.containerID == container.id { ShortcutStore.shared.remove(for: game) }
        games.removeAll { $0.containerID == container.id }
        containers.removeAll { $0.id == container.id }
        emptyingAllowed = true
        if fm.fileExists(atPath: container.prefixURL.path) {
            do { try fm.trashItem(at: container.prefixURL, resultingItemURL: nil) }
            catch {
                // Never erased outright: set aside where it can still be found.
                let aside = RuntimeManager.support.appendingPathComponent("Removed Containers", isDirectory: true)
                try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
                let dest = aside.appendingPathComponent("\(container.name) \(Int(Date().timeIntervalSince1970))")
                do { try fm.moveItem(at: container.prefixURL, to: dest) }
                catch { AnvilLog.write("container delete: \(container.name)'s folder couldn't be moved (\(error.localizedDescription)) — left where it was") }
            }
        }
        // Rebuilt by the next game that runs; nothing of the user's is in it.
        try? fm.removeItem(at: container.shaderCacheURL)
        save()
        AnvilLog.write("container deleted: \(container.name) — prefix moved to the Trash")
    }

    private func runWineboot(prefix: URL, runtime: Runtime) async throws {
        try await run(runtime.wine64, args: ["wineboot", "--init"],
                      env: ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all"])
    }

    /// Wire up controller support inside a prefix.
    ///
    /// Wine ships winexinput.sys and the xinput DLLs, but a fresh prefix has no
    /// DirectInput key at all — so a pad is enumerated as a plain HID joystick and
    /// never mapped to XInput, which is what Unity and most modern games actually
    /// read. That single missing key is the difference between a controller that
    /// works and one the game never notices.
    func configureControllers(in container: Container, runtime: Runtime) async {
        busyMessage = "Configuring controller support…"
        defer { busyMessage = nil }

        let settings: [(String, String, String)] = [
            (#"HKCU\Software\Wine\DirectInput"#, "MapNativeToXInput", "Y"),
            // Report pads as Xbox controllers so games that only look for XInput
            // devices find them.
            (#"HKCU\Software\Wine\DirectInput"#, "DefaultDeviceType", "Gamepad"),
        ]
        for (key, name, value) in settings {
            try? await run(runtime.wine64,
                           args: ["reg", "add", key, "/v", name, "/t", "REG_SZ",
                                  "/d", value, "/f"],
                           env: ["WINEPREFIX": container.prefixURL.path, "WINEDEBUG": "-all"])
        }
    }

    private func applyWindowsVersion(_ version: WindowsVersion, prefix: URL, runtime: Runtime) async throws {
        try await run(runtime.wine64, args: ["winecfg", "-v", version.wineValue],
                      env: ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all"])
    }

    func setWindowsVersion(_ version: WindowsVersion, on container: Container, runtime: Runtime) async {
        busyMessage = "Setting Windows version…"
        defer { busyMessage = nil }
        do { try await applyWindowsVersion(version, prefix: container.prefixURL, runtime: runtime) }
        catch { lastError = error.localizedDescription }
    }

    private func run(_ tool: URL, args: [String], env: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = tool
            p.arguments = args
            var e = ProcessInfo.processInfo.environment
            e.merge(env) { _, new in new }
            p.environment = e
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: LibraryError.toolFailed(tool.lastPathComponent, proc.terminationStatus)) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Games

    /// Walk a game folder for launchable executables, skipping the installers,
    /// crash handlers and redistributables that make naive scanners useless.
    func discoverExecutables(in folder: URL) -> [URL] {
        // Epic titles ship a bootstrapper that launches the real game, and it names
        // that game in an .ini beside it. Reading it beats any heuristic — the
        // bootstrapper is often the *larger* binary, so picking by size lands on the
        // login shim instead of the game.
        let bootstrapperConfig = folder.appendingPathComponent("EOSBootstrapper.ini")
        if let text = try? String(contentsOf: bootstrapperConfig, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("ApplicationPath=") {
                let name = line.dropFirst("ApplicationPath=".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let target = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { return [target] }
            }
        }

        let skip = ["unins", "setup", "vcredist", "directx", "dxsetup", "crashreport",
                    "crashhandler", "launcher_installer", "dotnetfx", "eula", "redist",
                    "eosbootstrapper", "epicgameslauncher", "eaanticheat", "battleye"]
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [(URL, Int)] = []
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if skip.contains(where: { name.contains($0) }) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            found.append((url, size))
        }
        // The main binary is nearly always the largest non-installer executable.
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    @discardableResult
    func addGame(title: String, executable: URL, container: Container) -> Game {
        let game = Game(title: title, executablePath: executable.path, containerID: container.id)
        games.append(game)
        save()
        // Cover art is looked up from the launchers' own metadata caches, so a game
        // added from anywhere gets its artwork without being asked for.
        Task { await ArtworkFetcher.shared.fetchArtwork(for: game) }
        return game
    }

    // MARK: Programs installed in another app's Wine setup

    /// The Wine setup of another app an executable is installed in, if any: a Whisky or
    /// CrossOver bottle, a Mythic or Heroic prefix.
    func foreignPrefix(of executable: URL) -> SaveTransfer.ExternalPrefix? {
        let path = executable.standardizedFileURL.path
        // Only an executable under one of those apps' folders is looked into. Listing
        // another app's folder in ~/Library/Containers can make macOS ask for permission,
        // and a game in /Applications has no reason to.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["Library/Containers/com.isaacmarovitz.Whisky/", "Library/Containers/xyz.blackxfiied.Mythic/",
                     "Games/Heroic/Prefixes/", "Library/Application Support/CrossOver/Bottles/"]
        guard roots.contains(where: { path.hasPrefix(home + "/" + $0) }) else { return nil }
        if SaveTransfer.shared.prefixes.isEmpty { SaveTransfer.shared.discoverPrefixes() }
        return SaveTransfer.shared.prefixes.first { path.hasPrefix($0.driveC.standardizedFileURL.path + "/") }
    }

    /// Add a game — in a container of its own when it is installed inside another app's
    /// Wine setup. Steam added from a Whisky bottle on 30 September went into the first
    /// container, whose Windows had none of it: its sign-in, its games and its updates are
    /// all in the bottle it was installed into, and it closed after two seconds. It now
    /// gets a copy of that bottle as its container, on the matching engine.
    @discardableResult
    func addGameKeepingItsSetup(title: String, executable: URL, otherwise container: Container) async -> Game {
        guard let foreign = foreignPrefix(of: executable) else {
            return addGame(title: title, executable: executable, container: container)
        }
        // Another program from a setup already brought over joins its container.
        if let existing = containers.first(where: { $0.sourceSetup == foreign.driveC.path }) {
            return addGame(title: title, executable: Self.inside(existing, executable: executable, from: foreign), container: existing)
        }
        do {
            let (own, exe) = try await containerFromSetup(foreign, executable: executable, title: title)
            return addGame(title: title, executable: exe, container: own)
        } catch {
            lastError = "Couldn't copy \(foreign.displayName) into Anvil (\(error.localizedDescription)); \(title) was added to “\(container.name)” instead."
            return addGame(title: title, executable: executable, container: container)
        }
    }

    /// A container made from a copy of another app's Wine setup, and where the executable
    /// is inside it. An APFS clone: seconds, and no extra disk until either copy changes.
    /// The other app's setup is left exactly as it was.
    func containerFromSetup(_ foreign: SaveTransfer.ExternalPrefix, executable: URL, title: String) async throws -> (Container, URL) {
        let runtimes = RuntimeManager.shared
        func newest(_ prefix: String) -> Runtime? {
            runtimes.runtimes.filter { $0.id.hasPrefix(prefix) && $0.isUsable }.max { $0.d3dMetalRank.lexicographicallyPrecedes($1.d3dMetalRank) }
        }
        let matching: Runtime? = switch foreign.launcher {
        case "Whisky": newest("whiskywine")
        case "CrossOver": runtimes.runtime(id: "crossover")
        case "Mythic": newest("mythic-engine")
        default: nil
        }
        let runtime = matching ?? runtimes.defaultRuntime
        guard let runtime else { throw LibraryError.toolFailed("No engine installed", 1) }
        var container = Container.performanceDefault(name: "\(title) (\(foreign.launcher))", runtimeID: runtime.id)
        container.sourceSetup = foreign.driveC.path
        let source = foreign.driveC.deletingLastPathComponent()
        let dest = container.prefixURL
        busyMessage = "Copying \(foreign.displayName) into Anvil…"
        defer { busyMessage = nil }
        let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/cp")
            p.arguments = ["-Rc", source.path, dest.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: dest.appendingPathComponent("drive_c").path)
        }.value
        guard copied else {
            try? FileManager.default.removeItem(at: dest)
            throw LibraryError.toolFailed("cp", 1)
        }
        containers.append(container)
        save()
        let exe = Self.inside(container, executable: executable, from: foreign)
        AnvilLog.write("library: \(foreign.displayName) copied into its own container “\(container.name)” on \(runtime.displayName), for \(title)")
        return (container, exe)
    }

    /// Where an executable from another app's setup is in the copy of it.
    static func inside(_ container: Container, executable: URL, from foreign: SaveTransfer.ExternalPrefix) -> URL {
        let relative = String(executable.standardizedFileURL.path.dropFirst(foreign.driveC.standardizedFileURL.path.count))
        return container.driveC.appendingPathComponent(String(relative.drop { $0 == "/" }))
    }

    func removeGame(_ game: Game) {
        games.removeAll { $0.id == game.id }
        emptyingAllowed = true
        save()
        ShortcutStore.shared.remove(for: game)
    }

    enum LibraryError: LocalizedError {
        case toolFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let code): "\(tool) failed with exit code \(code)."
            }
        }
    }
}
