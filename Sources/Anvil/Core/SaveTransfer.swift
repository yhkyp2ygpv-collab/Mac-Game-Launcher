import Foundation

/// Finding and moving save data between launchers.
///
/// Every Wine-based launcher on macOS builds its prefix the same way and names the
/// Windows user directory `crossover`, so save paths map one-to-one between them.
/// That is what makes an import a copy rather than a translation.
@MainActor
final class SaveTransfer: ObservableObject {

    /// A prefix belonging to another launcher.
    struct ExternalPrefix: Identifiable, Hashable {
        var id: String { driveC.path }
        var launcher: String
        var name: String
        var driveC: URL

        var displayName: String { "\(launcher) · \(name)" }
    }

    /// A directory that looks like save data.
    struct SaveCandidate: Identifiable, Hashable {
        var id: String { source.path }
        var source: URL
        /// Path beneath the Windows user profile, e.g. "AppData/LocalLow/Studio/Game".
        var relativePath: String
        var displayName: String
        var publisher: String
        var sizeBytes: Int64
        var modified: Date

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    @Published private(set) var prefixes: [ExternalPrefix] = []
    @Published private(set) var candidates: [SaveCandidate] = []
    @Published var status: String?
    @Published var scanning = false

    static let shared = SaveTransfer()
    private let fm = FileManager.default
    private init() {}

    // MARK: Discovery

    /// Save data lives in a handful of well-known places under the Windows profile.
    /// Scanning the whole prefix would surface every DLL and registry file as a
    /// "candidate"; these five cover essentially every PC game.
    nonisolated static let saveRoots = [
        "AppData/Roaming",
        "AppData/Local",
        "AppData/LocalLow",
        "Documents/My Games",
        "Saved Games",
        "Documents"
    ]

    /// Directories that live in the save roots but are never a game's save.
    /// This list is drawn from what a scan of real prefixes actually turns up — the
    /// launchers, crash reporters and browser caches that otherwise dominate the
    /// results and bury the one folder the user came for.
    nonisolated static let ignored: Set<String> = [
        "Microsoft", "Packages", "Temp", "CrashDumps", "ConnectedDevicesPlatform",
        "Comms", "Desktop", "Downloads", "Pictures", "Music", "Videos", "My Music",
        "My Pictures", "My Videos", "Application Data",
        // Launchers and runtimes
        "Steam", "EpicGamesLauncher", "Epic Games", "GOG.com", "Ubisoft Game Launcher",
        "NVIDIA Corporation", "NVIDIA", "AMD", "Battle.net", "Origin", "EA Desktop",
        "UnrealEngine", "Unity", "CrashReportClient", "Programs", "D3DSCache",
        "wine", "Mozilla", "Google"
    ]

    /// Substrings that mark a directory as machine-generated rather than player data.
    /// A crash folder or a browser cache is not a save, and a 400 MB htmlcache
    /// showing up above a 26 MB save makes the list useless.
    nonisolated static let ignoredSubstrings = [
        "crash", "cache", "logs", "log files", "shadercache", "temp", "telemetry",
        "diagnostics", "webcache", "gfnruntime"
    ]

    nonisolated static func isNoise(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ignored.contains(name) { return true }
        return ignoredSubstrings.contains { lower.contains($0) }
    }

    func discoverPrefixes() {
        let home = fm.homeDirectoryForCurrentUser
        var found: [ExternalPrefix] = []

        func addAll(in root: URL, launcher: String, nameFromDirectory: Bool = true) {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            for entry in entries where entry.hasDirectoryPath {
                let driveC = entry.appendingPathComponent("drive_c")
                guard fm.fileExists(atPath: driveC.path) else { continue }
                found.append(ExternalPrefix(launcher: launcher,
                                            name: entry.lastPathComponent,
                                            driveC: driveC))
            }
        }

        addAll(in: home.appendingPathComponent("Library/Containers/xyz.blackxfiied.Mythic/Containers"),
               launcher: "Mythic")
        addAll(in: home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles"),
               launcher: "Whisky")
        addAll(in: home.appendingPathComponent("Games/Heroic/Prefixes"), launcher: "Heroic")
        addAll(in: home.appendingPathComponent("Library/Application Support/CrossOver/Bottles"),
               launcher: "CrossOver")

        prefixes = found.sorted { $0.displayName < $1.displayName }
    }

