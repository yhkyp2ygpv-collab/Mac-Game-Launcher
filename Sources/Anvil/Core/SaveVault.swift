import Foundation

/// Saves that outlive a game: every export kept in two places, found again when the game comes back, and the
/// player choosing which to play on.
///
/// On 17 October LEGO Star Wars was deleted, its saves exported to Documents › Anvil Saves first. When it was
/// downloaded again on 19 October it went into another Windows setup ("Epic Games", not "Star Wars"), started
/// with no saves, and nothing said the export was there: the player started over. Now:
/// - an export is kept in Documents › Anvil Saves and in Anvil's own folder (Save Exports), each a copy of the other;
/// - when a game's saves began after an export of it was made — it was downloaded again, or moved to another
///   Windows setup — Anvil lists what there is, newest first: each export, by when it was made and when the game
///   last saved in it, and the saves left in a Windows setup it used before; and the player chooses, or keeps
///   what the game has now. Asked once for each newest export, before the game's next start or as soon as Anvil
///   opens;
/// - before anything is restored, what the game has now is exported too, so nothing is lost either way.
enum SaveVault {
    // MARK: Two places

    nonisolated static var documentsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Anvil Saves", isDirectory: true)
    }
    nonisolated(unsafe) static var appFolder: URL = RuntimeManager.support.appendingPathComponent("Save Exports", isDirectory: true)

    /// A copy of an export in whichever of the two places doesn't have it yet. Returns the places it's in.
    @discardableResult
    static func keepCopy(of zip: URL) -> [URL] {
        let fm = FileManager.default
        var places: [URL] = [zip]
        for folder in [documentsFolder, appFolder] where folder.standardizedFileURL.path != zip.deletingLastPathComponent().standardizedFileURL.path {
            let copy = folder.appendingPathComponent(zip.lastPathComponent)
            if !fm.fileExists(atPath: copy.path) {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if (try? fm.copyItem(at: zip, to: copy)) == nil { continue }
            }
            places.append(copy)
        }
        return places
    }

    /// Every export in Documents › Anvil Saves copied into Anvil's own folder too (they were only in Documents
    /// before 0.59.1). Returns how many were copied.
    @discardableResult
    static func mirror() -> Int {
        let fm = FileManager.default
        guard let zips = try? fm.contentsOfDirectory(at: documentsFolder, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for zip in zips where zip.pathExtension.lowercased() == "zip" {
            let copy = appFolder.appendingPathComponent(zip.lastPathComponent)
            guard !fm.fileExists(atPath: copy.path), (try? GameSaves.manifest(of: zip)) != nil else { continue }
            try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
            if (try? fm.copyItem(at: zip, to: copy)) != nil { n += 1 }
        }
        return n
    }

    // MARK: What there is to choose from

    struct Candidate: Identifiable, Hashable {
        enum Kind: Hashable {
            /// An Anvil export, in one or both of the two places.
            case export(zips: [URL], exportedAt: Date)
            /// Saves still in a Windows setup the game was in before.
            case otherSetup(containerID: UUID, name: String, places: [GameSaves.Place])
            /// What the game has now.
            case current
        }
        var kind: Kind
        /// When the game last wrote to these saves.
        var lastSaved: Date?
        var files: Int
        var bytes: Int64

        var id: String {
            switch kind {
            case .export(let zips, let at): "export-\(at.timeIntervalSince1970)-\(zips.first?.lastPathComponent ?? "")"
            case .otherSetup(let id, _, _): "setup-\(id.uuidString)"
            case .current: "current"
            }
        }
        /// When the choice was made: an export's time, else when the game last saved.
        var date: Date { if case .export(_, let at) = kind { return at }; return lastSaved ?? .distantPast }
    }

    /// The exports made of this game, newest first: an export is this game's when its list names it — the same
    /// title, Epic app or Steam app.
    static func exports(for game: Game) -> [Candidate] {
        let fm = FileManager.default
        var byTime: [Int: (zips: [URL], manifest: GameSaves.Manifest, listing: (Date?, Int, Int64))] = [:]
        for folder in [documentsFolder, appFolder] {
            for zip in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where zip.pathExtension.lowercased() == "zip" {
                guard let manifest = try? GameSaves.manifest(of: zip), matches(manifest, game) else { continue }
                let key = Int(manifest.exportedAt.timeIntervalSince1970)
                if var known = byTime[key] { known.zips.append(zip); byTime[key] = known; continue }
                byTime[key] = ([zip], manifest, listing(of: zip))
            }
        }
        return byTime.values.map { e in
            Candidate(kind: .export(zips: e.zips, exportedAt: e.manifest.exportedAt), lastSaved: e.listing.0, files: e.listing.1, bytes: e.listing.2)
        }.sorted { $0.date > $1.date }
    }

    static func matches(_ m: GameSaves.Manifest, _ game: Game) -> Bool {
        if let e = m.epicAppName, let g = game.epicAppName, e == g { return true }
        if let s = m.steamAppID, let g = game.steamAppID, s == g { return true }
        return GameSaves.words(m.game) == GameSaves.words(game.title)
    }

    /// When the game last saved in an export (its newest file), how many files, how many bytes — from the zip's
    /// listing, without unpacking it. Crash reports and caches the export carried aren't saves.
    static func listing(of zip: URL) -> (Date?, Int, Int64) {
        guard let text = try? String(data: run("/usr/bin/zipinfo", ["-T", "-l", zip.path]), encoding: .utf8) else { return (nil, 0, 0) }
        var newest: Date?, files = 0, bytes: Int64 = 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd.HHmmss"
        for line in text.split(separator: "\n") where line.hasPrefix("-") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10, let size = Int64(cols[3]) else { continue }
            let name = cols[9...].joined(separator: " ")
            guard !isNotASave(name) else { continue }
            files += 1
            bytes += size
            if let d = f.date(from: String(cols[7])), d > (newest ?? .distantPast) { newest = d }
        }
        return (newest, files, bytes)
    }

    /// What a save folder carries that isn't progress: crash reports, shader caches, logs, Anvil's own list.
    static func isNotASave(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix("anvil-saves.json") || p.contains("/crashdata/") || p.contains("cachedshaders") || p.contains("/logs/")
            || p.hasSuffix(".dmp") || p.hasSuffix(".log") || p.contains(".anvil-replaced-")
    }

    /// Saves for this game left in other Windows setups — where it was before it was downloaded again.
    static func otherSetups(for game: Game, containers: [Container]) -> [Candidate] {
        containers.filter { $0.id != game.containerID }.compactMap { other in
            let places = GameSaves.places(for: game, in: other, aloneInContainer: false)
            guard !places.isEmpty else { return nil }
            let stats = folderStats(places.compactMap { GameSaves.source(of: $0, in: other) })
            guard stats.files > 0 else { return nil }
            return Candidate(kind: .otherSetup(containerID: other.id, name: other.name, places: places), lastSaved: stats.newest,
                             files: stats.files, bytes: stats.bytes)
        }
    }

    /// The saves' files under some folders: how many, how big, the newest, and when the oldest folder was made.
    static func folderStats(_ folders: [URL]) -> (files: Int, bytes: Int64, newest: Date?, began: Date?) {
        let fm = FileManager.default
        var files = 0, bytes: Int64 = 0
        var newest: Date?, began: Date?
        for folder in folders {
            if let made = (try? fm.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date, made < (began ?? .distantFuture) { began = made }
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in walker {
                guard !isNotASave(url.path), let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      v.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(v.fileSize ?? 0)
                if let d = v.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
            }
        }
        return (files, bytes, newest, began)
    }

    struct Offer {
        var game: Game
        var candidates: [Candidate]
        /// What the game has now, listed last.
        var current: Candidate?
    }

    /// What to offer for a game, or nil when there's nothing to ask: its saves began after the newest export or
    /// other setup's saves (it came back, or moved), and that newest one hasn't been asked about.
    static func offer(for game: Game, container: Container, containers: [Container], aloneInContainer alone: Bool,
                      askedUpTo: Double, force: Bool = false) -> Offer? {
        let found = (exports(for: game) + otherSetups(for: game, containers: containers)).sorted { $0.date > $1.date }
        guard let newest = found.first else { return nil }
        // The folders named after the game only: alone in its setup, every save folder there counts as the game's for
        // an export, and another game's older folder (Five Nights at Freddy's beside LEGO Star Wars in "Epic Games")
        // would make its saves look older than they are.
        var mine = GameSaves.places(for: game, in: container, aloneInContainer: false).compactMap { GameSaves.source(of: $0, in: container) }
        if mine.isEmpty { mine = GameSaves.places(for: game, in: container, aloneInContainer: alone).compactMap { GameSaves.source(of: $0, in: container) } }
        let now = folderStats(mine)
        let current = now.files > 0 ? Candidate(kind: .current, lastSaved: now.newest, files: now.files, bytes: now.bytes) : nil
        if !force {
            guard askedUpTo < newest.date.timeIntervalSince1970 - 1 else { return nil }
            // Saves the game is still writing to from before the newest export — an export made to keep a copy —
            // aren't a game coming back.
            if let began = now.began, began < newest.date { return nil }
        }
        return Offer(game: game, candidates: found, current: current)
    }

    static func askedKey(_ game: Game) -> String { "saveVault-asked-\(game.id.uuidString)" }
    static func askedUpTo(_ game: Game) -> Double { UserDefaults.standard.double(forKey: askedKey(game)) }
    static func markAsked(game: Game, upTo date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: askedKey(game))
    }

    // MARK: Putting saves back

    enum Failure: LocalizedError {
        case gone(String)
        var errorDescription: String? { if case .gone(let why) = self { return why }; return nil }
    }

    /// The chosen saves into the game's Windows setup. What it has now is exported first (both places), and what's
    /// in the way is moved aside, never overwritten. Returns what was done, in words.
    static func restore(_ candidate: Candidate, for game: Game, container: Container, aloneInContainer: Bool,
                        containers: [Container]) throws -> String {
        if case .current = candidate.kind { return "kept the saves it has" }
        var before = "nothing there yet to keep"
        if let zip = try? GameSaves.export(game: game, container: container, aloneInContainer: aloneInContainer, to: appFolder,
                                           suffix: "before restoring") {
            keepCopy(of: zip)
            before = "what it had kept as \(zip.lastPathComponent)"
        }
        switch candidate.kind {
        case .current:
            return "kept the saves it has"
        case .export(let zips, let at):
            guard let zip = zips.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw Failure.gone("That export isn't there any more.")
            }
            let manifest = try GameSaves.restore(from: zip, into: container)
            return "restored \(manifest.places.count) save folder\(manifest.places.count == 1 ? "" : "s") from the export of \(at.formatted(date: .abbreviated, time: .shortened)) (\(zip.lastPathComponent)); \(before)"
        case .otherSetup(let id, let name, let places):
            guard let other = containers.first(where: { $0.id == id }) else { throw Failure.gone("That Windows setup isn't there any more.") }
            let n = try GameSaves.copy(places, from: other, into: container)
            return "copied \(n) save folder\(n == 1 ? "" : "s") from the “\(name)” Windows setup; \(before)"
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

// MARK: - Asking

/// The question itself: the main window shows `pending` as a sheet (SaveChoiceSheet), and whoever asked waits for
/// the answer — a start waits, so the game opens on the saves chosen.
@MainActor
final class SaveChoice: ObservableObject {
    static let shared = SaveChoice()

    struct Request: Identifiable {
        let id = UUID()
        var offer: SaveVault.Offer
        /// Shown while the chosen saves go in, and what happened after.
        var working: String?
        var done: String?
    }

    @Published var pending: Request?
    private var waiting: CheckedContinuation<Void, Never>?

    /// Ask about `game` if there's anything to ask, and wait until it's answered and done.
    func askIfNeeded(_ game: Game, force: Bool = false) async {
        guard pending == nil, let container = Library.shared.container(id: game.containerID) else { return }
        let containers = Library.shared.containers
        let alone = !Library.shared.games.contains { $0.id != game.id && $0.containerID == game.containerID }
        let askedUpTo = SaveVault.askedUpTo(game)
        let offer = await Task.detached(priority: .userInitiated) {
            SaveVault.offer(for: game, container: container, containers: containers, aloneInContainer: alone, askedUpTo: askedUpTo, force: force)
        }.value
        guard let offer else { return }
        AnvilLog.write("saves: \(game.title) — " + offer.candidates.map { describe($0) }.joined(separator: "; ") + " — asking which to play on")
        pending = Request(offer: offer)
        await withCheckedContinuation { waiting = $0 }
    }

    /// The player's choice: restore it (unless it's what the game has now), and say what happened.
    func choose(_ candidate: SaveVault.Candidate?) {
        guard var request = pending else { return }
        let game = request.offer.game
        if let newest = request.offer.candidates.first { SaveVault.markAsked(game: game, upTo: newest.date) }
        guard let candidate, candidate.kind != .current, let container = Library.shared.container(id: game.containerID) else {
            AnvilLog.write("saves: \(game.title) — kept the saves it has")
            finish()
            return
        }
        request.working = "Putting those saves back…"
        pending = request
        let alone = !Library.shared.games.contains { $0.id != game.id && $0.containerID == game.containerID }
        let containers = Library.shared.containers
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try SaveVault.restore(candidate, for: game, container: container, aloneInContainer: alone, containers: containers) }
            }.value
            guard var r = self.pending else { return }
            r.working = nil
            switch result {
            case .success(let what):
                AnvilLog.write("saves: \(game.title) — \(what)")
                r.done = what.prefix(1).uppercased() + what.dropFirst() + "."
            case .failure(let error):
                AnvilLog.write("saves: \(game.title) — restoring failed: \(error.localizedDescription)")
                r.done = "Those saves couldn't be put back: \(error.localizedDescription) Nothing was changed."
            }
            self.pending = r
        }
    }

    /// Closed: whoever was waiting goes on.
    func finish() {
        pending = nil
        waiting?.resume()
        waiting = nil
    }

    func describe(_ c: SaveVault.Candidate) -> String {
        switch c.kind {
        case .export(let zips, let at): "an export of \(at.formatted(date: .abbreviated, time: .shortened)) (\(zips.count) cop\(zips.count == 1 ? "y" : "ies"))"
        case .otherSetup(_, let name, _): "saves in the “\(name)” Windows setup"
        case .current: "the saves it has"
        }
    }

    /// At Anvil's start: any game that came back with saves from before it, asked about one at a time.
    func offerAtStart() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            let copied = await Task.detached(priority: .utility) { SaveVault.mirror() }.value
            if copied > 0 { AnvilLog.write("saves: \(copied) export\(copied == 1 ? "" : "s") in Documents › Anvil Saves copied into Anvil's own Save Exports too") }
            for game in Library.shared.games where game.exists && !SteamSupport.isSteamClient(game) && !Launcher.shared.isBusy(game) {
                await askIfNeeded(game)
            }
        }
    }
}
