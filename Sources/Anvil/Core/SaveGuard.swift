import Foundation
import CryptoKit
import Darwin

/// A copy of every container's saves, taken before each game starts and before anything
/// that replaces part of a container, and checked after each session.
///
/// Saves are the one thing in a container nothing can make again. A game that crashes, or
/// is forced to quit, while writing its save can leave an empty file where the save was;
/// a container deleted and the Trash emptied takes its saves with it. On APFS each copy is
/// a clone: a few milliseconds, and no space until the game changes the file. On 1 October
/// the saves in Anvil's three containers came to 224 KB (LEGO Star Wars), 2.5 MB (Cat
/// Quest II) and nothing at all for Steam once its own web cache is left out.
///
/// Backups live outside the containers, in Save Backups/<container>/<date>/, laid out as
/// they are under drive_c, so any of them can also be copied back by hand in Finder.
enum SaveGuard {

    /// Where backups live. Tests point this somewhere else.
    nonisolated(unsafe) static var root: URL =
        RuntimeManager.support.appendingPathComponent("Save Backups", isDirectory: true)

    struct Manifest: Codable, Sendable {
        var version: Int
        var containerName: String
        var reason: String
        var date: Date
        /// Of every file backed up: its path, size and modification date.
        var fingerprint: String
        var files: Int
        var bytes: Int64
        /// False when the volume can't clone and the files were copied.
        var cloned: Bool
        /// Files too big to be a save, left out (drive_c-relative).
        var leftOut: [String]?
    }

    struct Backup: Identifiable, Hashable, Sendable {
        var url: URL
        var containerID: UUID
        var date: Date
        var reason: String
        var files: Int
        var bytes: Int64
        var id: String { url.path }

        var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    enum Outcome: Sendable, Equatable {
        case made(URL, files: Int)
        case unchanged(since: Date)
        case nothingToKeep
        case failed(String)

        var logLine: String {
            switch self {
            case .made(let url, let files): "saves: \(files) file\(files == 1 ? "" : "s") backed up (Save Backups, \(url.lastPathComponent))"
            case .unchanged(let since): "saves: unchanged since the backup of \(SaveGuard.shortDate(since))"
            case .nothingToKeep: "saves: none yet"
            case .failed(let why): "saves: NOT backed up — \(why)"
            }
        }
    }

    nonisolated static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }

    // MARK: What counts as a save

    /// The places under a Windows user profile games keep their saves and settings.
    nonisolated static let profilePlaces = ["AppData/Roaming", "AppData/Local", "AppData/LocalLow", "Saved Games", "Documents"]

    /// Folders in those places that are never a save: Windows' and Wine's own, launchers,
    /// browsers and caches. Steam's folder there is its web cache, 5–9 MB of it.
    nonisolated static let skipped: Set<String> = [
        "microsoft", "packages", "temp", "crashdumps", "connecteddevicesplatform", "comms",
        "steam", "epicgameslauncher", "epic games", "unrealengine", "unrealenginelauncher", "cef",
        "nvidia", "nvidia corporation", "amd", "d3dscache", "wine", "mozilla", "google",
        "crashreportclient", "programs", "openal", "battle.net", "origin", "ea desktop",
        "ubisoft game launcher", "gog.com", "desktop.ini", "application data", "history",
        "temporary internet files", "my music", "my pictures", "my videos",
    ]

    /// Inside a game's folder: what changes every session and is never a save. Left out of
    /// backups, so a shader cache the game rewrites doesn't keep old copies alive on disk.
    nonisolated static func isChurn(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["cache", "logs", "crash", "webcache", "telemetry"].contains { lower.contains($0) }
            || lower == "temp" || lower == "tmp"
            || [".log", ".tmp", ".lock", ".dmp", ".etl", ".pid", ".lck"].contains { lower.hasSuffix($0) }
    }

    /// One file over this is a game's data, not its save.
    nonisolated static let largestSave: Int64 = 256 * 1_048_576

