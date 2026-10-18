import Foundation

/// Copies of what Anvil fetched from the internet, kept so they are there offline.
///
/// Each entry is the response body plus when it was fetched and the validators the
/// server gave (ETag, Last-Modified). A fetch while online asks the server whether the
/// copy is still current, so an unchanged catalogue costs a few hundred bytes; a fetch
/// while offline, or one that fails, answers from the copy and says how old it is.
enum DiskCache {
    static var directory: URL { RuntimeManager.support.appendingPathComponent("Cache", isDirectory: true) }

    struct Entry: Codable {
        var url: String
        var fetchedAt: Date
        var etag: String?
        var lastModified: String?
    }

    struct Result {
        var data: Data
        var fetchedAt: Date
        /// Answered from the copy on disk rather than the network.
        var fromCache: Bool
    }

    enum CacheError: LocalizedError {
        case offlineAndNotCached
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .offlineAndNotCached: "This Mac is offline and nothing has been saved for it yet."
            case .badResponse(let code): "The server answered with status \(code)."
            }
        }
    }

    private static func bodyURL(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private static func entryURL(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }

    /// The saved copy, if there is one.
    static func cached(_ name: String) -> Result? {
        guard let data = try? Data(contentsOf: bodyURL(name)) else { return nil }
        let entry = (try? Data(contentsOf: entryURL(name))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        return Result(data: data, fetchedAt: entry?.fetchedAt ?? .distantPast, fromCache: true)
    }

    /// Fetch `url`, keep the answer under `name`, and fall back to the kept copy when
    /// offline or when the fetch fails for any reason.
    static func fetch(_ url: URL, name: String, timeout: TimeInterval = 20) async throws -> Result {
        let copy = cached(name)
        guard Connectivity.isOnlineNow else {
            if let copy { return copy }
            throw CacheError.offlineAndNotCached
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let entry = (try? Data(contentsOf: entryURL(name))).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        if copy != nil, let entry {
            if let etag = entry.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = entry.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304, var copy {
                // Unchanged since it was kept: the copy is current as of now.
                var refreshed = entry ?? Entry(url: url.absoluteString, fetchedAt: Date())
                refreshed.fetchedAt = Date()
                writeEntry(refreshed, name: name)
                copy.fetchedAt = refreshed.fetchedAt
                copy.fromCache = false
                return copy
            }
            guard let http, (200...299).contains(http.statusCode) else {
                if let copy { return copy }
                throw CacheError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            store(data, name: name, url: url,
                  etag: http.value(forHTTPHeaderField: "ETag"),
                  lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
            return Result(data: data, fetchedAt: Date(), fromCache: false)
        } catch {
            if let copy { return copy }
            throw error
        }
    }

    static func store(_ data: Data, name: String, url: URL, etag: String? = nil, lastModified: String? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard writeReplacing(data, to: bodyURL(name)) else { return }
        writeEntry(Entry(url: url.absoluteString, fetchedAt: Date(), etag: etag, lastModified: lastModified), name: name)
    }

    private static func writeEntry(_ entry: Entry, name: String) {
        if let data = try? JSONEncoder().encode(entry) { _ = writeReplacing(data, to: entryURL(name)) }
    }

    /// Written beside the file and renamed over it, so a reader never finds half a file.
    /// `durable` also has the new contents on the disk before the rename, so a power cut
    /// straight after leaves the old file or the new one — never an empty one.
    @discardableResult
    static func writeReplacing(_ data: Data, to url: URL, durable: Bool = false) -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".partial")
        do {
            try data.write(to: temporary)
            if durable, let handle = try? FileHandle(forWritingTo: temporary) {
                _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
                try? handle.close()
            }
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// How old a copy is, in words: "fetched 3 days ago".
    static func age(_ date: Date) -> String {
        date == .distantPast ? "saved earlier" : "fetched \(date.formatted(.relative(presentation: .named)))"
    }
}
