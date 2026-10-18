import Foundation
import CryptoKit

/// Reads the published Mythic Engine update stream and installs engines into Anvil's
/// own runtime store.
///
/// Two rules hold here, and they are the reason this is a separate type rather than
/// something bolted onto the runtime picker:
///
/// 1. **Nothing Mythic owns is ever written to.** Anvil reads the public catalog and
///    unpacks into `~/Library/Application Support/Anvil/Runtimes`. A Mythic install
///    on the same Mac keeps whatever engine it had, and Mythic keeps updating it on
///    its own schedule.
/// 2. **A new engine never replaces the old one.** Each version lands in its own
///    directory and containers keep pointing at whatever they were built against, so
///    a regression is a one-click change back rather than a reinstall — and a save or
///    a prefix is never in the blast radius of an engine update.
@MainActor
final class EngineCatalog: ObservableObject {

    struct Release: Identifiable, Hashable {
        var id: String { "\(channel)-\(version)" }
        let channel: String              // "stable" | "preview"
        let version: String              // engine version, e.g. "3.0.0"
        let gptkVersion: String?         // the D3DMetal generation inside it
        let releaseDate: Date
        let downloadURL: URL
        let checksumURL: URL?
        let sizeBytes: Int?
        let minimumMacOS: String?
        let critical: Bool

        var runtimeID: String { "mythic-engine-\(version)" }

        /// What the user is actually choosing between. The engine version is a
        /// packaging number; the GPTK version is the one that changes how games run.
        var headline: String {
            gptkVersion.map { "Engine \(version) · D3DMetal \($0)" } ?? "Engine \(version)"
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case downloading(Double)      // 0…1
        case verifying
        case installing
        case failed(String)
        /// No connection: the list is the kept copy, and installing waits.
        case offline
    }

    @Published private(set) var releases: [Release] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// The list shown is the copy kept from the last check, not a fresh one.
    @Published private(set) var fromCache = false

    static let shared = EngineCatalog()
    private init() {
        // The last catalogue fetched, so the list is there offline and before a check.
        if let copy = DiskCache.cached(Self.cacheName), let parsed = try? Self.parse(copy.data) {
            releases = parsed
            lastChecked = copy.fetchedAt == .distantPast ? nil : copy.fetchedAt
            fromCache = true
        }
    }

    private static let catalogURL = URL(string: "https://dl.getmythic.app/engine/EngineUpdateStream.plist")!
    private static let cacheName = "EngineUpdateStream.plist"

    // MARK: Catalog

    func check() async {
        state = .checking
        do {
            let result = try await DiskCache.fetch(Self.catalogURL, name: Self.cacheName)
            releases = try Self.parse(result.data)
            lastChecked = result.fetchedAt
            fromCache = result.fromCache
            state = result.fromCache && !Connectivity.isOnlineNow ? .offline : .idle
        } catch DiskCache.CacheError.offlineAndNotCached {
            state = .offline
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) throws -> [Release] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let channels = root["channels"] as? [[String: Any]] else { throw CatalogError.malformed }

        var out: [Release] = []
        for channel in channels {
            let name = channel["name"] as? String ?? "stable"
            for entry in (channel["releases"] as? [[String: Any]]) ?? [] {
                guard let version = entry["version"] as? String,
                      let urlString = entry["downloadURL"] as? String,
                      // The catalog publishes plain http. Anvil upgrades it: an engine
                      // is executable code, and fetching it over a channel anyone on
                      // the path can rewrite is not acceptable for that.
                      let url = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
                else { continue }
                out.append(Release(
                    channel: name,
                    version: version,
                    gptkVersion: entry["targetGPTKVersion"] as? String,
                    releaseDate: entry["releaseDate"] as? Date ?? .distantPast,
                    downloadURL: url,
                    checksumURL: (entry["checksumURL"] as? String)
                        .flatMap { URL(string: $0.replacingOccurrences(of: "http://", with: "https://")) },
                    sizeBytes: entry["size"] as? Int,
                    minimumMacOS: entry["minimumMacOSVersion"] as? String,
                    critical: entry["critical"] as? Bool ?? false))
            }
        }
        return out.sorted { $0.releaseDate > $1.releaseDate }
    }

    /// Releases this Mac can actually run, newest first.
    func available(includePreview: Bool) -> [Release] {
        releases.filter { includePreview || $0.channel == "stable" }
                .filter { Self.macOSMeets($0.minimumMacOS) }
    }

    private static func macOSMeets(_ minimum: String?) -> Bool {
        guard let minimum else { return true }
        let want = minimum.split(separator: "-").first.map(String.init) ?? minimum
        let parts = want.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.majorVersion != major { return v.majorVersion > major }
        return v.minorVersion >= (parts.count > 1 ? parts[1] : 0)
    }

    // MARK: Install

