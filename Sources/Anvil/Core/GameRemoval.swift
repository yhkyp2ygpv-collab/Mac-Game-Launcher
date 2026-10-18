import Foundation

/// Deleting a game: its saves exported first — nothing is deleted unless they're safely out, or there were none —
/// then its folder moved to the Trash, or deleted at once to free the space now; legendary's records of it and of
/// its DLC cleared; and the game out of the library. Only a folder Anvil can tell is the game's own
/// (GameSaves.installFolder: what legendary installed it to, else the folder its program is in) and never one at the
/// top of the disk, the home folder or a folder of games. A Steam game's files are Steam's to uninstall.
@MainActor
enum GameRemoval {
    struct Plan {
        var folder: URL?
        var epic: EpicLibrary.Installed?
        /// What it takes on disk, as legendary recorded when it installed it (nil: not known without measuring).
        var bytes: Int64?
        var steam: Bool
    }

    static func plan(for game: Game) -> Plan {
        let epic = EpicLibrary.installed().first {
            $0.appName == game.epicAppName || $0.executable.standardizedFileURL.path == game.executableURL.standardizedFileURL.path
        }
        var folder = GameSaves.installFolder(of: game, epicInstallPath: epic?.installPath.path)
        if let f = folder, !safe(f) { folder = nil }
        return Plan(folder: folder, epic: epic, bytes: epic?.installSize, steam: game.steamAppID != nil)
    }

    /// Never the disk's top, a system folder, the home folder or one of its own, or a folder of games itself.
    nonisolated static func safe(_ folder: URL) -> Bool {
        let f = folder.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let protected: Set<String> = ["/", "/Applications", "/Applications/Games", "/Users", "/Library", "/System", "/Volumes",
                                      "/private", "/opt", "/usr", home, home + "/Applications", home + "/Games",
                                      home + "/Documents", home + "/Downloads", home + "/Desktop", home + "/Library",
                                      EpicLibrary.gamesDir.standardizedFileURL.path]
        return f.pathComponents.count >= 4 && !protected.contains(f.path) && !f.path.hasPrefix("/System/")
            && !f.path.hasPrefix("/usr/") && !f.path.hasPrefix("/Library/")
    }

    static var savesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Anvil Saves", isDirectory: true)
    }

    enum Outcome {
        /// What was done, in a line, and the saves' export (nil: there were none to keep).
        case done(String, URL?)
        case failed(String)
    }

    /// Delete `game` as described above: to the Trash, or `permanently`.
    static func delete(_ game: Game, permanently: Bool) async -> Outcome {
        let library = Library.shared
        guard let container = library.container(id: game.containerID) else { return .failed("Its container isn't in the library.") }
        let plan = plan(for: game)
        let alone = !library.games.contains { $0.id != game.id && $0.containerID == game.containerID }
        let saves = savesFolder
        // The saves first. A game never played has none, and that's no reason to keep it.
        var zip: URL?
        do {
            try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            zip = try await Task.detached(priority: .userInitiated) {
                try GameSaves.export(game: game, container: container, aloneInContainer: alone, to: saves)
            }.value
        } catch GameSaves.Failure.nothingFound {
            zip = nil
        } catch {
            return .failed("The saves couldn't be exported (\(error.localizedDescription)), so nothing was deleted.")
        }
        var done = "removed from the library"
        if let folder = plan.folder {
            let size = plan.bytes
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    if permanently { try FileManager.default.removeItem(at: folder) }
                    else { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let why = result {
                return .failed((zip == nil ? "" : "The saves are exported, but ")
                               + "the game's folder couldn't be \(permanently ? "deleted" : "moved to the Trash") (\(why)). It's still in the library.")
            }
            let freed = size.map { " (\(EpicLibrary.bytes($0)))" } ?? ""
            done = (permanently ? "its folder deleted\(freed)" : "its folder moved to the Trash\(freed)") + " and " + done
            // Anvil's own Epic records, the game's and its DLC's: they're no longer installed through it.
            if let epic = plan.epic, let tool = EpicAccount.legendary {
                for app in [epic.appName] + EpicLibrary.dlc(installedAt: epic.installPath) {
                    let (status, _) = await EpicAccount.run(tool, ["uninstall", app, "--keep-files", "-y"], timeout: 60)
                    if status != 0 { AnvilLog.write("delete: \(game.title) — legendary's record of \(app) couldn't be removed (\(status))") }
                }
            }
        }
        library.removeGame(game)
        let kept = zip.map { "its saves exported to \($0.path)" } ?? "no saves found to keep"
        AnvilLog.write("delete: \(game.title) — \(kept); \(done)")
        return .done("\(game.title): \(kept); \(done).", zip)
    }
}
