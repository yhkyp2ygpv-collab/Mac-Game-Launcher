// Save Guard, the library's own fail-safes and load-time estimates (0.24.0), on a made-up
// prefix in a scratch folder and on the real game log.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/SaveGuardTest.swift -o $TMPDIR/SaveGuardTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/SaveGuardTest <dir> [<real game.log>]
import Foundation

@main struct SaveGuardHarness {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        func write(_ rel: String, _ bytes: Int, in base: URL) {
            let url = base.appendingPathComponent(rel)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(repeating: 0x41, count: bytes).write(to: url)
        }
        func size(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }

        // 1. A prefix laid out as Wine lays one out, Documents a link to the Mac's own.
        let prefix = root.appendingPathComponent("prefix")
        let driveC = prefix.appendingPathComponent("drive_c")
        let macDocs = root.appendingPathComponent("MacDocuments")
        try? fm.removeItem(at: root.appendingPathComponent("prefix"))
        try? fm.removeItem(at: macDocs)
        SaveGuard.root = root.appendingPathComponent("Save Backups")
        try? fm.removeItem(at: SaveGuard.root)
        let profile = "users/crossover"
        write("\(profile)/AppData/Roaming/Studio/Game/save1.sav", 100, in: driveC)
        write("\(profile)/AppData/Local/Game/Saved/SaveGames/slot.sav", 300, in: driveC)
        write("\(profile)/AppData/Local/Game/Saved/Logs/game.log", 5000, in: driveC)
        write("\(profile)/AppData/Local/Game/ShaderCache/pipelines.bin", 90_000, in: driveC)
        write("\(profile)/AppData/Local/Steam/htmlcache/index", 4000, in: driveC)
        write("\(profile)/AppData/Roaming/Microsoft/Windows/x.dat", 10, in: driveC)
        write("\(profile)/Saved Games/Other/progress.dat", 50, in: driveC)
        write("My Games/X/save.dat", 70, in: macDocs)
        write("Personal/taxes.pdf", 900, in: macDocs)
        try! fm.createSymbolicLink(at: driveC.appendingPathComponent("\(profile)/Documents"), withDestinationURL: macDocs)
        write("Program Files (x86)/Steam/userdata/123/7/remote/sharedconfig.vdf", 20, in: driveC)
        write("Program Files (x86)/Steam/userdata/123/456/remote/save.bin", 40, in: driveC)
        write("user.reg", 2000, in: prefix)
        let id = UUID()

        let items = SaveGuard.items(in: driveC)
        print("items: \(items)")
        check(items.contains("\(profile)/AppData/Roaming/Studio") && items.contains("\(profile)/AppData/Local/Game"), "a game's folders are kept")
        check(!items.contains { $0.hasSuffix("/Steam") || $0.hasSuffix("/Microsoft") }, "Steam's web cache and Windows' own folders are left out")
        check(!items.contains { $0.contains("/Documents/") },
              "nothing is taken from the Mac's own Documents folder — looking there makes macOS ask for permission")
        check(items.contains("Program Files (x86)/Steam/userdata/123/456/remote") && !items.contains { $0.contains("/7/") },
              "Steam Cloud saves kept, Steam's own account settings not")

        let first = SaveGuard.backUp(prefix: prefix, containerID: id, containerName: "Test", reason: "Before playing")
        print("first: \(first.logLine)")
        guard case .made(let b1, let n1) = first else { print("FAIL: no backup made"); exit(1) }
        let saved = b1.appendingPathComponent("drive_c")
        check(n1 == 4, "four save files backed up (\(n1))")
        check(fm.fileExists(atPath: saved.appendingPathComponent("\(profile)/AppData/Roaming/Studio/Game/save1.sav").path), "save1.sav in the backup")
        check(!fm.fileExists(atPath: saved.appendingPathComponent("\(profile)/AppData/Local/Game/Saved/Logs").path)
              && !fm.fileExists(atPath: saved.appendingPathComponent("\(profile)/AppData/Local/Game/ShaderCache").path),
              "logs and shader caches are not backed up")
        check(fm.fileExists(atPath: b1.appendingPathComponent("user.reg").path), "the registry is kept with it")
        check(SaveGuard.manifest(of: b1)?.cloned == true, "copies are clones on this volume")

        check(SaveGuard.backUp(prefix: prefix, containerID: id, containerName: "Test", reason: "again") == .unchanged(since: SaveGuard.list(for: id)[0].date),
              "nothing changed: no second copy")
        write("\(profile)/AppData/Local/Game/Saved/Logs/game.log", 7000, in: driveC)
        if case .unchanged = SaveGuard.backUp(prefix: prefix, containerID: id, containerName: "Test", reason: "log") { check(true, "a log alone doesn't make a new copy") }
        else { check(false, "a log alone doesn't make a new copy") }

