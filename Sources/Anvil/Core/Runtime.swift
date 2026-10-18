import Foundation

/// A Wine + translation-layer toolchain on disk.
///
/// Anvil never mutates a runtime in place. Updating means installing a new
/// versioned directory next to the old one and re-pointing containers at it, so a
/// bad Metal/D3DMetal drop is a one-click revert and can never corrupt drive_c.
struct Runtime: Identifiable, Hashable, Codable {
    var id: String            // e.g. "whiskywine-2.5.0"
    var displayName: String
    var version: String
    var root: URL             // contains bin/, lib/, share/
    var isManaged: Bool       // true once Anvil owns a private copy
    var source: String = ""   // which app this toolchain came from, for the picker

    /// The Wine loader to launch. Usually bin/wine64, but newer engines (Wine 9, as
    /// in the preview engine with D3DMetal 3.0) ship bin/wine and leave bin/wine64 as
    /// a bash wrapper. Launching the wrapper would run it through /bin/bash, and macOS
    /// strips DYLD_* variables from protected system programs — so Anvil's
    /// interceptor, library paths and D3DMetal framework path would all silently
    /// vanish. The real Mach-O binary is used instead whenever wine64 is not one.
    var wine64: URL {
        let named = root.appendingPathComponent("bin/wine64")
        if Runtime.isMachO(named) { return named }
        let plain = root.appendingPathComponent("bin/wine")
        return FileManager.default.isExecutableFile(atPath: plain.path) ? plain : named
    }

    static func isMachOFile(_ url: URL) -> Bool { isMachO(url) }

    private static func isMachO(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url),
              let head = try? h.read(upToCount: 4), head.count == 4 else { return false }
        try? h.close()
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xFEEDFACF, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }
    var wineserver: URL { root.appendingPathComponent("bin/wineserver") }
    var externalLibs: URL { root.appendingPathComponent("lib/external") }

    var d3dMetalFramework: URL { externalLibs.appendingPathComponent("D3DMetal.framework") }

    var hasD3DMetal: Bool {
        FileManager.default.fileExists(atPath: d3dMetalFramework.path)
    }

    /// The D3DMetal build inside this toolchain, read from the framework itself.
    ///
    /// This is the number that decides how a DirectX 12 title actually performs, and
    /// two toolchains that both say "wine-7.7" can ship years apart here — so it is
    /// shown in the picker rather than left for the user to guess at.
    var d3dMetalVersion: String? {
        let info = d3dMetalFramework.appendingPathComponent("Resources/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// Newest-first ordering key. A missing version sorts last.
    var d3dMetalRank: [Int] {
        (d3dMetalVersion ?? "0").split(separator: ".").map { Int($0) ?? 0 }
    }

    var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: wine64.path)
    }
}

@MainActor
final class RuntimeManager: ObservableObject {
    @Published private(set) var runtimes: [Runtime] = []
    @Published private(set) var dxvkSources: [URL] = []
    /// Engines whose files differ from their seal, and which files: no game runs on them
    /// until they are repaired.
    @Published private(set) var sealProblems: [String: [String]] = [:]

    static let shared = RuntimeManager()

    private let fm = FileManager.default