    /// Download, verify, and unpack into Anvil's runtime store. Returns the installed
    /// runtime. Never touches an existing install, including Anvil's own: a version
    /// already present is returned as-is.
    @discardableResult
    func install(_ release: Release) async throws -> Runtime {
        let dest = RuntimeManager.runtimesDir.appendingPathComponent(release.runtimeID, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.appendingPathComponent("bin/wine64").path) {
            RuntimeManager.shared.discover()
            if let existing = RuntimeManager.shared.runtime(id: release.runtimeID) { return existing }
        }

        guard Connectivity.isOnlineNow else { throw CatalogError.offline }
        state = .downloading(0)
        let archive = try await download(release)
        defer { try? FileManager.default.removeItem(at: archive) }

        if let checksumURL = release.checksumURL {
            state = .verifying
            try await verify(archive, against: checksumURL)
        }

        state = .installing
        // Unpack to a staging directory first. A failed extraction then leaves
        // nothing behind that looks like a working runtime.
        let staging = RuntimeManager.runtimesDir
            .appendingPathComponent(".staging-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", archive.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw CatalogError.extractionFailed
        }

        // The archive contains an Engine layout (wine/, DXVK/), not a bare wine tree.
        let wineRoot = try Self.locateWineRoot(in: staging)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: wineRoot, to: dest)

        // Keep the DXVK that shipped alongside, if there was one.
        let dxvk = wineRoot.deletingLastPathComponent().appendingPathComponent("DXVK")
        if FileManager.default.fileExists(atPath: dxvk.path) {
            try? FileManager.default.moveItem(
                at: dxvk,
                to: RuntimeManager.runtimesDir.appendingPathComponent(release.runtimeID + "-dxvk"))
        }
        try? FileManager.default.removeItem(at: staging)

        RuntimeManager.shared.discover()
        guard let installed = RuntimeManager.shared.runtime(id: release.runtimeID) else {
            state = .idle
            throw CatalogError.notUsable
        }
        // Sealed straight from the download, before anything can run from it.
        let root = installed.root, id = installed.id
        let files = await Task.detached(priority: .userInitiated) { (try? EngineSeal.seal(root: root, id: id)) ?? 0 }.value
        AnvilLog.write("engines: \(installed.displayName) installed and sealed — \(files) files")
        state = .idle
        // Made ready for this Mac in the background: Game Mode copy, a first run.
        Task { await EngineOptimizer.shared.prepare(installed) }
        return installed
    }

    /// Find `bin/wine64` wherever the archive put it, rather than assuming a layout
    /// that may change between releases.
    private static func locateWineRoot(in staging: URL) throws -> URL {
        guard let walker = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil) else {
            throw CatalogError.extractionFailed
        }
        for case let url as URL in walker where url.lastPathComponent == "wine64"
            && url.deletingLastPathComponent().lastPathComponent == "bin" {
            return url.deletingLastPathComponent().deletingLastPathComponent()
        }
        throw CatalogError.notUsable
    }

    private func download(_ release: Release) async throws -> URL {
        // Progress for the engine list and the game's Health section: an engine is a few
        // hundred megabytes.
        let progress = DownloadProgress { fraction in
            Task { @MainActor in
                if case .downloading = EngineCatalog.shared.state { EngineCatalog.shared.state = .downloading(fraction) }
            }
        }
        let (temp, response) = try await URLSession.shared.download(from: release.downloadURL, delegate: progress)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CatalogError.badResponse
        }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-engine-\(release.version).tar.xz")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: temp, to: staged)
        return staged
    }

    private func verify(_ archive: URL, against checksumURL: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: checksumURL)
        guard let text = String(data: data, encoding: .utf8),
              let expected = text.split(whereSeparator: \.isWhitespace).first.map(String.init)?
                  .lowercased() else { throw CatalogError.checksumUnavailable }

        // Hash in chunks: the archive is well over a hundred megabytes and reading it
        // whole would spike memory for no reason.
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw CatalogError.checksumMismatch }
    }

    enum CatalogError: LocalizedError {
        case badResponse, malformed, extractionFailed, notUsable
        case checksumUnavailable, checksumMismatch, offline

        var errorDescription: String? {
            switch self {
            case .badResponse: "The engine catalogue could not be reached."
            case .malformed: "The engine catalogue was not in the expected format."
            case .extractionFailed: "The engine archive could not be unpacked."
            case .notUsable: "The downloaded engine contains no wine64 executable."
            case .checksumUnavailable: "The published checksum could not be read."
            case .checksumMismatch: "The download did not match its published checksum and was discarded."
            case .offline: "This Mac is offline. Engines already installed keep working; this one can be installed once you're back online."
            }
        }
    }
}

/// Reports how much of a download has arrived, from the task's own progress — without
/// taking over the finished file, which the async download API hands back itself.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: (Double) -> Void
    private var observation: NSKeyValueObservation?
    private var last = 0.0
    init(_ report: @escaping (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            let fraction = progress.fractionCompleted
            // A hundred updates at most, not one per packet.
            if fraction - self.last >= 0.01 || fraction >= 1 { self.last = fraction; self.report(fraction) }
        }
    }
}
