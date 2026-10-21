import Foundation

/// Windows Steam inside Anvil: installed into a container of its own, its games found
/// and added to the library, and each of them started with the Steam client running and
/// signed in beside it — which is what their multiplayer, DRM, cloud saves and
/// achievements need.
///
/// Steam is installed from Valve's own installer, downloaded from Valve's servers when
/// it is set up; nothing of Steam's ships inside Anvil.
///
/// A Steam game is started from its own .exe, with Steam already running in the same
/// Windows setup and the game's app id in its environment, rather than through
/// `steam.exe -applaunch`: that way the game is the process Anvil watches, so its frame
/// pacing, statistics, Health and Auto-Tune work exactly as for any other game.
@MainActor
final class SteamSupport: ObservableObject {
    static let shared = SteamSupport()

    /// What is happening, for the Stores page; nil when nothing is.
    @Published private(set) var status: String?
    @Published private(set) var lastError: String?
    /// What the last search for games found, for the page.
    @Published private(set) var lastFound: String?

    private init() {}

    /// Valve's Windows installer.
    static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Steam's web view runs without Chromium's sandbox, which cannot work under Wine —
    /// the arguments every Wine launcher starts Steam with.
    static let baseArguments = ["-no-cef-sandbox"]
    /// And with GPU drawing off for the web view: what Anvil switches to by itself once
    /// the web helper has crashed. On 30 September Steam's window never appeared, and
    /// its web helper ended with "crash server failed to launch, self-terminating".
    static let safeWebArguments = ["-cef-disable-gpu", "-cef-disable-gpu-compositing"]
    /// Steam's own link to its Library, given to Steam's window as it opens (see Launcher).
    static let libraryURL = "steam://open/games"
    /// A link for Steam to open with next time it starts — a game's install window, from the
    /// Stores page (see openInSteam) — in place of its Library.
    var nextLink: String?

    // MARK: Where things are

    nonisolated static func steamDir(in c: Container) -> URL {
        c.driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
    }
    nonisolated static func steamExe(in c: Container) -> URL { steamDir(in: c).appendingPathComponent("steam.exe") }
    nonisolated static func isInstalled(in c: Container) -> Bool {
        FileManager.default.fileExists(atPath: steamExe(in: c).path)
    }
    nonisolated static func isSteamClient(_ game: Game) -> Bool {
        game.executableURL.lastPathComponent.lowercased() == "steam.exe"
    }

    /// Containers with Steam installed, the one made for it first.
    var containers: [Container] {
        Library.shared.containers.filter { Self.isInstalled(in: $0) }
            .sorted { ($0.storefront == "steam" ? 0 : 1) < ($1.storefront == "steam" ? 0 : 1) }
    }
    var container: Container? { containers.first }
    var isSetUp: Bool { container != nil }

    /// Steam itself, as an entry in the library.
    func clientGame(in c: Container) -> Game? {
        Library.shared.games.first { $0.containerID == c.id && Self.isSteamClient($0) }
    }

    /// What Steam is started with in this container.
    func clientArguments(in c: Container) -> [String] {
        let chosen = clientGame(in: c)?.arguments ?? Self.baseArguments
        return chosen.isEmpty ? Self.baseArguments : chosen
    }

    // MARK: Setting up

    enum SteamError: LocalizedError {
        case noEngine, offline, badInstaller, installFailed(String)
        var errorDescription: String? {
            switch self {
            case .noEngine: "No engine is installed yet. Anvil downloads one in its setup, or from Engines."
            case .offline: "Setting up Steam needs an internet connection."
            case .badInstaller: "The download from Valve wasn't a Steam installer. Nothing was installed; try again later."
            case .installFailed(let why): "Steam's installer didn't finish: \(why)"
            }
        }
    }

    /// A container made for Steam, Valve's installer run in it, and Steam in the library.
    /// Already set up: the existing one.
    /// A set-up under way, shared by anyone who asks at the same time (the setup and the
    /// Steam page), so Steam is never installed twice.
    private var settingUp: Task<Container, Error>?

    @discardableResult
    func setUp() async throws -> Container {
        if let settingUp { return try await settingUp.value }
        let task = Task { try await self.performSetUp() }
        settingUp = task
        defer { settingUp = nil }
        return try await task.value
    }

