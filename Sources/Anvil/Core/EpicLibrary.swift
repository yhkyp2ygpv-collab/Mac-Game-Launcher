import Foundation

/// The Epic games an account owns, installed and added to the library by Anvil itself,
/// through its own legendary and sign-in (see EpicAccount) — so a Mac with no other
/// launcher can install and play them.
@MainActor
final class EpicLibrary: ObservableObject {
    static let shared = EpicLibrary()

    struct Title: Identifiable, Hashable, Codable {
        var id: String { appName }
        var appName: String
        var title: String
        var cover: URL?
        /// Bytes on disk once installed, and to download — from Epic's manifest, once asked (see `fetchSize`).
        var installSize: Int64?
        var downloadSize: Int64?
    }

    /// How a download is going, from legendary's own progress lines.
    struct Download: Equatable {
        var fraction: Double = 0
        /// MiB a second, as legendary measures it.
        var speed: Double?
        /// Seconds left, legendary's estimate.
        var secondsLeft: Int?
        /// What legendary said it will download and install, in bytes, before it began.
        var downloadBytes: Int64?
        var installBytes: Int64?
        /// Where it's going, once known: the folder a cancelled download can be cleared from.
        var folder: URL?
    }

    /// A game's sizes as Epic's manifest gives them, asked for before installing (the ⓘ on the Epic page).
    struct Size: Equatable {
        var download: Int64?
        var install: Int64?
        /// Free on the disk games install to, when asked.
        var free: Int64?
        var failed: String?
    }

    @Published private(set) var owned: [Title] = []
    @Published private(set) var refreshing = false
    /// When the list was last read from Epic.
    @Published private(set) var updatedAt: Date?
    /// Downloads under way: app name → 0…1.
    @Published private(set) var installing: [String: Double] = [:]
    @Published private(set) var downloads: [String: Download] = [:]
    @Published private(set) var lastError: String?
    /// Sizes asked for, by app name; nil value while being asked.
    @Published private(set) var sizes: [String: Size] = [:]
    @Published private(set) var sizing: Set<String> = []
    /// Downloads stopped on purpose, so their end isn't reported as a failure.
    private var cancelled: Set<String> = []
    /// What a download said when it stopped, for its row: "Stopped — 2.1 GB kept; Install carries on from there."
    @Published private(set) var stopped: [String: String] = [:]
    /// A refresh asked for offline, waiting for the connection.
    private var refreshWaiting = false

    /// The list as it was last read from Epic, kept on disk. `legendary list` takes 10–30 s for
    /// an account with 200 games (209 here on 10 October: Epic's weekly free games add up), and
    /// the page used to wait for it every time Anvil was opened.
    nonisolated static var listCache: URL { DiskCache.directory.appendingPathComponent("EpicOwned.json") }
    private struct Saved: Codable { var at: Date; var titles: [Title] }

