import Foundation
import CryptoKit

/// A seal on each engine Anvil keeps: the SHA-256 of every file in it, recorded when it is
/// installed and signed with a 512-bit HMAC-SHA-512 key only this Mac has (ProtectionKey).
///
/// An engine is Wine and Apple's D3DMetal — thousands of programs and libraries that run
/// with your account's rights every time a game starts. Encrypting them would protect
/// nothing (Wine has to read them as plain files to run them, so they would sit decrypted
/// on disk all through every game) and would cost a gigabyte of decrypting at every launch.
/// What matters is that nobody and nothing changes them, so that is what the seal catches:
/// - before every launch, a quick look at every file's size and date, with any file that
///   differs hashed again;
/// - at Anvil's start, once a day, every file hashed again in full.
/// A changed, added or removed file — or a seal that wasn't signed with this Mac's key —
/// stops games running on that engine until it is repaired (RuntimeManager.repair), which
/// puts the changed copy in the Trash and installs a clean one.
enum EngineSeal {
    struct Entry: Codable, Equatable {
        var size: Int64
        var modified: Double
        /// SHA-256 of the contents, or "link:<destination>" for a symbolic link.
        var digest: String
    }

    struct Manifest: Codable {
        var id: String
        var keyID: String
        var sealedAt: Date
        var lastFullCheck: Date
        var files: [String: Entry]
    }

    /// The manifest as written, and its tag.
    private struct Stored: Codable {
        var manifest: Data
        var tag: String
    }

    enum Verdict: Equatable {
        case intact
        case notSealed
        /// The protection key changed (a new Mac, a reinstalled macOS): sealed afresh.
        case resealed
        /// Paths, relative to the engine, that differ from the seal.
        case changed([String])
        /// Anvil's protection key isn't available this run, so the seal can't be read.
        case unverified
    }

    nonisolated static var dir: URL { RuntimeManager.support.appendingPathComponent("Seals", isDirectory: true) }
    nonisolated static func url(for id: String) -> URL { dir.appendingPathComponent(id + ".seal") }

    // MARK: Reading an engine

    private struct Found {
        var url: URL
        var size: Int64
        var modified: Double
        var link: String?
    }