    private func performSetUp() async throws -> Container {
        lastError = nil
        defer { status = nil }
        if let existing = container {
            ensureClientEntry(in: existing)
            return existing
        }
        guard let runtime = RuntimeManager.shared.defaultRuntime else { throw SteamError.noEngine }
        guard Connectivity.isOnlineNow else { throw SteamError.offline }
        do {
            status = "Downloading Steam from Valve…"
            let installer = try await Self.downloadInstaller()
            defer { try? FileManager.default.removeItem(at: installer) }

            status = "Making a Windows setup for Steam…"
            guard let c = await Library.shared.createContainer(named: "Steam", runtime: runtime, configure: {
                $0.storefront = "steam"
                // Steam supports Windows 10 and 11 only.
                if $0.windowsVersion != .win11 { $0.windowsVersion = .win10 }
            }) else { throw SteamError.installFailed(Library.shared.lastError ?? "the Windows setup couldn't be made") }

            status = "Installing Steam…"
            let env = ["WINEPREFIX": c.prefixURL.path, "WINEDEBUG": "-all"]
            let wine = runtime.wine64
            let code = await Task.detached(priority: .userInitiated) {
                Launcher.runHelper(wine, [installer.path, "/S"], environment: env, timeout: 300)
            }.value
            await Launcher.waitForWineserver(container: c, runtime: runtime, timeout: 30)
            guard Self.isInstalled(in: c) else {
                throw SteamError.installFailed(code.map { "it exited with code \($0)" } ?? "it took more than five minutes")
            }
            ensureClientEntry(in: c)
            AnvilLog.write("steam: installed into “\(c.name)” on \(runtime.displayName)")
            return c
        } catch {
            lastError = error.localizedDescription
            AnvilLog.write("steam: set-up failed — \(error.localizedDescription)")
            throw error
        }
    }

    /// Steam in the library, started the way Wine needs it.
    @discardableResult
    func ensureClientEntry(in c: Container) -> Game {
        if let existing = clientGame(in: c) { return existing }
        var game = Library.shared.addGame(title: "Steam", executable: Self.steamExe(in: c), container: c)
        game.arguments = Self.baseArguments
        // Steam is a store, not a game: nothing to measure, tune or pace.
        game.autopilot = false
        game.anvilEnhancementsOff = true
        Library.shared.update(game)
        StoreArt.ensureAll()
        return game
    }

