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

    /// An Unreal Engine game's project name — the folder its program is in, <Project>/Binaries/Win64 — which names
    /// its folder under AppData/Local: Hogwarts Legacy's saves are in "Phoenix/Saved/SaveGames". Nil for any other
    /// game. Until 0.62 that folder wasn't taken for the game's: on 18 October its export, before it was deleted,
    /// held only an empty "Hogwarts Legacy" folder (74 bytes), and its saves stayed only because its Windows setup did.
    nonisolated static func unrealProject(of game: Game) -> String? {
        let comps = GameAnalysis.drawingProgram(for: game.executableURL).pathComponents
        guard let bin = comps.lastIndex(of: "Binaries"), bin > 0 else { return nil }
        let project = comps[bin - 1]
        return project == "Engine" ? nil : project
    }

    /// Whether a save folder's name is the game's, by `belongs` or as its Unreal project.
    nonisolated static func isGames(_ folder: String, _ game: Game, project: String?) -> Bool {
        if let project, folder.caseInsensitiveCompare(project) == .orderedSame { return true }
        return belongs(folder, title: game.title, executable: game.executableURL.lastPathComponent)
    }

    /// Whether a place in an export or a setup is `game`'s, by any folder on its path below the profile's own
    /// ("AppData/Local/Phoenix", "Documents/Cat Quest II"), or as its Steam cloud folder.
    nonisolated static func isGames(_ place: Place, _ game: Game) -> Bool {
        if place.underDriveC { return game.steamAppID.map { place.relativePath.hasSuffix("/" + $0) } ?? false }
        let project = unrealProject(of: game)
        return place.relativePath.split(separator: "/").dropFirst().contains { isGames(String($0), game, project: project) }
    }

    /// Of an export's places, the ones to put back for `game` into a setup it shares with `others`: its own, where it
    /// has any; otherwise every one no other game there owns. An export made while a game was alone in its setup holds
    /// every save folder there — LEGO Star Wars' "before restoring" copy of 21 October held Hogwarts Legacy's, left
    /// in the setup after it was deleted — and putting that back would take another game back to that day.
    nonisolated static func toRestore(_ places: [Place], for game: Game, others: [Game]) -> [Place] {
        let own = places.filter { isGames($0, game) }
        if !own.isEmpty { return own }
        return places.filter { place in !others.contains { isGames(place, $0) } }
    }

    /// Where what's in the way goes, beside it: "….anvil-replaced-<time>", and "-2", "-3"… after that when the same
    /// second already has one. Two restores in one second used to collide on the name (Cocoa error 516, 21 October).
    nonisolated static func aside(for url: URL) -> URL {
        let base = "\(url.lastPathComponent).anvil-replaced-\(Int(Date().timeIntervalSince1970))"
        let folder = url.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            candidate = folder.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    /// The Windows user's profile folder in a container ("drive_c/users/crossover").
    nonisolated static func profile(in container: Container) -> URL? { profile(driveC: container.driveC) }

    /// The same under any drive C laid out as a container's — one of Save Guard's backups ("…/drive_c").
    nonisolated static func profile(driveC: URL) -> URL? {
        let users = driveC.appendingPathComponent("users")
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: users.path))?
            .sorted().first(where: { $0 != "Public" && !$0.hasPrefix(".") }) else { return nil }
        return users.appendingPathComponent(name, isDirectory: true)
    }

    /// The game's save folders in its container. `macDocuments`: false leaves out a Documents linked out to
    /// the Mac's own — one folder every setup shares, so it isn't a setup's own saves to choose or copy.
    nonisolated static func places(for game: Game, in container: Container, aloneInContainer: Bool,
                                   macDocuments: Bool = true) -> [Place] {
        places(for: game, driveC: container.driveC, aloneInContainer: aloneInContainer, macDocuments: macDocuments,
               steamFolder: SteamSupport.steamDir(in: container))
    }

    /// The same under any drive C laid out as a container's — a Save Guard backup's, where a Documents that was linked
    /// out is a folder of its own.
    nonisolated static func places(for game: Game, driveC driveCURL: URL, aloneInContainer: Bool, macDocuments: Bool = true,
                                   steamFolder: URL? = nil) -> [Place] {
        let fm = FileManager.default
        var out: [Place] = []
        var all: [Place] = []
        let project = unrealProject(of: game)
        if let profile = profile(driveC: driveCURL) {
            let driveC = driveCURL.resolvingSymlinksInPath().path + "/"
            for root in SaveTransfer.saveRoots {
                let rootURL = profile.appendingPathComponent(root, isDirectory: true)
                // A Documents linked out to the Mac's own holds the person's files — and, under the
                // game's own name, a game's saves (Cat Quest II's "Cat Quest II/save_file1.dat").
                // Only that folder is looked for; nothing else there is read.
                guard rootURL.resolvingSymlinksInPath().path.hasPrefix(driveC) else {
                    if root == "Documents", macDocuments {
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
                for entry in entries where entry.hasDirectoryPath && !SaveTransfer.isNoise(entry.lastPathComponent)
                    && (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true {
                    // "Documents" holds "My Games" (its own root) — not a save of its own.
                    if root == "Documents", entry.lastPathComponent == "My Games" { continue }
                    let rel = root + "/" + entry.lastPathComponent
                    // A publisher's folder ("Warner Bros. Interactive Entertainment") holds the
                    // game's: the game's own folder is taken where there is one.
                    let children = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.hasDirectoryPath && !SaveTransfer.isNoise($0.lastPathComponent) }
                    if isGames(entry.lastPathComponent, game, project: project) {
                        let size = SaveTransfer.directorySize(entry)
                        if size > 0 { out.append(Place(relativePath: rel, bytes: size)) }
                        continue
                    }
                    var matchedChild = false
                    for child in children where isGames(child.lastPathComponent, game, project: project) {
                        let size = SaveTransfer.directorySize(child)
                        if size > 0 { out.append(Place(relativePath: rel + "/" + child.lastPathComponent, bytes: size)); matchedChild = true }
                    }
                    // Sized only when it may be taken: in a setup of the game's own.
                    if !matchedChild, aloneInContainer {
                        let size = SaveTransfer.directorySize(entry)
                        if size > 0 { all.append(Place(relativePath: rel, bytes: size)) }
                    }
                }
            }
        }
        // Steam's cloud copy of the game's saves, for each account that played it.
        if let appID = game.steamAppID, let steamFolder {
            let userdata = steamFolder.appendingPathComponent("userdata", isDirectory: true)
            for account in (try? fm.contentsOfDirectory(atPath: userdata.path)) ?? [] {
                let folder = userdata.appendingPathComponent(account).appendingPathComponent(appID, isDirectory: true)
                guard fm.fileExists(atPath: folder.path) else { continue }
                let rel = String(folder.path.dropFirst(driveCURL.path.count + 1))
                out.append(Place(relativePath: rel, bytes: SaveTransfer.directorySize(folder), underDriveC: true))
            }
        }
        // In a container of its own, every save folder there is the game's.
        if aloneInContainer { out += all }
        return out
    }

    nonisolated static func source(of place: Place, in container: Container) -> URL? { source(of: place, driveC: container.driveC) }

    nonisolated static func source(of place: Place, driveC: URL) -> URL? {
        place.underDriveC ? driveC.appendingPathComponent(place.relativePath)
                          : profile(driveC: driveC)?.appendingPathComponent(place.relativePath)
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
    /// moved aside beside it ("….anvil-replaced-<time>"), never overwritten. `keep` chooses which of the export's
    /// places go back (`toRestore`); the manifest returned lists the ones that did.
    @discardableResult
    nonisolated static func restore(from zip: URL, into container: Container,
                                    keep: ([Place]) -> [Place] = { $0 }) throws -> Manifest {
        let fm = FileManager.default
        var manifest = try manifest(of: zip)
        let stage = staging.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path])
        var restored: [Place] = []
        for place in keep(manifest.places) {
            let from = stage.appendingPathComponent(place.underDriveC ? "drive_c" : "profile").appendingPathComponent(place.relativePath)
            // Nothing outside the place it names: no "..", no absolute path.
            guard fm.fileExists(atPath: from.path), !place.relativePath.contains(".."), !place.relativePath.hasPrefix("/"),
                  let to = source(of: place, in: container) else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) {
                try fm.moveItem(at: to, to: aside(for: to))
            }
            try run("/bin/cp", ["-Rc", from.path, to.path])
            restored.append(place)
        }
        manifest.places = restored
        return manifest
    }

    /// Save folders from one Windows setup into another, each at its own place — a game downloaded again into a
    /// new setup gets the saves it left in the old one. What is there already is moved aside, as `restore` does.
    /// Returns how many folders were copied.
    @discardableResult
    nonisolated static func copy(_ places: [Place], from other: Container, into container: Container) throws -> Int {
        try copy(places, fromDriveC: other.driveC, into: container)
    }

    /// The same from any drive C laid out as a container's — one of Save Guard's backups.
    @discardableResult
    nonisolated static func copy(_ places: [Place], fromDriveC otherDriveC: URL, into container: Container) throws -> Int {
        let fm = FileManager.default
        var n = 0
        for place in places {
            guard !place.relativePath.contains(".."), !place.relativePath.hasPrefix("/"),
                  let from = source(of: place, driveC: otherDriveC), fm.fileExists(atPath: from.path),
                  let to = source(of: place, in: container),
                  // Both setups' Documents linked to the Mac's: one folder — moving it aside would lose it.
                  from.resolvingSymlinksInPath().path != to.resolvingSymlinksInPath().path else { continue }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: to.path) {
                try fm.moveItem(at: to, to: aside(for: to))
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
