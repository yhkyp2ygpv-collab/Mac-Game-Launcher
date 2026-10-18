import Foundation
import CryptoKit

/// The public edition's self-check against the real built app: a copy as shipped passes;
/// an edited, an added and a removed file each fail; a re-copy passes again.
/// Usage: protectiontest <path to the public Anvil.app> <scratch folder>
@main struct ProtectionHarness {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: protectiontest <Anvil.app> <scratch>"); exit(2) }
        let shipped = URL(fileURLWithPath: args[1]), scratch = URL(fileURLWithPath: args[2])
        let fm = FileManager.default
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        func fresh() -> URL {
            let copy = scratch.appendingPathComponent("Anvil.app")
            try? fm.removeItem(at: copy)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = [shipped.path, copy.path]; try! p.run(); p.waitUntilExit()
            return copy
        }
        print("requirement:", AppProtection.requirementText)
        // The ownership file: the digest compiled into Anvil matches the one in the source tree.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Resources/Ownership.txt").standardizedFileURL
        let digest = SHA256.hash(data: try! Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        check(digest == AppProtection.ownershipDigest, "Ownership.txt matches the digest compiled into Anvil")
        check(AppProtection.verifyOwnership(bundle: shipped) == nil, "the built app's ownership file passes")
        check(AppProtection.verify(bundle: shipped) == nil, "the public edition as built passes")
        var app = fresh()
        check(AppProtection.verify(bundle: app) == nil, "a copy of it passes (as from the .dmg)")
        let lib = app.appendingPathComponent("Contents/Resources/libanvil.dylib")
        let h = try! FileHandle(forWritingTo: lib); try! h.seek(toOffset: 4096); try! h.write(contentsOf: Data([0x90])); try! h.close()
        check(AppProtection.verify(bundle: app) != nil, "one byte changed in a library: refused")
        app = fresh()
        try! Data("x".utf8).write(to: app.appendingPathComponent("Contents/Resources/extra.txt"))
        check(AppProtection.verify(bundle: app) != nil, "a file added: refused")
        app = fresh()
        try! fm.removeItem(at: app.appendingPathComponent("Contents/Resources/Legal/License.txt"))
        check(AppProtection.verify(bundle: app) != nil, "the licence removed: refused")
        app = fresh()
        let plist = app.appendingPathComponent("Contents/Info.plist")
        var text = try! String(contentsOf: plist, encoding: .utf8)
        text = text.replacingOccurrences(of: "Jay Chirag Patel", with: "Someone Else")
        try! Data(text.utf8).write(to: plist)
        check(AppProtection.verify(bundle: app) != nil, "the author's name edited: refused")
        // The ownership file, on its own — checked in every edition, signature or not.
        app = fresh()
        let owner = app.appendingPathComponent("Contents/Resources/Ownership.txt")
        var ownerText = try! String(contentsOf: owner, encoding: .utf8)
        ownerText = ownerText.replacingOccurrences(of: "Jay Chirag Patel", with: "Someone Else")
        try! Data(ownerText.utf8).write(to: owner)
        print("ownership edited:", AppProtection.verifyOwnership(bundle: app) ?? "passed")
        check(AppProtection.verifyOwnership(bundle: app) != nil, "the ownership file edited: refused")
        try! Data((ownerText + " ").utf8).write(to: owner)
        check(AppProtection.verifyOwnership(bundle: app) != nil, "a space added to it: refused")
        try! fm.removeItem(at: owner)
        print("ownership removed:", AppProtection.verifyOwnership(bundle: app) ?? "passed")
        check(AppProtection.verifyOwnership(bundle: app) != nil, "the ownership file deleted: refused")
        app = fresh()
        try! fm.moveItem(at: app.appendingPathComponent("Contents/Resources/Ownership.txt"),
                         to: app.appendingPathComponent("Contents/Resources/Legal/Ownership.txt"))
        check(AppProtection.verifyOwnership(bundle: app) != nil, "the ownership file moved: refused")
        let exe = app.appendingPathComponent("Contents/MacOS/Anvil")
        check(fm.fileExists(atPath: exe.path), "nothing was deleted by the check")
        app = fresh()
        check(AppProtection.verify(bundle: app) == nil, "a fresh copy passes again")
        // The tampered copy goes: left behind, it is an app macOS can pick to open anvil://
        // links with — and it refuses to start (9 October: "ownership file is missing").
        try? fm.removeItem(at: scratch.appendingPathComponent("Anvil.app"))
        print(failures == 0 ? "protection: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
