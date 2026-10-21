import Foundation

/// A game's link to the Epic account it was installed from.
///
/// Mythic and Heroic install Epic games through `legendary`, which records each one —
/// and each piece of DLC — in `installed.json`, with the store's catalogue beside it in
/// `metadata/`. That is enough to say, for a game already in Anvil's library, which
/// DLC it has, which of it is installed, and which Epic app it is.
///
/// DLC on Epic is unlocked by ownership, not by files: the DLC's content usually sits
/// in the game's own folder, and the game asks Epic at start-up which of it the player
/// owns. It can only ask once it is signed in, and a game started straight from its
/// .exe is not — every Cat Quest II launch logged "EOS_Auth_Credentials.Token must not
/// be null or empty". Mythic signs a game in by asking legendary for the arguments
/// Epic's own launcher would pass: a one-time exchange code and the account's name and
/// id. Anvil asks for exactly the same thing, through the same launcher's own
/// legendary, so DLC, cloud saves and achievements work as they do in Mythic.
struct EpicLink: Hashable {
    struct DLC: Hashable, Identifiable {
        var id: String          // catalogue item id
        var title: String
        var installed: Bool
        /// Its own app on Epic (the store's "releaseInfo"): what legendary installs it as.
        var appName: String? = nil
        /// On the account, as legendary last read it: among the apps it can download, or its entitlements.
        var owned = false
        /// Owned, with files of its own to download — legendary puts them in the game's folder. Owned DLC without
        /// is unlocked by ownership alone: the game finds it once it starts signed in.
        var downloadable = false
        /// Owned and not here yet: what Download gets.
        var toDownload: Bool { downloadable && !installed }
    }

    var appName: String
    var title: String
    /// "Anvil", "Mythic" or "Heroic" — whose sign-in the game uses.
    var launcher: String
    /// legendary's configuration folder for that launcher (LEGENDARY_CONFIG_PATH).
    var configDir: URL
    /// That launcher's own legendary, when it can be found.
    var legendary: URL?
    var dlc: [DLC]

    var installedDLC: [DLC] { dlc.filter(\.installed) }
    var ownedDLC: [DLC] { dlc.filter { $0.owned || $0.installed } }
    /// Owned DLC with files of its own that aren't installed — LEGO Star Wars' Classic Obi-Wan on 21 October.
    var dlcToDownload: [DLC] { dlc.filter(\.toDownload) }

    // MARK: Discovery

    private struct Source {
        var launcher: String
        var configDir: URL
        var legendaryCandidates: [URL]
    }

    private static var launcherSources: [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let apps = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        return [
            Source(launcher: "Mythic",
                   configDir: home.appendingPathComponent("Library/Application Support/Mythic/Epic"),
                   legendaryCandidates: apps.map { $0.appendingPathComponent("Mythic.app/Contents/Resources/legendary/cli") }),
            Source(launcher: "Heroic",
                   configDir: home.appendingPathComponent("Library/Application Support/heroic/legendaryConfig/legendary"),
                   legendaryCandidates: apps.flatMap { app in
                       ["arm64", "x64"].map {
                           app.appendingPathComponent("Heroic.app/Contents/Resources/app.asar.unpacked/build/bin/\($0)/darwin/legendary")
                       }
                   }),
        ]
    }

    /// Anvil's own sign-in first (see EpicAccount), with its own legendary — or another
    /// launcher's copy of the same program until Anvil's is installed. The other
    /// launchers' own sign-ins are used only while Anvil has none.
    private static var sources: [Source] {
        let others = launcherSources
        guard EpicAccount.isSignedIn else { return others }
        let anvil = Source(launcher: "Anvil", configDir: EpicAccount.configDir,
                           legendaryCandidates: [EpicAccount.binary] + others.flatMap(\.legendaryCandidates))
        return [anvil] + others
    }

