import Foundation

/// One game's own saves, out of Anvil into a single file and back: to keep a copy, or before
/// deleting a game — the game goes, its progress doesn't.
///
/// A game's saves are the folders under its container's Windows profile named after it (its
/// title's words, its program's name), its Steam cloud folder for a Steam game, and — in a
/// container that holds no other game — every save folder there. The export is a .zip with the
/// folders at their places under the profile and a list of them (anvil-saves.json), so Anvil,
/// or anyone, can put them back where the game looks for them.
enum GameSaves {
    struct Place: Codable, Hashable {
        /// Under the Windows profile ("AppData/Roaming/Warner Bros. Interactive Entertainment/…"),
        /// or under the container's drive C for Steam's cloud folder ("C:/Program Files (x86)/…").
        var relativePath: String
        var bytes: Int64
        var underDriveC = false
    }

    struct Manifest: Codable {
        var game: String
        var exportedAt: Date
        var anvilVersion: String
        var steamAppID: String?
        var epicAppName: String?
        var places: [Place]
    }

    enum Failure: LocalizedError {
        case nothingFound(String)
        case notAnExport
        case toolFailed(String)
        var errorDescription: String? {
            switch self {
            case .nothingFound(let title): "No saves for \(title) were found in its container."
            case .notAnExport: "That file isn't a save export made by Anvil."
            case .toolFailed(let why): why
            }
        }
    }

    /// Words too common to tell one game from another.
    nonisolated static let commonWords: Set<String> = ["the", "and", "of", "for", "edition", "game", "games", "remastered",
                                                       "definitive", "deluxe", "complete", "goty", "ultimate"]

    /// The words of a title or folder name, lowercase letters and digits only.
    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Whether a folder's name is this game's: it carries the program's name, or at least two of
    /// the title's telling words (all of them for a one-word title).
    nonisolated static func belongs(_ folder: String, title: String, executable: String) -> Bool {
        let joined = words(folder).joined()
        let stem = words((executable as NSString).deletingPathExtension).joined()
        if stem.count >= 4, joined.contains(stem) { return true }
        let telling = words(title).filter { $0.count >= 3 && !commonWords.contains($0) }
        guard !telling.isEmpty else { return false }
        let found = telling.filter { joined.contains($0) }.count
        return found >= min(2, telling.count)
    }

