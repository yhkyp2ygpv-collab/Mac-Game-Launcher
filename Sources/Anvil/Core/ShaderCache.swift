import Foundation

/// Keeps D3DMetal's compiled-shader cache alive across system cleanups.
///
/// D3DMetal caches translated pipelines per executable, at
/// `$(getconf DARWIN_USER_CACHE_DIR)/d3dm/<Game.exe>/shaders.cache`. That directory
/// lives under `/var/folders`, which macOS treats as scratch space and purges on its
/// own schedule — after an OS update, under disk pressure, or on a periodic sweep.
///
/// When it is purged the game has to recompile every pipeline it meets, which is
/// felt as the stutter that "came back" after the game had already run smoothly. The
/// cache is not the problem; its location is.
///
/// Anvil keeps a copy somewhere macOS will not touch, restores it before a launch,
/// and takes the grown copy back afterwards — so shader compilation is a cost paid
/// once for a game rather than once per cleanup.
@MainActor
final class ShaderCacheManager: ObservableObject {

    struct Entry: Identifiable, Hashable {
        var id: String { executable }
        let executable: String      // "Cat Quest II.exe"
        let liveBytes: Int64        // what D3DMetal has right now
        let storedBytes: Int64      // what Anvil has kept
        var isProtected: Bool { storedBytes > 0 }
        /// True when the system cache has been wiped but Anvil still holds it.
        var isRecoverable: Bool { liveBytes < storedBytes }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastAction: String = ""

    static let shared = ShaderCacheManager()
    private let fm = FileManager.default
    private init() {}

    // MARK: Locations

    /// D3DMetal's live cache. Resolved through `getconf` rather than hard-coded,
    /// because the `/var/folders` path is per-user and generated at boot.
    nonisolated static var liveRoot: URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        p.arguments = ["DARWIN_USER_CACHE_DIR"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).appendingPathComponent("d3dm", isDirectory: true)
    }

    /// Anvil's durable copy, inside Application Support where nothing sweeps it.
    nonisolated static var storeRoot: URL {
        RuntimeManager.shaderCacheDir.appendingPathComponent("d3dm", isDirectory: true)
    }

    // MARK: Inspection

