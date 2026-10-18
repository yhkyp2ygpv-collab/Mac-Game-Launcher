import Foundation

/// The protection key, AES-256 encryption, the encrypted Epic sign-in and the engine seal,
/// in a throwaway home (CFFIXED_USER_HOME …/vault/home). The engine seal runs on an APFS
/// clone of a real engine, given as the first argument; nothing of the real one is touched.
@main struct VaultHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/vault/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        guard CommandLine.arguments.count == 2 else { print("usage: vaulttest <engine folder to clone>"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        func clock<T>(_ work: () throws -> T) rethrows -> (T, Double) {
            let t = Date(); let r = try work(); return (r, Date().timeIntervalSince(t))
        }

        // MARK: Key
        guard let key = ProtectionKey.current else { print("FAIL: no key"); exit(1) }
        print("key:", key.id, key.inEnclave ? "(Secure Enclave)" : "(Keys folder — no Secure Enclave in this sandbox)", key.isNew ? "new" : "existing")
        check(ProtectionKey.key(for: "a").map { $0.bitCount } == 512, "512-bit keys")
        check(ProtectionKey.key(for: "a") != ProtectionKey.key(for: "b"), "each use gets its own key")
        if !key.inEnclave {
            let file = ProtectionKey.dir.appendingPathComponent("protection.key")
            let perms = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check(perms == 0o600, "the key file is readable only by this user")
        }

        // MARK: Vault
        let secret = Data(#"{"refresh_token": "SECRET-REFRESH-TOKEN-123", "displayName": "Jay"}"#.utf8)
        let sealed = try! Vault.seal(secret, purpose: "test")
        check(sealed.range(of: Data("SECRET".utf8)) == nil, "the encrypted file doesn't contain the secret")
        check((try? Vault.open(sealed, purpose: "test")) == secret, "and opens back to exactly what went in")
        var flipped = sealed; flipped[flipped.count - 20] ^= 0x01
        check((try? Vault.open(flipped, purpose: "test")) == nil, "one bit changed: refused, not opened wrong")
        check((try? Vault.open(sealed, purpose: "other")) == nil, "sealed for one use can't be opened as another")
        var foreign = sealed; foreign[6] ^= 0x01   // the key id
        do {
            _ = try Vault.open(foreign, purpose: "test")
            failures += 1; print("FAIL: a file from another key opened")
        } catch Vault.Failure.otherKey {
            print("ok: a file from another key is recognised as such")
        } catch { failures += 1; print("FAIL: unexpected \(error)") }

        // MARK: Epic sign-in
        try? fm.createDirectory(at: EpicAccount.configDir, withIntermediateDirectories: true)
        try! secret.write(to: EpicVault.plain)
        EpicVault.sealLeftover()
        check(!fm.fileExists(atPath: EpicVault.plain.path), "the plain sign-in is gone after sealing")
        let onDisk = (try? Data(contentsOf: EpicVault.sealed)) ?? Data()
        check(!onDisk.isEmpty && onDisk.range(of: Data("SECRET".utf8)) == nil, "the sign-in on disk is encrypted")
        check(EpicAccount.isSignedIn, "Anvil still counts as signed in")
        EpicVault.open()
        check((try? Data(contentsOf: EpicVault.plain)) == secret, "legendary sees the plain sign-in while it runs")
        EpicVault.open()                                   // a second run at the same time
        EpicVault.close()
        check(fm.fileExists(atPath: EpicVault.plain.path), "still there while the other run goes on")
        // legendary replaces the token, as Epic does on every use.
        let rotated = Data(#"{"refresh_token": "SECRET-NEW-TOKEN-456"}"#.utf8)
        try! rotated.write(to: EpicVault.plain)
        EpicVault.close()
        check(!fm.fileExists(atPath: EpicVault.plain.path), "sealed again when the last run ends")
        EpicVault.open()
        check((try? Data(contentsOf: EpicVault.plain)) == rotated, "and the new token is the one kept")
        EpicVault.close()
        let tampered = RuntimeManager.support.appendingPathComponent("t")
        var t = try! Data(contentsOf: EpicVault.sealed); t[t.count - 5] ^= 0x10; try! t.write(to: EpicVault.sealed)
        EpicVault.open()
        check(!fm.fileExists(atPath: EpicVault.plain.path) && !EpicAccount.isSignedIn, "a tampered sign-in is discarded: sign in again, nothing leaks")
        EpicVault.close()
        _ = tampered

        // MARK: Engine seal
        let engine = RuntimeManager.runtimesDir.appendingPathComponent("mythic-engine-2.6.1")
        try? fm.createDirectory(at: RuntimeManager.runtimesDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: engine)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", CommandLine.arguments[1], engine.path]; try! p.run(); p.waitUntilExit()
        let id = "mythic-engine-2.6.1"
        let (count, sealTime) = try! clock { try EngineSeal.seal(root: engine, id: id) }
        print(String(format: "sealed %d files in %.2f s", count, sealTime))
        check(count > 1000, "every file of the engine recorded")
        let (quick, quickTime) = clock { EngineSeal.check(root: engine, id: id, full: false) }
        print(String(format: "quick check before a launch: %.0f ms", quickTime * 1000))
        check(quick == .intact && quickTime < 1.0, "intact, and the check before a launch is quick")
        let (full, fullTime) = clock { EngineSeal.check(root: engine, id: id, full: true) }
        print(String(format: "full check: %.2f s", fullTime))
        check(full == .intact, "every file hashed again: intact")

        let dylib = try! fm.subpathsOfDirectory(atPath: engine.path).first { $0.hasSuffix(".dll") && $0.contains("x86_64-windows") }
            ?? fm.subpathsOfDirectory(atPath: engine.path).first { $0.hasSuffix(".dll") }!
        let target = engine.appendingPathComponent(dylib)
        let originalDate = try! fm.attributesOfItem(atPath: target.path)[.modificationDate] as! Date
        let original = try! Data(contentsOf: target)
        var changed = original; changed[changed.count / 2] ^= 0x01
        try! changed.write(to: target)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed([dylib]), "one byte changed in \(URL(fileURLWithPath: dylib).lastPathComponent): caught before launch")
        try! fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: target.path)
        check(EngineSeal.check(root: engine, id: id, full: false) == .intact, "with its date put back, the quick check alone can't tell…")
        check(EngineSeal.check(root: engine, id: id, full: true) == .changed([dylib]), "…and the daily full check catches it")
        try! original.write(to: target)
        try! fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        check(EngineSeal.check(root: engine, id: id, full: false) == .intact, "same contents with a new date: still intact")

        let added = engine.appendingPathComponent("lib/extra.dylib")
        try! Data("x".utf8).write(to: added)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed(["lib/extra.dylib"]), "a file added: caught")
        try! fm.removeItem(at: added)
        let removedPath = try! fm.subpathsOfDirectory(atPath: engine.path).first { $0.hasSuffix(".dll") && $0 != dylib }!
        let removed = engine.appendingPathComponent(removedPath)
        let keep = try! Data(contentsOf: removed)
        try! fm.removeItem(at: removed)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed([removedPath]), "a file removed: caught")
        try! keep.write(to: removed)

        // The seal itself.
        let sealURL = EngineSeal.url(for: id)
        let goodSeal = try! Data(contentsOf: sealURL)
        var text = String(decoding: goodSeal, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"tag\":\"", with: "\"tag\":\"0")
        try! Data(text.utf8).write(to: sealURL)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed(["(the seal itself)"]), "a seal edited by hand: refused")
        try! goodSeal.write(to: sealURL)

        // Changing a file and re-writing the seal without the key.
        var stored = try! JSONSerialization.jsonObject(with: goodSeal) as! [String: Any]
        let manifestData = Data(base64Encoded: stored["manifest"] as! String)!
        var manifest = try! JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        var files = manifest["files"] as! [String: Any]
        var entry = files[dylib] as! [String: Any]
        entry["digest"] = String(repeating: "0", count: 64)
        files[dylib] = entry; manifest["files"] = files
        stored["manifest"] = try! JSONSerialization.data(withJSONObject: manifest).base64EncodedString()
        try! JSONSerialization.data(withJSONObject: stored).write(to: sealURL)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed(["(the seal itself)"]), "a seal re-written without this Mac's key: refused")
        manifest["keyID"] = "0000000000000000"
        stored["manifest"] = try! JSONSerialization.data(withJSONObject: manifest).base64EncodedString()
        try! JSONSerialization.data(withJSONObject: stored).write(to: sealURL)
        if key.isNew {
            // A key made during this run is the case of a Mac restored from a backup.
            check(EngineSeal.check(root: engine, id: id, full: false) == .resealed, "with a brand-new key, a seal from another key is replaced (run again for the other case)")
        } else {
            check(EngineSeal.check(root: engine, id: id, full: false) == .changed(["(the seal itself)"]), "a seal claiming another key, with this Mac's key in place: refused")
        }
        try! goodSeal.write(to: sealURL)
        check(EngineSeal.check(root: engine, id: id, full: true) == .intact, "the real seal still holds")
        if !key.isNew {
            // Deleting the seal doesn't get a changed engine accepted as new.
            try! fm.removeItem(at: sealURL)
            check(EngineSeal.check(root: engine, id: id, full: false) == .changed(["(the seal is missing)"]), "the seal deleted: refused, not sealed afresh")
            let registry = EngineSeal.dir.appendingPathComponent("sealed-engines")
            let keepRegistry = try! Data(contentsOf: registry)
            try! fm.removeItem(at: registry)
            check(EngineSeal.check(root: engine, id: id, full: false) != .notSealed, "the seal and the list of sealed engines both deleted: still refused")
            try! keepRegistry.write(to: registry)
            try! goodSeal.write(to: sealURL)
            check(EngineSeal.check(root: engine, id: id, full: false) == .intact, "put back: intact")
        }

        // A launch on a changed engine is refused before Wine is touched.
        RuntimeManager.shared.discover()
        guard let runtime = RuntimeManager.shared.runtime(id: id) else { print("FAIL: engine not found"); exit(1) }
        var c = Container(name: "Test", runtimeID: id)
        c.storefront = nil
        Library.shared.containers.append(c)
        let exe = RuntimeManager.support.appendingPathComponent("game/Game.exe")
        try? fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(repeating: 1, count: 100).write(to: exe)
        let game = Library.shared.addGame(title: "Test Game", executable: exe, container: c)
        try! changed.write(to: target)
        do {
            _ = try await Launcher.shared.prepareAndLaunch(game: game, container: c, runtime: runtime)
            failures += 1; print("FAIL: a changed engine was launched")
        } catch {
            print("launch refused:", error.localizedDescription)
            check(error.localizedDescription.contains("Repair"), "a game on a changed engine doesn't start, and says how to fix it")
        }
        check(RuntimeManager.shared.sealProblems[id] == [dylib], "the engine page knows which file")
        try! original.write(to: target)

        // Game Mode's copy of the engine: sealed when made, rebuilt if changed.
        _ = try? EngineSeal.check(root: engine, id: id, full: true)
        if let copy = try? GameModeEngine.prepared(for: runtime) {
            let sealID = EngineSeal.isSealed("gamemode-mythic-engine-2.6.1")
            check(sealID, "the Game Mode copy is sealed when it's made")
            let inCopy = copy.root.appendingPathComponent(dylib.replacingOccurrences(of: "bin/", with: "MacOS/"))
            try? changed.write(to: inCopy)
            _ = try? GameModeEngine.prepared(for: runtime)
            check((try? Data(contentsOf: inCopy)) == original, "a changed Game Mode copy is rebuilt clean")
        } else {
            print("skipped: the Game Mode copy couldn't be made here")
        }

        print(failures == 0 ? "vault: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