        // 2. A game killed while writing: its save left empty, put back.
        let save1 = driveC.appendingPathComponent("\(profile)/AppData/Roaming/Studio/Game/save1.sav")
        let slot = driveC.appendingPathComponent("\(profile)/AppData/Local/Game/Saved/SaveGames/slot.sav")
        try! Data().write(to: save1)
        write("\(profile)/AppData/Local/Game/Saved/SaveGames/slot.sav", 350, in: driveC)
        try! Data().write(to: driveC.appendingPathComponent("\(profile)/AppData/Local/Game/Saved/Logs/game.log"))
        let repairs = SaveGuard.repairEmptied(prefix: prefix, since: b1)
        print("repairs: \(repairs)")
        check(repairs.count == 1 && size(save1) == 100, "the emptied save is put back whole (\(size(save1)) bytes)")
        check(size(slot) == 350, "a save the game rewrote with something in it is left as the game wrote it")
        check(!((try? fm.contentsOfDirectory(atPath: save1.deletingLastPathComponent().path)) ?? []).contains { $0.contains(".anvil-") },
              "nothing of Anvil's left beside the save")

        // 3. Putting a backup back, undoably.
        Thread.sleep(forTimeInterval: 1.1)
        guard case .made(let b2, _) = SaveGuard.backUp(prefix: prefix, containerID: id, containerName: "Test", reason: "later") else { print("FAIL: second backup"); exit(1) }
        write("\(profile)/AppData/Local/Game/Saved/SaveGames/new-slot.sav", 10, in: driveC)
        Thread.sleep(forTimeInterval: 1.1)
        let restored = (try? SaveGuard.restore(b1, prefix: prefix, containerID: id, containerName: "Test")) ?? -1
        check(restored == 4 && size(slot) == 300, "restoring the first backup puts slot.sav back to 300 bytes (\(size(slot)))")
        check(fm.fileExists(atPath: slot.deletingLastPathComponent().appendingPathComponent("new-slot.sav").path),
              "a save made since the backup is left where it is")
        let all = SaveGuard.list(for: id)
        check(all.count == 3 && all[0].reason.hasPrefix("Before putting back"), "what was there before the restore was backed up first (\(all.map(\.reason)))")
        check(SaveGuard.files(in: all[0].url).contains { $0.path.hasSuffix("slot.sav") && $0.size == 350 }, "…holding the 350-byte slot.sav")
        _ = b2

