import Foundation
import CryptoKit
import IOKit

/// Anvil's protection key: 512 bits, belonging to this Mac.
///
/// A random 512-bit secret in Anvil's Keys folder, readable only by this user, mixed with
/// this Mac's own hardware identity (HKDF with SHA-512): a copy of Anvil's files on another
/// Mac can't be opened or re-sealed there, and the key survives restarts, macOS updates and
/// password changes.
///
/// From 0.21 to 0.24.0 the key was worked out from a Secure Enclave key instead. That key
/// stopped working at this Mac's first restart after it was made — the Enclave refused it
/// ("unable to compute shared secret") from Anvil and from any other program alike — and
/// the Epic sign-in sealed with it could no longer be opened. The keys used before are kept
/// for opening what they sealed, which is then sealed again with this one.
///
/// Every use gets its own key derived from this one (HKDF-SHA-512), so the key that seals
/// the engines never encrypts anything, and the other way round.
enum ProtectionKey {
    nonisolated static var dir: URL { RuntimeManager.support.appendingPathComponent("Keys", isDirectory: true) }
    private nonisolated static var enclaveFile: URL { dir.appendingPathComponent("protection.enclave") }
    private nonisolated static var plainFile: URL { dir.appendingPathComponent("protection.key") }
    /// The id of the key last in use, so a change of key is known as one.
    private nonisolated static var recordFile: URL { dir.appendingPathComponent("key-id") }

    struct Material {
        let key: SymmetricKey
        /// Names the key without revealing it: which key a seal or a sealed file was made with.
        let id: String
        let inEnclave: Bool
        /// Not the key in use at the last start: there was none (a first start, a new Mac,
        /// Keys removed), or it changed. Only then may seals made with an unknown key be
        /// replaced.
        var isNew = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Material?
    nonisolated(unsafe) private static var earlierCached: [Material]?

    static var current: Material? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard var m = macKey() else { return nil }
        let last = (try? String(contentsOf: recordFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if last != m.id {
            m.isNew = true
            _ = write(Data(m.id.utf8), to: recordFile)
        }
        cached = m
        AnvilLog.write("protection: 512-bit key belonging to this Mac (\(m.id))" + (m.isNew ? (last == nil ? " — new" : " — replaces \(last!)") : ""))
        return m
    }

    /// The keys Anvil used before this one, for opening what they sealed: the same secret
    /// without this Mac's identity (0.24.1, after the Enclave refused its key), and the
    /// Secure Enclave key of 0.21–0.24.0 if the Enclave accepts it again. Looked for only
    /// when something sealed with another key is opened.
    static var earlier: [Material] {
        lock.lock()
        defer { lock.unlock() }
        if let earlierCached { return earlierCached }
        var out: [Material] = []
        if let data = try? Data(contentsOf: plainFile), data.count == 64 {
            out.append(material(from: SymmetricKey(data: data), inEnclave: false))
        }
        if let enclave = enclaveKey() { out.append(enclave) }
        earlierCached = out
        return out
    }

    /// The key with this id: the one in use, or one used before.
    static func material(id: String) -> Material? {
        if let m = current, m.id == id { return m }
        return earlier.first { $0.id == id }
    }

    /// A 512-bit key for one purpose.
    static func key(for purpose: String, using m: Material? = nil) -> SymmetricKey? {
        guard let m = m ?? current else { return nil }
        return HKDF<SHA512>.deriveKey(inputKeyMaterial: m.key, salt: Data("Anvil · Jay Chirag Patel · Santa Clara".utf8),
                                      info: Data(purpose.utf8), outputByteCount: 64)
    }

    private struct EnclaveRecord: Codable {
        var enclaveKey: Data      // the Enclave's wrapped key: usable only by this Mac's chip
        var peer: Data            // a public key to agree with; its private half was discarded
    }

    private static func material(from secret: SymmetricKey, inEnclave: Bool) -> Material {
        let tag = HMAC<SHA256>.authenticationCode(for: Data("anvil key id".utf8), using: secret)
        return Material(key: secret, id: Data(tag).prefix(8).map { String(format: "%02x", $0) }.joined(), inEnclave: inEnclave)
    }

    /// The secret mixed with this Mac's identity.
    private static func bound(_ secret: Data, to machine: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               salt: Data("Anvil protection · \(machine)".utf8),
                               info: Data("this Mac".utf8), outputByteCount: 64)
    }