    /// The Windows user's profile folder in a container ("drive_c/users/crossover").
    nonisolated static func profile(in container: Container) -> URL? {
        let users = container.driveC.appendingPathComponent("users")
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: users.path))?
            .sorted().first(where: { $0 != "Public" && !$0.hasPrefix(".") }) else { return nil }
        return users.appendingPathComponent(name, isDirectory: true)
    }

    /// The game's save folders in its container.
    nonisolated static func places(for game: Game, in container: Container, aloneInContainer: Bool) -> [Place] {
        let fm = FileManager.default
        var out: [Place] = []
        var all: [Place] = []
        if let profile = profile(in: container) {
            let driveC = container.driveC.resolvingSymlinksInPath().path + "/"
            for root in SaveTransfer.saveRoots {
                let rootURL = profile.appendingPathComponent(root, isDirectory: true)
                // A Documents linked out to the Mac's own holds the person's files — and, under the
                // game's own name, a game's saves (Cat Quest II's "Cat Quest II/save_file1.dat").
                // Only that folder is looked for; nothing else there is read.
                guard rootURL.resolvingSymlinksInPath().path.hasPrefix(driveC) else {
                    if root == "Documents" {
                        for folder in SaveGuard.documentsFolders(for: [game.title, game.executableURL.deletingPathExtension().lastPathComponent]) {
                            let url = rootURL.appendingPathComponent(folder, isDirectory: true)
                            var isDir: ObjCBool = false
                            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                            let size = SaveTransfer.directorySize(url)
                            if size > 0 { out.append(Place(relativePath: root + "/" + folder, bytes: size)) }
                        }
                    }
                    continue
                }
                guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { continue }
                for entry in entries where entry.hasDirectoryPath && !SaveTransfer.isNoise(entry.lastPathComponent) {
                    // "Documents" holds "My Games" (its own root) — not a save of its own.
                    if root == "Documents", entry.lastPathComponent == "My Games" { continue }
                    let rel = root + "/" + entry.lastPathComponent
                    // A publisher's folder ("Warner Bros. Interactive Entertainment") holds the
                    // game's: the game's own folder is taken where there is one.
                    let children = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.hasDirectoryPath && !SaveTransfer.isNoise($0.lastPathComponent) }
                    if belongs(entry.lastPathComponent, title: game.title, executable: game.executableURL.lastPathComponent) {
                        let size = SaveTransfer.directorySize(entry)
                        if size > 0 { out.append(Place(relativePath: rel, bytes: size)) }
                        continue
                    }
                    var matchedChild = false
                    for child in children where belongs(child.lastPathComponent, title: game.title, executable: game.executableURL.lastPathComponent) {
                        let size = SaveTransfer.directorySize(child)
                        if size > 0 { out.append(Place(relativePath: rel + "/" + child.lastPathComponent, bytes: size)); matchedChild = true }
                    }
                    if !matchedChild {
                        let size = SaveTransfer.directorySize(entry)
                        if size > 0 { all.append(Place(relativePath: rel, bytes: size)) }
                    }
                }
            }
        }
        // Steam's cloud copy of the game's saves, for each account that played it.
        if let appID = game.steamAppID {
            let userdata = SteamSupport.steamDir(in: container).appendingPathComponent("userdata", isDirectory: true)
            for account in (try? fm.contentsOfDirectory(atPath: userdata.path)) ?? [] {
                let folder = userdata.appendingPathComponent(account).appendingPathComponent(appID, isDirectory: true)
                guard fm.fileExists(atPath: folder.path) else { continue }
                let rel = String(folder.path.dropFirst(container.driveC.path.count + 1))
                out.append(Place(relativePath: rel, bytes: SaveTransfer.directorySize(folder), underDriveC: true))
            }
        }
        // In a container of its own, every save folder there is the game's.
        if aloneInContainer { out += all }
        return out
    }

    nonisolated static func source(of place: Place, in container: Container) -> URL? {
        place.underDriveC ? container.driveC.appendingPathComponent(place.relativePath)
                          : profile(in: container)?.appendingPathComponent(place.relativePath)
    }

    /// Where an export is put together, and one is unpacked: Anvil's own folder, on the disk the
    /// containers are on, so the saves are cloned rather than copied.
    nonisolated static var staging: URL { RuntimeManager.support.appendingPathComponent("Cache/SaveExport", isDirectory: true) }

    /// The game's saves as one .zip in `folder`; its URL. `suffix` goes after the date in its name ("before restoring").
    nonisolated static func export(game: Game, container: Container, aloneInContainer: Bool, to folder: URL,
                                   suffix: String? = nil) throws -> URL {
        let fm = FileManager.default
        let found = places(for: game, in: container, aloneInContainer: aloneInContainer)
        guard !found.isEmpty else { throw Failure.nothingFound(game.title) }
        let stage = staging.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        for place in found {
            guard let from = source(of: place, in: container) else { continue }
            let to = stage.appendingPathComponent(place.underDriveC ? "drive_c" : "profile")
                .appendingPathComponent(place.relativePath)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/bin/cp", ["-Rc", from.path, to.path])
        }
        let manifest = Manifest(game: game.title, exportedAt: Date(), anvilVersion: AnvilVersion.current,
                                steamAppID: game.steamAppID, epicAppName: game.epicAppName, places: found)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("anvil-saves.json"))

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let safeTitle = game.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined()
            .split(separator: " ").joined(separator: " ")
        let tail = suffix.map { " \($0)" } ?? ""
        var zip = folder.appendingPathComponent("\(safeTitle) saves \(day)\(tail).zip")
        var n = 2
        while fm.fileExists(atPath: zip.path) {
            zip = folder.appendingPathComponent("\(safeTitle) saves \(day)\(tail) (\(n)).zip"); n += 1
        }
        try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", stage.path, zip.path])
        return zip
    }

    /// What an export holds, without unpacking it.
    nonisolated static func manifest(of zip: URL) throws -> Manifest {
        let out = try output("/usr/bin/unzip", ["-p", zip.path, "anvil-saves.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: out) else { throw Failure.notAnExport }
        return manifest
    }

    /// An export's saves back into a container, each at its own place. What is there already is
    /// moved aside beside it ("….anvil-replaced-<time>"), never overwritten.
    @discardableResult
    nonisolated static func restore(from zip: URL, into container: Container) throws -> Manifest {
        let fm = FileManager.default
        let manifest = try manifest(of: zip)
        let stage = staging.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path])
        for place in manifest.places {
            let from = stage.appendingPathComponent(place.underDriveC ? "drive_c" : "profile").appendingPathComponent(place.relativePath)
            // Nothing outside the place it names: no "..", no absolute path.
            guard fm.fileExists(atPath: from.path), !place.relativePath.contains(".."), !place.relativePath.hasPrefix("/"),
                  let to = source(of: place, in: container) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) {
                let aside = to.deletingLastPathComponent()
                    .appendingPathComponent("\(to.lastPathComponent).anvil-replaced-\(Int(Date().timeIntervalSince1970))")
                try fm.moveItem(at: to, to: aside)
            }
            try run("/bin/cp", ["-Rc", from.path, to.path])
        }
        return manifest
    }

    /// Save folders from one Windows setup into another, each at its own place — a game downloaded again into a
    /// new setup gets the saves it left in the old one. What is there already is moved aside, as `restore` does.
    /// Returns how many folders were copied.
    @discardableResult
    nonisolated static func copy(_ places: [Place], from other: Container, into container: Container) throws -> Int {
        let fm = FileManager.default
        var n = 0
        for place in places {
            guard !place.relativePath.contains(".."), !place.relativePath.hasPrefix("/"),
                  let from = source(of: place, in: other), fm.fileExists(atPath: from.path),
                  let to = source(of: place, in: container) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) {
                let aside = to.deletingLastPathComponent()
                    .appendingPathComponent("\(to.lastPathComponent).anvil-replaced-\(Int(Date().timeIntervalSince1970))")
                try fm.moveItem(at: to, to: aside)
            }
            try run("/bin/cp", ["-Rc", from.path, to.path])
            n += 1
        }
        return n
    }

    /// Where a game's own files are, for deleting it: the install folder its store recorded, or
    /// the folder of its program when that is plainly the game's own. Nil when Anvil can't tell —
    /// a Steam game is Steam's to remove, and a program at the top of a disk or inside a
    /// container's Windows folders isn't a folder to throw away.
    nonisolated static func installFolder(of game: Game, epicInstallPath: String?) -> URL? {
        if game.steamAppID != nil { return nil }
        if let path = epicInstallPath { return URL(fileURLWithPath: path, isDirectory: true) }
        let folder = game.executableURL.deletingLastPathComponent().standardizedFileURL
        let parts = folder.pathComponents
        let protected: Set<String> = ["/", "/Applications", "/Users", "/Library", "/System", "/Volumes",
                                      FileManager.default.homeDirectoryForCurrentUser.path]
        guard parts.count >= 4, !protected.contains(folder.path),
              !folder.path.contains("/drive_c/windows"), folder.lastPathComponent != "drive_c",
              !["Program Files", "Program Files (x86)", "Games", "Desktop", "Downloads", "Documents"].contains(folder.lastPathComponent)
        else { return nil }
        return folder
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure.toolFailed("\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func output(_ tool: String, _ arguments: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.notAnExport }
        return data
    }
}