        // 4. Still saving?
        write("\(profile)/AppData/Roaming/Studio/Game/save1.sav", 120, in: driveC)
        check(SaveGuard.isWriting(prefix: prefix, within: 3), "a save written a moment ago: the game is still saving")
        for f in SaveGuard.walk(SaveGuard.items(in: driveC), in: driveC).files {
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: f.url.path)
        }
        check(!SaveGuard.isWriting(prefix: prefix, within: 3), "nothing written for a minute: not saving")

        // 5. Pruning: the newest ten, and one a day for a month.
        let pid = UUID()
        let dir = SaveGuard.folder(for: pid)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        for i in 0..<30 {
            let date = now.addingTimeInterval(-Double(i) * 6 * 3600)   // every six hours, back 7.5 days
            let b = dir.appendingPathComponent(SaveGuard.folderName(for: date))
            try? fm.createDirectory(at: b, withIntermediateDirectories: true)
            let m = SaveGuard.Manifest(version: 1, containerName: "P", reason: "r\(i)", date: date, fingerprint: "\(i)", files: 1, bytes: 1, cloned: true)
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            try! e.encode(m).write(to: b.appendingPathComponent("backup.json"))
        }
        SaveGuard.prune(containerID: pid, now: now)
        let kept = SaveGuard.list(for: pid)
        let days = Set(kept.map { Calendar.current.startOfDay(for: $0.date) })
        check(kept.count >= 10 && kept.count <= 18 && days.count >= 8, "pruned to the newest ten and one a day (\(kept.count) kept over \(days.count) days)")

        // 6. Disk space.
        let free = SaveGuard.freeSpace(at: prefix) ?? -1
        check(free > 0, "free space read (\(SaveGuard.sizeText(free)))")

        // 7. The library never saves an empty list over a full one by accident, keeps
        //    copies, and comes back from them.
        let support = RuntimeManager.support
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let container = Container(name: "C", runtimeID: "r")
        let game = Game(title: "G", executablePath: "/x/G.exe", containerID: container.id)
        let e = JSONEncoder()
        struct Store: Codable { var containers: [Container]; var games: [Game] }
        try! e.encode(Store(containers: [container], games: [game])).write(to: support.appendingPathComponent("library.json"))
        try? fm.removeItem(at: Library.backupsDir)
        let lib = Library.shared
        check(lib.games.count == 1, "library loaded")
        lib.games = []
        lib.containers = []
        lib.save()
        let onDisk = try? JSONDecoder().decode(Store.self, from: Data(contentsOf: support.appendingPathComponent("library.json")))
        check(onDisk?.games.count == 1, "an empty library is not saved over one with a game in it")
        lib.load()
        check(lib.games.count == 1, "…and the game is still there to load")
        lib.save()
        let copies = (try? fm.contentsOfDirectory(atPath: Library.backupsDir.path)) ?? []
        check(copies.count == 1, "a copy of the library is kept (\(copies))")
        lib.removeGame(lib.games[0])
        let afterRemove = try? JSONDecoder().decode(Store.self, from: Data(contentsOf: support.appendingPathComponent("library.json")))
        check(afterRemove?.games.isEmpty == true, "a game the user removes is removed")
        try? fm.removeItem(at: support.appendingPathComponent("library.json"))
        lib.games = []; lib.containers = []      // as at a fresh start
        lib.load()
        check(lib.games.count == 1 && lib.lastError?.contains("brought back") == true, "a missing library comes back from its copy (\(lib.lastError ?? "-"))")

        // 7b. A game that keeps its saves in a Documents linked to the Mac's own (Cat Quest II:
        // "Documents/Cat Quest II/save_file1.dat"): its folder kept, nothing else of the person's.
        let cqContainer = Container(name: "Cat Quest", runtimeID: "none")
        let cq = cqContainer.prefixURL
        let cqC = cqContainer.driveC
        let cqDocs = root.appendingPathComponent("CQMacDocuments")
        try? fm.removeItem(at: cq); try? fm.removeItem(at: cqDocs)
        write("Cat Quest II/save_file1.dat", 15302, in: cqDocs)
        write("Cat Quest II/save_file1.dat.bak", 15302, in: cqDocs)
        write("Cat Quest II/settings", 458, in: cqDocs)
        write("Cat Quest II/Crashes/Crash_2026/error.log", 3000, in: cqDocs)
        write("Personal/taxes.pdf", 900, in: cqDocs)
        write("users/crossover/AppData/LocalLow/The Gentlebros Pte. Ltd_/Cat Quest II/Player.log", 2000, in: cqC)
        try! fm.createSymbolicLink(at: cqC.appendingPathComponent("users/crossover/Documents"), withDestinationURL: cqDocs)
        let cqNames = ["Cat Quest II", "Cat Quest II"]
        check(SaveGuard.documentsFolders(for: ["LEGO® Star Wars™: The Skywalker Saga"]).first == "LEGO Star Wars: The Skywalker Saga",
              "a title's folder name without ® and ™")
        let cqItems = SaveGuard.items(in: cqC, games: cqNames)
        check(cqItems.contains("users/crossover/Documents/Cat Quest II") && !cqItems.contains { $0.contains("Personal") },
              "the game's own folder in the linked Documents is kept, the person's files aren't (\(cqItems))")
        check(!SaveGuard.items(in: cqC).contains { $0.contains("/Documents/") }, "without the container's games, nothing in Documents is looked at")
        let cqID = UUID()
        let cqBackup = SaveGuard.backUp(prefix: cq, containerID: cqID, containerName: "Cat Quest", reason: "Before playing Cat Quest II", games: cqNames)
        print("cat quest: \(cqBackup.logLine)")
        if case .made(let b, _) = cqBackup {
            let kept = b.appendingPathComponent("drive_c/users/crossover/Documents/Cat Quest II")
            check(size(kept.appendingPathComponent("save_file1.dat")) == 15302 && size(kept.appendingPathComponent("settings")) == 458,
                  "save_file1.dat and settings backed up before the game runs (was: “saves: none yet”)")
            check(!fm.fileExists(atPath: kept.appendingPathComponent("Crashes").path), "its crash reports left out")
            check(!fm.fileExists(atPath: b.appendingPathComponent("drive_c/users/crossover/Documents/Personal").path), "the person's own files never copied")
        } else { check(false, "a backup was made for Cat Quest II (\(cqBackup.logLine))") }
        let cqGame = Game(title: "Cat Quest II", executablePath: "/Games/CatQuestII/Cat Quest II.exe", containerID: cqContainer.id)
        let places = GameSaves.places(for: cqGame, in: cqContainer, aloneInContainer: true)
        check(places.contains { $0.relativePath == "Documents/Cat Quest II" }, "Export Saves takes it too (\(places.map(\.relativePath)))")

        // 8. Load times from the real game log.
        if CommandLine.arguments.count > 2, let text = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8) {
            let title = "LEGO® Star Wars™: The Skywalker Saga"
            let seen = LoadTime.history(of: title, text: text)
            print("LEGO load times: \(seen.map { String(format: "%.0f", $0) }.joined(separator: ", ")) s")
            if let est = LoadTime.estimate(of: title, text: text) {
                print("LEGO estimate: about \(LoadTime.text(est.typical)), up to \(LoadTime.text(est.longest)), from \(est.sessions) sessions")
                check(est.sessions >= 3 && est.typical >= 8 && est.typical <= 120, "LEGO's load time read from its sessions (it loads in 12–15 s since 10 October)")
            } else { check(false, "LEGO's load time read from its sessions") }
            check(LoadTime.estimate(of: "No Such Game", text: text) == nil, "no estimate for a game never played")
        }
        check(LoadTime.clock("18:24:42.465 [anvil] x") == 66282.465, "clock parsed")
        check(LoadTime.text(37) == "40 s" && LoadTime.text(166) == "2 min 50 s" && LoadTime.text(120) == "2 min", "times read naturally")

        print(failures == 0 ? "save guard: all checks passed" : "save guard: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
