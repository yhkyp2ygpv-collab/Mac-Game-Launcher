// Saves that outlive a game (SaveVault): exports kept in two places, found again when the game comes back in
// another Windows setup, offered newest first, and put back — the export or the old setup's saves — with what the
// game had kept first, each saying what it holds, the furthest picked, and Undo. Run on copies of LEGO Star Wars' real
// saves of 17 and 20 October, in a home of its own:
//
//   CFFIXED_USER_HOME=$T/home HOME=$T/home SaveVaultTest <export.zip> <old setup's LEGO save folder> <new setup's LEGO save folder>
import Foundation

@main
struct SaveVaultTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static let publisher = "AppData/Roaming/Warner Bros. Interactive Entertainment"
    static let folder = "LEGO Star Wars - The Skywalker Saga"

    static func makeSetup(_ name: String, from saves: URL) -> Container {
        var c = Container(name: name, runtimeID: "none")
        c.id = UUID()
        let dest = c.driveC.appendingPathComponent("users/crossover/\(publisher)/\(folder)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? FileManager.default.copyItem(at: saves, to: dest)
        return c
    }

    static func size(_ c: Container, _ file: String) -> Int {
        let url = c.driveC.appendingPathComponent("users/crossover/\(publisher)/\(folder)/SAVEDGAMES/EPIC/2D99795513544C2CBDC588A08B453AC8/\(file)")
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    /// A file's size inside the export, read from the zip.
    static func zipped(_ zip: URL, _ suffix: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-l", zip.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        for line in text.split(separator: "\n") where line.hasSuffix(suffix) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count > 3, let n = Int(cols[3]) { return n }
        }
        return -2
    }

    @MainActor
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 4 else { print("usage: see header"); exit(2) }
        let fm = FileManager.default
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
        guard SaveVault.documentsFolder.path.hasPrefix(NSHomeDirectory()), !SaveVault.documentsFolder.path.hasPrefix(realHome + "/Documents"),
              !SaveVault.appFolder.path.hasPrefix(realHome + "/Library") else { print("refusing: not in a throwaway home"); exit(2) }
        let exportZip = URL(fileURLWithPath: a[1]), oldSaves = URL(fileURLWithPath: a[2]), newSaves = URL(fileURLWithPath: a[3])

        // The world of 20 October: the export in Documents only, the old setup still holding the saves, the game in a new
        // setup with a few minutes of a new start.
        try? fm.createDirectory(at: SaveVault.documentsFolder, withIntermediateDirectories: true)
        let inDocs = SaveVault.documentsFolder.appendingPathComponent(exportZip.lastPathComponent)
        try? fm.copyItem(at: exportZip, to: inDocs)
        let old = makeSetup("Star Wars", from: oldSaves)
        let new = makeSetup("Epic Games", from: newSaves)
        // The game's folder in the new setup was made on 19 October, two days after the export.
        let newFolder = new.driveC.appendingPathComponent("users/crossover/\(publisher)/\(folder)")
        try? fm.setAttributes([.creationDate: ISO8601DateFormatter().date(from: "2026-10-20T02:00:00Z")!], ofItemAtPath: newFolder.path)
        var game = Game(title: "LEGO® Star Wars™: The Skywalker Saga",
                        executablePath: "/nowhere/LEGOSTARWARSSKYWALKERSAGA_DX11.exe", containerID: new.id)
        game.epicAppName = "c390e58246ea4a778acefd7e0bf4a01f"
        let containers = [old, new]
        let oldCollectables = size(old, "SLOT1/COLLECTABLES.BLOB"), newCollectables = size(new, "SLOT1/COLLECTABLES.BLOB")
        check(oldCollectables > newCollectables && newCollectables > 0,
              "the old saves hold more than the new start (collectables \(oldCollectables) against \(newCollectables) bytes)")

        print("— kept in two places")
        check(SaveVault.mirror() == 1, "the export in Documents copied into Anvil's own Save Exports")
        check(fm.fileExists(atPath: SaveVault.appFolder.appendingPathComponent(exportZip.lastPathComponent).path), "and it's there")
        check(SaveVault.mirror() == 0, "and not copied twice")

        print("— what there is to choose from")
        let exports = SaveVault.exports(for: game)
        check(exports.count == 1, "one export of the game (\(exports.count)), found in both places as one")
        if case .export(let zips, let at)? = exports.first?.kind {
            check(zips.count == 2, "kept in Documents and in Anvil: \(zips.map { $0.deletingLastPathComponent().lastPathComponent })")
            check(at.formatted(.iso8601.year().month().day()) == "2026-10-18" || at.formatted(.iso8601.year().month().day()) == "2026-10-17",
                  "made when it was exported: \(at)")
        }
        let e = exports.first
        check((e?.files ?? 0) > 10 && (e?.files ?? 0) < 48, "its saves counted without the crash reports and caches it carries (\(e?.files ?? 0) of 48 files)")
        check(e?.lastSaved.map { $0 < (exports.first?.date ?? .distantPast) } == true, "the game last saved before it was exported: \(e?.lastSaved.map { "\($0)" } ?? "-")")
        let others = SaveVault.otherSetups(for: game, containers: containers)
        check(others.count == 1, "the old “Star Wars” setup still has its saves (\(others.count))")
        check(others.first?.files == e?.files, "the same save files as the export (\(others.first?.files ?? 0))")
        check((others.first?.lastSaved ?? .distantFuture) < (e?.lastSaved ?? .distantPast),
              "but older — the export's last save is the newest, and it's listed with it: \(others.first?.lastSaved.map { "\($0)" } ?? "-")")

        print("— an export's listing")
        let spaced = "-rw-r--r--  2.1 unx     1380 bX      544 defN 20261017.152528 profile/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/SAVEDGAMES/EPIC/2D99795513544C2CBDC588A08B453AC8/SLOT1/SAVEGAMEMETA.BLOB"
        let plain = "-rw-r--r--  2.1 unx     4096 bX      100 defN 20261018.195933 profile/AppData/Local/FNAF/Saved/SaveGames/Slot0.sav"
        check(SaveVault.entryName(Substring(spaced)) == "profile/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/SAVEDGAMES/EPIC/2D99795513544C2CBDC588A08B453AC8/SLOT1/SAVEGAMEMETA.BLOB",
              "a name with spaces read whole")
        check(SaveVault.entryName(Substring(plain)) == "profile/AppData/Local/FNAF/Saved/SaveGames/Slot0.sav", "and one without any, counted")

        print("— what each holds, read from the saves")
        check(SaveReader.placeName(area: "PLANET_CORUSCANT", route: "FULLTITLE_EPISODE1") == "Coruscant · Episode I"
              && SaveReader.placeName(area: "EP3LEVEL02", route: "FULLTITLE_EPISODE3") == "Episode III, level 2"
              && SaveReader.placeName(area: "EPSELECT_TITLE", route: nil) == "Episode Select", "the game's place names in words")
        check(e?.summary?.place == "Episode Select" && abs((e?.percent ?? 0) - 34.25) < 0.01,
              "the export: \(e?.summary?.text ?? "-") — the whole story done, back at Episode Select")
        check((others.first?.percent ?? 100) < (e?.percent ?? 0), "the old setup: \(others.first?.summary?.text ?? "-") — less far")

        // Save Guard's backups, as made before each play: the old setup's holds what it has; the new setup's, the new start.
        SaveGuard.backUp(prefix: old.prefixURL, containerID: old.id, containerName: old.name, reason: "test", force: true)
        SaveGuard.backUp(prefix: new.prefixURL, containerID: new.id, containerName: new.name, reason: "test", force: true)
        check(SaveVault.backups(for: game, containers: containers).count == 2, "a backup of each setup found, with the game's saves in it")

        print("— asked when it came back")
        guard let offer = SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: 0) else {
            check(false, "no offer for a game downloaded again"); exit(1)
        }
        check(offer.candidates.count == 2, "both offered: the export and the old setup (\(offer.candidates.count)) — the backups hold the same saves")
        check(offer.candidates.first { if case .otherSetup = $0.kind { true } else { false } }?.copies == 2,
              "the old setup's backup listed once with it: 2 copies of the same saves")
        check(!offer.candidates.contains { $0.isBackup }, "and the backup of what it has now isn't offered — nothing to go back to")
        check((offer.current?.percent ?? 100) < 5 && offer.current?.summary?.place.contains("Episode I") == true,
              "what it has now: \(offer.current?.summary?.text ?? "-") — the new start")
        check(offer.recommended.map { if case .export = $0.kind { true } else { false } } == true, "the furthest is picked: the export")
        check(offer.because?.contains("furthest") == true, "and it says why: \(offer.because ?? "-")")
        check(offer.candidates.first.map { if case .export = $0.kind { true } else { false } } == true, "newest first: the export")
        check(offer.current != nil && (offer.current?.lastSaved ?? .distantPast) > (offer.candidates.first?.date ?? .distantFuture),
              "and what it has now, the newer start, to keep instead")
        let asked = offer.candidates.first!.date.timeIntervalSince1970
        check(SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: asked) == nil,
              "asked once: not again for the same export")
        check(SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: asked, force: true) != nil,
              "but shown whenever Choose Saves from Before is pressed")
        // A game still writing to saves it had before the export — a copy kept, not a game come back — isn't asked about.
        try? fm.setAttributes([.creationDate: ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z")!], ofItemAtPath: newFolder.path)
        check(SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: 0) == nil,
              "a game whose saves began before the export: nothing to ask")
        try? fm.setAttributes([.creationDate: ISO8601DateFormatter().date(from: "2026-10-20T02:00:00Z")!], ofItemAtPath: newFolder.path)

        print("— the export put back")
        do {
            let done = try SaveVault.restoreKeeping(offer.candidates[0], for: game, container: new, aloneInContainer: true, containers: containers)
            let said = done.text
            if let zip = done.keptAs { SaveVault.rememberUndo(game: game, keptAs: zip, restored: "the export") }
            // The export holds the end of 17 October's afternoon (3:25 PM); the old setup now has 12:52 PM's, put back
            // there from a backup on 19 October — so the export, not the old setup, is what comes back.
            check(size(new, "SLOT1/COLLECTABLES.BLOB") == zipped(exportZip, "SLOT1/COLLECTABLES.BLOB"),
                  "the game's progress is the export's (\(size(new, "SLOT1/COLLECTABLES.BLOB")) bytes): \(said)")
            check(size(new, "SLOT1/GAMEPROGRESS.BLOB") == zipped(exportZip, "SLOT1/GAMEPROGRESS.BLOB"), "its story progress too")
        } catch { check(false, "restore: \(error)") }
        let before = ((try? fm.contentsOfDirectory(atPath: SaveVault.appFolder.path)) ?? []).filter { $0.contains("before restoring") }
        check(before.count == 1, "the new start exported first, in Anvil: \(before)")
        check(fm.fileExists(atPath: SaveVault.documentsFolder.appendingPathComponent(before.first ?? "-").path), "and in Documents")
        let asides = ((try? fm.contentsOfDirectory(atPath: newFolder.deletingLastPathComponent().path)) ?? []).filter { $0.contains(".anvil-replaced-") }
        check(asides.count == 1, "what was there moved aside, not overwritten: \(asides)")
        let places = GameSaves.places(for: game, in: new, aloneInContainer: true).map(\.relativePath)
        check(!places.contains { $0.contains(".anvil-replaced-") }, "and the moved-aside folder isn't taken for the game's saves: \(places)")
        let later = SaveVault.exports(for: game)
        check(later.count == 2, "the new start is now one of the choices too, should it be wanted back (\(later.count) exports)")

        print("— asked once, as on 21 October")
        // The restore just made a safety copy ("before restoring", the newest export now) and made the save folder
        // anew. Answered a moment ago: the start right after mustn't ask again.
        let answered = Date().timeIntervalSince1970
        check(SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: answered) == nil,
              "the start right after choosing doesn't ask again")
        // Never answered (or Ask Me Later): still not asked — nothing from before is further through than what it has now.
        check(SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: 0) == nil
              && SaveVault.lastDecision?.contains("as far through") == true, "nor when never answered: \(SaveVault.lastDecision ?? "-")")
        SaveVault.lastDecision = nil
        if let again = SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: 0, force: true) {
            check(again.candidates.contains { ($0.percent ?? 100) < 5 }, "the new start is listed to go back to: "
                  + again.candidates.map { SaveChoice.shared.describe($0) }.joined(separator: "; "))
            check(again.recommended?.kind == .current, "and what's picked is what it has now, the furthest — never the safety copy")
            check(again.candidates.first { if case .export = $0.kind, !$0.isSafetyCopy { true } else { false } }?.sameAsNow == true,
                  "the export it came from is marked the same as now")
        } else { check(false, "nothing listed by Choose Saves from Before") }

        print("— undo")
        if let u = SaveVault.undo(for: game) {
            check((u.candidate.percent ?? 100) < 5, "Undo would put back the new start: \(u.candidate.summary?.text ?? "-")")
            do {
                let back = try SaveVault.restoreKeeping(u.candidate, for: game, container: new, aloneInContainer: true, containers: containers)
                check(size(new, "SLOT1/COLLECTABLES.BLOB") == newCollectables, "undone: the new start is back")
                if let zip = back.keptAs { SaveVault.rememberUndo(game: game, keptAs: zip, restored: "the new start") }
                if let u2 = SaveVault.undo(for: game) {
                    check(abs((u2.candidate.percent ?? 0) - 34.25) < 0.01, "and undoing the undo would bring the finished game back")
                    _ = try SaveVault.restoreKeeping(u2.candidate, for: game, container: new, aloneInContainer: true, containers: containers)
                    check(size(new, "SLOT1/COLLECTABLES.BLOB") == zipped(exportZip, "SLOT1/COLLECTABLES.BLOB"), "which it does")
                } else { check(false, "no undo after the undo") }
            } catch { check(false, "undo: \(error)") }
        } else { check(false, "no undo kept after the restore") }

        print("— links out of the setup aren't followed")
        // Wine 7.7 made AppData/Roaming/Microsoft/Windows/Templates a link to the home folder.
        let outside = fm.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try? Data(count: 5_000_000).write(to: outside.appendingPathComponent("big-file-not-a-save.bin"))
        let templates = old.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Microsoft/Windows", isDirectory: true)
        try? fm.createDirectory(at: templates, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: templates.appendingPathComponent("Templates"), withDestinationURL: outside)
        let microsoft = old.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Microsoft")
        check(SaveTransfer.directorySize(microsoft) < 1_000_000, "a folder's size doesn't count what a link inside it points to (\(SaveTransfer.directorySize(microsoft)) bytes)")
        var seen = 0
        SaveTransfer.walk(old.driveC.appendingPathComponent("users/crossover/AppData")) { url, _ in if url.path.contains("big-file-not-a-save") { seen += 1 } }
        check(seen == 0, "nor is anything through it visited")
        let started = Date()
        let oldPlaces = GameSaves.places(for: game, in: old, aloneInContainer: true).map(\.relativePath)
        check(!oldPlaces.contains { $0.contains("Microsoft") } && Date().timeIntervalSince(started) < 5,
              String(format: "the setup's save folders found without it (%.2f s): %@", Date().timeIntervalSince(started), oldPlaces.description))

        print("— the old setup's saves put back")
        let fresh = makeSetup("Epic Games 2", from: newSaves)
        var game2 = game; game2.containerID = fresh.id
        if let setup = SaveVault.otherSetups(for: game2, containers: [old, fresh]).first {
            do {
                let said = try SaveVault.restore(setup, for: game2, container: fresh, aloneInContainer: true, containers: [old, fresh])
                check(size(fresh, "SLOT1/COLLECTABLES.BLOB") == oldCollectables, "copied from “Star Wars”: \(said)")
                check(size(old, "SLOT1/COLLECTABLES.BLOB") == oldCollectables, "and the old setup's own copy is left as it was")
            } catch { check(false, "copy: \(error)") }
        } else { check(false, "no old setup found") }

        print("— a backup put back")
        let fresh2 = makeSetup("Epic Games 3", from: newSaves)
        var game3 = game; game3.containerID = fresh2.id
        if let b = SaveVault.backups(for: game3, containers: [old, new, fresh2]).first(where: {
            if case .backup(_, let id, _, _, _) = $0.kind { id == old.id } else { false } }) {
            do {
                let said = try SaveVault.restore(b, for: game3, container: fresh2, aloneInContainer: true, containers: [old, new, fresh2])
                check(size(fresh2, "SLOT1/COLLECTABLES.BLOB") == oldCollectables, "the game's folder from the “Star Wars” backup: \(said)")
            } catch { check(false, "backup: \(error)") }
        } else { check(false, "no backup of the old setup") }

        print("— one Documents shared by every setup")
        // Wine links each setup's Documents to the Mac's: Cat Quest II's saves there are one folder, not saves left behind.
        let shared = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Cat Quest II", isDirectory: true)
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 4096).write(to: shared.appendingPathComponent("save_file1.dat"))
        func linked(_ name: String) -> Container {
            var c = Container(name: name, runtimeID: "none")
            c.id = UUID()
            let profile = c.driveC.appendingPathComponent("users/crossover", isDirectory: true)
            try? fm.createDirectory(at: profile, withIntermediateDirectories: true)
            try? fm.createSymbolicLink(at: profile.appendingPathComponent("Documents"), withDestinationURL: shared.deletingLastPathComponent())
            return c
        }
        let catA = linked("Cat Quest"), catB = linked("Epic Games 4")
        let cat = Game(title: "Cat Quest II", executablePath: "/nowhere/Cat Quest II.exe", containerID: catB.id)
        check(!GameSaves.places(for: cat, in: catB, aloneInContainer: false).isEmpty, "its own setup finds its saves in the Mac's Documents")
        check(SaveVault.otherSetups(for: cat, containers: [catA, catB]).isEmpty, "but another setup isn't offered as having them")
        let copied = (try? GameSaves.copy([GameSaves.Place(relativePath: "Documents/Cat Quest II", bytes: 4096)], from: catA, into: catB)) ?? -1
        check(copied == 0 && fm.fileExists(atPath: shared.appendingPathComponent("save_file1.dat").path),
              "and copying that folder onto itself is skipped — nothing moved aside, nothing lost")

        print("— kept what it has")
        let keep = SaveVault.Candidate(kind: .current, lastSaved: Date(), files: 1, bytes: 1)
        let kept = (try? SaveVault.restore(keep, for: game, container: new, aloneInContainer: true, containers: containers)) ?? "-"
        check(kept.hasPrefix("kept"), "keeping what it has changes nothing: \(kept)")

        print(failures == 0 ? "save vault: all checks passed" : "save vault: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
