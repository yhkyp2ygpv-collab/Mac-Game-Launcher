// 0.33.0, in a throwaway home: a game's own saves picked out of its container, exported to one
// .zip, read back and restored — what was there moved aside, never overwritten — and the folders
// "Delete Game, Keep Saves" will and won't throw away.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/SavesExportTest.swift -o $TMPDIR/SavesExportTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/SavesExportTest
import Foundation

@main struct SavesExportHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/") else { print("refusing: not in a throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        func write(_ text: String, _ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

        // 1. Whose folder is whose.
        let lego = "LEGO® Star Wars™: The Skywalker Saga", legoExe = "LEGOSTARWARSSKYWALKERSAGA_DX11.exe"
        check(GameSaves.belongs("LEGO Star Wars - The Skywalker Saga", title: lego, executable: legoExe), "LEGO's own folder is LEGO's")
        check(!GameSaves.belongs("Warner Bros. Interactive Entertainment", title: lego, executable: legoExe), "its publisher's folder isn't")
        check(GameSaves.belongs("Cat Quest II", title: "Cat Quest II", executable: "Cat Quest II.exe"), "Cat Quest II's is")
        check(!GameSaves.belongs("Star Trek Online", title: lego, executable: legoExe), "one word in common isn't enough")
        check(GameSaves.belongs("Hades", title: "Hades", executable: "Hades.exe"), "a one-word title matches itself")

        // 2. A container with LEGO's saves, another game's, and noise.
        let c = Container(name: "Saves Test", runtimeID: "none")
        let profile = c.driveC.appendingPathComponent("users/crossover")
        let legoDir = profile.appendingPathComponent("AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga")
        write("slot one", legoDir.appendingPathComponent("SAVEDGAMES/EPIC/ABC/SAVEGAME0.SAV"))
        write("Windowed 0", legoDir.appendingPathComponent("PCCONFIG.TXT"))
        write("other", profile.appendingPathComponent("AppData/LocalLow/Some Studio/Another Game/save.dat"))
        write("cache", profile.appendingPathComponent("AppData/Local/D3DSCache/x.bin"))
        let game = Game(title: lego, executablePath: "/Applications/Games/Mythic/LEGOStarWarsTSS/\(legoExe)", containerID: c.id)
        let shared = GameSaves.places(for: game, in: c, aloneInContainer: false)
        check(shared.map(\.relativePath) == ["AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga"],
              "sharing a container, only LEGO's own folder (\(shared.map(\.relativePath)))")
        let alone = GameSaves.places(for: game, in: c, aloneInContainer: true)
        check(alone.count == 2 && alone.contains { $0.relativePath.hasSuffix("Some Studio") } && !alone.contains { $0.relativePath.contains("D3DSCache") },
              "alone in its container, every save folder there but the noise (\(alone.map(\.relativePath)))")

        // A Documents linked out to the Mac's own is never taken.
        let macDocs = RuntimeManager.support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Documents/Personal")
        write("tax return", macDocs.appendingPathComponent("2026.pdf"))
        try? fm.createSymbolicLink(at: profile.appendingPathComponent("Documents"), withDestinationURL: macDocs.deletingLastPathComponent())
        check(!GameSaves.places(for: game, in: c, aloneInContainer: true).contains { $0.relativePath.hasPrefix("Documents") },
              "the Mac's own Documents, linked into the container, is left out")

        // 3. Export, read back, restore.
        let out = RuntimeManager.support.appendingPathComponent("exports")
        var zip: URL?
        do { zip = try GameSaves.export(game: game, container: c, aloneInContainer: false, to: out) }
        catch { check(false, "export: \(error.localizedDescription)") }
        check(zip.map { fm.fileExists(atPath: $0.path) && $0.lastPathComponent.hasPrefix("LEGO® Star Wars™ The Skywalker Saga saves ") } == true,
              "one .zip, named after the game (\(zip?.lastPathComponent ?? "none"))")
        if let zip {
            let manifest = try? GameSaves.manifest(of: zip)
            check(manifest?.game == lego && manifest?.places.count == 1, "its list says what's inside")
            let second = try? GameSaves.export(game: game, container: c, aloneInContainer: false, to: out)
            check(second != nil && second != zip, "a second export the same day doesn't replace the first (\(second?.lastPathComponent ?? "none"))")

            write("slot one — played on", legoDir.appendingPathComponent("SAVEDGAMES/EPIC/ABC/SAVEGAME0.SAV"))
            let restored = try? GameSaves.restore(from: zip, into: c)
            check(restored?.places.count == 1, "restored")
            check(read(legoDir.appendingPathComponent("SAVEDGAMES/EPIC/ABC/SAVEGAME0.SAV")) == "slot one", "the export's save is back")
            let parent = legoDir.deletingLastPathComponent()
            let aside = (try? fm.contentsOfDirectory(atPath: parent.path))?.filter { $0.contains(".anvil-replaced-") } ?? []
            check(aside.count == 1 && read(parent.appendingPathComponent(aside[0]).appendingPathComponent("SAVEGAME0.SAV")) == nil
                  && read(parent.appendingPathComponent(aside[0]).appendingPathComponent("SAVEDGAMES/EPIC/ABC/SAVEGAME0.SAV")) == "slot one — played on",
                  "what was there is kept beside it, not overwritten (\(aside))")

            // Into a fresh container: a reinstall's.
            let fresh = Container(name: "Fresh", runtimeID: "none")
            write("", fresh.driveC.appendingPathComponent("users/crossover/.keep"))
            _ = try? GameSaves.restore(from: zip, into: fresh)
            check(read(fresh.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT")) == "Windowed 0",
                  "an export restores into a new container, where the game looks")
        }
        let notExport = out.appendingPathComponent("random.zip")
        write("not a zip", notExport)
        check((try? GameSaves.manifest(of: notExport)) == nil, "a file that isn't an export is refused")
        let empty = Game(title: "Nothing Here", executablePath: "/x/nothing.exe", containerID: c.id)
        check((try? GameSaves.export(game: empty, container: c, aloneInContainer: false, to: out)) == nil, "a game with no saves found: no empty export")

        // 4. What Delete may throw away.
        check(GameSaves.installFolder(of: game, epicInstallPath: "/Applications/Games/Mythic/LEGOStarWarsTSS")?.path == "/Applications/Games/Mythic/LEGOStarWarsTSS",
              "an Epic game: the folder its install record names")
        var steamGame = game; steamGame.steamAppID = "920210"
        check(GameSaves.installFolder(of: steamGame, epicInstallPath: nil) == nil, "a Steam game: Steam's to remove")
        check(GameSaves.installFolder(of: Game(title: "X", executablePath: "/Applications/x.exe", containerID: c.id), epicInstallPath: nil) == nil,
              "never /Applications itself")
        check(GameSaves.installFolder(of: Game(title: "X", executablePath: c.driveC.appendingPathComponent("Program Files/x.exe").path, containerID: c.id), epicInstallPath: nil) == nil,
              "never a container's Program Files")
        check(GameSaves.installFolder(of: Game(title: "X", executablePath: c.driveC.appendingPathComponent("windows/system32/notepad.exe").path, containerID: c.id), epicInstallPath: nil) == nil,
              "never Windows' own folders")
        check(GameSaves.installFolder(of: Game(title: "X", executablePath: "/Users/someone/Games/Hades/Hades.exe", containerID: c.id), epicInstallPath: nil)?.lastPathComponent == "Hades",
              "a game's own folder elsewhere")

        print(failures == 0 ? "saves export: all passed" : "saves export: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
