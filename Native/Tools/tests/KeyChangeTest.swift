// A change of protection key (0.24.2), in a throwaway home (…/keys/home): what an earlier key
// sealed is opened with it and sealed again with the key in use; what no key here can open
// is set aside, never counted as tampering.
//
// On 3 October the Secure Enclave refused the key it had held since 30 September, after the
// Mac's first restart, and 0.24.1 made a stand-in key — the 64 bytes in Keys/protection.key,
// used as they are. 0.24.2 keeps that file but mixes in this Mac's hardware identity. This
// test makes files the way the stand-in sealed them and checks they are carried over.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/KeyChangeTest.swift -o $TMPDIR/KeyChangeTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/KeyChangeTest 1 <engine folder>   # makes the key
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/KeyChangeTest 2 <engine folder>   # the checks
import Foundation
import CryptoKit

@main struct KeyChangeHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/keys/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        let phase = CommandLine.arguments[1]
        let engineSource = URL(fileURLWithPath: CommandLine.arguments[2])
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default

        guard let key = ProtectionKey.current else { print("FAIL: no key (this Mac's identity unreadable?)"); exit(1) }
        print("key:", key.id, key.isNew ? "new" : "in use since the last start", "· machine:", ProtectionKey.machineID() != nil ? "identity read" : "none")
        if phase == "1" {
            check(key.isNew, "a first start makes a key")
            check(ProtectionKey.machineID() != nil, "this Mac's identity is read")
            print("key change: phase 1 done")
            exit(failures == 0 ? 0 : 1)
        }
        check(!key.isNew, "a second start uses the same key — a restart doesn't change it")

        // The stand-in key of 0.24.1: the same 64 bytes, without this Mac's identity.
        let raw = SymmetricKey(data: try! Data(contentsOf: ProtectionKey.dir.appendingPathComponent("protection.key")))
        let rawID = Data(HMAC<SHA256>.authenticationCode(for: Data("anvil key id".utf8), using: raw)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        check(rawID != key.id, "the key in use isn't the stand-in itself")
        func derived(_ purpose: String) -> SymmetricKey {
            HKDF<SHA512>.deriveKey(inputKeyMaterial: raw, salt: Data("Anvil · Jay Chirag Patel · Santa Clara".utf8),
                                   info: Data(purpose.utf8), outputByteCount: 64)
        }
        func sealOld(_ plain: Data, purpose: String, id: String = rawID) -> Data {
            let aes = derived("encrypt:" + purpose).withUnsafeBytes { SymmetricKey(data: Data($0.prefix(32))) }
            let box = try! AES.GCM.seal(plain, using: aes, authenticating: Data(purpose.utf8))
            var out = Data("ANVV".utf8); out.append(UInt8(id.utf8.count)); out.append(Data(id.utf8)); out.append(box.combined!)
            return out
        }
        func tagOld(_ data: Data, purpose: String) -> String {
            Data(HMAC<SHA512>.authenticationCode(for: data, using: derived("tag:" + purpose))).map { String(format: "%02x", $0) }.joined()
        }

        // 1. The Epic sign-in, sealed by the stand-in.
        try? fm.createDirectory(at: EpicAccount.configDir, withIntermediateDirectories: true)
        let signIn = Data(#"{"refresh_token": "TEST-TOKEN"}"#.utf8)
        try! sealOld(signIn, purpose: "epic-sign-in").write(to: EpicVault.sealed)
        check((try? Vault.open(Data(contentsOf: EpicVault.sealed), purpose: "epic-sign-in")) == signIn, "a sign-in sealed with the stand-in key opens")
        EpicVault.checkAtStart()
        let resealed = (try? Data(contentsOf: EpicVault.sealed)) ?? Data()
        check(Vault.keyID(of: resealed) == key.id, "…and is sealed again with this Mac's key at start")
        check((try? Vault.open(resealed, purpose: "epic-sign-in")) == signIn, "…holding the same sign-in")
        check(EpicAccount.isSignedIn, "still signed in")

        // 2. One sealed with a key nothing here has: set aside, signed out, not deleted.
        try! sealOld(signIn, purpose: "epic-sign-in", id: "0123456789abcdef").write(to: EpicVault.sealed)
        EpicVault.checkAtStart()
        check(!fm.fileExists(atPath: EpicVault.sealed.path) && fm.fileExists(atPath: EpicVault.unreadable.path),
              "a sign-in no key here opens is set aside as user.json.sealed.unreadable")
        check(!EpicAccount.isSignedIn, "…so Epic shows as signed out and asks for a sign-in")
        // Another launcher still signed in (Mythic, on this Mac): its sign-in is brought in.
        try! Data("{}".utf8).write(to: EpicAccount.configDir.appendingPathComponent("installed.json"))
        let mythic = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mythic/Epic")
        try? fm.createDirectory(at: mythic, withIntermediateDirectories: true)
        let mythicSignIn = Data(#"{"refresh_token": "MYTHIC-TEST"}"#.utf8)
        try! mythicSignIn.write(to: mythic.appendingPathComponent("user.json"))
        EpicAccount.shared.importSignInIfNeeded()
        check(EpicAccount.isSignedIn && !fm.fileExists(atPath: EpicVault.plain.path), "Mythic's sign-in is brought in again, and sealed")
        check((try? Vault.open(Data(contentsOf: EpicVault.sealed), purpose: "epic-sign-in")) == mythicSignIn, "…with this Mac's key")
        check(fm.fileExists(atPath: EpicVault.unreadable.path), "the unreadable one stays set aside, not deleted")
        try? fm.removeItem(at: EpicVault.unreadable)

        // 3. A game's offline start, sealed by the stand-in.
        let args = ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=", "-AUTH_TYPE=exchangecode", "-epicapp=Game", "-epicuserid=u1"]
        try! sealOld(try! JSONEncoder().encode(["Game": args]), purpose: "epic-offline-start").write(to: EpicOfflineStart.file)
        check(EpicOfflineStart.arguments(appName: "Game") == args, "an offline start sealed by the stand-in still starts the game")
        check(Vault.keyID(of: (try? Data(contentsOf: EpicOfflineStart.file)) ?? Data()) == key.id, "…and is sealed again with this Mac's key")

        // 4. An engine sealed by the stand-in: checked against that seal, then sealed again.
        let id = "mythic-engine-2.6.1"
        let engine = RuntimeManager.runtimesDir.appendingPathComponent(id)
        try? fm.createDirectory(at: RuntimeManager.runtimesDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: engine)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", engineSource.path, engine.path]; try! p.run(); p.waitUntilExit()
        _ = try! EngineSeal.seal(root: engine, id: id)
        // Re-sign the seal and the list of sealed engines as the stand-in key did.
        let sealURL = EngineSeal.url(for: id)
        var stored = try! JSONSerialization.jsonObject(with: Data(contentsOf: sealURL)) as! [String: Any]
        var manifest = try! JSONSerialization.jsonObject(with: Data(base64Encoded: stored["manifest"] as! String)!) as! [String: Any]
        manifest["keyID"] = rawID
        let body = try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        stored["manifest"] = body.base64EncodedString()
        stored["tag"] = tagOld(body, purpose: "engine-seal:" + id)
        try! JSONSerialization.data(withJSONObject: stored).write(to: sealURL)
        let registryURL = EngineSeal.dir.appendingPathComponent("sealed-engines")
        let registryBody = Data(([id].joined(separator: "\n") + "|" + rawID).utf8)
        try! JSONSerialization.data(withJSONObject: ["ids": [id], "keyID": rawID, "tag": tagOld(registryBody, purpose: "engine-registry")]).write(to: registryURL)

        check(EngineSeal.check(root: engine, id: id, full: false) == .intact, "an engine sealed by the stand-in is intact — a launch isn't refused")
        let after = try! JSONSerialization.jsonObject(with: Data(contentsOf: sealURL)) as! [String: Any]
        let afterManifest = try! JSONSerialization.jsonObject(with: Data(base64Encoded: after["manifest"] as! String)!) as! [String: Any]
        check(afterManifest["keyID"] as? String == key.id, "…and its seal is made again with this Mac's key")
        check(EngineSeal.check(root: engine, id: id, full: true) == .intact, "every file hashed again under the new seal: intact")

        // A changed file is still caught through the stand-in's seal.
        try! JSONSerialization.data(withJSONObject: stored).write(to: sealURL)
        let dll = try! fm.subpathsOfDirectory(atPath: engine.path).first { $0.hasSuffix(".dll") }!
        let target = engine.appendingPathComponent(dll)
        let original = try! Data(contentsOf: target)
        var changed = original; changed[changed.count / 2] ^= 0x01
        try! changed.write(to: target)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed([dll]), "a file changed under the stand-in's seal: still caught")
        try! original.write(to: target)

        // A seal claiming a key nothing here has, with this Mac's key in place: tampering.
        var forged = manifest; forged["keyID"] = "fedcba9876543210"
        let forgedBody = try! JSONSerialization.data(withJSONObject: forged, options: [.sortedKeys])
        stored["manifest"] = forgedBody.base64EncodedString()
        try! JSONSerialization.data(withJSONObject: stored).write(to: sealURL)
        check(EngineSeal.check(root: engine, id: id, full: false) == .changed(["(the seal itself)"]), "a seal from an unknown key: refused as before")

        print(failures == 0 ? "key change: all checks passed" : "key change: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