    /// This Mac's hardware identity: the same on every start, different on every Mac.
    nonisolated static func machineID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let uuid = value as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// The key in use: the secret in the Keys folder (made if there is none) with this Mac's
    /// identity. Without the identity there is no key this run — a key made differently
    /// would leave everything sealed so far unreadable.
    private static func macKey() -> Material? {
        guard let machine = machineID() else {
            AnvilLog.write("protection: this Mac's identity couldn't be read — nothing is sealed or opened this run")
            return nil
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var secret = try? Data(contentsOf: plainFile)
        if secret?.count != 64 {
            if fm.fileExists(atPath: plainFile.path) {
                // Never overwritten: set aside, in case it is needed.
                try? fm.moveItem(at: plainFile, to: dir.appendingPathComponent("protection.key.unreadable-\(Int(Date().timeIntervalSince1970))"))
            }
            var bytes = [UInt8](repeating: 0, count: 64)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
            guard write(Data(bytes), to: plainFile) else { return nil }
            secret = Data(bytes)
        }
        return material(from: bound(secret!, to: machine), inEnclave: false)
    }

    /// The Secure Enclave key of 0.21–0.24.0, if the Enclave still accepts it. Asked three
    /// times: right after a restart the service behind it can be slow to answer.
    private static func enclaveKey() -> Material? {
        guard let data = try? Data(contentsOf: enclaveFile),
              let record = try? JSONDecoder().decode(EnclaveRecord.self, from: data),
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: record.peer) else { return nil }
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            guard SecureEnclave.isAvailable,
                  let enclave = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.enclaveKey),
                  let shared = try? enclave.sharedSecretFromKeyAgreement(with: peer) else { continue }
            let secret = shared.hkdfDerivedSymmetricKey(using: SHA512.self, salt: Data("Anvil protection".utf8),
                                                        sharedInfo: Data(), outputByteCount: 64)
            return material(from: secret, inEnclave: true)
        }
        return nil
    }

    /// Readable only by this user.
    private static func write(_ data: Data, to url: URL) -> Bool {
        if (try? data.write(to: url, options: [.atomic])) == nil {
            guard (try? data.write(to: url)) != nil else { return false }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}

/// Encryption for Anvil's own secrets: AES-256-GCM, with a key from ProtectionKey. Opening
/// a file that was changed by even one bit fails rather than giving back altered contents.
enum Vault {
    enum Failure: LocalizedError {
        case noKey, notSealed, otherKey, damaged
        var errorDescription: String? {
            switch self {
            case .noKey: "Anvil's protection key isn't available."
            case .notSealed: "That isn't a file Anvil sealed."
            case .otherKey: "It was sealed on another Mac, or with a key this Mac no longer has."
            case .damaged: "It has been changed since Anvil sealed it."
            }
        }
    }

    private static let magic = Data("ANVV".utf8)

    /// The 256-bit AES key for one purpose — the first half of its 512-bit derived key.
    private static func aesKey(_ purpose: String, using m: ProtectionKey.Material? = nil) -> SymmetricKey? {
        ProtectionKey.key(for: "encrypt:" + purpose, using: m).map { k in k.withUnsafeBytes { SymmetricKey(data: Data($0.prefix(32))) } }
    }

    /// "ANVV", the key's id, then nonce + ciphertext + tag.
    static func seal(_ plain: Data, purpose: String) throws -> Data {
        guard let key = aesKey(purpose), let id = ProtectionKey.current?.id else { throw Failure.noKey }
        let box = try AES.GCM.seal(plain, using: key, authenticating: Data(purpose.utf8))
        guard let combined = box.combined else { throw Failure.noKey }
        var out = magic
        out.append(UInt8(id.utf8.count))
        out.append(Data(id.utf8))
        out.append(combined)
        return out
    }

    /// The id of the key a sealed file was made with.
    static func keyID(of sealed: Data) -> String? {
        guard sealed.count > 5, sealed.prefix(4) == magic else { return nil }
        let idLength = Int(sealed[sealed.startIndex + 4])
        guard sealed.count > 5 + idLength else { return nil }
        return String(decoding: sealed.dropFirst(5).prefix(idLength), as: UTF8.self)
    }

    static func open(_ sealed: Data, purpose: String) throws -> Data {
        guard sealed.count > 5, sealed.prefix(4) == magic else { throw Failure.notSealed }
        let idLength = Int(sealed[sealed.startIndex + 4])
        guard sealed.count > 5 + idLength else { throw Failure.notSealed }
        let id = String(decoding: sealed.dropFirst(5).prefix(idLength), as: UTF8.self)
        guard ProtectionKey.current != nil else { throw Failure.noKey }
        // The key in use, or one used before: what it sealed is still opened.
        guard let m = ProtectionKey.material(id: id), let key = aesKey(purpose, using: m) else { throw Failure.otherKey }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(5 + idLength))
            return try AES.GCM.open(box, using: key, authenticating: Data(purpose.utf8))
        } catch { throw Failure.damaged }
    }

    /// A 512-bit HMAC-SHA-512 tag, for things that must not change but needn't be secret.
    static func tag(_ data: Data, purpose: String, using m: ProtectionKey.Material? = nil) -> String? {
        guard let key = ProtectionKey.key(for: "tag:" + purpose, using: m) else { return nil }
        return Data(HMAC<SHA512>.authenticationCode(for: data, using: key)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Anvil's Epic sign-in, encrypted on disk.
///
/// legendary keeps the sign-in — the refresh token that stands for the account — in a
/// plain user.json. Anvil keeps it sealed as user.json.sealed instead, and puts the plain
/// file back only while legendary runs, sealing whatever legendary leaves (Epic replaces
/// the token each time it is used) the moment the last run ends.
enum EpicVault {
    nonisolated static var plain: URL { EpicAccount.configDir.appendingPathComponent("user.json") }
    nonisolated static var sealed: URL { EpicAccount.configDir.appendingPathComponent("user.json.sealed") }
    private static let purpose = "epic-sign-in"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var users = 0

    static var hasSignIn: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: plain.path) || fm.fileExists(atPath: sealed.path)
    }

    /// Before legendary runs with Anvil's own configuration.
    static func open() {
        lock.lock()
        defer { lock.unlock() }
        users += 1
        guard users == 1 else { return }
        let fm = FileManager.default
        // A plain file is the newest: just signed in, brought over, or left by a crash.
        guard !fm.fileExists(atPath: plain.path), let data = try? Data(contentsOf: sealed) else { return }
        do {
            let json = try Vault.open(data, purpose: purpose)
            try json.write(to: plain)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plain.path)
        } catch Vault.Failure.damaged {
            AnvilLog.write("epic: the sealed sign-in was changed since it was sealed — discarded; sign in to Epic again")
            try? fm.removeItem(at: sealed)
        } catch Vault.Failure.otherKey {
            setAside()
        } catch {
            AnvilLog.write("epic: the sealed sign-in couldn't be opened (\(error.localizedDescription)) — kept")
        }
    }

    /// Where a sign-in no key on this Mac can open is kept: out of the way, so Anvil shows
    /// Epic as signed out and asks for a sign-in, rather than counting a sign-in it can't use.
    nonisolated static var unreadable: URL { EpicAccount.configDir.appendingPathComponent("user.json.sealed.unreadable") }

    private static func setAside() {
        let fm = FileManager.default
        try? fm.removeItem(at: unreadable)
        try? fm.moveItem(at: sealed, to: unreadable)
        AnvilLog.write("epic: the sealed sign-in was made with a key this Mac can no longer use — set aside as user.json.sealed.unreadable; sign in to Epic again")
    }

    /// At start: a sign-in sealed with a key Anvil used before is sealed again with the key
    /// in use; one no key here can open is set aside, so Epic shows as signed out. One set
    /// aside before comes back if a key for it is found again.
    static func checkAtStart() {
        lock.lock()
        defer { lock.unlock() }
        guard users == 0 else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: sealed.path), !fm.fileExists(atPath: plain.path),
           let old = try? Data(contentsOf: unreadable), (try? Vault.open(old, purpose: purpose)) != nil {
            try? fm.moveItem(at: unreadable, to: sealed)
            AnvilLog.write("epic: the sign-in set aside earlier opens again — back in use")
        }
        guard !fm.fileExists(atPath: plain.path), let data = try? Data(contentsOf: sealed) else { return }
        do {
            let json = try Vault.open(data, purpose: purpose)
            if Vault.keyID(of: data) != ProtectionKey.current?.id {
                let again = try Vault.seal(json, purpose: purpose)
                if (try? again.write(to: sealed, options: .atomic)) == nil { try again.write(to: sealed) }
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sealed.path)
                AnvilLog.write("epic: the sign-in sealed again with this Mac's key")
            }
        } catch Vault.Failure.otherKey {
            setAside()
        } catch {}
    }

    /// After it ends: the sign-in sealed again, the plain file gone.
    static func close() {
        lock.lock()
        defer { lock.unlock() }
        users = max(0, users - 1)
        guard users == 0 else { return }
        sealPlain()
    }

    /// At start: a plain sign-in left by an earlier version, a crash or an import is sealed.
    static func sealLeftover() {
        lock.lock()
        defer { lock.unlock() }
        guard users == 0 else { return }
        sealPlain()
    }

    private static func sealPlain() {
        let fm = FileManager.default
        guard let json = try? Data(contentsOf: plain) else { return }
        do {
            let data = try Vault.seal(json, purpose: purpose)
            if (try? data.write(to: sealed, options: .atomic)) == nil { try data.write(to: sealed) }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sealed.path)
            try fm.removeItem(at: plain)
        } catch {
            // Left as legendary wrote it rather than lost.
            AnvilLog.write("epic: the sign-in couldn't be sealed (\(error.localizedDescription)) — left as it was")
        }
    }

    /// Around one legendary run.
    static func around<T>(_ body: () throws -> T) rethrows -> T {
        open()
        defer { close() }
        return try body()
    }
}