    /// ~/Library/Application Support/Anvil
    nonisolated static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Anvil", isDirectory: true)
    }
    nonisolated static var runtimesDir: URL { support.appendingPathComponent("Runtimes", isDirectory: true) }
    nonisolated static var containersDir: URL { support.appendingPathComponent("Containers", isDirectory: true) }
    nonisolated static var snapshotsDir: URL { support.appendingPathComponent("Snapshots", isDirectory: true) }
    nonisolated static var shaderCacheDir: URL { support.appendingPathComponent("ShaderCache", isDirectory: true) }

    private init() {
        for dir in [Self.support, Self.runtimesDir, Self.containersDir, Self.snapshotsDir, Self.shaderCacheDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        discover()
    }

    func discover() {
        var found: [Runtime] = []
        var dxvk: [URL] = []

        // 1. Runtimes Anvil manages itself.
        if let entries = try? fm.contentsOfDirectory(at: Self.runtimesDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.hasDirectoryPath && !entry.lastPathComponent.hasPrefix(".") {
                let id = entry.lastPathComponent
                let r = Runtime(id: id,
                                displayName: Self.displayName(forManaged: id),
                                version: id.split(separator: "-").last.map(String.init) ?? id,
                                root: entry,
                                isManaged: true,
                                source: "Anvil")
                if r.isUsable { found.append(r) }
            }
        }

        // 2. Toolchains already installed by Whisky / Mythic / CrossOver. Reusing them
        //    means the user isn't re-downloading a 1.5 GB toolchain they already have.
        //
        //    Anvil's own copy of one wins. Both carry the same id, and the list used to be
        //    sorted by display name — "Mythic Engine 2.6.1" before "mythic-engine-2.6.1" —
        //    so a container on Anvil's copy of Mythic's engine ran from Mythic's own folder,
        //    which Mythic can update underneath it at any time.
        for candidate in Self.externalCandidates() {
            guard candidate.runtime.isUsable else { continue }
            if !found.contains(where: { $0.root == candidate.runtime.root || $0.id == candidate.runtime.id }) {
                found.append(candidate.runtime)
            }
            if let d = candidate.dxvk, fm.fileExists(atPath: d.path) { dxvk.append(d) }
        }

        runtimes = found.sorted { $0.displayName < $1.displayName }
        dxvkSources = dxvk
    }

    private struct Candidate { let runtime: Runtime; let dxvk: URL? }

    private static func externalCandidates() -> [Candidate] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fm = FileManager.default
        var out: [Candidate] = []

        // Whisky keeps its toolchain under its bundle identifier.
        let whisky = base.appendingPathComponent("com.isaacmarovitz.Whisky/Libraries")
        if fm.fileExists(atPath: whisky.path) {
            let version = readPlistVersion(whisky.appendingPathComponent("WhiskyWineVersion.plist")) ?? "unknown"
            out.append(Candidate(
                runtime: Runtime(id: "whiskywine-\(version)",
                                 displayName: "WhiskyWine \(version)",
                                 version: version,
                                 root: whisky.appendingPathComponent("Wine"),
                                 isManaged: false,
                                 source: "Whisky"),
                dxvk: whisky.appendingPathComponent("DXVK")))
        }

        // Mythic keeps its engine under a plain "Mythic" directory, not under its
        // bundle identifier — the identifier path Anvil looked in before does not
        // exist, so Mythic Engine was never found and its newer D3DMetal never used.
        let mythic = base.appendingPathComponent("Mythic/Engine")
        if fm.fileExists(atPath: mythic.appendingPathComponent("wine/bin/wine64").path) {
            let version = readPlistVersion(mythic.appendingPathComponent("Properties.plist")) ?? "unknown"
            out.append(Candidate(
                runtime: Runtime(id: "mythic-engine-\(version)",
                                 displayName: "Mythic Engine \(version)",
                                 version: version,
                                 root: mythic.appendingPathComponent("wine"),
                                 isManaged: false,
                                 source: "Mythic"),
                dxvk: mythic.appendingPathComponent("DXVK")))
        }

        // CrossOver ships the same D3DMetal lineage; use it if it is the newest here.
        let crossover = URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver")
        if fm.fileExists(atPath: crossover.appendingPathComponent("bin/wine64").path) {
            out.append(Candidate(
                runtime: Runtime(id: "crossover",
                                 displayName: "CrossOver",
                                 version: "bundled",
                                 root: crossover,
                                 isManaged: false,
                                 source: "CrossOver"),
                dxvk: nil))
        }

        // Apple's Game Porting Toolkit, when installed directly via Homebrew.
        for brew in ["/opt/homebrew/opt/game-porting-toolkit", "/usr/local/opt/game-porting-toolkit"] {
            let gptk = URL(fileURLWithPath: brew)
            if fm.fileExists(atPath: gptk.appendingPathComponent("bin/wine64").path) {
                out.append(Candidate(
                    runtime: Runtime(id: "gptk",
                                     displayName: "Game Porting Toolkit",
                                     version: "bundled",
                                     root: gptk,
                                     isManaged: false,
                                     source: "Homebrew"),
                    dxvk: nil))
                break
            }
        }

        return out
    }

    private static func readPlistVersion(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = plist["version"] as? [String: Any] else { return nil }
        let major = v["major"] as? Int ?? 0
        let minor = v["minor"] as? Int ?? 0
        let patch = v["patch"] as? Int ?? 0
        return "\(major).\(minor).\(patch)"
    }

    func runtime(id: String) -> Runtime? {
        runtimes.first { $0.id == id && $0.isManaged } ?? runtimes.first { $0.id == id }
    }

    /// "mythic-engine-3.0.0" → "Mythic Engine 3.0.0", "whiskywine-2.5.0" → "WhiskyWine 2.5.0".
    nonisolated static func displayName(forManaged id: String) -> String {
        let known = [("mythic-engine-", "Mythic Engine "), ("whiskywine-", "WhiskyWine ")]
        for (prefix, name) in known where id.hasPrefix(prefix) { return name + id.dropFirst(prefix.count) }
        return id
    }

    /// Containers that still run from another app's folder get Anvil's own copy of it, so
    /// nothing that app does — an update, an uninstall — changes a game that runs here.
    /// The copy keeps the engine's id, so the container needs no change. APFS clones it
    /// in a second or two, without using more disk, off the main thread.
    func ownEnginesInUse(by containers: [Container]) async {
        let external = Set(containers.map(\.runtimeID)).compactMap { id -> Runtime? in
            guard let r = runtime(id: id), !r.isManaged else { return nil }
            return r
        }
        for r in external {
            let dest = Self.runtimesDir.appendingPathComponent(r.id, isDirectory: true)
            let dxvk = dxvkSources.first { $0.deletingLastPathComponent() == r.root.deletingLastPathComponent() }
            let copied = await Task.detached(priority: .utility) { () -> Bool in
                let fm = FileManager.default
                guard !fm.fileExists(atPath: dest.path) else { return true }
                let staging = dest.deletingLastPathComponent().appendingPathComponent(".adopting-" + r.id)
                try? fm.removeItem(at: staging)
                guard Self.clone(r.root, to: staging) else { try? fm.removeItem(at: staging); return false }
                do { try fm.moveItem(at: staging, to: dest) } catch { try? fm.removeItem(at: staging); return false }
                if let dxvk {
                    let dxvkDest = dest.deletingLastPathComponent().appendingPathComponent(r.id + "-dxvk")
                    if !fm.fileExists(atPath: dxvkDest.path) { _ = Self.clone(dxvk, to: dxvkDest) }
                }
                return true
            }.value
            AnvilLog.write(copied ? "engines: \(r.displayName) copied into Anvil's own engines — its containers no longer run from \(r.source)'s folder"
                                  : "engines: couldn't copy \(r.displayName) from \(r.source) — its containers keep running from there")
        }
        if !external.isEmpty { discover() }
    }

    nonisolated private static func clone(_ from: URL, to: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", from.path, to.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: to.path)
    }

    func noteSealProblem(_ id: String, files: [String]) { sealProblems[id] = files }

    /// Seal what isn't sealed, check what is (fully once a day), and remember problems.
    func checkSeals() async {
        let verdicts = await EngineSeal.sweep(runtimes)
        for (id, verdict) in verdicts {
            if case .changed(let files) = verdict { sealProblems[id] = files } else { sealProblems[id] = nil }
        }
    }

    enum RepairError: LocalizedError {
        case noSource(String)
        var errorDescription: String? {
            switch self {
            case .noSource(let name): "There's no clean copy of \(name) to repair it from. Install an engine from the list below and move its containers to it."
            }
        }
    }

    /// Replace a changed engine with a clean copy — downloaded again from its publisher, or
    /// cloned again from the app it was taken from — and seal that. The changed copy goes
    /// to the Trash, not away for good.
    func repair(_ runtime: Runtime) async throws {
        guard runtime.isManaged else { return }
        let dest = Self.runtimesDir.appendingPathComponent(runtime.id, isDirectory: true)
        let catalog = EngineCatalog.shared
        if catalog.releases.isEmpty { await catalog.check() }
        let release = catalog.releases.first { $0.runtimeID == runtime.id }
        let external = Self.externalCandidates().first { $0.runtime.id == runtime.id && $0.runtime.isUsable }?.runtime
        guard release != nil || external != nil else { throw RepairError.noSource(runtime.displayName) }
        do { try fm.trashItem(at: dest, resultingItemURL: nil) }
        catch {
            let aside = Self.runtimesDir.appendingPathComponent(".changed-\(runtime.id)-\(Int(Date().timeIntervalSince1970))")
            try fm.moveItem(at: dest, to: aside)
        }
        try? fm.removeItem(at: EngineSeal.url(for: runtime.id))
        AnvilLog.write("engines: repairing \(runtime.displayName) — the changed copy is in the Trash")
        if let release {
            try await catalog.install(release)          // seals it too
        } else if let external {
            guard cloneTree(from: external.root, to: dest) else { throw RepairError.noSource(runtime.displayName) }
            discover()
            let root = dest, id = runtime.id
            _ = await Task.detached(priority: .userInitiated) { try? EngineSeal.seal(root: root, id: id) }.value
        }
        sealProblems[runtime.id] = nil
        AnvilLog.write("engines: \(runtime.displayName) repaired and sealed")
    }

    /// Prefer the toolchain with the newest D3DMetal, not merely the first one that
    /// has any. Anvil previously took the first match alphabetically, which meant a
    /// 2024 D3DMetal was chosen over a 2025 one sitting right beside it.
    var defaultRuntime: Runtime? {
        let withMetal = runtimes.filter { $0.hasD3DMetal }
        return withMetal.max { lexLess($0.d3dMetalRank, $1.d3dMetalRank) } ?? runtimes.first
    }

    /// The best D3DMetal available on this Mac, whichever app happens to own it.
    var bestD3DMetal: Runtime? {
        runtimes.filter { $0.hasD3DMetal }.max { lexLess($0.d3dMetalRank, $1.d3dMetalRank) }
    }

    /// Take ownership of an external toolchain by cloning it into Anvil's own store.
    ///
    /// Two things matter here. Anvil gets a copy that another app can't change
    /// underneath a container that was known-good — and the app it came from is left
    /// exactly as it was, because a clone never writes to the source. On APFS this is
    /// copy-on-write, so adopting a 1.5 GB toolchain is instant and costs no disk
    /// until one of the two copies is modified.
    @discardableResult
    func adopt(_ external: Runtime) throws -> Runtime {
        guard !external.isManaged else { return external }
        let dest = Self.runtimesDir.appendingPathComponent(external.id, isDirectory: true)
        if !fm.fileExists(atPath: dest.path) {
            try fm.createDirectory(at: Self.runtimesDir, withIntermediateDirectories: true)
            if !cloneTree(from: external.root, to: dest) {
                try fm.copyItem(at: external.root, to: dest)   // non-APFS fallback
            }
        }
        // The engine's DXVK sits beside the wine tree rather than inside it, so it
        // has to be brought along or the adopted copy loses the DXVK backend.
        if let dxvk = dxvkSources.first(where: { $0.deletingLastPathComponent() == external.root.deletingLastPathComponent() }) {
            let dxvkDest = dest.deletingLastPathComponent().appendingPathComponent(external.id + "-dxvk", isDirectory: true)
            if !fm.fileExists(atPath: dxvkDest.path) { _ = cloneTree(from: dxvk, to: dxvkDest) }
        }
        discover()
        return runtime(id: external.id) ?? external
    }

    /// APFS clone. Returns false when the filesystem can't do it, so the caller falls
    /// back to a real copy instead of silently ending up with nothing.
    private func cloneTree(from: URL, to: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", from.path, to.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && fm.fileExists(atPath: to.path)
    }
}

/// Lexicographic compare on version components, so 2.10 beats 2.9.
private func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x < y }
    }
    return false
}
