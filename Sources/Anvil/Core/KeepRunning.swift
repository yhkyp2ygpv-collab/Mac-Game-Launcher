import Foundation

/// A game's own switch for carrying on while another app is in front.
///
/// LEGO Star Wars: The Skywalker Saga pauses whenever it isn't the app in front, its
/// loading included: its frame loop sleeps ten milliseconds at a time until it is back.
/// Every LEGO start closed "stuck on the loading screen" on 1–3 October had spent part of
/// its load behind Anvil, Finder, Chrome or Claude, where it made no progress at all — on
/// 3 October one was still on its loading screen, paused, twenty minutes later.
///
/// Its engine, TT Games', reads `-NoFocus_Process` from the command line and sets the flag
/// that skips that loop (`-NoFocus_Pause` clears it again): found in the game's own code
/// on 3 October, at the command-line parser beside `-Windowed` and `MAXFPS`. Any game whose
/// program carries the switch is given it — the TT Games LEGO games share the engine — so
/// a load finishes while the player is elsewhere. Behind other apps Anvil's library holds
/// the game to 30 frames a second (see anvil_window.mm), so carrying on costs little.
enum KeepRunning {
    /// Switches that keep a game going behind other apps, as its own program spells them.
    nonisolated static let switches = ["-NoFocus_Process"]

    private struct Entry: Codable {
        var size: Int64
        var modified: Date
        var found: String?
    }

    nonisolated static var cacheURL: URL {
        RuntimeManager.support.appendingPathComponent("Cache/keep-running.json")
    }
    nonisolated(unsafe) private static var memory: [String: Entry]?
    private static let lock = NSLock()

    /// The switch this program understands, or nil. Read once per version of the program —
    /// a 120 MB executable is a tenth of a second, mapped rather than read — and remembered.
    nonisolated static func supportedSwitch(for exe: URL) -> String? {
        let path = exe.resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        lock.lock()
        if memory == nil {
            memory = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        }
        if let e = memory?[path], e.size == size, abs(e.modified.timeIntervalSince(modified)) < 1 {
            lock.unlock()
            return e.found
        }
        lock.unlock()

        let found = scan(path)
        lock.lock()
        memory?[path] = Entry(size: size, modified: modified, found: found)
        let snapshot = memory ?? [:]
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = DiskCache.writeReplacing(data, to: cacheURL)
        }
        return found
    }

    /// The first switch whose text, ended by a zero byte as a C string in the program's
    /// data, appears in the file.
    nonisolated static func scan(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let base = raw.baseAddress else { return nil }
            for s in switches {
                let needle = Array(s.utf8) + [0]
                let hit = needle.withUnsafeBytes { n in memmem(base, raw.count, n.baseAddress, n.count) }
                if hit != nil { return s }
            }
            return nil
        }
    }
}