    nonisolated static func downloadInstaller() async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: installerURL)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("SteamSetup-\(UUID().uuidString).exe")
        try FileManager.default.moveItem(at: temp, to: dest)
        guard (response as? HTTPURLResponse)?.statusCode == 200, looksLikeInstaller(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw SteamError.badInstaller
        }
        return dest
    }

    /// A Windows program of a believable size: a captive-portal page or an error saved
    /// under the installer's name is neither.
    nonisolated static func looksLikeInstaller(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 2) else { return false }
        try? h.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return head == Data("MZ".utf8) && size > 500_000 && size < 50_000_000
    }

    // MARK: Games

    struct InstalledGame: Identifiable, Hashable {
        var id: String { appID }
        var appID: String
        var name: String
        var installDir: URL
        var sizeOnDisk: Int64?
        /// Downloaded and ready: not mid-download or mid-update.
        var ready: Bool
    }

    /// Every Steam library folder in a container: steamapps folders, the default first.
    nonisolated static func libraryFolders(in c: Container) -> [URL] {
        var folders = [steamDir(in: c).appendingPathComponent("steamapps", isDirectory: true)]
        let vdf = folders[0].appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let root = parseVDF(text)["libraryfolders"] as? [String: Any] {
            for case let entry as [String: Any] in root.values {
                guard let path = entry["path"] as? String, let url = hostURL(forWindowsPath: path, in: c) else { continue }
                let apps = url.appendingPathComponent("steamapps", isDirectory: true)
                if !folders.contains(where: { $0.standardizedFileURL == apps.standardizedFileURL }) { folders.append(apps) }
            }
        }
        return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Steam's own tools, which are in every library and are not games.
    nonisolated static let notGames: Set<String> = ["228980"]   // Steamworks Common Redistributables

    nonisolated static func installedGames(in c: Container) -> [InstalledGame] {
        var games: [InstalledGame] = []
        let fm = FileManager.default
        for folder in libraryFolders(in: c) {
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8),
                      let game = manifest(text, commonDir: folder.appendingPathComponent("common", isDirectory: true))
                else { continue }
                if !notGames.contains(game.appID), !game.name.hasPrefix("Steamworks"),
                   !games.contains(where: { $0.appID == game.appID }) {
                    games.append(game)
                }
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether Steam in this container remembers a sign-in (“Remember me”), which its Offline Mode
    /// needs; nil when nobody has signed in to Steam there. Only loginusers.vdf's yes/no flags are
    /// read; Anvil never writes the file.
    nonisolated static func rememberedSignIn(in c: Container) -> Bool? {
        let url = steamDir(in: c).appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let users = parseVDF(text)["users"] as? [String: Any], !users.isEmpty else { return nil }
        return users.values.contains { ($0 as? [String: Any])?["rememberpassword"] as? String == "1" }
    }

    /// One appmanifest_<id>.acf.
    nonisolated static func manifest(_ text: String, commonDir: URL) -> InstalledGame? {
        guard let state = parseVDF(text)["appstate"] as? [String: Any],
              let appID = state["appid"] as? String, let name = state["name"] as? String,
              let dir = state["installdir"] as? String, !dir.isEmpty else { return nil }
        // StateFlags 4 is "fully installed"; anything else added to it is an update,
        // download or validation in progress.
        let flags = Int(state["stateflags"] as? String ?? "") ?? 0
        return InstalledGame(appID: appID, name: name,
                             installDir: commonDir.appendingPathComponent(dir, isDirectory: true),
                             sizeOnDisk: Int64(state["sizeondisk"] as? String ?? ""),
                             ready: flags & 4 != 0 && flags & ~(4 | 512) == 0)
    }

    /// Where a Windows path in a container is on the Mac: C: is drive_c, other letters
    /// follow the container's dosdevices links.
    nonisolated static func hostURL(forWindowsPath path: String, in c: Container) -> URL? {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":") else { return nil }
        let letter = drive.lowercased()
        var root: URL
        if letter == "c:" {
            root = c.driveC
        } else {
            let link = c.prefixURL.appendingPathComponent("dosdevices/\(letter)")
            root = link.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        }
        for part in parts.dropFirst() { root.appendPathComponent(String(part)) }
        return root
    }

    /// Valve's KeyValues text format, as used by appmanifest_*.acf and
    /// libraryfolders.vdf. Keys are lowercased: Steam's own casing varies.
    nonisolated static func parseVDF(_ text: String) -> [String: Any] {
        enum Token { case string(String), open, close }
        var tokens: [Token] = []
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "{" { tokens.append(.open); i += 1; continue }
            if ch == "}" { tokens.append(.close); i += 1; continue }
            if ch == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if ch == "\"" {
                var s = ""
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        let next = chars[i + 1]
                        s.append(next == "n" ? "\n" : next == "t" ? "\t" : next)
                        i += 2
                    } else { s.append(chars[i]); i += 1 }
                }
                i += 1
                tokens.append(.string(s))
                continue
            }
            if ch.isWhitespace { i += 1; continue }
            var s = ""
            while i < chars.count, !chars[i].isWhitespace, !"{}\"".contains(chars[i]) { s.append(chars[i]); i += 1 }
            tokens.append(.string(s))
        }
        var at = 0
        func object() -> [String: Any] {
            var dict: [String: Any] = [:]
            while at < tokens.count {
                guard case .string(let key) = tokens[at] else { at += 1; return dict }
                at += 1
                guard at < tokens.count else { break }
                switch tokens[at] {
                case .open: at += 1; dict[key.lowercased()] = object()
                case .string(let value): at += 1; dict[key.lowercased()] = value
                case .close: return dict
                }
            }
            return dict
        }
        return object()
    }

    /// Add every installed Steam game the library doesn't have yet, and point games that
    /// moved at where they are now. Returns the titles added.
    @discardableResult
    func importGames() -> [String] {
        var added: [String] = []
        var waiting: [String] = []
        let library = Library.shared
        for c in containers {
            for found in Self.installedGames(in: c) {
                if var known = library.games.first(where: { $0.steamAppID == found.appID && $0.containerID == c.id }) {
                    if !known.exists, let exe = library.discoverExecutables(in: found.installDir).first {
                        known.executablePath = exe.path
                        library.update(known)
                    }
                    continue
                }
                guard found.ready else { waiting.append(found.name); continue }
                guard let exe = library.discoverExecutables(in: found.installDir).first else { continue }
                var game = library.addGame(title: found.name, executable: exe, container: c)
                game.steamAppID = found.appID
                library.update(game)
                if let art = Self.cachedArtwork(appID: found.appID, in: c) {
                    _ = try? ArtworkStore.shared.setArtwork(from: art, for: game)
                }
                added.append(found.name)
                AnvilLog.write("steam: added \(found.name) (app \(found.appID)) from “\(c.name)”")
                // Downloaded again: its saves from before, to choose from (SaveVault).
                let back = game
                Task { await SaveChoice.shared.askIfNeeded(back) }
            }
        }
        var parts: [String] = []
        parts.append(added.isEmpty ? "No new Steam games." : "Added \(added.joined(separator: ", ")).")
        if !waiting.isEmpty { parts.append("Still downloading or updating in Steam: \(waiting.joined(separator: ", ")).") }
        lastFound = parts.joined(separator: " ")
        return added
    }

    /// The cover Steam itself downloaded for a game, from its library cache.
    nonisolated static func cachedArtwork(appID: String, in c: Container) -> URL? {
        let cache = steamDir(in: c).appendingPathComponent("appcache/librarycache", isDirectory: true)
        let fm = FileManager.default
        let flat = cache.appendingPathComponent("\(appID)_library_600x900.jpg")
        if fm.fileExists(atPath: flat.path) { return flat }
        // Newer clients keep a folder per game, with the images inside or one level down.
        let folder = cache.appendingPathComponent(appID, isDirectory: true)
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("library_600x900") {
            return url
        }
        return nil
    }

    // MARK: Running games

    /// Steam started by Anvil for a game, by container.
    private var helpers: [UUID: Process] = [:]
    /// Web-helper crashes seen in Steam's output, by container.
    private var webCrashes: [UUID: Int] = [:]

    func clientRunning(in c: Container) -> Bool {
        Launcher.shared.sessions.contains { $0.container.id == c.id && Self.isSteamClient($0.game) }
            || helpers[c.id]?.isRunning == true
    }

    // MARK: Steam's own update

    /// Where Steam's own download stands, from its bootstrap log. Valve's installer puts in
    /// only Steam's updater; at its first start Steam downloads the client itself — 336 MB
    /// on 1 October. That start was shut down 14 MB in, from Steam's own window, with
    /// nothing in Anvil saying an update was running or that it had to be left open.
    struct UpdateState: Equatable, Sendable {
        var doneKB: Int
        var totalKB: Int
        /// Shut down before the download finished: it carries on at Steam's next start.
        var stopped: Bool
        var finished: Bool
        var percent: Int { totalKB > 0 ? min(100, doneKB * 100 / totalKB) : 0 }
        var amounts: String { "\(doneKB / 1024) of \(totalKB / 1024) MB" }
    }

    /// Updating, by container, while Steam runs — for the now-playing bar.
    @Published private(set) var updating: [UUID: UpdateState] = [:]
    private var updateWatchers: [UUID: Task<Void, Never>] = [:]

    nonisolated static func updateState(in c: Container) -> UpdateState? {
        let log = steamDir(in: c).appendingPathComponent("logs/bootstrap_log.txt")
        guard let data = try? Data(contentsOf: log) else { return nil }
        return parseUpdate(String(decoding: data.suffix(96 * 1024), as: UTF8.self))
    }

    /// The last run of Steam's updater in its bootstrap log: how far its download got,
    /// and whether it finished or was shut down part-way. Nil when that run downloaded nothing.
    nonisolated static func parseUpdate(_ text: String) -> UpdateState? {
        let all = text.split(whereSeparator: \.isNewline).map(String.init)
        let run = all.lastIndex { $0.contains("Startup - ") }.map { Array(all[$0...]) } ?? all
        guard let i = run.lastIndex(where: { $0.contains("Downloading update (") }),
              let m = run[i].firstMatch(of: #/\(([\d,]+) of ([\d,]+) KB\)/#),
              let done = Int(m.1.replacingOccurrences(of: ",", with: "")),
              let total = Int(m.2.replacingOccurrences(of: ",", with: "")) else { return nil }
        let after = run[(i + 1)...].map { $0.lowercased() }
        let finished = after.contains { l in
            ["download complete", "extracting package", "installing update", "update complete", "verification complete"].contains { l.contains($0) }
        }
        let stopped = !finished && after.contains { $0.contains("] shutdown") }
        return UpdateState(doneKB: done, totalKB: total, stopped: stopped, finished: finished)
    }

    // MARK: Steam's connection

    /// How Steam's last session went with Steam's servers, from its own logs. On 1 October
    /// it never signed in: 34 servers didn't answer — Frankfurt, Santiago, São Paulo, Lima,
    /// Johannesburg, none in the US — and its sign-in reported no connection four times,
    /// with Proton VPN on; it called that an error, again and again.
    struct ConnectionReport: Equatable, Sendable {
        var signedIn: Bool
        /// Steam's servers it couldn't talk to.
        var serversFailed: Int
        /// "LogonFailure No Connection" in its console.
        var noConnection: Int
        var certificateFailures: Int
        /// Where the servers it tried are, most-tried first.
        var places: [String]
        /// Its web view met Windows socket error 10045 (operation not supported) — Wine's.
        var socketUnsupported: Bool
        /// Times Steam turned its own window away ("WebUITransport: Connection rejected"): it
        /// couldn't tell the window was its own, so nothing typed there reached Steam.
        var windowRejected: Int = 0
        var couldNotConnect: Bool { !signedIn && windowRejected == 0 && (noConnection > 0 || serversFailed >= 5) }
    }

    nonisolated static func connectionReport(in c: Container) -> ConnectionReport? {
        let logs = steamDir(in: c).appendingPathComponent("logs")
        func read(_ name: String) -> String {
            guard let data = try? Data(contentsOf: logs.appendingPathComponent(name)) else { return "" }
            return String(decoding: data.suffix(512 * 1024), as: UTF8.self)
        }
        return parseConnection(connectionLog: read("connection_log.txt"), consoleLog: read("console_log.txt"),
                               cefLog: read("cef_log.txt"), transportLog: read("transport_steamui.txt"))
    }

    /// From the last session in each log — each starts with Steam's "Client version:" line.
    nonisolated static func parseConnection(connectionLog: String, consoleLog: String, cefLog: String,
                                            transportLog: String = "") -> ConnectionReport? {
        func lastSession(_ text: String) -> [Substring] {
            let lines = text.split(whereSeparator: \.isNewline)
            return lines.lastIndex { $0.contains("Client version:") }.map { Array(lines[$0...]) } ?? lines
        }
        let connection = lastSession(connectionLog), console = lastSession(consoleLog), transport = lastSession(transportLog)
        guard !connection.isEmpty || !console.isEmpty else { return nil }
        var codes: [String: Int] = [:]
        for line in connection where line.contains("failed talking to cm") {
            if let m = line.firstMatch(of: #/[a-z0-9]+-([a-z]{3})[0-9]\.steamserver\.net/#) { codes[String(m.1), default: 0] += 1 }
        }
        let places = codes.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { placeName($0.key) }
        return ConnectionReport(
            signedIn: connection.contains { $0.contains("[Logged On,") },
            serversFailed: connection.filter { $0.contains("failed talking to cm") }.count,
            noConnection: console.filter { $0.contains("LogonFailure No Connection") }.count,
            certificateFailures: console.filter { $0.contains("Crypto API failed certificate check") }.count,
            places: places,
            socketUnsupported: cefLog.contains("Unknown error 10045"),
            windowRejected: transport.filter { $0.contains("WebUITransport: Connection rejected") }.count)
    }

    /// Steam names its servers after the nearest airport.
    nonisolated static func placeName(_ code: String) -> String {
        let names = ["ams": "Amsterdam", "atl": "Atlanta", "bom": "Mumbai", "can": "Guangzhou", "dfw": "Dallas", "dxb": "Dubai",
                     "eze": "Buenos Aires", "fra": "Frankfurt", "gru": "São Paulo", "hel": "Helsinki", "hkg": "Hong Kong",
                     "iad": "Washington", "jnb": "Johannesburg", "lax": "Los Angeles", "lhr": "London", "lim": "Lima",
                     "maa": "Chennai", "mad": "Madrid", "ord": "Chicago", "par": "Paris", "scl": "Santiago", "sea": "Seattle",
                     "sgp": "Singapore", "sto": "Stockholm", "syd": "Sydney", "tyo": "Tokyo", "vie": "Vienna", "waw": "Warsaw",
                     "sha": "Shanghai", "pek": "Beijing", "sel": "Seoul", "bog": "Bogotá", "mex": "Mexico City", "tor": "Toronto"]
        return names[code] ?? code.uppercased()
    }

    /// While Steam runs in a container, its download's progress every two seconds.
    func watchUpdate(in c: Container) {
        updateWatchers[c.id]?.cancel()
        let id = c.id
        updateWatchers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self, self.clientRunning(in: c) else { break }
                let state = await Task.detached(priority: .utility) { Self.updateState(in: c) }.value
                let now = (state?.finished == false && state?.stopped == false) ? state : nil
                if self.updating[id] != now { self.updating[id] = now }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.updating[id] = nil
            self?.updateWatchers[id] = nil
        }
    }

    /// Steam running and signed in, in the game's container, before a Steam game starts.
    /// Returns what happened, for the launch log.
    func prepareClient(for game: Game, container c: Container, runtime: Runtime,
                       environment base: [String: String]) async -> String {
        guard game.steamAppID != nil, Self.isInstalled(in: c), !Self.isSteamClient(game) else { return "" }
        // Steam beside the game gets Anvil's library only for Wine's connection table, as when
        // it's opened from the library — not the game's frame hook, pacing or input settings.
        var env = Launcher.storeClientEnvironment(base)
        for key in ["SteamAppId", "SteamGameId"] { env.removeValue(forKey: key) }
        if !clientRunning(in: c) {
            startHelper(in: c, runtime: runtime, environment: env)
        }
        watchUpdate(in: c)
        // A first start updates Steam, which can take a couple of minutes. Offline there is
        // no update and no sign-in to wait for: Steam is either in its own offline mode,
        // chosen in Steam while online (Steam › Go Offline), and up within seconds — or it
        // won't sign in at all, and the game shouldn't wait 2½ minutes for nothing.
        let offline = !Connectivity.isOnlineNow
        let deadline = Date().addingTimeInterval(offline ? 20 : 150)
        var restarted = false
        while Date() < deadline {
            if await Self.signedIn(in: c, wine: runtime.wine64, environment: env) {
                return "Steam is running and signed in"
            }
            // Steam closes with code 42 after updating itself and expects to be started again.
            if let helper = helpers[c.id], !helper.isRunning {
                guard helper.terminationStatus == 42, !restarted else {
                    return "Steam closed (code \(helper.terminationStatus)) before signing in — the game was started anyway"
                }
                restarted = true
                startHelper(in: c, runtime: runtime, environment: env)
            }
            // Steam's web view crashed: the sign-in window can't appear without it.
            if (webCrashes[c.id] ?? 0) > 0, useSafeWebView(in: c) {
                helpers[c.id]?.terminate()
                try? await Task.sleep(for: .seconds(2))
                startHelper(in: c, runtime: runtime, environment: env)
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if offline {
            return "Steam isn't signed in offline — the game was started anyway. Games that need Steam running work offline once Steam's own offline mode is chosen in Steam while online (Steam › Go Offline)"
        }
        return "Steam didn't sign in within 2½ minutes — open Steam from the library and sign in once"
    }

    private func startHelper(in c: Container, runtime: Runtime, environment env: [String: String]) {
        let p = Process()
        p.executableURL = runtime.wine64
        p.arguments = [Self.steamExe(in: c).path, "-silent"] + clientArguments(in: c)
        p.currentDirectoryURL = Self.steamDir(in: c)
        var full = ProcessInfo.processInfo.environment
        full.merge(env) { _, new in new }
        p.environment = full
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let id = c.id
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if Self.isWebHelperCrash(text) { Task { @MainActor in SteamSupport.shared.webHelperCrashed(containerID: id) } }
        }
        p.terminationHandler = { _ in try? pipe.fileHandleForReading.close() }
        do {
            try p.run()
            helpers[c.id] = p
            webCrashes[c.id] = 0
            AnvilLog.write("  steam: started in the background for the game (\(clientArguments(in: c).joined(separator: " ")))")
        } catch {
            AnvilLog.write("  steam: couldn't start — \(error.localizedDescription)")
        }
    }

    /// Steam's sign-in, as Steam itself records it: the active user in the registry.
    nonisolated static func signedIn(in c: Container, wine: URL, environment: [String: String]) async -> Bool {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = wine
            p.arguments = ["reg", "query", #"HKCU\Software\Valve\Steam\ActiveProcess"#, "/v", "ActiveUser"]
            var env = ProcessInfo.processInfo.environment
            env.merge(environment) { _, new in new }
            // As Steam itself has it: should this be what starts the Windows setup, everything
            // Wine starts with it — winedevice, where the connection table is made — has the fix.
            env = Launcher.storeClientEnvironment(env)
            env["WINEDEBUG"] = "-all"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return activeUser(in: String(data: data, encoding: .utf8) ?? "") != 0
        }.value
    }

    /// The ActiveUser value out of `reg query` output; 0 when signed out or missing.
    nonisolated static func activeUser(in output: String) -> UInt32 {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("ActiveUser") {
            guard let raw = line.split(separator: " ").last(where: { !$0.isEmpty }) else { continue }
            let hex = raw.lowercased().hasPrefix("0x") ? raw.dropFirst(2) : raw[...]
            return UInt32(hex, radix: 16) ?? 0
        }
        return 0
    }

    nonisolated static func isWebHelperCrash(_ text: String) -> Bool {
        text.contains("crash server failed to launch") || text.contains("steamwebhelper.exe encountered")
    }

    /// Steam's web view crashed — seen in the output of Steam started either way.
    func webHelperCrashed(containerID: UUID) {
        webCrashes[containerID, default: 0] += 1
        guard let c = Library.shared.container(id: containerID), webCrashes[containerID] == 1 else { return }
        AnvilLog.write("steam: Steam's web view crashed in “\(c.name)”")
        // Steam opened from the library: started again in the safer mode, once.
        guard let client = clientGame(in: c), Launcher.shared.isRunning(client),
              useSafeWebView(in: c), let updated = clientGame(in: c),
              let runtime = RuntimeManager.shared.runtime(id: c.runtimeID) else { return }
        Launcher.shared.note("Steam's window crashed under Wine. Starting it again with its web view drawn without the GPU…")
        Task { @MainActor in
            Launcher.shared.quit(client)
            for _ in 0..<40 where Launcher.shared.isRunning(client) { try? await Task.sleep(for: .milliseconds(500)) }
            webCrashes[containerID] = 0
            _ = try? await Launcher.shared.prepareAndLaunch(game: updated, container: c, runtime: runtime)
        }
    }

    /// Switch Steam in this container to the safer web view. False when it already was.
    func useSafeWebView(in c: Container) -> Bool {
        let client = ensureClientEntry(in: c)
        guard !client.arguments.contains(Self.safeWebArguments[0]) else { return false }
        var updated = client
        updated.arguments = Array(Set(updated.arguments + Self.baseArguments)).sorted() + Self.safeWebArguments
        Library.shared.update(updated)
        AnvilLog.write("steam: Steam in “\(c.name)” now starts with its web view drawn without the GPU (\(Self.safeWebArguments.joined(separator: " ")))")
        return true
    }

    /// After the last game in a container ends: Steam started for it is asked to close —
    /// properly, so it finishes uploading cloud saves — before the Windows setup is shut down.
    func closeHelper(in c: Container, runtime: Runtime) async {
        guard let helper = helpers[c.id], helper.isRunning else { helpers[c.id] = nil; return }
        let env = ["WINEPREFIX": c.prefixURL.path, "WINEDEBUG": "-all"]
        let wine = runtime.wine64, exe = Self.steamExe(in: c).path
        _ = await Task.detached(priority: .utility) {
            Launcher.runHelper(wine, [exe, "-shutdown"], environment: env, timeout: 20)
        }.value
        for _ in 0..<60 where helper.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
        AnvilLog.write("steam: closed after the game\(helper.isRunning ? " — it hadn't finished after 30 s" : "")")
        helpers[c.id] = nil
    }
}
