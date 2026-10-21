// Saves that outlive a game (SaveVault): exports kept in two places, found again when the game comes back in
// another Windows setup, offered newest first, and put back — the export or the old setup's saves — with what the
// game had kept first. Run on copies of LEGO Star Wars' real saves of 17 and 20 October, in a home of its own:
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

        print("— asked when it came back")
        guard let offer = SaveVault.offer(for: game, container: new, containers: containers, aloneInContainer: true, askedUpTo: 0) else {
            check(false, "no offer for a game downloaded again"); exit(1)
        }
        check(offer.candidates.count == 2, "both offered: the export and the old setup")
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
            let said = try SaveVault.restore(offer.candidates[0], for: game, container: new, aloneInContainer: true, containers: containers)
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

        print("— kept what it has")
        let keep = SaveVault.Candidate(kind: .current, lastSaved: Date(), files: 1, bytes: 1)
        let kept = (try? SaveVault.restore(keep, for: game, container: new, aloneInContainer: true, containers: containers)) ?? "-"
        check(kept.hasPrefix("kept"), "keeping what it has changes nothing: \(kept)")

        print(failures == 0 ? "save vault: all checks passed" : "save vault: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
