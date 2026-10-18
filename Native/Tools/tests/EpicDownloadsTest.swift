import Foundation

// 0.53: an Epic game's sizes before it's installed (legendary info), a download stopped and its leftovers, and
// deleting a game (GameRemoval) — what legendary's words are read as, which folders may ever be deleted, and a
// whole delete of a game in a scratch library. Run with CFFIXED_USER_HOME set to a scratch folder.
@main struct EpicDownloadsHarness {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil, RuntimeManager.support.path.contains("/home/") else {
            print("FAIL: run with CFFIXED_USER_HOME, not on the real library"); exit(1)
        }

        // 1. Sizes, from legendary info's JSON and from its words.
        let json = """
        [cli] INFO: Getting info for game...
        {"game": {"app_name": "Styx", "title": "Styx: Master of Shadows"}, "install": null,
         "manifest": {"size": 1234, "disk_size": 9573418189, "download_size": 4511234567, "launch_exe": "Binaries/Win32/StyxGame.exe"}}
        """
        let fromJSON = EpicLibrary.parseSize(json)
        check(fromJSON.download == 4_511_234_567 && fromJSON.install == 9_573_418_189, "JSON sizes: \(fromJSON)")
        let words = "[cli] INFO: Download size (compressed): 4.20 GiB\n[cli] INFO: Disk size (uncompressed): 8.92 GiB\n"
        let fromWords = EpicLibrary.parseSize(words)
        check(fromWords.download.map { abs(Double($0) - 4.20 * 1_073_741_824) < 1_000_000 } == true
              && fromWords.install.map { abs(Double($0) - 8.92 * 1_073_741_824) < 1_000_000 } == true, "sizes in words: \(fromWords)")
        check(EpicLibrary.parseSize("[cli] ERROR: Login failed").download == nil, "nothing said: no size")
        check(EpicLibrary.amount(in: "x: 512.00 MiB") == 536_870_912, "MiB")

        // 2. The install's own lines before it downloads.
        let start = """
        [cli] INFO: Install path: /Users/someone/Games/Anvil/StyxMasterofShadowshWzSS
        [cli] INFO: Install size: 9129.84 MiB
        [cli] INFO: Download size: 4302.21 MiB (Compression savings: 52.9%)
        [cli] INFO: Reusable size: 0.00 MiB (chunks) / 0.00 MiB (unchanged / skipped)
        """
        let u = EpicLibrary.progress(in: start)
        check(u.folder?.path == "/Users/someone/Games/Anvil/StyxMasterofShadowshWzSS", "install path: \(String(describing: u.folder))")
        check(u.installBytes.map { abs(Double($0) - 9129.84 * 1_048_576) < 10_000 } == true, "install size: \(String(describing: u.installBytes))")
        check(u.downloadBytes.map { abs(Double($0) - 4302.21 * 1_048_576) < 10_000 } == true, "download size, not the savings: \(String(describing: u.downloadBytes))")
        let going = EpicLibrary.progress(in: "[DLManager] INFO: = Progress: 42.50% (1234/2900), Running for 00:01:10, ETA: 00:01:35\n")
        check(going.fraction == 0.425 && going.secondsLeft == 95 && going.any, "progress line")
        check(!EpicLibrary.progress(in: "[cli] INFO: nothing\n").any, "a line about nothing: no update")

        // 3. Which folders a stopped download is ever cleared from: one directly in Anvil's games folder.
        let games = EpicLibrary.gamesDir
        check(EpicLibrary.isOurs(games.appendingPathComponent("Styx")), "a download's own folder")
        check(!EpicLibrary.isOurs(games), "never the games folder itself")
        check(!EpicLibrary.isOurs(games.appendingPathComponent(".hidden")), "never a hidden one")
        check(!EpicLibrary.isOurs(games.appendingPathComponent("Styx/Binaries")), "never deeper")
        check(!EpicLibrary.isOurs(URL(fileURLWithPath: "/Applications/Games/Mythic/LEGOStarWarsTSS")), "never another launcher's")

        // 4. Which folders a game's delete may ever take.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/", "/Applications", "/Applications/Games", "/Users", home, home + "/Games", home + "/Games/Anvil",
                     home + "/Documents", home + "/Downloads", home + "/Desktop", "/System/Library/Fonts", "/Library/Fonts", "/usr/local/bin"] {
            check(!GameRemoval.safe(URL(fileURLWithPath: path)), "never \(path)")
        }
        for path in ["/Applications/Games/Mythic/LEGOStarWarsTSS", home + "/Games/Anvil/StyxMasterofShadowshWzSS"] {
            check(GameRemoval.safe(URL(fileURLWithPath: path)), "a game's own folder: \(path)")
        }

        // 5. A whole delete, at once, of a game in a scratch library: no saves to keep, its folder gone, out of the library.
        let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!)
        let folder = scratch.appendingPathComponent("Stuff/Test Game", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 300_000).write(to: folder.appendingPathComponent("Data/pak0.dat"))
        try? Data("MZ".utf8).write(to: folder.appendingPathComponent("Game.exe"))
        let container = Container(name: "Scratch", runtimeID: "none")
        var game = Game(title: "Test Game", executablePath: folder.appendingPathComponent("Game.exe").path, containerID: container.id)
        game.id = UUID()
        let other = Game(title: "Other", executablePath: "/nowhere/Other.exe", containerID: container.id)
        struct Store: Codable { var containers: [Container]; var games: [Game] }
        try? FileManager.default.createDirectory(at: RuntimeManager.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Store(containers: [container], games: [game, other])).write(to: RuntimeManager.support.appendingPathComponent("library.json"))
        await MainActor.run {
            check(Library.shared.games.count == 2, "the scratch library: \(Library.shared.games.map(\.title))")
            let plan = GameRemoval.plan(for: game)
            check(plan.folder?.standardizedFileURL.path == folder.standardizedFileURL.path && plan.epic == nil, "plan: its folder, not Epic's: \(String(describing: plan.folder))")
        }
        check(EpicLibrary.allocatedSize(of: folder) >= 300_000, "its size measured")
        let outcome = await GameRemoval.delete(game, permanently: true)
        switch outcome {
        case .done(let text, let zip):
            check(zip == nil && text.contains("no saves found") && text.contains("deleted"), "said: \(text)")
        case .failed(let why):
            check(false, "deleted: \(why)")
        }
        check(!FileManager.default.fileExists(atPath: folder.path), "its folder gone")
        check(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Stuff").path), "the folder around it kept")
        await MainActor.run {
            check(Library.shared.games.map(\.title) == ["Other"], "out of the library, the other kept: \(Library.shared.games.map(\.title))")
        }

        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("epic downloads: all checks passed")
    }
}