    /// Another launcher's copy of legendary, while Anvil's own isn't installed.
    static func otherLegendary() -> URL? {
        launcherSources.flatMap(\.legendaryCandidates).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The Epic install this game's executable belongs to, if any launcher knows one.
    static func find(for game: Game) -> EpicLink? {
        let exe = normalised(game.executablePath)
        guard !exe.isEmpty else { return nil }
        for source in sources {
            guard let installed = readJSON(source.configDir.appendingPathComponent("installed.json")) else { continue }
            for (appName, value) in installed {
                guard let entry = value as? [String: Any],
                      (entry["is_dlc"] as? Bool) != true,
                      let installPath = entry["install_path"] as? String,
                      let executable = entry["executable"] as? String,
                      !executable.isEmpty,
                      normalised(installPath + "/" + executable) == exe else { continue }
                let fm = FileManager.default
                return EpicLink(appName: appName,
                                title: (entry["title"] as? String) ?? game.title,
                                launcher: source.launcher,
                                configDir: source.configDir,
                                legendary: source.legendaryCandidates.first { fm.isExecutableFile(atPath: $0.path) },
                                dlc: dlc(of: appName, installed: installed, configDir: source.configDir))
            }
        }
        return nil
    }

    /// Every DLC the store lists for the game, marked installed when legendary has it.
    private static func dlc(of appName: String, installed: [String: Any], configDir: URL) -> [DLC] {
        let metadataDir = configDir.appendingPathComponent("metadata")
        func catalogue(_ app: String) -> [String: Any]? {
            (readJSON(metadataDir.appendingPathComponent("\(app).json"))?["metadata"]) as? [String: Any]
        }
        guard let base = catalogue(appName) else { return [] }
        let baseID = base["id"] as? String

        let owns = owned(configDir: configDir)

        // Installed DLC, by catalogue id: legendary records each as its own install
        // with is_dlc set, and the DLC's catalogue entry names its main game.
        var installedIDs = Set<String>()
        var installedTitles: [String: String] = [:]
        for (app, value) in installed {
            guard let entry = value as? [String: Any], (entry["is_dlc"] as? Bool) == true,
                  let meta = catalogue(app), let id = meta["id"] as? String else { continue }
            let parent = (meta["mainGameItem"] as? [String: Any])?["id"] as? String
            if parent == nil || parent == baseID {
                installedIDs.insert(id)
                installedTitles[id] = (entry["title"] as? String) ?? (meta["title"] as? String)
            }
        }

        var list: [DLC] = []
        var listed = Set<String>()
        for item in (base["dlcItemList"] as? [[String: Any]]) ?? [] {
            guard let id = item["id"] as? String, listed.insert(id).inserted else { continue }
            let releases = (item["releaseInfo"] as? [[String: Any]]) ?? []
            let app = (releases.first { ($0["platform"] as? [String])?.contains("Windows") == true } ?? releases.first)?["appId"] as? String
            let downloadable = app.map { owns.apps.contains($0) } ?? false
            list.append(DLC(id: id, title: (item["title"] as? String) ?? id, installed: installedIDs.contains(id), appName: app,
                            owned: downloadable || owns.items.contains(id), downloadable: downloadable))
        }
        // Installed DLC the catalogue copy does not list yet (it is refreshed less often).
        for id in installedIDs where !listed.contains(id) {
            list.append(DLC(id: id, title: installedTitles[id] ?? id, installed: true, owned: true))
        }
        // Installed, then yours to download, then yours that unlocks by itself, then what isn't yours; by name.
        func rank(_ d: DLC) -> Int { d.installed ? 0 : d.toDownload ? 1 : d.owned ? 2 : 3 }
        return list.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1)
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// What the account owns, as legendary last read it from Epic (each `legendary list`, which the Epic page runs):
    /// the Windows apps it can download — games and DLC with files of their own (assets.json) — and the catalogue items
    /// of its entitlements (entitlements.json). Neither file holds a sign-in.
    static func owned(configDir: URL) -> (apps: Set<String>, items: Set<String>) {
        var apps = Set<String>()
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("assets.json")),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for asset in (root["Windows"] as? [[String: Any]]) ?? [] {
                if let app = asset["app_name"] as? String { apps.insert(app) }
            }
        }
        var items = Set<String>()
        if let data = try? Data(contentsOf: configDir.appendingPathComponent("entitlements.json")),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for e in list { if let id = e["catalogItemId"] as? String { items.insert(id) } }
        }
        return (apps, items)
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func normalised(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    // MARK: Signing in

    enum SignInError: LocalizedError {
        case noLegendary(String)
        case failed(String)
        case timedOut
        case notSignedIn(String)

        var errorDescription: String? {
            switch self {
            case .noLegendary(let launcher): "\(launcher)'s legendary was not found."
            case .failed(let why): why
            case .timedOut: "legendary did not answer in time."
            case .notSignedIn(let launcher): "Epic isn't signed in\(launcher == "Anvil" ? "" : " in \(launcher)") — sign in to Epic under Stores, once, while online."
            }
        }
    }

    /// The arguments Epic's launcher would pass this game: a one-time exchange code
    /// and the signed-in account. Asked of the same launcher's legendary with the same
    /// call Mythic makes on Play; nothing is launched by it.
    ///
    /// The exchange code is a credential. It is handed to the game and never written to
    /// a log — see `Launcher.redacted`.
    ///
    /// `wine` is required even though nothing is launched: on macOS legendary builds the
    /// Wine command line before it answers, and with no Wine configured for a game it
    /// indexes an empty list and crashes — `IndexError` in `get_app_launch_command`,
    /// reproduced here against a copy of Mythic's install records. That crash was the
    /// first LEGO Star Wars launch: no sign-in, so the game never learned which Epic
    /// account it was running for, found no profile in SAVEDGAMES/EPIC, and sat at the
    /// sign-in step. With a Wine path given, legendary answers normally.
    ///
    /// `offline` asks for the same arguments without contacting Epic: no exchange code,
    /// but the account's name and id, which is enough for a game that can run offline
    /// to find its player's profile and saves.
    func signInArguments(wine: URL, offline: Bool = false, timeout: TimeInterval = 30) async throws -> [String] {
        guard let legendary else { throw SignInError.noLegendary(launcher) }
        let appName = appName
        let configDir = configDir
        let launcher = launcher
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Anvil's own sign-in is kept encrypted, and opened only for this run.
                let ownSignIn = configDir.standardizedFileURL == EpicAccount.configDir.standardizedFileURL
                if ownSignIn { EpicVault.open() }
                defer { if ownSignIn { EpicVault.close() } }
                // No sign-in, no start: legendary would spend seconds failing on it (3 October,
                // after the key that sealed the sign-in stopped working).
                guard FileManager.default.fileExists(atPath: configDir.appendingPathComponent("user.json").path) else {
                    continuation.resume(throwing: SignInError.notSignedIn(launcher))
                    return
                }
                let process = Process()
                process.executableURL = legendary
                process.arguments = ["launch", appName, "--json", "--skip-version-check", "--wine", wine.path]
                    + (offline ? ["--offline"] : [])
                var env = ProcessInfo.processInfo.environment
                env["LEGENDARY_CONFIG_PATH"] = configDir.path
                // An app started from the Dock has no LANG; legendary then guesses the game's language.
                if env["LANG"] == nil {
                    env["LANG"] = "\(Locale.current.language.languageCode?.identifier ?? "en")_\(Locale.current.region?.identifier ?? "US").UTF-8"
                }
                for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("WINE") || key.hasPrefix("ANVIL_") {
                    env.removeValue(forKey: key)
                }
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err

                // Read while it runs: a full pipe would otherwise stall it.
                var stdout = Data(), stderr = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { stderr = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                do { try process.run() } catch {
                    // Close the ends the child never took, so the readers above finish.
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    continuation.resume(throwing: SignInError.failed("Could not start legendary: \(error.localizedDescription)"))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                if group.wait(timeout: deadline) == .timedOut {
                    process.terminate()
                    continuation.resume(throwing: SignInError.timedOut)
                    return
                }
                process.waitUntilExit()

                guard process.terminationStatus == 0,
                      let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
                      let egl = json["egl_parameters"] as? [String], !egl.isEmpty else {
                    // legendary's own explanation, minus anything that could carry a token.
                    // A Python traceback ends with a PyInstaller line that says only that
                    // the script failed; the exception line above it says why.
                    let lines = (String(data: stderr, encoding: .utf8) ?? "")
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("token")
                                  && !$0.localizedCaseInsensitiveContains("auth_password") }
                    // The first exception is the cause; a PyInstaller hook can fail after it on
                    // the way out ("No module named '_socket'") and say nothing about why.
                    let exception = lines.first { $0.range(of: #"^\w+(Error|Exception)\b"#, options: .regularExpression) != nil }
                    let why = exception ?? lines.last { !$0.hasPrefix("[PYI-") } ?? lines.last
                        ?? "legendary exited with status \(process.terminationStatus)"
                    continuation.resume(throwing: SignInError.failed(why))
                    return
                }
                continuation.resume(returning: egl)
            }
        }
    }
}

/// The ways an Epic game can be started with no connection, tried in this order until one gets
/// it going — kept per game in its OfflineRecord. Each gives the game what it would have on a
/// PC with no internet; none signs it in, and none gets around a sign-in it waits for.
///
/// On 8 October all three were tried here with LEGO Star Wars' Epic edition, its connections
/// held back, for 150 s each: it stayed on its loading screen with every one, idle at 2.2 GB and
/// under a tenth of a core. Cat Quest II, started as its program alone, found its Epic sign-in
/// failing at once ("Error logging in") and carried on to its save.
enum EpicOfflineWay: String, Codable, CaseIterable, Sendable {
    /// The arguments of its last online start without the one-time sign-in code: legendary's
    /// offline start (an empty -AUTH_PASSWORD).
    case keptArguments
    /// What Epic's own launcher passes in its Offline Mode, by Epic's store testing guide: the
    /// account's name and id, and no sign-in arguments at all.
    case epicOfflineMode
    /// Its program on its own, with no Epic arguments: for a game that only looks for Epic when
    /// Epic started it.
    case programAlone

    /// The game's arguments this way, from the kept offline ones.
    func arguments(from kept: [String]) -> [String] {
        switch self {
        case .keptArguments: kept
        case .epicOfflineMode: kept.filter { !$0.hasPrefix("-AUTH_") && !$0.hasPrefix("-epicovt=") }
        case .programAlone: []
        }
    }

    var title: String {
        switch self {
        case .keptArguments: "Epic's arguments from its last online start"
        case .epicOfflineMode: "Epic Offline Mode's start (account name and id only)"
        case .programAlone: "its program on its own, with no Epic arguments"
        }
    }

    /// In the launch log, read back after the session (OfflineStarts.epicWay).
    var logMark: String { "offline way: \(rawValue)" }

    var next: EpicOfflineWay? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

/// The arguments for starting an Epic game offline, kept from its last online start and
/// sealed with Anvil's protection key (AES-256-GCM), so an offline start runs no legendary
/// at all. legendary's own offline start gives exactly these: the online arguments with no
/// sign-in code (an empty -AUTH_PASSWORD) and no ownership token. On 1 October, offline,
/// legendary took about 7 seconds to give them — after Anvil had already waited 3 to find
/// Epic out of reach.
enum EpicOfflineStart {
    private static let purpose = "epic-offline-start"
    nonisolated static var file: URL { EpicAccount.configDir.appendingPathComponent("offline-start.sealed") }

    /// The online arguments made offline: the one-time sign-in code and ownership token out.
    nonisolated static func offline(from online: [String]) -> [String] {
        online.compactMap { arg in
            if arg.hasPrefix("-AUTH_PASSWORD=") { return "-AUTH_PASSWORD=" }
            if arg.hasPrefix("-epicovt=") { return nil }
            return arg
        }
    }

    /// After an online start: its arguments, made offline, kept for the next offline one.
    nonisolated static func remember(_ online: [String], appName: String) {
        let args = offline(from: online)
        guard args.contains("-epicapp=\(appName)"), args.contains(where: { $0.hasPrefix("-epicuserid=") }) else { return }
        var all = load()
        guard all[appName] != args else { return }
        all[appName] = args
        guard let json = try? JSONEncoder().encode(all), let sealed = try? Vault.seal(json, purpose: purpose) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? sealed.write(to: file, options: .atomic)) == nil { try? sealed.write(to: file) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The offline arguments for a game started online before, or nil.
    nonisolated static func arguments(appName: String) -> [String]? {
        guard let args = load()[appName], args.contains("-epicapp=\(appName)"),
              args.contains(where: { $0.hasPrefix("-epicuserid=") }) else { return nil }
        return args
    }

    /// Dropped when the Epic sign-in changes hands — a different account's arguments would
    /// open the wrong saves.
    nonisolated static func forget() { try? FileManager.default.removeItem(at: file) }

    private static func load() -> [String: [String]] {
        guard let sealed = try? Data(contentsOf: file) else { return [:] }
        let json: Data
        do { json = try Vault.open(sealed, purpose: purpose) }
        catch Vault.Failure.otherKey { forget(); return [:] }   // made again by the next online start
        catch { return [:] }
        guard let all = try? JSONDecoder().decode([String: [String]].self, from: json) else { return [:] }
        // Sealed with a key Anvil used before: sealed again with the one in use.
        if Vault.keyID(of: sealed) != ProtectionKey.current?.id, let again = try? Vault.seal(json, purpose: purpose) {
            if (try? again.write(to: file, options: .atomic)) == nil { try? again.write(to: file) }
        }
        return all
    }
}