    /// Folder names a game keeps its saves under in a Documents that is the Mac's own: its title
    /// (without ® and ™) and its program's name, there or under "My Games".
    nonisolated static func documentsFolders(for games: [String]) -> [String] {
        var out: [String] = []
        for name in games {
            let clean = name.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
                .replacingOccurrences(of: "©", with: "").trimmingCharacters(in: .whitespaces)
            guard clean.count >= 3, !clean.contains("/"), !clean.hasPrefix(".") else { continue }
            for candidate in [clean, "My Games/" + clean] where !out.contains(candidate) { out.append(candidate) }
        }
        return out
    }

    /// drive_c-relative paths of the folders and files worth keeping in this prefix. `games`: the
    /// titles and program names of the games in it, for the one place outside the container a game
    /// may keep its saves — a Documents linked to the Mac's own (Cat Quest II keeps
    /// "Cat Quest II/save_file1.dat" there). Only those folders are looked at; nothing else of
    /// the person's Documents is read.
    nonisolated static func items(in driveC: URL, games: [String] = []) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        let people = ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).filter { $0 != "Public" && !$0.hasPrefix(".") }
        let inside = driveC.resolvingSymlinksInPath().path + "/"
        for person in people.sorted() {
            for place in profilePlaces {
                let rel = "users/\(person)/\(place)"
                let dir = driveC.appendingPathComponent(rel, isDirectory: true)
                // The prefix's Documents is usually a link to the Mac's own Documents folder.
                // Nothing there is Anvil's to copy, and only looking at it makes macOS ask
                // for permission: the first launch of 0.24.0 spent 1.9 s in this step, where
                // reading a container's own saves takes 50 ms. What a game keeps there is
                // outside every container, where deleting one never reaches it.
                guard dir.resolvingSymlinksInPath().path.hasPrefix(inside) else {
                    // Until 0.38.2 nothing there was kept, and a game that saves there had no
                    // copy taken before it ran: Cat Quest II's "saves: none yet" at every start.
                    if place == "Documents" {
                        for folder in documentsFolders(for: games) {
                            var isDir: ObjCBool = false
                            if fm.fileExists(atPath: dir.appendingPathComponent(folder).path, isDirectory: &isDir), isDir.boolValue {
                                out.append("\(rel)/\(folder)")
                            }
                        }
                    }
                    continue
                }
                let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
                for name in names where !name.hasPrefix(".") && !name.contains(".anvil-") {
                    if skipped.contains(name.lowercased()) || isChurn(name) { continue }
                    out.append("\(rel)/\(name)")
                }
            }
        }
        // Steam Cloud's copy of each game's saves: userdata/<account>/<app>/remote. Only the
        // saves — not Steam's settings for the account (app 7) or its screenshots (760).
        let userdata = driveC.appendingPathComponent("Program Files (x86)/Steam/userdata", isDirectory: true)
        for account in ((try? fm.contentsOfDirectory(atPath: userdata.path)) ?? []).sorted() where !account.hasPrefix(".") {
            let accountDir = userdata.appendingPathComponent(account)
            for app in ((try? fm.contentsOfDirectory(atPath: accountDir.path)) ?? []).sorted()
            where app != "7" && app != "760" && !app.hasPrefix(".") {
                let rel = "Program Files (x86)/Steam/userdata/\(account)/\(app)/remote"
                if fm.fileExists(atPath: driveC.appendingPathComponent(rel).path) { out.append(rel) }
            }
        }
        return out
    }

    struct File: Sendable {
        /// drive_c-relative.
        var path: String
        var url: URL
        var size: Int64
        var modified: Date
    }

    struct Walk: Sendable {
        var files: [File] = []
        var leftOut: [String] = []
        var bytes: Int64 = 0
        var newest: Date = .distantPast
        var fingerprint = ""
    }

    /// Every save file under these items. A folder linked in from elsewhere is followed at
    /// the top, as the game sees it; links further down are not.
    nonisolated static func walk(_ items: [String], in driveC: URL, limit: Int = 100_000) -> Walk {
        let fm = FileManager.default
        var w = Walk()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        func add(_ url: URL, as path: String) {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return }
            let size = Int64(v.fileSize ?? 0)
            if size > largestSave { w.leftOut.append(path); return }
            let date = v.contentModificationDate ?? .distantPast
            w.files.append(File(path: path, url: url, size: size, modified: date))
            w.bytes += size
            if date > w.newest { w.newest = date }
        }
        for item in items {
            let base = driveC.appendingPathComponent(item).resolvingSymlinksInPath()
            guard let v = try? base.resourceValues(forKeys: keys) else { continue }
            if v.isRegularFile == true { add(base, as: item); continue }
            guard v.isDirectory == true,
                  let e = fm.enumerator(at: base, includingPropertiesForKeys: Array(keys), options: []) else { continue }
            let prefix = base.path + "/"
            for case let url as URL in e {
                if isChurn(url.lastPathComponent) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { e.skipDescendants() }
                    continue
                }
                var full = url.path
                if !full.hasPrefix(prefix) { full = url.resolvingSymlinksInPath().path }
                guard full.hasPrefix(prefix) else { continue }
                add(url, as: item + "/" + full.dropFirst(prefix.count))
                if w.files.count >= limit { break }
            }
        }
        let lines = w.files.map { "\($0.path)|\($0.size)|\(Int($0.modified.timeIntervalSince1970 * 1000))" }.sorted()
        w.fingerprint = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return w
    }

    // MARK: Backing up

    nonisolated static func folder(for containerID: UUID) -> URL {
        root.appendingPathComponent(containerID.uuidString, isDirectory: true)
    }

    nonisolated static func list(for containerID: UUID) -> [Backup] {
        let dir = folder(for: containerID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> Backup? in
            guard !name.hasPrefix(".") else { return nil }
            let url = dir.appendingPathComponent(name, isDirectory: true)
            guard let m = manifest(of: url) else { return nil }
            return Backup(url: url, containerID: containerID, date: m.date, reason: m.reason, files: m.files, bytes: m.bytes)
        }
        .sorted { $0.date > $1.date }
    }

    nonisolated static func manifest(of backup: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent("backup.json")) else { return nil }
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// Copy the container's saves now. Skipped when nothing changed since the last copy,
    /// unless `force` — before a container is replaced or deleted there is always a copy.
    @discardableResult
    nonisolated static func backUp(prefix: URL, containerID: UUID, containerName: String,
                                   reason: String, force: Bool = false, games: [String] = []) -> Outcome {
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        guard fm.fileExists(atPath: driveC.path) else { return .nothingToKeep }
        let w = walk(items(in: driveC, games: games), in: driveC)
        let userReg = prefix.appendingPathComponent("user.reg")
        let hasRegistry = fm.fileExists(atPath: userReg.path)
        guard !w.files.isEmpty || (force && hasRegistry) else { return .nothingToKeep }
        if !force, let last = list(for: containerID).first, manifest(of: last.url)?.fingerprint == w.fingerprint {
            return .unchanged(since: last.date)
        }
        try? fm.createDirectory(at: folder(for: containerID), withIntermediateDirectories: true)
        let date = Date()
        var dest = folder(for: containerID).appendingPathComponent(folderName(for: date), isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            dest = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + " \(UUID().uuidString.prefix(4))")
        }
        let partial = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        let saved = partial.appendingPathComponent("drive_c", isDirectory: true)
        do { try fm.createDirectory(at: saved, withIntermediateDirectories: true) }
        catch { return .failed(error.localizedDescription) }
        // A clone takes no space. Off APFS each file is really copied, so there must be room.
        var cloned = true
        var made = Set<String>()
        for file in w.files {
            let target = saved.appendingPathComponent(file.path)
            let dir = target.deletingLastPathComponent()
            if made.insert(dir.path).inserted { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            switch copy(file.url, to: target) {
            case .cloned: break
            case .copied:
                if cloned, let free = freeSpace(at: partial), free < w.bytes + 1_073_741_824 {
                    try? fm.removeItem(at: partial)
                    return .failed("this disk can't make instant copies and has only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                }
                cloned = false
            case .failed:
                try? fm.removeItem(at: partial)
                return .failed("couldn't copy \(file.path)")
            }
        }
        // The registry: Unity games and many older ones keep settings, and some their
        // progress, under HKEY_CURRENT_USER. Kept for copying back by hand.
        if hasRegistry { _ = copy(userReg, to: partial.appendingPathComponent("user.reg")) }
        let m = Manifest(version: 1, containerName: containerName, reason: reason, date: date,
                         fingerprint: w.fingerprint, files: w.files.count, bytes: w.bytes, cloned: cloned,
                         leftOut: w.leftOut.isEmpty ? nil : w.leftOut)
        guard let data = try? encoder.encode(m),
              // Plain: the whole folder is renamed into place in one step below.
              (try? data.write(to: partial.appendingPathComponent("backup.json"))) != nil,
              rename(partial.path, dest.path) == 0 else {
            try? fm.removeItem(at: partial)
            return .failed("couldn't write to \(root.path)")
        }
        prune(containerID: containerID, now: date)
        return .made(dest, files: w.files.count)
    }

    nonisolated static func folderName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    enum CopyResult { case cloned, copied, failed }

    /// A clone where the volume can (APFS), a copy where it can't.
    nonisolated static func copy(_ source: URL, to target: URL) -> CopyResult {
        if clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 { return .cloned }
        if errno == EEXIST { return .failed }
        return (try? FileManager.default.copyItem(at: source, to: target)) != nil ? .copied : .failed
    }

    /// The newest ten backups, and the newest of each day for a month. Older copies go;
    /// the saves themselves are never touched here.
    nonisolated static func prune(containerID: UUID, now: Date = Date()) {
        let fm = FileManager.default
        let all = list(for: containerID)
        var keep = Set(all.prefix(10).map(\.url))
        var days = Set<String>()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for b in all where now.timeIntervalSince(b.date) < 31 * 86_400 {
            if days.insert(day.string(from: b.date)).inserted { keep.insert(b.url) }
        }
        for b in all where !keep.contains(b.url) { try? fm.removeItem(at: b.url) }
        // A backup cut short by a crash or a full disk.
        let dir = folder(for: containerID)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".partial") {
            let url = dir.appendingPathComponent(name)
            let made = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(made) > 3600 { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Putting back

    enum RestoreError: LocalizedError {
        case notABackup
        case nothingRestored
        var errorDescription: String? {
            switch self {
            case .notABackup: "That folder isn't one of Anvil's save backups."
            case .nothingRestored: "Nothing in the backup could be put back. Check free disk space."
            }
        }
    }

    /// Put a backup's saves back into the container. What is there now is backed up first,
    /// so a restore can itself be undone. Only files the backup has are put back: a save the
    /// game made since stays where it is. Each file is copied in beside the one it replaces
    /// and swapped in by rename, so a failure part-way leaves every file either as it was or
    /// as it is in the backup — never half of one.
    @discardableResult
    nonisolated static func restore(_ backup: URL, prefix: URL, containerID: UUID, containerName: String) throws -> Int {
        guard let m = manifest(of: backup) else { throw RestoreError.notABackup }
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        backUp(prefix: prefix, containerID: containerID, containerName: containerName,
               reason: "Before putting back the saves of \(shortDate(m.date))", force: true)
        var restored = 0, total = 0
        for file in files(in: backup) {
            total += 1
            if replace(driveC.appendingPathComponent(file.path), with: file.url) { restored += 1 }
        }
        if restored == 0 && total > 0 { throw RestoreError.nothingRestored }
        return restored
    }

    /// The files a backup holds, drive_c-relative.
    nonisolated static func files(in backup: URL) -> [File] {
        let saved = backup.appendingPathComponent("drive_c", isDirectory: true).resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: saved, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return [] }
        let prefix = saved.path + "/"
        var out: [File] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  v.isRegularFile == true else { continue }
            var full = url.path
            if !full.hasPrefix(prefix) { full = url.resolvingSymlinksInPath().path }
            guard full.hasPrefix(prefix) else { continue }
            out.append(File(path: String(full.dropFirst(prefix.count)), url: url,
                            size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Swap `live` for a copy of `source`: the copy made beside it first, then renamed over
    /// it in one step. Through a link to the Mac's Documents, the real folder is written.
    @discardableResult
    nonisolated static func replace(_ live: URL, with source: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = live.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(live.lastPathComponent)
        let staged = parent.appendingPathComponent(".anvil-restore-\(UUID().uuidString)")
        guard copy(source, to: staged) != .failed else { try? fm.removeItem(at: staged); return false }
        if Darwin.rename(staged.path, target.path) == 0 { return true }
        try? fm.removeItem(at: staged)
        return false
    }

    // MARK: After a session

    struct Repair: Sendable, Equatable { var path: String; var bytes: Int64 }

    /// Save files that were whole before the session and are empty now: what a game killed
    /// while writing leaves behind. Each is put back from the backup taken before the
    /// session. A file the game removed, or rewrote with anything in it, is the game's
    /// business and is left as it is.
    nonisolated static func repairEmptied(prefix: URL, since backup: URL) -> [Repair] {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        var repairs: [Repair] = []
        for file in files(in: backup) where file.size > 0 && !file.url.lastPathComponent.lowercased().contains("log") {
            let live = driveC.appendingPathComponent(file.path).resolvingSymlinksInPath()
            guard let now = try? live.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  now.isRegularFile == true, now.fileSize == 0 else { continue }
            if replace(live, with: file.url) { repairs.append(Repair(path: file.path, bytes: file.size)) }
        }
        return repairs
    }

    /// The backup that holds the saves as they were when a session began.
    nonisolated static func backup(for containerID: UUID, before date: Date) -> URL? {
        list(for: containerID).first { $0.date <= date }?.url
    }

    /// Whether the game is writing a save right now: anything in its saves changed within
    /// the last `seconds`. A game asked to close that is still saving is not forced yet.
    nonisolated static func isWriting(prefix: URL, within seconds: TimeInterval) -> Bool {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let w = walk(items(in: driveC), in: driveC, limit: 20_000)
        return Date().timeIntervalSince(w.newest) < seconds
    }

    // MARK: Disk space

    /// Free space for the volume holding `url`, as macOS counts it for things that matter.
    nonisolated static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Below this a game isn't started: a save written onto a full disk is a broken save.
    nonisolated static let launchMinimum: Int64 = 1_073_741_824
    /// Below this the launch log and the Activity screen say so.
    nonisolated static let launchWarning: Int64 = 5 * 1_073_741_824

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: Saves in the Mac's own Documents

extension SaveGuard {
    /// Whether the newest copy of this container's saves holds one of `games`' folders from a
    /// Documents linked to the Mac's own — known without looking in Documents itself, which macOS
    /// may first have to allow.
    nonisolated static func keptInDocuments(containerID: UUID, games: [String]) -> Bool {
        guard let newest = list(for: containerID).first?.url else { return false }
        let users = newest.appendingPathComponent("drive_c/users", isDirectory: true)
        let fm = FileManager.default
        for person in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let docs = users.appendingPathComponent("\(person)/Documents", isDirectory: true)
            if documentsFolders(for: games).contains(where: { fm.fileExists(atPath: docs.appendingPathComponent($0).path) }) { return true }
        }
        return false
    }

    /// The Mac's own Documents, when the prefix's is linked to it.
    nonisolated static func linkedDocuments(in driveC: URL) -> URL? {
        let fm = FileManager.default
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        let inside = driveC.resolvingSymlinksInPath().path + "/"
        for person in ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).sorted() where person != "Public" && !person.hasPrefix(".") {
            let docs = users.appendingPathComponent("\(person)/Documents", isDirectory: true)
            let real = docs.resolvingSymlinksInPath()
            if real.path != docs.path, !real.path.hasPrefix(inside) { return real }
        }
        return nil
    }

    /// Whether Anvil may open `games`' folders in the Mac's Documents: false when macOS refuses.
    /// Blocks while macOS is still asking — call it off the main thread.
    nonisolated static func documentsAllowed(_ documents: URL, games: [String]) -> Bool {
        for folder in documentsFolders(for: games) {
            if let dir = opendir(documents.appendingPathComponent(folder).path) { closedir(dir); continue }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true
    }
}

extension SaveGuard {
    /// The titles and program names of the library's games in a container: what to look for in a
    /// Documents linked to the Mac's own (see `items(in:games:)`).
    @MainActor static func gameNames(in container: Container) -> [String] {
        Library.shared.games(in: container).flatMap { [$0.title, $0.executableURL.deletingPathExtension().lastPathComponent] }
    }
}
