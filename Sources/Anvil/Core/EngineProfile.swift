import Foundation

/// What Anvil knows about an engine, read from its files — no Wine is run, so it works
/// offline the moment an engine is installed or updated — and how Anvil runs games on it
/// as a result.
///
/// Engines differ in ways that decide whether Anvil's help reaches a game at all. Engine
/// 3.0 (Wine 9) showed every one of them on 1 October: its games run as `wine` rather than
/// a preloader, it starts them through a path macOS doesn't see as inside an app (no Game
/// Mode), its settings reach the game's process late (no pacing until 0.19.2), and its
/// controller driver isn't the one Anvil's Switch Pro support is built for. Reading the
/// engine first means the next engine gets the right treatment from its first launch.
struct EngineProfile: Codable, Hashable {
    var runtimeID: String
    /// "9.0", "7.7" — from the version ntdll carries.
    var wineVersion: String?
    var wineMajor: Int
    var d3dMetal: String?
    /// The binary a game's own process runs as: wine64-preloader under Wine 7.7, wine under 9.
    var gameBinary: String
    /// New processes must be told which loader to use (WINELOADER), or Wine 9 starts them
    /// through bin/, a link, and macOS doesn't count them as the Game Mode app.
    var needsLoaderPath: Bool
    /// D3DMetal 3 hands each frame's work to the GPU without waiting for it.
    var asyncCommit: Bool
    /// CrossOver's Mach-port synchronisation is built in.
    var msync: Bool
    /// The controller driver Anvil's Switch Pro support is built for (Wine 7.7's winebus).
    var proController: Bool

    /// How fully Anvil supports this kind of engine. Raised when Anvil learns to handle a
    /// generation better, so an engine that lost a trial before can have one more.
    var supportLevel: Int { EngineProfile.supportLevel(wineMajor: wineMajor) }

    /// 1: what 0.19.1 knew. 2 (0.20.0): Wine 9's late settings, loader path, Game Mode
    /// binary and display fitting handled.
    static func supportLevel(wineMajor: Int) -> Int { wineMajor >= 9 ? 2 : 1 }

    /// For an engine in Anvil's store, by id, read from its files.
    static func supportLevel(ofManaged runtimeID: String) -> Int {
        let ntdll = RuntimeManager.runtimesDir.appendingPathComponent(runtimeID)
            .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let major = wineVersion(in: ntdll).flatMap { Int($0.split(separator: ".").first ?? "") } ?? 7
        return supportLevel(wineMajor: major)
    }

    /// What Anvil does differently because of it, in words, for the Engines page.
    var adjustments: [String] {
        var out: [String] = []
        out.append("Game Mode through Anvil's copy, run as \(gameBinary)")
        if needsLoaderPath { out.append("each process registered with macOS as that app, wherever Wine runs it from") }
        if asyncCommit { out.append("D3DMetal \(d3dMetal ?? "3") hands frames to the GPU without waiting") }
        if msync { out.append("Mach-port synchronisation") }
        out.append(proController ? "Switch pads as a real Pro Controller" : "Switch pads as Xbox-style pads")
        return out
    }

    var title: String {
        ["Wine \(wineVersion ?? "?")", d3dMetal.map { "D3DMetal \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Reading an engine

    nonisolated(unsafe) private static var cache: [String: EngineProfile] = [:]
    private static let lock = NSLock()

    /// The profile of an engine (or Anvil's Game Mode copy of one), read once per run.
    static func of(_ runtime: Runtime) -> EngineProfile {
        let key = runtime.root.path
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let profile = read(runtime)
        lock.lock(); cache[key] = profile; lock.unlock()
        return profile
    }

    static func read(_ runtime: Runtime) -> EngineProfile {
        let fm = FileManager.default
        let root = runtime.root
        let ntdll = ["lib/wine/x86_64-unix/ntdll.so", "lib64/wine/x86_64-unix/ntdll.so", "lib/wine/ntdll.so"]
            .map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        let version = ntdll.flatMap { wineVersion(in: $0) }
        let major = version.flatMap { Int($0.split(separator: ".").first ?? "") } ?? 7
        let hasPreloader64 = fm.fileExists(atPath: root.appendingPathComponent("bin/wine64-preloader").path)
        let wineIsBinary = Runtime.isMachOFile(root.appendingPathComponent("bin/wine"))
        let modern = !hasPreloader64 && wineIsBinary
        let hasPreloader = Runtime.isMachOFile(root.appendingPathComponent("bin/wine-preloader"))
        let d3d = runtime.d3dMetalVersion
        let d3dMajor = d3d.flatMap { Int($0.split(separator: ".").first ?? "") } ?? 0
        let msync = [ntdll, root.appendingPathComponent("bin/wineserver")].compactMap { $0 }
            .contains { contains($0, "WINEMSYNC") }
        return EngineProfile(runtimeID: runtime.id, wineVersion: version, wineMajor: major, d3dMetal: d3d,
                             gameBinary: hasPreloader64 ? "wine64-preloader" : (hasPreloader || !modern ? "wine-preloader" : "wine"),
                             needsLoaderPath: modern, asyncCommit: d3dMajor >= 3, msync: msync,
                             proController: major < 9)
    }

    /// "wine-9.0" in ntdll → "9.0".
    static func wineVersion(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let marker = Data("wine-".utf8)
        var from = data.startIndex
        while let r = data.range(of: marker, in: from..<data.endIndex) {
            var end = r.upperBound
            while end < data.endIndex, end < r.upperBound + 12, (data[end] >= 0x30 && data[end] <= 0x39) || data[end] == 0x2E { end += 1 }
            let digits = String(decoding: data[r.upperBound..<end], as: UTF8.self)
            if digits.contains("."), digits.first?.isNumber == true { return digits.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            from = r.upperBound
        }
        return nil
    }

    private static func contains(_ file: URL, _ text: String) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return false }
        return data.range(of: Data(text.utf8)) != nil
    }
}