    /// Add a prefix the user points at by hand, for a launcher Anvil doesn't know.
    func addCustomPrefix(_ url: URL) -> ExternalPrefix? {
        // Accept either the prefix root or drive_c itself.
        let driveC = url.lastPathComponent == "drive_c" ? url : url.appendingPathComponent("drive_c")
        guard fm.fileExists(atPath: driveC.path) else {
            status = "That folder isn't a Wine prefix — no drive_c inside it."
            return nil
        }
        let prefix = ExternalPrefix(launcher: "Custom",
                                    name: driveC.deletingLastPathComponent().lastPathComponent,
                                    driveC: driveC)
        if !prefixes.contains(prefix) { prefixes.append(prefix) }
        return prefix
    }

    // MARK: Scanning

    func scan(_ prefix: ExternalPrefix) {
        scanning = true
        defer { scanning = false }

        var found: [SaveCandidate] = []
        let users = prefix.driveC.appendingPathComponent("users")
        guard let userDirs = try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) else {
            candidates = []
            return
        }

        for userDir in userDirs where userDir.lastPathComponent != "Public" {
            for root in Self.saveRoots {
                let rootURL = userDir.appendingPathComponent(root)
                guard let entries = try? fm.contentsOfDirectory(
                    at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }

                for entry in entries where entry.hasDirectoryPath {
                    let name = entry.lastPathComponent
                    if Self.isNoise(name) { continue }

                    // A publisher folder holds the game folder; report the game, not
                    // the publisher, so the list reads like a list of games.
                    let children = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil))?
                        .filter(\.hasDirectoryPath) ?? []
                    let targets = children.isEmpty ? [entry] : children

                    for target in targets {
                        if Self.isNoise(target.lastPathComponent) { continue }
                        let size = Self.directorySize(target)
                        guard size > 0 else { continue }
                        let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast
                        found.append(SaveCandidate(
                            source: target,
                            relativePath: Self.relativeToProfile(target, profile: userDir),
                            displayName: target.lastPathComponent,
                            publisher: target == entry ? root : "\(root)/\(name)",
                            sizeBytes: size,
                            modified: modified))
                    }
                }
            }
        }

        // Most recently played first — that is nearly always the save being looked for.
        candidates = found.sorted { $0.modified > $1.modified }
    }

    private static func relativeToProfile(_ url: URL, profile: URL) -> String {
        let full = url.path
        let base = profile.path + "/"
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
    }

    // MARK: Import

    /// Copy a save into an Anvil container at the same profile-relative path.
    ///
    /// Anything already there is moved aside first, never overwritten — a save is the
    /// one thing in a prefix that cannot be regenerated.
    func importSave(_ candidate: SaveCandidate, into container: Container) throws {
        let users = container.driveC.appendingPathComponent("users")
        // Match the destination profile to whatever wineboot created.
        let profileName = (try? fm.contentsOfDirectory(atPath: users.path))?
            .first { $0 != "Public" } ?? "crossover"
        let destination = users
            .appendingPathComponent(profileName)
            .appendingPathComponent(candidate.relativePath)

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        // Build the copy under a temporary name first, then swap it in.
        //
        // `cp -R src dst` copies *into* dst when dst already exists, producing
        // "Cat Quest II/Cat Quest II" instead of replacing it. Staging to a name that
        // cannot exist makes that structurally impossible, and it means a failure
        // part-way through leaves the existing save untouched rather than half-written.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".anvil-import-\(UUID().uuidString)")

        // Clone rather than copy: instant on APFS, and correct elsewhere.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", candidate.source.path, staging.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? fm.removeItem(at: staging)
            throw TransferError.copyFailed
        }

        // Only now displace whatever is already there, keeping it rather than
        // deleting it — a save is the one thing in a prefix that cannot be rebuilt.
        if fm.fileExists(atPath: destination.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = destination.deletingLastPathComponent()
                .appendingPathComponent("\(destination.lastPathComponent).anvil-replaced-\(stamp)")
            try fm.moveItem(at: destination, to: aside)
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        status = "Imported \(candidate.displayName) (\(candidate.sizeDescription))."
    }

    /// What an export contains, written alongside it so the folder is
    /// self-describing months later.
    struct ExportManifest: Codable {
        var container: String
        var exportedAt: Date
        var anvilVersion: String
        var entries: [Entry]
        struct Entry: Codable {
            var name: String
            var relativePath: String
            var sizeBytes: Int64
        }
    }

    /// Copy saves out of an Anvil container, for archiving or moving to another Mac.
    ///
    /// Exports the Windows user profile with a manifest describing what is inside and
    /// where each item came from, so it can be put back — by Anvil or by hand — without
    /// having to work out the original paths again.
    @discardableResult
    func exportSaves(from container: Container, to destination: URL,
                     only selected: [SaveCandidate]? = nil) throws -> URL {
        let stamp = ISO8601DateFormatter()
        let formatter = stamp
        formatter.formatOptions = [.withFullDate]
        let folder = destination.appendingPathComponent(
            "\(container.name) saves \(formatter.string(from: Date()))")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let users = container.driveC.appendingPathComponent("users")
        var entries: [ExportManifest.Entry] = []

        if let selected, !selected.isEmpty {
            // Just the chosen saves, each at its profile-relative path.
            for candidate in selected {
                let target = folder.appendingPathComponent(candidate.relativePath)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try clone(candidate.source, to: target)
                entries.append(.init(name: candidate.displayName,
                                     relativePath: candidate.relativePath,
                                     sizeBytes: candidate.sizeBytes))
            }
        } else {
            try clone(users, to: folder.appendingPathComponent("users"))
            entries.append(.init(name: "Entire Windows user profile",
                                 relativePath: "users",
                                 sizeBytes: Self.directorySize(users)))
        }

        let manifest = ExportManifest(container: container.name,
                                      exportedAt: Date(),
                                      anvilVersion: "0.1.0",
                                      entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("anvil-export.json"))

        status = "Exported \(entries.count) item\(entries.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
        return folder
    }

    /// Scan a container's own saves, so they can be exported selectively.
    func scanOwnSaves(_ container: Container) {
        scan(ExternalPrefix(launcher: "Anvil", name: container.name, driveC: container.driveC))
    }

    private func clone(_ src: URL, to dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", src.path, dst.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TransferError.copyFailed }
    }

    // MARK: Registry saves

    /// Unity and many older engines keep settings — and sometimes progress — in the
    /// Windows registry rather than in files, so a file-only import silently leaves
    /// them behind. Cat Quest II is a plain example: its save is a file, but its
    /// controller bindings and options live under HKCU\Software.
    ///
    /// Wine's user.reg is close to a .reg file but not identical: keys are written
    /// without a hive prefix, backslashes are doubled, and each key carries a
    /// timestamp line Windows would reject. This converts, then lets `regedit`
    /// perform the merge rather than editing user.reg by hand, which would race with
    /// a running wineserver.
    func registryKeys(in prefix: ExternalPrefix, matching term: String) -> [String] {
        let userReg = prefix.driveC.deletingLastPathComponent().appendingPathComponent("user.reg")
        guard let text = try? String(contentsOf: userReg, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .filter { $0.hasPrefix("[") && $0.localizedCaseInsensitiveContains(term) }
            .map { String($0.split(separator: "]")[0].dropFirst()) }
    }

    /// Copy every registry key matching `term` from one prefix into a container.
    func importRegistry(from prefix: ExternalPrefix, matching term: String,
                        into container: Container, runtime: Runtime) async throws {
        let userReg = prefix.driveC.deletingLastPathComponent().appendingPathComponent("user.reg")
        guard let text = try? String(contentsOf: userReg, encoding: .utf8) else { return }

        var out = ["Windows Registry Editor Version 5.00", ""]
        var capturing = false
        var keys = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                let key = String(line.split(separator: "]")[0].dropFirst())
                capturing = key.localizedCaseInsensitiveContains(term)
                if capturing {
                    keys += 1
                    out.append("")
                    out.append("[HKEY_CURRENT_USER\\" + key.replacingOccurrences(of: "\\\\", with: "\\") + "]")
                }
                continue
            }
            // #time is Wine bookkeeping and is not valid in a .reg file.
            if capturing && !line.hasPrefix("#time") { out.append(String(line)) }
        }
        guard keys > 0 else { return }

        // regedit reads a path inside the prefix, so the file has to live in drive_c.
        let staged = container.driveC.appendingPathComponent("anvil-import.reg")
        try out.joined(separator: "\n").write(to: staged, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: staged) }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = runtime.wine64
            p.arguments = ["regedit", "/S", "C:\\anvil-import.reg"]   // silently: no window for the player to close
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = container.prefixURL.path
            env["WINEDEBUG"] = "-all"
            env["DYLD_FALLBACK_LIBRARY_PATH"] =
                "\(runtime.root.appendingPathComponent("lib").path):\(runtime.externalLibs.path):/usr/lib"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in cont.resume() }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        status = "Imported \(keys) registry key\(keys == 1 ? "" : "s")."
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        var counted = 0
        for case let f as URL in walker {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            counted += 1
            if counted > 20_000 { break }
        }
        return total
    }

    enum TransferError: LocalizedError {
        case copyFailed
        var errorDescription: String? { "Could not copy the save. Check free disk space and permissions." }
    }
}
