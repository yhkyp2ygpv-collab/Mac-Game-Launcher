import Foundation
import CryptoKit

/// File integrity for game installs and saves.
///
/// Anvil records a baseline when you ask it to, then tells you what changed since.
/// It cannot verify a game against the publisher's own hashes — it has no access to
/// them — so what it detects is drift from a known-good state you captured: a
/// half-finished copy, a failed update, disk corruption, or a mod you forgot about.
@MainActor
final class IntegrityChecker: ObservableObject {

    struct Manifest: Codable, Sendable {
        var gameID: UUID
        var title: String
        var root: String
        var createdAt: Date
        var fileCount: Int
        var totalBytes: Int64
        /// Path relative to root → SHA-256. Only for files worth hashing; see `hashLimit`.
        var hashes: [String: String]
        /// Files recorded by size alone, because hashing them all would take hours.
        var sizes: [String: Int64]
    }

    /// How far short of its expected size an install is, as a percentage, or nil
    /// when it is complete.
    nonisolated static func shortfall(installPath: String, expectedBytes: Int64) -> Int? {
        let r = quickCheck(installPath: installPath, expectedBytes: expectedBytes)
        guard !r.ok else { return nil }
        return Int((1.0 - Double(r.actual) / Double(max(expectedBytes, 1))) * 100)
    }

    struct Report: Sendable {
        var missing: [String] = []
        var modified: [String] = []
        var added: [String] = []
        var unreadable: [String] = []
        var checked: Int = 0

        var isClean: Bool { missing.isEmpty && modified.isEmpty && unreadable.isEmpty }
        var summary: String {
            if isClean {
                return added.isEmpty
                    ? "All \(checked) files match the baseline."
                    : "\(checked) files match. \(added.count) new file\(added.count == 1 ? "" : "s") since — usually a mod, a save, or a patch."
            }
            var parts: [String] = []
            if !missing.isEmpty { parts.append("\(missing.count) missing") }
            if !modified.isEmpty { parts.append("\(modified.count) changed") }
            if !unreadable.isEmpty { parts.append("\(unreadable.count) unreadable") }
            return parts.joined(separator: ", ") + " out of \(checked)."
        }
    }

    @Published var progress: Double = 0
    @Published var status: String?
    @Published var busy = false

    static let shared = IntegrityChecker()
    private let fm = FileManager.default
    private init() {}

    nonisolated static var directory: URL {
        RuntimeManager.support.appendingPathComponent("Integrity", isDirectory: true)
    }

    private func manifestURL(for game: Game) -> URL {
        Self.directory.appendingPathComponent("\(game.id.uuidString).json")
    }

    func hasBaseline(for game: Game) -> Bool {
        fm.fileExists(atPath: manifestURL(for: game).path)
    }

    func manifest(for game: Game) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: game)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Files above this size are recorded by size and modification date rather than
    /// hashed. A 76 GB install would otherwise take the better part of an hour to
    /// checksum, and the large files are overwhelmingly packed assets that a partial
    /// download truncates — which a size check already catches.
    private static let hashLimit: Int64 = 64 * 1024 * 1024

    // MARK: Baseline

    func recordBaseline(for game: Game) async throws -> Manifest {
        busy = true; progress = 0
        defer { busy = false; progress = 0 }

        let root = URL(fileURLWithPath: game.executablePath).deletingLastPathComponent()
        status = "Reading \(game.title)…"

        let limit = Self.hashLimit
        let scan = await Task.detached(priority: .utility) { () -> (
            [String: String], [String: Int64], Int64, Int) in
            let files = Self.walk(root)
            var hashes: [String: String] = [:]
            var sizes: [String: Int64] = [:]
            var total: Int64 = 0
            for file in files {
                let rel = Self.relative(file, to: root)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init) ?? 0
                total += size
                if size <= limit, let digest = try? Self.sha256(of: file) {
                    hashes[rel] = digest
                } else {
                    sizes[rel] = size
                }
            }
            return (hashes, sizes, total, files.count)
        }.value
        let (hashes, sizes, total, fileCount) = scan

        let manifest = Manifest(gameID: game.id, title: game.title, root: root.path,
                                createdAt: Date(), fileCount: fileCount,
                                totalBytes: total, hashes: hashes, sizes: sizes)
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(for: game), options: .atomic)

        status = "Baseline recorded: \(fileCount) files, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))."
        return manifest
    }

    // MARK: Verify

    func verify(_ game: Game) async throws -> Report {
        guard let manifest = manifest(for: game) else { throw IntegrityError.noBaseline }
        busy = true; progress = 0
        defer { busy = false; progress = 0 }

        let root = URL(fileURLWithPath: manifest.root)
        status = "Verifying \(game.title)…"

        let report = await Task.detached(priority: .utility) { () -> Report in
            var r = Report()
            var present = Set<String>()
            for file in Self.walk(root) {
                let rel = Self.relative(file, to: root)
                present.insert(rel)

                if let expected = manifest.hashes[rel] {
                    r.checked += 1
                    guard let digest = try? Self.sha256(of: file) else {
                        r.unreadable.append(rel); continue
                    }
                    if digest != expected { r.modified.append(rel) }
                } else if let expectedSize = manifest.sizes[rel] {
                    r.checked += 1
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init) ?? -1
                    if size != expectedSize { r.modified.append(rel) }
                } else {
                    r.added.append(rel)
                }
            }
            for known in manifest.hashes.keys where !present.contains(known) {
                r.missing.append(known)
            }
            for known in manifest.sizes.keys where !present.contains(known) {
                r.missing.append(known)
            }
            return r
        }.value

        status = report.summary
        return report
    }

    /// A size-only check against what the source launcher recorded at install time.
    /// Fast, and catches the common case of an interrupted download.
    nonisolated static func quickCheck(installPath: String, expectedBytes: Int64) -> (actual: Int64, ok: Bool) {
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: installPath),
                                      includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in walker {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        // Only a shortfall means trouble. Extra bytes are saves, configs, shader
        // caches or mods accumulating after install, and flagging those as damage
        // would cry wolf on every healthy game. A real shortfall is an interrupted
        // or abandoned download, which is exactly what this is for.
        let ratio = Double(total) / Double(max(expectedBytes, 1))
        return (total, ratio > 0.97)
    }

    // MARK: Helpers

    /// Walking and hashing a 76 GB install is minutes of I/O, so it runs off the
    /// main actor. Doing it inline would freeze the window for the duration.
    nonisolated private static func walk(_ root: URL) -> [URL] {
        var files: [URL] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files.append(url)
        }
        return files
    }

    nonisolated private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// Streamed so a large file never lands in memory whole.
    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum IntegrityError: LocalizedError {
        case noBaseline
        var errorDescription: String? {
            "No baseline recorded for this game yet. Record one while it's known-good, then Anvil can tell you what changed."
        }
    }
}
