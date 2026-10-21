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
///   last saved in it, the saves left in a Windows setup it used before, and Save Guard's backups of it; each says
///   what it holds where Anvil can read the game's saves (SaveReader: "Episode Select · 34.3% complete"), copies
///   holding the same saves are listed once, and the one picked for the player is the furthest through, else the
///   newest. Asked once for each newest export, before the game's next start or as soon as Anvil opens;
/// - before anything is restored, what the game has now is exported too, so nothing is lost either way, and the
///   restore can be undone in one step.
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
            /// One of Save Guard's backups of a Windows setup the game is or was in (Save Backups/<setup>/<date>).
            case backup(folder: URL, containerID: UUID, name: String, places: [GameSaves.Place], madeAt: Date)
            /// What the game has now.
            case current
        }
        var kind: Kind
        /// When the game last wrote to these saves.
        var lastSaved: Date?
        var files: Int
        var bytes: Int64
        /// What the saves hold, where Anvil can read them.
        var summary: SaveReader.Summary? = nil
        /// Each file's folder, name and size: the same for two copies of the same saves.
        var fingerprint: String = ""
        /// How many copies of these same saves there are (an export in both places counts once).
        var copies: Int = 1
        /// Holds the same saves as the game has now.
        var sameAsNow = false
        /// Older backups at this same point of the game (the same place, as far through), listed as this one.
        var samePoint = 0

        var id: String {
            switch kind {
            case .export(let zips, let at): "export-\(at.timeIntervalSince1970)-\(zips.first?.lastPathComponent ?? "")"
            case .otherSetup(let id, _, _): "setup-\(id.uuidString)"
            case .backup(let folder, _, _, _, _): "backup-\(folder.path)"
            case .current: "current"
            }
        }
        /// When the copy was made: an export's or backup's time, else when the game last saved.
        var date: Date {
            switch kind {
            case .export(_, let at): at
            case .backup(_, _, _, _, let at): at
            default: lastSaved ?? .distantPast
            }
        }
        /// What Anvil exported itself just before putting other saves back ("… before restoring.zip"): listed, so
        /// it can be had back, but never what prompts the question or what's picked for the player. On 21 October
        /// one made at 6:43 AM was the newest, so the next start asked again with it chosen, and put the new game
        /// back over the progress just restored.
        var isSafetyCopy: Bool {
            if case .export(let zips, _) = kind { return !zips.isEmpty && zips.allSatisfy { $0.lastPathComponent.contains("before restoring") } }
            return false
        }
        var isBackup: Bool { if case .backup = kind { return true }; return false }
        var percent: Double? { summary?.percent }
    }

    /// The exports made of this game, newest first: an export is this game's when its list names it — the same
    /// title, Epic app or Steam app.
    static func exports(for game: Game) -> [Candidate] {
        let fm = FileManager.default
        var byTime: [Int: (zips: [URL], manifest: GameSaves.Manifest)] = [:]
        for folder in [documentsFolder, appFolder] {
            for zip in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where zip.pathExtension.lowercased() == "zip" {
                guard let manifest = try? GameSaves.manifest(of: zip), matches(manifest, game) else { continue }
                let key = Int(manifest.exportedAt.timeIntervalSince1970)
                if var known = byTime[key] { known.zips.append(zip); byTime[key] = known; continue }
                byTime[key] = ([zip], manifest)
            }
        }
        return byTime.values.map { candidate(zips: $0.zips, exportedAt: $0.manifest.exportedAt) }.sorted { $0.date > $1.date }
    }

    /// One export as a choice: what it holds, from its listing and the save files Anvil can read in it.
    static func candidate(zips: [URL], exportedAt: Date) -> Candidate {
        let l = listing(of: zips[0])
        let summary = SaveReader.summary(ofZip: zips[0], entries: l.readable)
        return Candidate(kind: .export(zips: zips, exportedAt: exportedAt), lastSaved: l.newest, files: l.files, bytes: l.bytes,
                         summary: summary, fingerprint: fingerprint(l.parts, summary))
    }

    static func matches(_ m: GameSaves.Manifest, _ game: Game) -> Bool {
        if let e = m.epicAppName, let g = game.epicAppName, e == g { return true }
        if let s = m.steamAppID, let g = game.steamAppID, s == g { return true }
        return GameSaves.words(m.game) == GameSaves.words(game.title)
    }

    struct Listing { var newest: Date?; var files = 0; var bytes: Int64 = 0; var parts: [String] = []; var readable: [String] = [] }

    /// When the game last saved in an export (its newest file), how many files, how many bytes — from the zip's
    /// listing, without unpacking it. Crash reports and caches the export carried aren't saves.
    static func listing(of zip: URL) -> Listing {
        var out = Listing()
        guard let text = try? String(data: run("/usr/bin/zipinfo", ["-T", "-l", zip.path]), encoding: .utf8) else { return out }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd.HHmmss"
        for line in text.split(separator: "\n") where line.hasPrefix("-") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9, let size = Int64(cols[3]), let name = entryName(line) else { continue }
            guard !isNotASave(name) else { continue }
            out.files += 1
            out.bytes += size
            out.parts.append(part(name, size))
            if SaveReader.isReadable(name) { out.readable.append(name) }
            if let d = f.date(from: String(cols[7])), d > (out.newest ?? .distantPast) { out.newest = d }
        }
        return out
    }

    /// The name in a `zipinfo -l` line: all after its eighth column (permissions, version, system, size, type,
    /// packed size, method, date), its own spaces kept. Before 0.60 the name was read from the ninth, so a file whose
    /// path had no space in it wasn't counted at all, and the rest lost their first word.
    static func entryName(_ line: Substring) -> String? {
        var i = line.startIndex
        for _ in 0..<8 {
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            while i < line.endIndex, line[i] != " " { i = line.index(after: i) }
        }
        guard i < line.endIndex else { return nil }
        i = line.index(after: i)
        return i < line.endIndex ? String(line[i...]) : nil
    }

    /// What a save folder carries that isn't progress: crash reports, shader caches, logs, Anvil's own list.
    static func isNotASave(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix("anvil-saves.json") || p.contains("/crashdata/") || p.contains("cachedshaders") || p.contains("/logs/")
            || p.hasSuffix(".dmp") || p.hasSuffix(".log") || p.contains(".anvil-replaced-") || p.hasSuffix("backup.json")
    }

    /// Saves for this game left in other Windows setups — where it was before it was downloaded again. A Documents
    /// linked out to the Mac's own is one folder every setup shares, not saves left behind, so it isn't looked in.
    static func otherSetups(for game: Game, containers: [Container]) -> [Candidate] {
        containers.filter { $0.id != game.containerID }.compactMap { other in
            let places = GameSaves.places(for: game, in: other, aloneInContainer: false, macDocuments: false)
            guard !places.isEmpty else { return nil }
            let folders = places.compactMap { GameSaves.source(of: $0, in: other) }
            let stats = folderStats(folders)
            guard stats.files > 0 else { return nil }
            let summary = SaveReader.summary(ofFolders: folders)
            return Candidate(kind: .otherSetup(containerID: other.id, name: other.name, places: places), lastSaved: stats.newest,
                             files: stats.files, bytes: stats.bytes, summary: summary, fingerprint: fingerprint(stats.parts, summary))
        }
    }

    /// Save Guard's backups of this game, from every Windows setup: the game's own folders in each, newest first.
    /// Backups hold every game of a setup; only folders named after this game are taken from them.
    static func backups(for game: Game, containers: [Container]) -> [Candidate] {
        var out: [Candidate] = []
        for container in containers {
            for backup in SaveGuard.list(for: container.id) {
                let driveC = backup.url.appendingPathComponent("drive_c", isDirectory: true)
                let places = GameSaves.places(for: game, driveC: driveC, aloneInContainer: false)
                guard !places.isEmpty else { continue }
                let folders = places.compactMap { GameSaves.source(of: $0, driveC: driveC) }
                let stats = folderStats(folders)
                guard stats.files > 0 else { continue }
                let summary = SaveReader.summary(ofFolders: folders)
                out.append(Candidate(kind: .backup(folder: backup.url, containerID: container.id, name: container.name, places: places,
                                                   madeAt: backup.date),
                                     lastSaved: stats.newest, files: stats.files, bytes: stats.bytes,
                                     summary: summary, fingerprint: fingerprint(stats.parts, summary)))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// The saves' files under some folders: how many, how big, the newest, when the oldest folder was made, and each
    /// file's folder, name and size.
    static func folderStats(_ folders: [URL]) -> (files: Int, bytes: Int64, newest: Date?, began: Date?, parts: [String]) {
        let fm = FileManager.default
        var files = 0, bytes: Int64 = 0
        var newest: Date?, began: Date?
        var parts: [String] = []
        for folder in folders {
            if let made = (try? fm.attributesOfItem(atPath: folder.path))?[.creationDate] as? Date, made < (began ?? .distantFuture) { began = made }
            SaveTransfer.walk(folder) { url, v in
                guard !isNotASave(url.path) else { return }
                files += 1
                bytes += Int64(v.fileSize ?? 0)
                parts.append(part(url.path, Int64(v.fileSize ?? 0)))
                if let d = v.contentModificationDate, d > (newest ?? .distantPast) { newest = d }
            }
        }
        return (files, bytes, newest, began, parts)
    }

    /// A file as the fingerprint knows it: its folder, name and size ("SLOT1/COLLECTABLES.BLOB 1205904") — the same in
    /// an export, a setup and a backup, whatever lies above.
    private static func part(_ path: String, _ size: Int64) -> String {
        let pieces = path.split(separator: "/")
        return pieces.suffix(2).joined(separator: "/") + " \(size)"
    }

    /// Copies holding the same saves share it: the same files at the same sizes, and the same progress where read.
    static func fingerprint(_ parts: [String], _ summary: SaveReader.Summary?) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in (parts.sorted().joined(separator: "\n") + "\n" + (summary?.text ?? "")).utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The same saves listed once: the export where there is one, else the other setup, else the newest backup;
    /// Anvil's own safety copies last. Backups of what the game has now are left out — they hold nothing to go back to.
    static func merged(_ all: [Candidate], current: Candidate?) -> [Candidate] {
        func rank(_ c: Candidate) -> Int {
            if c.isSafetyCopy { return 3 }
            switch c.kind { case .export: return 0; case .otherSetup: return 1; case .backup: return 2; case .current: return 4 }
        }
        var byPrint: [String: Candidate] = [:]
        var order: [String] = []
        for c in all {
            var c = c
            c.sameAsNow = !c.fingerprint.isEmpty && c.fingerprint == current?.fingerprint
            if c.sameAsNow && c.isBackup { continue }
            let key = c.fingerprint.isEmpty ? c.id : c.fingerprint
            if var kept = byPrint[key] {
                kept.copies += c.copies
                if rank(c) < rank(kept) || (rank(c) == rank(kept) && c.date > kept.date) { c.copies = kept.copies; kept = c }
                byPrint[key] = kept
            } else {
                byPrint[key] = c
                order.append(key)
            }
        }
        // Backups at the same point of the game — the same place, as far through — are one choice: the newest of them.
        var out: [Candidate] = []
        var point: [String: Int] = [:]
        for c in order.compactMap({ byPrint[$0] }).sorted(by: { $0.date > $1.date }) {
            if c.isBackup, let text = c.summary?.text {
                if let i = point[text] { out[i].samePoint += 1; continue }
                point[text] = out.count
            }
            out.append(c)
        }
        return out
    }

    struct Offer {
        var game: Game
        var candidates: [Candidate]
        /// What the game has now, listed last.
        var current: Candidate?

        /// What's picked for the player: the furthest through where Anvil can read the saves — what the game has now,
        /// when nothing is further — else the newest that isn't Anvil's own safety copy or a backup.
        var recommended: Candidate? {
            let pool = candidates.filter { !$0.sameAsNow }
            // As far through, to a tenth of a point: an export before another setup's saves, before a backup, before
            // Anvil's own safety copy — at 6:53 AM on 21 October that copy held the finished game too, and was newer.
            func standing(_ c: Candidate) -> (Double, Int, Date) {
                let kind = c.isSafetyCopy ? 0 : c.isBackup ? 1 : { if case .otherSetup = c.kind { return 2 }; return 3 }()
                return (((c.percent ?? -1) * 10).rounded(), kind, c.date)
            }
            if let best = pool.filter({ $0.percent != nil }).max(by: { standing($0) < standing($1) }) {
                if let now = current?.percent, now >= best.percent! - 0.05 { return current }
                return best
            }
            return pool.first { !$0.isSafetyCopy && !$0.isBackup } ?? pool.first { !$0.isSafetyCopy } ?? pool.first
        }

        /// Why it's picked, in words, when the saves were read.
        var because: String? {
            guard let pick = recommended, let pct = pick.percent else { return nil }
            if pick.kind == .current { return String(format: "What it has now is the furthest through (%.1f%%).", pct) }
            let others = candidates.filter { $0.id != pick.id && $0.percent != nil }.count + (current?.percent != nil ? 1 : 0)
            guard others > 0 else { return nil }
            let now = current?.percent.map { String(format: " — what it has now is %.1f%%", $0) } ?? ""
            return String(format: "Picked: the furthest through (%.1f%%)%@.", pct, now)
        }
    }

    /// What to offer for a game, or nil when there's nothing to ask: its saves began after the newest export or
    /// other setup's saves (it came back, or moved), that newest one hasn't been asked about, and something there is
    /// further through than what it has now (where the saves can be read).
    static func offer(for game: Game, container: Container, containers: [Container], aloneInContainer alone: Bool,
                      askedUpTo: Double, force: Bool = false) -> Offer? {
        let found = (exports(for: game) + otherSetups(for: game, containers: containers)).sorted { $0.date > $1.date }
        // What prompts the question: the newest that isn't Anvil's own safety copy. Backups are the game's history,
        // made every start — listed, never what prompts it.
        let newest = found.first(where: { !$0.isSafetyCopy })
        guard newest != nil || force else { return nil }
        // The folders named after the game only: alone in its setup, every save folder there counts as the game's for
        // an export, and another game's older folder (Five Nights at Freddy's beside LEGO Star Wars in "Epic Games")
        // would make its saves look older than they are.
        var mine = GameSaves.places(for: game, in: container, aloneInContainer: false).compactMap { GameSaves.source(of: $0, in: container) }
        if mine.isEmpty { mine = GameSaves.places(for: game, in: container, aloneInContainer: alone).compactMap { GameSaves.source(of: $0, in: container) } }
        let now = folderStats(mine)
        let nowSummary = SaveReader.summary(ofFolders: mine)
        let current = now.files > 0 ? Candidate(kind: .current, lastSaved: now.newest, files: now.files, bytes: now.bytes,
                                                summary: nowSummary, fingerprint: fingerprint(now.parts, nowSummary)) : nil
        if !force, let newest {
            guard askedUpTo < newest.date.timeIntervalSince1970 - 1 else { return nil }
            // Saves the game is still writing to from before the newest export — an export made to keep a copy —
            // aren't a game coming back.
            if let began = now.began, began < newest.date {
                lastDecision = "its saves began \(began.formatted(date: .abbreviated, time: .shortened)), before the newest of \(found.count) to choose from (\(newest.date.formatted(date: .abbreviated, time: .shortened))) — a copy kept, not a game come back"
                return nil
            }
            // Nothing from before is further through than what it has now.
            if let pct = current?.percent, let best = found.compactMap(\.percent).max(), pct >= best - 0.05 {
                lastDecision = String(format: "what it has now is as far through (%.1f%%) as anything from before (%.1f%% at most)", pct, best)
                return nil
            }
        }
        let all = merged(found + backups(for: game, containers: containers), current: current)
        guard !all.isEmpty else { return nil }
        return Offer(game: game, candidates: all, current: current)
    }

    /// Why the last offer() found saves from before and didn't ask, for the log.
    nonisolated(unsafe) static var lastDecision: String?

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

    struct Restored {
        /// What was done, in words.
        var text: String
        /// The export of what the game had just before — what Undo puts back.
        var keptAs: URL?
    }

    /// The chosen saves into the game's Windows setup. What it has now is exported first (both places), and what's
    /// in the way is moved aside, never overwritten. Returns what was done, in words.
    static func restore(_ candidate: Candidate, for game: Game, container: Container, aloneInContainer: Bool,
                        containers: [Container]) throws -> String {
        try restoreKeeping(candidate, for: game, container: container, aloneInContainer: aloneInContainer, containers: containers).text
    }

    static func restoreKeeping(_ candidate: Candidate, for game: Game, container: Container, aloneInContainer: Bool,
                               containers: [Container]) throws -> Restored {
        if case .current = candidate.kind { return Restored(text: "kept the saves it has") }
        var before = "nothing there yet to keep"
        var keptAs: URL?
        // The game's own folders only, where it has any: putting this copy back mustn't touch another game's.
        let named = !GameSaves.places(for: game, in: container, aloneInContainer: false).isEmpty
        if let zip = try? GameSaves.export(game: game, container: container, aloneInContainer: named ? false : aloneInContainer,
                                           to: appFolder, suffix: "before restoring") {
            keepCopy(of: zip)
            keptAs = zip
            before = "what it had kept as \(zip.lastPathComponent)"
        }
        let what: String
        switch candidate.kind {
        case .current:
            what = "kept the saves it has"
        case .export(let zips, let at):
            guard let zip = zips.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw Failure.gone("That export isn't there any more.")
            }
            let manifest = try GameSaves.restore(from: zip, into: container)
            what = "restored \(manifest.places.count) save folder\(manifest.places.count == 1 ? "" : "s") from the export of \(at.formatted(date: .abbreviated, time: .shortened)) (\(zip.lastPathComponent))"
        case .otherSetup(let id, let name, let places):
            guard let other = containers.first(where: { $0.id == id }) else { throw Failure.gone("That Windows setup isn't there any more.") }
            let n = try GameSaves.copy(places, from: other, into: container)
            what = "copied \(n) save folder\(n == 1 ? "" : "s") from the “\(name)” Windows setup"
        case .backup(let folder, _, let name, let places, let at):
            guard FileManager.default.fileExists(atPath: folder.path) else { throw Failure.gone("That backup isn't there any more.") }
            let n = try GameSaves.copy(places, fromDriveC: folder.appendingPathComponent("drive_c", isDirectory: true), into: container)
            what = "put back \(n) save folder\(n == 1 ? "" : "s") from the backup of “\(name)” made \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        let read = candidate.summary.map { " (\($0.text))" } ?? ""
        return Restored(text: what + read + "; " + before, keptAs: keptAs)
    }

    // MARK: Undo

    static func undoKey(_ game: Game) -> String { "saveVault-undo-\(game.id.uuidString)" }

    /// Kept after each restore: the export of what the game had just before, and when.
    static func rememberUndo(game: Game, keptAs zip: URL, restored: String) {
        UserDefaults.standard.set(["zip": zip.lastPathComponent, "at": Date().timeIntervalSince1970, "restored": restored], forKey: undoKey(game))
    }

    /// What Undo would put back — the game as it was just before the last restore — while that export is still there.
    static func undo(for game: Game) -> (candidate: Candidate, at: Date)? {
        guard let d = UserDefaults.standard.dictionary(forKey: undoKey(game)), let name = d["zip"] as? String,
              let at = d["at"] as? Double else { return nil }
        let zips = [documentsFolder, appFolder].map { $0.appendingPathComponent(name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !zips.isEmpty, let manifest = try? GameSaves.manifest(of: zips[0]) else { return nil }
        return (candidate(zips: zips, exportedAt: manifest.exportedAt), Date(timeIntervalSince1970: at))
    }

    static func forgetUndo(_ game: Game) { UserDefaults.standard.removeObject(forKey: undoKey(game)) }

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
        /// The restore just done can be undone from the sheet.
        var undoable = false
    }

    @Published var pending: Request?
    /// Said in the main window while Anvil's start looks for saves from before and it's taking a while — most often
    /// because macOS is asking whether Anvil may open Documents, and the question waits on that answer.
    @Published var checking: String?
    /// Bumped after each restore or undo, so the game's page shows what can be undone now.
    @Published var changes = 0
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
        guard let offer else {
            if let why = SaveVault.lastDecision { AnvilLog.write("saves: \(game.title) — not asking: \(why)"); SaveVault.lastDecision = nil }
            return
        }
        let pick = offer.recommended.map { " — picked: \(describe($0))" } ?? ""
        AnvilLog.write("saves: \(game.title) — " + offer.candidates.map { describe($0) }.joined(separator: "; ")
                       + (offer.current.map { "; now: \(describe($0))" } ?? "") + pick + " — asking which to play on")
        checking = nil
        pending = Request(offer: offer)
        await withCheckedContinuation { waiting = $0 }
    }

    /// The player's choice: restore it (unless it's what the game has now), and say what happened.
    func choose(_ candidate: SaveVault.Candidate?) {
        guard var request = pending else { return }
        let game = request.offer.game
        // Answered: nothing up to now is asked about again — not the safety copy made below, either.
        SaveVault.markAsked(game: game, upTo: max(request.offer.candidates.first?.date ?? .distantPast, Date()))
        guard let candidate, candidate.kind != .current else {
            AnvilLog.write("saves: \(game.title) — kept the saves it has")
            finish()
            return
        }
        request.working = "Putting those saves back…"
        pending = request
        Task {
            let result = await restore(candidate, for: game)
            guard var r = self.pending else { return }
            r.working = nil
            switch result {
            case .success(let what):
                r.done = what.prefix(1).uppercased() + what.dropFirst() + "."
                r.undoable = SaveVault.undo(for: game) != nil
            case .failure(let error):
                r.done = "Those saves couldn't be put back: \(error.localizedDescription) Nothing was changed."
            }
            self.pending = r
        }
    }

    /// Any copy of a game's saves into it, the way a choice is: what it has exported first, the undo kept, logged.
    func restore(_ candidate: SaveVault.Candidate, for game: Game) async -> Result<String, Error> {
        guard let container = Library.shared.container(id: game.containerID) else {
            return .failure(SaveVault.Failure.gone("Its Windows setup isn't there any more."))
        }
        let alone = !Library.shared.games.contains { $0.id != game.id && $0.containerID == game.containerID }
        let containers = Library.shared.containers
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SaveVault.Restored, Error> in
            Result { try SaveVault.restoreKeeping(candidate, for: game, container: container, aloneInContainer: alone, containers: containers) }
        }.value
        changes += 1
        switch result {
        case .success(let done):
            AnvilLog.write("saves: \(game.title) — \(done.text)")
            if let zip = done.keptAs { SaveVault.rememberUndo(game: game, keptAs: zip, restored: describe(candidate)) }
            return .success(done.text)
        case .failure(let error):
            AnvilLog.write("saves: \(game.title) — restoring failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// The last restore undone: the game's saves as they were just before it. Undoing is a restore too, so it can
    /// itself be undone.
    func undo(_ game: Game) async -> Result<String, Error> {
        guard let found = await Task.detached(priority: .userInitiated, operation: { SaveVault.undo(for: game) }).value else {
            return .failure(SaveVault.Failure.gone("There's nothing to undo — the copy kept before the last restore isn't there any more."))
        }
        SaveVault.markAsked(game: game, upTo: Date())
        AnvilLog.write("saves: \(game.title) — undoing the last restore")
        return await restore(found.candidate, for: game)
    }

    /// From the sheet, right after a restore.
    func undoFromSheet() {
        guard var r = pending else { return }
        let game = r.offer.game
        r.working = "Putting back what it had…"
        r.done = nil
        pending = r
        Task {
            let result = await undo(game)
            guard var r = self.pending else { return }
            r.working = nil
            r.undoable = false
            switch result {
            case .success: r.done = "Undone: \(game.title) has the saves it had before."
            case .failure(let error): r.done = "That couldn't be undone: \(error.localizedDescription)"
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
        let read = c.summary.map { ", \($0.text)" } ?? ""
        let copies = c.copies > 1 ? ", \(c.copies) copies" : ""
        return switch c.kind {
        case .export(_, let at): "\(c.isSafetyCopy ? "a safety copy" : "an export") of \(at.formatted(date: .abbreviated, time: .shortened))\(read)\(copies)"
        case .otherSetup(_, let name, _): "saves in the “\(name)” Windows setup\(read)\(copies)"
        case .backup(_, _, let name, _, let at): "a backup of “\(name)” of \(at.formatted(date: .abbreviated, time: .shortened))\(read)\(copies)"
        case .current: "the saves it has\(read)"
        }
    }

    /// At Anvil's start: any game that came back with saves from before it, asked about one at a time.
    func offerAtStart() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Opening Documents › Anvil Saves the first time after an update, macOS asks whether Anvil may: until that's
            // answered, the look waits (21 October: 0.59.2's waited four minutes on it).
            let hint = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, pending == nil else { return }
                checking = "Looking for saves from before… If macOS asks whether Anvil may open your Documents folder, choose Allow — your save exports are kept there."
            }
            defer { hint.cancel(); checking = nil }
            let copied = await Task.detached(priority: .utility) { SaveVault.mirror() }.value
            if copied > 0 { AnvilLog.write("saves: \(copied) export\(copied == 1 ? "" : "s") in Documents › Anvil Saves copied into Anvil's own Save Exports too") }
            let games = Library.shared.games.filter { $0.exists && !SteamSupport.isSteamClient($0) && !Launcher.shared.isBusy($0) }
            let started = Date()
            for game in games { await askIfNeeded(game) }
            AnvilLog.write(String(format: "saves: looked for saves from before for %d game%@ (%.1f s)", games.count, games.count == 1 ? "" : "s",
                                  Date().timeIntervalSince(started)))
        }
    }
}