    private init() {
        if let data = try? Data(contentsOf: Self.listCache), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            owned = saved.titles
            updatedAt = saved.at
        }
    }

    /// Read again from Epic when the copy kept is older than `maxAge` (or there is none). The
    /// list kept is shown meanwhile.
    func refreshIfStale(maxAge: TimeInterval = 30 * 60) async {
        guard EpicAccount.isSignedIn, !refreshing else { return }
        if let updatedAt, Date().timeIntervalSince(updatedAt) < maxAge, !owned.isEmpty { return }
        await refresh()
    }

    /// The account changed: nothing of the last one's list is shown.
    func forgetList() {
        owned = []
        updatedAt = nil
        try? FileManager.default.removeItem(at: Self.listCache)
    }

    /// Where games installed through Anvil go.
    nonisolated static var gamesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Anvil", isDirectory: true)
    }

    var legendary: URL? { EpicAccount.legendary ?? EpicLink.otherLegendary() }

    // MARK: Owned games

    func refresh() async {
        guard EpicAccount.isSignedIn else { lastError = "Sign in to Epic first."; return }
        guard let tool = legendary else { lastError = "Anvil's Epic tool isn't installed yet — it downloads at the next start with a connection."; return }
        // The list of what an account owns is Epic's, online; installed games are read from
        // this Mac and play offline either way. On 8 October the Stores page opened offline
        // ran legendary anyway, which failed and logged it as a fault.
        guard Connectivity.isOnlineNow else {
            if owned.isEmpty {
                lastError = "Epic's list of your games needs a connection — it's read again once there is one. Installed games play offline."
                if !refreshWaiting {
                    refreshWaiting = true
                    Connectivity.shared.whenOnline {
                        Task { @MainActor in
                            EpicLibrary.shared.refreshWaiting = false
                            await EpicLibrary.shared.refresh()
                        }
                    }
                }
            }
            return
        }
        refreshing = true
        defer { refreshing = false }
        let began = Date()
        let (status, output) = await EpicAccount.run(tool, ["list", "--platform", "Windows", "--json"], timeout: 180)
        guard status == 0, let data = Self.jsonPart(of: output) else {
            if Self.signInExpired(output) {
                EpicAccount.shared.signInExpired = true
                lastError = "Epic asked for you to sign in again — its sign-ins last a few weeks unused. Sign in below and the list comes back."
                AnvilLog.write("epic: list failed — Epic's sign-in has expired")
            } else {
                lastError = owned.isEmpty ? "Epic's game list couldn't be read (\(status)). If this keeps happening, sign in to Epic again." : nil
                AnvilLog.write("epic: list failed with \(status)")
            }
            return
        }
        owned = Self.parseOwned(data)
        updatedAt = Date()
        lastError = nil
        EpicAccount.shared.signInExpired = false
        if let saved = try? JSONEncoder().encode(Saved(at: updatedAt!, titles: owned)) {
            try? FileManager.default.createDirectory(at: DiskCache.directory, withIntermediateDirectories: true)
            try? saved.write(to: Self.listCache)
        }
        AnvilLog.write(String(format: "epic: %d games owned (read from Epic in %.1f s)", owned.count, Date().timeIntervalSince(began)))
        if EpicAccount.shared.accountName == nil { await EpicAccount.shared.readAccountName() }
    }

    /// legendary's words when the sign-in it has no longer works.
    nonisolated static func signInExpired(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("login failed") || text.contains("no saved credentials")
            || (text.contains("invalid") && text.contains("token")) || text.contains("please run \"legendary auth\"")
    }

    /// legendary writes its log lines — "[cli] INFO: …" — to the same pipe; the JSON is
    /// the array that parses, from the first bracket that starts one.
    nonisolated static func jsonPart(of output: String) -> Data? {
        guard let end = output.lastIndex(of: "]") else { return nil }
        var from = output.startIndex
        while let start = output[from..<end].firstIndex(of: "[") {
            let candidate = Data(output[start...end].utf8)
            if (try? JSONSerialization.jsonObject(with: candidate)) is [Any] { return candidate }
            from = output.index(after: start)
        }
        return nil
    }

    /// `legendary list --json`: each entry is legendary's own record of a game, with
    /// Epic's catalogue entry under "metadata".
    nonisolated static func parseOwned(_ data: Data) -> [Title] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let app = entry["app_name"] as? String,
                  let title = entry["app_title"] as? String ?? (entry["metadata"] as? [String: Any])?["title"] as? String
            else { return nil }
            let images = (entry["metadata"] as? [String: Any])?["keyImages"] as? [[String: Any]] ?? []
            let preferred = ["DieselGameBoxTall", "OfferImageTall", "DieselGameBox", "Thumbnail"]
            let cover = preferred.lazy.compactMap { kind in
                images.first { $0["type"] as? String == kind }?["url"] as? String
            }.first.flatMap(URL.init(string:))
            return Title(appName: app, title: title, cover: cover, installSize: nil, downloadSize: nil)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Installed games

    struct Installed: Hashable {
        var appName: String
        var title: String
        var installPath: URL
        var executable: URL
        /// Bytes, as legendary recorded when it installed it.
        var installSize: Int64? = nil
    }

    /// The DLC legendary has installed into a game's folder: cleared from its records with the game.
    nonisolated static func dlc(installedAt folder: URL) -> [String] {
        let url = EpicAccount.configDir.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return root.compactMap { app, entry in
            (entry["is_dlc"] as? Bool) == true && (entry["install_path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path } == folder.standardizedFileURL.path ? app : nil
        }
    }

    /// What Anvil's own Epic connection has installed: legendary's installed.json.
    nonisolated static func installed() -> [Installed] {
        let url = EpicAccount.configDir.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return root.compactMap { app, entry in
            guard let title = entry["title"] as? String, let path = entry["install_path"] as? String,
                  let exe = entry["executable"] as? String, !exe.isEmpty else { return nil }
            let base = URL(fileURLWithPath: path, isDirectory: true)
            return Installed(appName: app, title: title, installPath: base,
                             executable: base.appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/")),
                             installSize: (entry["install_size"] as? NSNumber)?.int64Value)
        }
    }

    func isInstalled(_ appName: String) -> Bool { Self.installed().contains { $0.appName == appName } }

    /// Every game installed through Anvil, in the library.
    @discardableResult
    func importInstalled() async -> [String] {
        let library = Library.shared
        // Games the library already has — imported from Mythic, say — are only marked as
        // Epic's. The Epic container is made only for a game that needs it: on 1 October
        // Mythic's two games were already in the library, and three empty containers
        // (434 MB each) were made anyway.
        var needed: [Installed] = []
        for found in Self.installed() {
            if var known = library.games.first(where: { $0.epicAppName == found.appName }) {
                if known.executablePath != found.executable.path, !known.exists {
                    known.executablePath = found.executable.path
                    library.update(known)
                }
            } else if var known = library.games.first(where: { $0.executablePath == found.executable.path }) {
                known.epicAppName = found.appName
                library.update(known)
            } else {
                needed.append(found)
            }
        }
        guard !needed.isEmpty, let c = await container() else { return [] }
        var added: [String] = []
        for found in needed {
            // Added by another call while this one waited for the container.
            if library.games.contains(where: { $0.epicAppName == found.appName }) { continue }
            var game = library.addGame(title: found.title, executable: found.executable, container: c)
            game.epicAppName = found.appName
            library.update(game)
            if let cover = owned.first(where: { $0.appName == found.appName })?.cover {
                Task { await Self.saveCover(cover, for: game) }
            }
            added.append(found.title)
            AnvilLog.write("epic: added \(found.title) to “\(c.name)”")
        }
        return added
    }

    /// The one being made, so callers at the same time share it rather than each making
    /// their own: making one takes Wine several seconds, and the startup, the setup and
    /// the Epic page all asked within those seconds on 1 October.
    private var making: Task<Container?, Never>?

    /// The container Epic games go in: one made for them, on the best engine.
    func container() async -> Container? {
        let library = Library.shared
        if let c = library.containers.first(where: { $0.storefront == "epic" }) { return c }
        if let making { return await making.value }
        guard let runtime = RuntimeManager.shared.defaultRuntime else {
            lastError = "No engine is installed yet. Anvil downloads one in its setup, or from Engines."
            return nil
        }
        let task = Task { await library.createContainer(named: "Epic Games", runtime: runtime) { $0.storefront = "epic" } }
        making = task
        defer { making = nil }
        return await task.value
    }

    private static func saveCover(_ url: URL, for game: Game) async {
        guard let (temp, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let named = temp.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).jpg")
        try? FileManager.default.moveItem(at: temp, to: named)
        _ = try? ArtworkStore.shared.setArtwork(from: named, for: game)
        try? FileManager.default.removeItem(at: named)
    }

    // MARK: Installing

    func install(_ title: Title) async {
        guard let tool = legendary else { lastError = "Anvil's Epic tool isn't installed yet."; return }
        guard installing[title.appName] == nil else { return }
        guard Connectivity.isOnlineNow else { lastError = "Installing needs an internet connection."; return }
        installing[title.appName] = 0
        downloads[title.appName] = Download()
        stopped[title.appName] = nil
        cancelled.remove(title.appName)
        lastError = nil
        try? FileManager.default.createDirectory(at: Self.gamesDir, withIntermediateDirectories: true)
        // What was in the games folder before: a folder that appears is this download's.
        let before = Set(Self.folders(in: Self.gamesDir).map(\.lastPathComponent))
        AnvilLog.write("epic: installing \(title.title) into \(Self.gamesDir.path)")
        let app = title.appName
        let status = await Self.runInstall(tool, appName: app, into: Self.gamesDir) { update in
            Task { @MainActor in
                let lib = EpicLibrary.shared
                guard lib.installing[app] != nil else { return }
                var d = lib.downloads[app] ?? Download()
                if let f = update.fraction { d.fraction = f; lib.installing[app] = f }
                if let v = update.speed { d.speed = v }
                if let t = update.secondsLeft { d.secondsLeft = t }
                if let b = update.downloadBytes { d.downloadBytes = b }
                if let b = update.installBytes { d.installBytes = b }
                if let f = update.folder { d.folder = f }
                if d.folder == nil, let new = Self.folders(in: Self.gamesDir).first(where: { !before.contains($0.lastPathComponent) }) {
                    d.folder = new
                }
                lib.downloads[app] = d
                // Sizes heard from the install itself are as good as the ⓘ's.
                if d.downloadBytes != nil || d.installBytes != nil {
                    var size = lib.sizes[app] ?? Size()
                    size.download = d.downloadBytes ?? size.download
                    size.install = d.installBytes ?? size.install
                    lib.sizes[app] = size
                }
            }
        }
        let download = downloads[app]
        installing[app] = nil
        downloads[app] = nil
        if cancelled.remove(app) != nil {
            let folder = download?.folder
            let kept = await Task.detached(priority: .utility) { folder.map { Self.allocatedSize(of: $0) } ?? 0 }.value
            stopped[app] = kept > 0
                ? "Stopped — \(Self.bytes(kept)) downloaded so far is kept; Install carries on from there."
                : "Stopped."
            AnvilLog.write("epic: download of \(title.title) stopped (\(Self.bytes(kept)) kept)")
            return
        }
        guard status == 0, isInstalled(app) else {
            lastError = "\(title.title) didn't finish installing (\(status)). Free disk space and the connection are the usual reasons; installing again carries on where it stopped."
            AnvilLog.write("epic: install of \(title.title) ended with \(status)")
            return
        }
        AnvilLog.write("epic: \(title.title) installed")
        await importInstalled()
    }

    /// A download under way stopped. legendary is interrupted as Ctrl-C would — it writes down what it has, so
    /// installing again carries on — and ended outright if it hasn't in 10 s. With `deleting`, what it had
    /// downloaded goes to the Trash too, with its note of where it was.
    func cancel(_ appName: String, deleting: Bool) {
        guard installing[appName] != nil else { return }
        cancelled.insert(appName)
        let folder = downloads[appName]?.folder
        let title = owned.first { $0.appName == appName }?.title ?? appName
        AnvilLog.write("epic: stopping the download of \(title)\(deleting ? ", and deleting what it had" : "")")
        Self.interrupt(appName)
        guard deleting else { return }
        Task {
            // Once legendary has let go of its files.
            for _ in 0..<40 where installing[appName] != nil { try? await Task.sleep(for: .milliseconds(250)) }
            let freed = await Task.detached(priority: .utility) { () -> Int64 in
                var freed: Int64 = 0
                if let folder, Self.isOurs(folder) {
                    freed = Self.allocatedSize(of: folder)
                    try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                }
                try? FileManager.default.removeItem(at: Self.resumeFile(appName))
                return freed
            }.value
            stopped[appName] = freed > 0 ? "Stopped, and the \(Self.bytes(freed)) downloaded moved to the Trash." : "Stopped."
            AnvilLog.write("epic: \(title) — partial download deleted (\(Self.bytes(freed)) to the Trash)")
        }
    }

    /// The running `legendary install`s, by app name, so one can be stopped.
    nonisolated(unsafe) private static var running: [String: Process] = [:]
    nonisolated private static let runningLock = NSLock()

    nonisolated private static func interrupt(_ appName: String) {
        runningLock.lock()
        let p = running[appName]
        runningLock.unlock()
        guard let p, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
    }

    /// Where legendary notes how far a download got (its tmp folder, in Anvil's Epic settings).
    nonisolated static func resumeFile(_ appName: String) -> URL {
        EpicAccount.configDir.appendingPathComponent("tmp/\(appName).resume")
    }

    /// A folder directly inside the games folder Anvil installs to — the only kind it clears a download from.
    nonisolated static func isOurs(_ folder: URL) -> Bool {
        let base = gamesDir.standardizedFileURL.path
        let f = folder.standardizedFileURL
        return f.deletingLastPathComponent().path == base && !f.lastPathComponent.isEmpty && !f.lastPathComponent.hasPrefix(".")
    }

    nonisolated static func folders(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// What a folder takes on disk, in bytes.
    nonisolated static func allocatedSize(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Free on the disk a folder is on, for what a game can still take.
    nonisolated static func freeSpace(at folder: URL) -> Int64? {
        var dir = folder
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir = dir.deletingLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
    }

    nonisolated static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    // MARK: Sizes

    /// How big a game is, from Epic's manifest of it — `legendary info`, which reads the manifest and nothing else:
    /// what downloading takes (it comes compressed) and what it takes on disk once installed, with what's free here.
    func fetchSize(_ title: Title) async {
        let app = title.appName
        guard !sizing.contains(app) else { return }
        if let known = sizes[app], known.failed == nil, known.download != nil || known.install != nil {
            sizes[app]?.free = Self.freeSpace(at: Self.gamesDir)
            return
        }
        guard let tool = legendary else { sizes[app] = Size(failed: "Anvil's Epic tool isn't installed yet."); return }
        guard Connectivity.isOnlineNow else { sizes[app] = Size(free: Self.freeSpace(at: Self.gamesDir), failed: "Epic's sizes need a connection."); return }
        sizing.insert(app)
        defer { sizing.remove(app) }
        let (status, output) = await EpicAccount.run(tool, ["info", app, "--platform", "Windows", "--json"], timeout: 90)
        var size = Self.parseSize(output)
        size.free = Self.freeSpace(at: Self.gamesDir)
        if size.download == nil && size.install == nil {
            size.failed = Self.signInExpired(output) ? "Epic asked for you to sign in again." : "Epic didn't say (\(status))."
            AnvilLog.write("epic: size of \(title.title) not read (\(status))")
        } else {
            AnvilLog.write("epic: \(title.title) — download \(size.download.map(Self.bytes) ?? "?"), installed \(size.install.map(Self.bytes) ?? "?")")
            if let i = owned.firstIndex(where: { $0.appName == app }) {
                owned[i].downloadSize = size.download
                owned[i].installSize = size.install
            }
        }
        sizes[app] = size
    }

    /// `legendary info --json`'s manifest sizes, in bytes ("download_size", "disk_size"); else its words for them
    /// ("Download size (compressed): 12.34 GiB", "Disk size (uncompressed): …").
    nonisolated static func parseSize(_ output: String) -> Size {
        var size = Size()
        if let end = output.lastIndex(of: "}"), let start = output.firstIndex(of: "{"), start < end,
           let root = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
           let manifest = root["manifest"] as? [String: Any] {
            size.download = (manifest["download_size"] as? NSNumber)?.int64Value
            size.install = (manifest["disk_size"] as? NSNumber)?.int64Value
        }
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if size.download == nil, line.contains("Download size") { size.download = amount(in: line) }
            if size.install == nil, line.contains("Disk size") || line.contains("Install size") { size.install = amount(in: line) }
        }
        return size
    }

    /// "…: 12.34 GiB" (or MiB, KiB) → bytes.
    nonisolated static func amount(in line: String) -> Int64? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let number = rest.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        let unit = rest.dropFirst(number.count).trimmingCharacters(in: .whitespaces).prefix(3).uppercased()
        let kib = 1024.0
        let scale: Double = unit.hasPrefix("GIB") || unit.hasPrefix("GB") ? kib * kib * kib : unit.hasPrefix("MIB") || unit.hasPrefix("MB") ? kib * kib
            : unit.hasPrefix("KIB") || unit.hasPrefix("KB") ? kib : unit.hasPrefix("TIB") ? kib * kib * kib * kib : 1
        return Int64(value * scale)
    }

    // MARK: Leftovers

    /// Folders in the games folder no installed game uses and no download is writing to: downloads stopped or
    /// failed before 0.53, which stayed behind — and how much each takes. None while a download runs.
    struct Leftover: Identifiable, Hashable { var id: String { folder.path }; var folder: URL; var bytes: Int64 }

    func leftovers() async -> [Leftover] {
        guard installing.isEmpty else { return [] }
        return await Task.detached(priority: .utility) { () -> [Leftover] in
            let used = Set(Self.installed().map { $0.installPath.standardizedFileURL.path })
            return Self.folders(in: Self.gamesDir)
                .filter { !used.contains($0.standardizedFileURL.path) }
                .map { Leftover(folder: $0, bytes: Self.allocatedSize(of: $0)) }
        }.value
    }

    /// A leftover download to the Trash.
    func trashLeftover(_ leftover: Leftover) async {
        guard installing.isEmpty, Self.isOurs(leftover.folder) else { return }
        let folder = leftover.folder
        let done = await Task.detached(priority: .utility) { (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) != nil }.value
        AnvilLog.write("epic: leftover download \(folder.lastPathComponent) \(done ? "moved to the Trash" : "couldn't be moved to the Trash") (\(Self.bytes(leftover.bytes)))")
    }

    /// `legendary install`, with its progress lines turned into a fraction as they come.
    /// What one chunk of legendary's output said about the download.
    struct ProgressUpdate: Sendable {
        var fraction: Double?; var speed: Double?; var secondsLeft: Int?
        var downloadBytes: Int64?; var installBytes: Int64?; var folder: URL?
        var any: Bool { fraction != nil || speed != nil || secondsLeft != nil || downloadBytes != nil || installBytes != nil || folder != nil }
    }

    nonisolated static func progress(in text: String) -> ProgressUpdate {
        var u = ProgressUpdate()
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if let f = progressFraction(in: line) { u.fraction = f }
            if let t = secondsLeft(in: line) { u.secondsLeft = t }
            if let v = speed(in: line) { u.speed = v }
            // Before it starts: "[cli] INFO: Install size: 41234.56 MiB", "… Download size: 30123.45 MiB (Compression
            // savings: …)", and where it goes ("Install path: /…").
            if line.contains("Download size:") { u.downloadBytes = amount(in: String(line.prefix { $0 != "(" })) }
            if line.contains("Install size:") { u.installBytes = amount(in: line) }
            if let r = line.range(of: "Install path: ") {
                let path = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { u.folder = URL(fileURLWithPath: path, isDirectory: true) }
            }
        }
        return u
    }

    /// "… ETA: 00:09:23" → 563.
    nonisolated static func secondsLeft(in line: String) -> Int? {
        guard let r = line.range(of: "ETA: ") else { return nil }
        let parts = line[r.upperBound...].prefix { $0.isNumber || $0 == ":" }.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// "[DLManager] INFO:  + Download\t- 13.76 MiB/s (raw) / …" → 13.76.
    nonisolated static func speed(in line: String) -> Double? {
        guard line.contains("+ Download"), let dash = line.range(of: "- ", range: line.range(of: "+ Download")!.upperBound..<line.endIndex)
        else { return nil }
        return Double(line[dash.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    nonisolated static func runInstall(_ tool: URL, appName: String, into dir: URL,
                                       progress: @escaping @Sendable (ProgressUpdate) -> Void) async -> Int32 {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = tool
            p.arguments = ["install", appName, "--platform", "Windows", "--base-path", dir.path, "--yes", "--skip-sdl"]
            var env = ProcessInfo.processInfo.environment
            env["LEGENDARY_CONFIG_PATH"] = EpicAccount.configDir.path
            for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("WINE") || key.hasPrefix("ANVIL_") {
                env.removeValue(forKey: key)
            }
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let update = Self.progress(in: text)
                if update.any { progress(update) }
            }
            p.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                runningLock.lock(); running[appName] = nil; runningLock.unlock()
                EpicVault.close()
                continuation.resume(returning: process.terminationStatus)
            }
            // The sign-in is decrypted while legendary downloads, and sealed again when it ends.
            EpicVault.open()
            do {
                try p.run()
                runningLock.lock(); running[appName] = p; runningLock.unlock()
            } catch { EpicVault.close(); continuation.resume(returning: -1) }
        }
    }

    /// "[DLManager] INFO: = Progress: 12.34% (…)" → 0.1234.
    nonisolated static func progressFraction(in line: String) -> Double? {
        guard let range = line.range(of: "Progress: ") else { return nil }
        let number = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}