    /// Every file and link under `root`, by its path relative to it. fts walks the tree
    /// and hands back each entry's lstat as it goes — about 15 ms for an engine's 4,656
    /// files, where FileManager's enumerator took 70 to 120 — and a link is recorded as a
    /// link (to where it points), never followed out of the engine.
    private static func scan(_ root: URL) -> [String: Found] {
        let base = root.path
        guard let cRoot = strdup(base) else { return [:] }
        defer { free(cRoot) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return [:] }
        defer { fts_close(fts) }
        var found: [String: Found] = [:]
        found.reserveCapacity(5_000)
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_SL || info == FTS_SLNONE,
                  let cPath = entry.pointee.fts_path else { continue }
            let path = String(cString: cPath)
            guard path.count > base.count + 1, !path.hasSuffix("/.DS_Store") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            let url = root.appendingPathComponent(relative)
            if info == FTS_F, let st = entry.pointee.fts_statp?.pointee {
                let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                found[relative] = Found(url: url, size: Int64(st.st_size), modified: modified, link: nil)
            } else {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(cPath, &buffer, Int(PATH_MAX))
                let target = n >= 0 ? String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self) : "?"
                found[relative] = Found(url: url, size: 0, modified: 0, link: target)
            }
        }
        return found
    }

    nonisolated static func sha256(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash many files across every core.
    private static func digests(_ files: [(String, Found)]) -> [String: String] {
        var out: [String: String] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let (path, f) = files[i]
            let d = f.link.map { "link:" + $0 } ?? sha256(of: f.url)
            lock.lock(); out[path] = d; lock.unlock()
        }
        return out
    }

    // MARK: Sealing

    /// Record every file in `root` and sign the record. Returns the number of files.
    @discardableResult
    static func seal(root: URL, id: String) throws -> Int {
        guard let keyID = ProtectionKey.current?.id else { throw Vault.Failure.noKey }
        let found = scan(root)
        let hashes = digests(Array(found))
        var files: [String: Entry] = [:]
        for (path, f) in found { files[path] = Entry(size: f.size, modified: f.modified, digest: hashes[path] ?? "") }
        let now = Date()
        try write(Manifest(id: id, keyID: keyID, sealedAt: now, lastFullCheck: now, files: files))
        var sealed = registry().ids
        sealed.insert(id)
        writeRegistry(sealed)
        return files.count
    }

    // MARK: The list of sealed engines

    /// Which engines have been sealed, itself signed — so deleting an engine's seal reads
    /// as tampering, not as an engine that was never sealed.
    private static var registryURL: URL { dir.appendingPathComponent("sealed-engines") }

    private struct Registry: Codable { var ids: [String]; var keyID: String; var tag: String }

    /// The engines listed, and whether the list itself could be trusted.
    private static func registry() -> (ids: Set<String>, trusted: Bool) {
        guard let data = try? Data(contentsOf: registryURL),
              let r = try? JSONDecoder().decode(Registry.self, from: data) else { return ([], false) }
        let body = Data((r.ids.sorted().joined(separator: "\n") + "|" + r.keyID).utf8)
        guard let m = ProtectionKey.material(id: r.keyID), let expected = Vault.tag(body, purpose: "engine-registry", using: m),
              constantTimeEqual(expected, r.tag) else { return ([], false) }
        return (Set(r.ids), true)
    }

    private static func writeRegistry(_ ids: Set<String>) {
        guard let keyID = ProtectionKey.current?.id else { return }
        let sorted = ids.sorted()
        let body = Data((sorted.joined(separator: "\n") + "|" + keyID).utf8)
        guard let tag = Vault.tag(body, purpose: "engine-registry"),
              let data = try? JSONEncoder().encode(Registry(ids: sorted, keyID: keyID, tag: tag)) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? data.write(to: registryURL, options: .atomic)) == nil { try? data.write(to: registryURL) }
    }

    /// Whether an engine with no seal may be sealed as it is: a new engine, or a new key.
    /// Not when the list says it was sealed, or the list has gone or been changed while
    /// this Mac's key stayed the same.
    private static func mayTrustOnFirstUse(_ id: String) -> Bool {
        if ProtectionKey.current?.isNew == true { return true }
        let r = registry()
        if !r.trusted { return !FileManager.default.fileExists(atPath: registryURL.path) && !anySealExists() }
        return !r.ids.contains(id)
    }

    private static func anySealExists() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".seal") }
    }

    private static func write(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let body = try encoder.encode(manifest)
        guard let tag = Vault.tag(body, purpose: "engine-seal:" + manifest.id) else { throw Vault.Failure.noKey }
        let data = try JSONEncoder().encode(Stored(manifest: body, tag: tag))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? data.write(to: url(for: manifest.id), options: .atomic)) == nil { try data.write(to: url(for: manifest.id)) }
    }

    /// `earlierKey`: sealed with a key Anvil used before this one, and read with it.
    private enum Read { case missing, otherKey, forged, ok(Manifest, earlierKey: Bool) }

    private static func read(_ id: String) -> Read {
        guard let data = try? Data(contentsOf: url(for: id)) else { return .missing }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .forged }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let manifest = try? decoder.decode(Manifest.self, from: stored.manifest), manifest.id == id else { return .forged }
        guard let m = ProtectionKey.material(id: manifest.keyID) else { return .otherKey }
        guard let expected = Vault.tag(stored.manifest, purpose: "engine-seal:" + id, using: m),
              constantTimeEqual(expected, stored.tag) else { return .forged }
        return .ok(manifest, earlierKey: m.id != ProtectionKey.current?.id)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    static func isSealed(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }

    // MARK: Checking

    /// Compare an engine with its seal. `full` hashes every file; otherwise only files
    /// whose size or date changed are hashed.
    static func check(root: URL, id: String, full: Bool) -> Verdict {
        // Without the key no seal can be read: unverified, never "changed".
        guard ProtectionKey.current != nil else { return .unverified }
        var manifest: Manifest
        var earlierKey = false
        switch read(id) {
        case .missing:
            return mayTrustOnFirstUse(id) ? .notSealed : .changed(["(the seal is missing)"])
        case .forged: return .changed(["(the seal itself)"])
        case .otherKey:
            // A seal from another key is accepted only when this Mac's key was just made — a
            // Mac restored from a backup has a new Secure Enclave key. A seal that merely
            // claims another key, with this Mac's key long in place, was tampered with.
            guard ProtectionKey.current?.isNew == true else { return .changed(["(the seal itself)"]) }
            _ = try? seal(root: root, id: id)
            AnvilLog.write("engines: \(id) sealed again — this Mac's protection key is new")
            return .resealed
        case .ok(let m, let earlier): manifest = m; earlierKey = earlier
        }
        let found = scan(root)
        var changed = Set(manifest.files.keys).symmetricDifference(found.keys)
        let common = found.filter { manifest.files[$0.key] != nil }
        let toHash = full ? Array(common)
            : common.filter { manifest.files[$0.key]!.size != $0.value.size || manifest.files[$0.key]!.modified != $0.value.modified }
        let hashes = digests(Array(toHash))
        var refreshed = false
        for (path, digest) in hashes {
            guard var entry = manifest.files[path] else { continue }
            if entry.digest != digest {
                changed.insert(path)
            } else if let f = found[path], entry.size != f.size || entry.modified != f.modified {
                // Same contents, a new date (a copy, a touch): recorded so it isn't hashed every time.
                entry.modified = f.modified
                manifest.files[path] = entry
                refreshed = true
            }
        }
        if !changed.isEmpty { return .changed(changed.sorted()) }
        if full { manifest.lastFullCheck = Date(); refreshed = true }
        // Read with a key Anvil used before, and every file as it was: sealed again with
        // the key in use, so the earlier one is never needed for it again.
        if earlierKey, let keyID = ProtectionKey.current?.id {
            manifest.keyID = keyID
            refreshed = true
            let listed = registry()
            if listed.trusted { writeRegistry(listed.ids.union([id])) }
            AnvilLog.write("engines: \(id) checked against its seal from Anvil's earlier key and sealed again with this Mac's key")
        }
        if refreshed { try? write(manifest) }
        return .intact
    }

    /// When the last full check was.
    static func lastFullCheck(_ id: String) -> Date? {
        if case .ok(let m, _) = read(id) { return m.lastFullCheck }
        return nil
    }

    // MARK: Anvil's engines

    /// Seal every engine Anvil keeps that has no seal yet — engines installed before seals
    /// existed are sealed as they are — and check each fully once a day. Off the main thread.
    static func sweep(_ runtimes: [Runtime]) async -> [String: Verdict] {
        await Task.detached(priority: .utility) {
            var verdicts: [String: Verdict] = [:]
            for r in runtimes where r.isManaged {
                // Reading every file of an engine competes with a game loading its own; the
                // full check waits for a start with nothing running. Each launch still
                // checks its engine's files before the game starts.
                let idle = await MainActor.run { Launcher.shared.isIdle }
                let due = idle && (lastFullCheck(r.id).map { Date().timeIntervalSince($0) > 86_400 } ?? true)
                var v = check(root: r.root, id: r.id, full: due)
                if v == .notSealed {
                    let n = (try? seal(root: r.root, id: r.id)) ?? 0
                    AnvilLog.write("engines: \(r.displayName) sealed — \(n) files, SHA-256 each, signed with this Mac's key")
                    v = .intact
                }
                verdicts[r.id] = v
                if case .changed(let files) = v {
                    AnvilLog.write("engines: \(r.displayName) has \(files.count) changed file(s) since it was sealed: \(files.prefix(5).joined(separator: ", "))")
                } else if due {
                    AnvilLog.write("engines: \(r.displayName) checked in full — every file as sealed")
                }
            }
            return verdicts
        }.value
    }
}