    func refresh() {
        var found: [String: (Int64, Int64)] = [:]
        if let live = Self.liveRoot {
            for name in (try? fm.contentsOfDirectory(atPath: live.path)) ?? [] {
                found[name, default: (0, 0)].0 = Self.size(of: live.appendingPathComponent(name))
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: Self.storeRoot.path)) ?? [] {
            found[name, default: (0, 0)].1 = Self.size(of: Self.storeRoot.appendingPathComponent(name))
        }
        entries = found
            .map { Entry(executable: $0.key, liveBytes: $0.value.0, storedBytes: $0.value.1) }
            .sorted { $0.executable.localizedCaseInsensitiveCompare($1.executable) == .orderedAscending }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url,
                                                     includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Which D3DMetal and macOS a cache was made for

    /// D3DMetal's stamp on a cache: `shaders.cache/MTLGPUFamily*/version.bin`, which names the
    /// D3DMetal build and the macOS it compiled for ("air64-apple-macosx27.0.1"). D3DMetal throws
    /// away a cache whose stamp isn't its own the first time it runs, and compiles everything
    /// again. Nil when there's no cache, or none D3DMetal has stamped.
    nonisolated static func stamp(of executableDir: URL) -> Data? {
        let cache = executableDir.appendingPathComponent("shaders.cache", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cache.path) else { return nil }
        for name in names.sorted() where name.hasPrefix("MTLGPUFamily") {
            let file = cache.appendingPathComponent(name).appendingPathComponent("version.bin")
            if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        }
        return nil
    }

    /// The macOS a stamp was made for, as "27.0.1".
    nonisolated static func macOS(inStamp stamp: Data) -> String? {
        guard let text = String(data: stamp, encoding: .isoLatin1), let r = text.range(of: "apple-macosx") else { return nil }
        let version = String(text[r.upperBound...].prefix { $0.isNumber || $0 == "." })
        return version.isEmpty ? nil : version
    }

    nonisolated static var thisMacOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Whether Anvil's kept copy should be put back over what D3DMetal has, and why not.
    /// Only a copy made for the same D3DMetal and macOS as the live one (or, with none live,
    /// for this macOS) is any use; and of two of those, the bigger has more pipelines in it.
    ///
    /// Until 0.38 the bigger copy always won. After the update to macOS 27.0.1 Anvil's copy
    /// (168 MB, made on 27.0.0) was bigger than the one D3DMetal was rebuilding, so it went back
    /// before every start of LEGO Star Wars, D3DMetal threw it away on the first frame, and every
    /// start compiled its shaders again: on 10 October the first minute ran as low as 4.6 fps,
    /// with gaps of half a second, and was at an even 120 only once they were all compiled.
    nonisolated static func shouldRestore(live: (stamp: Data?, bytes: Int64), stored: (stamp: Data?, bytes: Int64),
                                          macOS current: String) -> (Bool, String) {
        guard let storedStamp = stored.stamp, stored.bytes > 0 else { return (false, "no usable copy kept") }
        if let liveStamp = live.stamp {
            guard liveStamp == storedStamp else {
                return (false, "the copy kept was made for \(describe(storedStamp)), and D3DMetal's own for \(describe(liveStamp)) — the kept one would be thrown away")
            }
            return live.bytes >= stored.bytes ? (false, "D3DMetal's own is as complete") : (true, "D3DMetal's own had lost pipelines")
        }
        guard macOS(inStamp: storedStamp) == current else {
            return (false, "the copy kept was made for \(describe(storedStamp)), not macOS \(current) — it would be thrown away")
        }
        return (true, "D3DMetal had none")
    }

    /// Whether D3DMetal's cache should replace Anvil's copy: a newer stamp always, the same stamp
    /// when it has grown.
    nonisolated static func shouldCapture(live: (stamp: Data?, bytes: Int64), stored: (stamp: Data?, bytes: Int64)) -> Bool {
        guard let liveStamp = live.stamp, live.bytes > 0 else { return false }
        guard stored.stamp == liveStamp else { return true }
        return live.bytes > stored.bytes
    }

    nonisolated static func describe(_ stamp: Data) -> String {
        macOS(inStamp: stamp).map { "macOS \($0)" } ?? "another D3DMetal"
    }

    // MARK: Launch hooks

    /// Put Anvil's kept cache back before the game starts, when it is one D3DMetal will use and
    /// has more in it. Called on the launch path; never throws into a launch.
    nonisolated static func restore(executable: String) {
        guard let live = liveRoot else { return }
        let fm = FileManager.default
        let stored = storeRoot.appendingPathComponent(executable, isDirectory: true)
        guard fm.fileExists(atPath: stored.path) else { return }
        let liveDir = live.appendingPathComponent(executable, isDirectory: true)
        let (put, why) = shouldRestore(live: (stamp(of: liveDir), size(of: liveDir)),
                                       stored: (stamp(of: stored), size(of: stored)), macOS: thisMacOS)
        guard put else {
            AnvilLog.write("  shader cache: \(executable) — D3DMetal's own kept (\(why))")
            return
        }
        try? fm.createDirectory(at: live, withIntermediateDirectories: true)
        try? fm.removeItem(at: liveDir)
        clone(stored, liveDir)
        AnvilLog.write("  shader cache: \(executable) — Anvil's copy put back (\(why)), \(sizeText(size(of: liveDir)))")
    }

    /// Take the grown cache back after the game exits.
    nonisolated static func capture(executable: String) {
        guard let live = liveRoot else { return }
        let fm = FileManager.default
        let liveDir = live.appendingPathComponent(executable, isDirectory: true)
        guard fm.fileExists(atPath: liveDir.path) else { return }
        let stored = storeRoot.appendingPathComponent(executable, isDirectory: true)
        let liveState = (stamp(of: liveDir), size(of: liveDir)), storedState = (stamp(of: stored), size(of: stored))
        guard shouldCapture(live: liveState, stored: storedState) else { return }
        try? fm.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stored)
        clone(liveDir, stored)
        let newer = storedState.0 != liveState.0
        AnvilLog.write("shader cache: \(executable) — kept, \(sizeText(liveState.1))"
                       + (newer ? " (made for \(liveState.0.map(describe) ?? "this Mac"); the copy from \(storedState.0.map(describe) ?? "before") replaced)" : ""))
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// APFS clone — instant, and costs no disk until one side changes.
    private nonisolated static func clone(_ from: URL, _ to: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", from.path, to.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            try? FileManager.default.copyItem(at: from, to: to)
        }
    }

    // MARK: Manual actions

    func protectAll() {
        guard let live = Self.liveRoot else { return }
        for name in (try? fm.contentsOfDirectory(atPath: live.path)) ?? [] {
            Self.capture(executable: name)
        }
        lastAction = "Kept every cache D3DMetal currently has."
        refresh()
    }

    func restoreAll() {
        for name in (try? fm.contentsOfDirectory(atPath: Self.storeRoot.path)) ?? [] {
            Self.restore(executable: name)
        }
        lastAction = "Put Anvil's caches back where D3DMetal reads them."
        refresh()
    }

    /// For the one case where purging is the right answer: a cache written by an
    /// older D3DMetal that the new one rejects, which shows up as a hang or a black
    /// screen at startup rather than as stutter.
    func discard(_ entry: Entry, alsoStored: Bool) {
        if let live = Self.liveRoot {
            try? fm.removeItem(at: live.appendingPathComponent(entry.executable))
        }
        if alsoStored {
            try? fm.removeItem(at: Self.storeRoot.appendingPathComponent(entry.executable))
        }
        lastAction = "Discarded the cache for \(entry.executable). It will rebuild on the next run."
        refresh()
    }
}
