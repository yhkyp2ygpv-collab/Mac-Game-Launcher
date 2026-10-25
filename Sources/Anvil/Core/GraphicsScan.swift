import CoreGraphics
import Foundation

/// A look at a game's graphics before it first starts, and again while it first runs — and
/// what Anvil does about upscaling and frame generation for it as a result.
///
/// Asked for on 3 October: "a feature before launching a game once to let the app look at all
/// of the graphics and more and make FSR work for the game". FSR 3's own upscaling and frame
/// generation take motion vectors and depth that only a game's renderer has, so what can be
/// made to work depends on the game, and the scan finds out which case it is:
///
/// - A game that ships DLSS hands its upscaler exactly that data. On an engine with Apple's
///   DLSS-to-MetalFX translation (D3DMetal 3.0), Anvil sets it up, and choosing DLSS in the
///   game runs Apple's MetalFX temporal upscaler on the game's own motion vectors — and its
///   frame generation on MetalFX frame interpolation.
/// - A game that ships FSR 2 or 3 runs it as it is: it is plain shaders, on any GPU.
/// - Every other game, which is most, gets AMD FSR 1 at the display's own pixels and Anvil's
///   frame generation, neither of which needs anything from the game. That covers a game
///   whose frames reach the screen through Metal; a game Wine draws with OpenGL can't be
///   reached, and the scan says so.
///
/// The first part reads files: the game's executable and the libraries beside it, the engine
/// it runs on, the display. It is done once per build of the game and engine, before that
/// build's first start, and takes well under a second. The second part is the first session
/// itself: Anvil's library reports what actually drew the game, at what size and in what
/// format, and whether FSR ran — kept with the scan as what was seen in play.
struct GraphicsScan: Codable, Hashable {
    /// An upscaler or frame generator the game ships, found from its files.
    struct Builtin: Codable, Hashable {
        enum Kind: String, Codable, CaseIterable {
            case fsr1, fsr2, fsr3, fsr31, fsr4, fsrFrameGen
            case dlss, dlssFrameGen, xess, xessFrameGen

            var name: String {
                switch self {
                case .fsr1: "FSR 1"
                case .fsr2: "FSR 2"
                case .fsr3: "FSR 3"
                case .fsr31: "FSR 3.1"
                case .fsr4: "FSR 4"
                case .fsrFrameGen: "FSR frame generation"
                case .dlss: "DLSS"
                case .dlssFrameGen: "DLSS frame generation"
                case .xess: "XeSS"
                case .xessFrameGen: "XeSS frame generation"
                }
            }
            /// Reconstructs from the game's motion vectors and depth, over several frames.
            var temporal: Bool { ![.fsr1, .fsrFrameGen, .dlssFrameGen, .xessFrameGen].contains(self) }
            var generatesFrames: Bool { [.fsrFrameGen, .dlssFrameGen, .xessFrameGen].contains(self) }
        }
        var kind: Kind
        var version: String?
        /// Where it was found: a file beside the game, or "the game's program".
        var source: String

        var title: String {
            guard let version else { return kind.name }
            // AMD's FSR 3.1 and 4 libraries carry the FidelityFX SDK's version, not FSR's.
            if source.lowercased().contains("amd_fidelityfx") { return "\(kind.name) (FidelityFX SDK \(version))" }
            return "\(kind.name) \(version)"
        }
    }

    /// How the game's frames reach the screen.
    enum Path: String, Codable {
        case d3dMetal       // DirectX 11/12 through D3DMetal to a Metal layer
        case moltenVK       // Vulkan, or DirectX through DXVK, to a Metal layer by MoltenVK
        case wineOpenGL     // Wine's own renderer on OpenGL: no Metal layer of the game's
        case unknown

        var title: String {
            switch self {
            case .d3dMetal: "D3DMetal"
            case .moltenVK: "MoltenVK"
            case .wineOpenGL: "Wine's OpenGL renderer"
            case .unknown: "not known yet"
            }
        }
    }

    /// What Anvil does for the game.
    struct Plan: Codable, Hashable {
        /// AMD FSR 1 at the display's pixels can reach the game's frames.
        var anvilFSR: Bool
        var anvilFSRWhyNot: String?
        /// The game's DLSS runs as Apple's MetalFX (set up at each start).
        var dlssThroughMetalFX: Bool
        /// Anvil's frame generation applies to the frames it shows.
        var anvilFrameGen: Bool
        /// What to choose in the game itself, in words.
        var inGame: [String]
    }

    /// What the first session showed, read from game.log afterwards.
    struct Live: Codable, Hashable {
        var at: Date
        /// The libraries that set the size of a Metal layer: what drew the game.
        var drawnBy: [String]
        var gameSize: String?
        var shownSize: String?
        var pixelFormat: Int?
        var fsrRan: Bool
        var fsrWhyNot: String?
        var generated: Int
        var shown: Int
        /// Depth-stencil states the game asked for that Metal would have stopped it over.
        var guardCorrections: Int
    }

    // What the game is.
    var api: String?
    var engine: String
    var is64Bit: Bool
    var builtins: [Builtin]
    var antiCheat: [String]
    // Where it runs.
    var engineName: String
    var d3dMetal: String?
    var path: Path
    var metalFXForDLSS: Bool
    // The display.
    var displayPixels: [Int]
    var displayHz: Int
    // The result.
    var plan: Plan
    var scannedAt: Date
    var live: Live?

    var upscalers: [Builtin] { builtins.filter { !$0.kind.generatesFrames } }
    var frameGenerators: [Builtin] { builtins.filter(\.kind.generatesFrames) }
    var hasTemporal: Bool { builtins.contains { $0.kind.temporal } }

    /// "AMD FSR 1 to the display's 3024 × 1964".
    var fsrText: String {
        displayPixels.count == 2 ? "AMD FSR 1 to the display's \(displayPixels[0]) × \(displayPixels[1])" : "AMD FSR 1 to the display's own pixels"
    }

    /// One line for the launch log.
    var summary: String {
        var parts: [String] = []
        parts.append([api, engine, is64Bit ? "64-bit" : "32-bit"].compactMap { $0 }.joined(separator: " · "))
        parts.append(builtins.isEmpty ? "no upscaler or frame generation of its own"
                                      : "built in: " + builtins.map(\.title).joined(separator: ", "))
        parts.append("through \(path.title)" + (d3dMetal.map { " \($0)" } ?? ""))
        var does: [String] = []
        if plan.dlssThroughMetalFX { does.append("DLSS through Apple's MetalFX") }
        does.append(plan.anvilFSR ? fsrText : "no FSR to the display (\(plan.anvilFSRWhyNot ?? "not reachable"))")
        if plan.anvilFrameGen { does.append("Anvil's frame generation") }
        parts.append(does.joined(separator: ", "))
        return parts.joined(separator: " — ")
    }
}

// MARK: - Scanning

extension GraphicsScan {
    /// Read the game, its engine and the display, and decide. Files only; no network, no Wine.
    nonisolated static func scan(executable: URL, backend: GraphicsBackend, runtime: Runtime) -> GraphicsScan {
        let analysis = GameAnalysis.cached(for: executable)
            ?? GameAnalysis(apis: [], primary: nil, engine: .other, is64Bit: true, rendersAtWindowSize: false)
        let builtins = findBuiltins(executable: executable, engine: analysis.engine)
        let antiCheat = AntiCheat.detect(forExecutable: executable).map(\.name)
        let path = path(api: analysis.primary, backend: backend, is64Bit: analysis.is64Bit, runtime: runtime)
        let metalFX = DLSSThroughMetalFX.available(in: runtime)
        let (pixels, hz) = display()

        var plan = Plan(anvilFSR: false, anvilFSRWhyNot: nil, dlssThroughMetalFX: false, anvilFrameGen: false, inGame: [])
        switch path {
        case .d3dMetal:
            plan.anvilFSR = true
        case .moltenVK:
            plan.anvilFSRWhyNot = "its frames come through MoltenVK, which FSR to the display doesn't take yet"
        case .wineOpenGL:
            plan.anvilFSRWhyNot = "Wine draws it with OpenGL, outside the Metal layer FSR works on"
        case .unknown:
            plan.anvilFSRWhyNot = "what draws it is only known once it runs"
            plan.anvilFSR = true       // tried; the library says in play whether it ran
        }
        plan.anvilFrameGen = plan.anvilFSR || path == .unknown

        let has = { (k: Builtin.Kind) in builtins.contains { $0.kind == k } }
        if has(.dlss) {
            if metalFX && path == .d3dMetal && antiCheat.isEmpty {
                plan.dlssThroughMetalFX = true
                plan.inGame.append("Choose DLSS in the game's graphics settings: Anvil has it run as Apple's MetalFX upscaler, from the game's own motion vectors — the kind of upscaling FSR 3 does. Quality or Balanced looks best.")
                if has(.dlssFrameGen) {
                    plan.inGame.append("Its DLSS frame generation runs as MetalFX frame interpolation, with the game's motion vectors too. With it on in the game, switch Anvil's frame generation off for this game.")
                }
            } else if !antiCheat.isEmpty {
                plan.inGame.append("It has DLSS, but with anti-cheat Anvil adds nothing to its setup — DLSS stays unavailable on a Mac.")
            } else if path == .d3dMetal {
                plan.inGame.append("It has DLSS. Apple's DLSS-to-MetalFX translation is in D3DMetal 3.0 (Mythic Engine 3.0): on that engine, DLSS in the game runs as MetalFX, from the game's own motion vectors.")
            }
        }
        if let fsr = builtins.first(where: { [.fsr2, .fsr3, .fsr31, .fsr4].contains($0.kind) }) {
            if fsr.kind == .fsr4 {
                plan.inGame.append("It has FSR 4, which needs a Radeon RX 9000 graphics card; choose FSR 3.1 or 2 in the game if it offers them.")
            } else {
                plan.inGame.append("Choose \(fsr.kind.name) in the game's graphics settings: it is AMD's own temporal upscaling, from the game's motion vectors, and runs on any GPU. Anvil's FSR still takes the result to the display's \(pixels.count == 2 ? "\(pixels[0]) × \(pixels[1])" : "pixels").")
            }
            if has(.fsrFrameGen) {
                plan.inGame.append("Its FSR frame generation can be tried in the game; with it on, switch Anvil's frame generation off for this game.")
            }
        }
        if has(.xess) && !plan.dlssThroughMetalFX {
            plan.inGame.append("XeSS in the game runs on any GPU too, if it offers no FSR.")
        }
        if builtins.contains(where: { $0.kind == .fsr1 }) && !builtins.contains(where: { $0.kind.temporal }) {
            plan.inGame.append("Its own FSR 1 option can stay off: Anvil's runs at the display's full pixels, after the game.")
        }

        return GraphicsScan(api: analysis.primary?.title,
                            engine: analysis.engine == .other ? "its own engine" : analysis.engine.title,
                            is64Bit: analysis.is64Bit, builtins: builtins, antiCheat: antiCheat,
                            engineName: runtime.displayName, d3dMetal: runtime.d3dMetalVersion, path: path,
                            metalFXForDLSS: metalFX, displayPixels: pixels, displayHz: hz,
                            plan: plan, scannedAt: Date(), live: nil)
    }

    /// How a game with this API reaches the screen with this graphics setting.
    nonisolated static func path(api: GameAnalysis.API?, backend: GraphicsBackend, is64Bit: Bool = true, runtime: Runtime) -> Path {
        guard let api else { return .unknown }
        // What the engines hold (DXVKSetup): D3DMetal's 64-bit d3d10, d3d11, d3d12 and dxgi whatever
        // the setting, Wine's own 32-bit ones and d3d9 on OpenGL, and DXVK for macOS with d3d10core,
        // d3d11 and dxgi in both sizes.
        let effective = DXVKSetup.effective(chosen: backend, api: api, is64Bit: is64Bit, runtime: runtime).backend
        switch api {
        case .vulkan: return .moltenVK
        case .opengl, .d3d9: return .wineOpenGL
        case .d3d10, .d3d11, .d3d12:
            if effective == .dxvk { return .moltenVK }
            if !is64Bit { return api == .d3d12 ? .moltenVK : .wineOpenGL }   // Wine's own: vkd3d, WineD3D
            return runtime.hasD3DMetal ? .d3dMetal : .wineOpenGL
        }
    }

    /// The main display's pixels and top refresh rate.
    nonisolated static func display() -> ([Int], Int) {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return ([], 0) }
        let hz = Int(DisplayProfile.maxHz.rounded())
        return ([mode.pixelWidth, mode.pixelHeight], hz > 0 ? hz : Int(mode.refreshRate.rounded()))
    }

    // MARK: Built-in upscalers

    /// File names that give each one away, lowercased.
    private static let fileMarkers: [(String, Builtin.Kind)] = [
        ("nvngx_dlssg", .dlssFrameGen), ("sl.dlss_g", .dlssFrameGen),
        ("nvngx_dlss", .dlss), ("sl.dlss", .dlss),
        ("libxess_fg", .xessFrameGen), ("libxess", .xess),
        ("amd_fidelityfx_upscaler", .fsr4), ("amd_fidelityfx_framegeneration", .fsrFrameGen),
        ("amd_fidelityfx_dx12", .fsr31), ("amd_fidelityfx_vk", .fsr31),
        ("ffx_frameinterpolation", .fsrFrameGen),
        ("ffx_fsr3upscaler", .fsr3), ("ffx_fsr3", .fsr3),
        ("ffx_fsr2", .fsr2),
    ]

    /// Strings a game's own program carries when an upscaler is built into it — Unreal's
    /// console settings among them, which it keeps as UTF-16.
    private static let programMarkers: [(String, Builtin.Kind)] = [
        ("r.FidelityFX.FSR4", .fsr4), ("r.FidelityFX.FSR3.Enabled", .fsr31), ("r.FidelityFX.FI.Enabled", .fsrFrameGen),
        ("r.FidelityFX.FSR2.Enabled", .fsr2), ("r.NGX.DLSS.Enable", .dlss), ("r.Streamline.DLSSG.Enable", .dlssFrameGen),
        ("r.XeSS.Enabled", .xess),
        ("ffxFsr3ContextCreate", .fsr3), ("ffxFsr3UpscalerContextCreate", .fsr3), ("ffxFsr2ContextCreate", .fsr2),
        ("FsrEasuCon", .fsr1), ("FidelityFX Super Resolution 1", .fsr1),
    ]

    /// The libraries in a game's install folder whose names give an upscaler away, nearest the
    /// program first and then by name — a fixed order, so the same folder gives the same answer
    /// however the disk lists it.
    nonisolated static func upscalerLibraries(in root: URL) -> [(url: URL, relative: String, kind: Builtin.Kind)] {
        var hits: [(url: URL, relative: String, kind: Builtin.Kind)] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 40_000 { break }
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".dll"), let kind = fileMarkers.first(where: { name.hasPrefix($0.0) })?.1 else { continue }
            let relative = url.path.hasPrefix(root.path) ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
            hits.append((url, relative, kind))
        }
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        return hits.sorted { depth($0.relative) != depth($1.relative) ? depth($0.relative) < depth($1.relative) : $0.relative < $1.relative }
    }

    nonisolated static func findBuiltins(executable: URL, engine: GameAnalysis.Engine) -> [Builtin] {
        var found: [Builtin.Kind: Builtin] = [:]
        let fm = FileManager.default
        // What the game ships, not what Anvil put beside it. LEGO Star Wars was scanned as having
        // "FSR 3.1 (FidelityFX SDK 1.0.1.41314)" — the FidelityFX payload Anvil had force-injected
        // — whenever that was in its folder, and as having nothing once Autopilot had taken it out.
        for library in upscalerLibraries(in: AntiCheat.installFolder(of: executable)) where found[library.kind] == nil {
            guard let own = UpscalerManager.gamesOwn(library.url) else { continue }
            found[library.kind] = Builtin(kind: library.kind, version: PEVersion.fileVersion(of: own), source: library.relative)
        }
        // The program itself, and Unity's or Unreal's engine library beside it.
        var programs = [executable]
        let unity = executable.deletingLastPathComponent().appendingPathComponent("UnityPlayer.dll")
        if fm.fileExists(atPath: unity.path) { programs.append(unity) }
        for program in programs {
            guard let data = try? Data(contentsOf: program, options: .mappedIfSafe) else { continue }
            for (marker, kind) in programMarkers where found[kind] == nil {
                if PEVersion.contains(data, marker) {
                    found[kind] = Builtin(kind: kind, version: nil, source: "the game's program")
                }
            }
        }
        // FSR 3.1's library supersedes the names an older FSR 3 left in the program.
        if found[.fsr31] != nil { found[.fsr3] = nil }
        if found[.fsr31] != nil || found[.fsr3] != nil { found[.fsr2] = nil }
        if found.keys.contains(where: { $0 != .fsr1 && $0.temporal }) { found[.fsr1] = nil }
        return Builtin.Kind.allCases.compactMap { found[$0] }
    }
}

// MARK: - Keeping it

extension GraphicsScan {
    /// Which build of the game on which engine a scan is of, and of what beside it: a new build,
    /// another engine, or upscaler libraries come or gone is scanned again.
    struct Key: Codable, Hashable {
        var path: String
        var size: Int
        var modified: Double
        var runtimeID: String
        var backend: String
        /// The upscaler libraries in the install folder, Unity's engine library and Anvil's
        /// injection record, each by name, size and date. Before 0.29 only the program was in
        /// the key, so a scan made while Anvil's injected FidelityFX was beside LEGO's program
        /// kept saying "FSR 3.1" after Autopilot had taken it out.
        var libraries: String?
        /// How the game was read (`GraphicsScan.reading`): a scan read the older way is made again.
        var reading: Int?

        /// The same build of the game on the same engine, whatever is beside it.
        func sameBuild(as other: Key) -> Bool {
            path == other.path && size == other.size && modified == other.modified
                && runtimeID == other.runtimeID && backend == other.backend
        }
    }

    /// 2 since 0.29: Anvil's own injected libraries aren't the game's.
    /// 3 since 0.39.0: what draws a game follows what the engines hold — DirectX 10 through D3DMetal,
    /// 32-bit DirectX 10 and 11 through DXVK (DXVKSetup).
    nonisolated static let reading = 3

    private struct Entry: Codable { var key: Key; var scan: GraphicsScan }

    nonisolated private static var url: URL { DiskCache.directory.appendingPathComponent("GraphicsScan.json") }
    nonisolated(unsafe) private static var memory: [String: Entry]?
    private static let lock = NSLock()

    /// Walks the install folder for its libraries, as the scan does: off the main thread.
    nonisolated static func key(executable: URL, runtimeID: String, backend: GraphicsBackend) -> Key? {
        let fm = FileManager.default
        guard let a = try? fm.attributesOfItem(atPath: executable.path) else { return nil }
        func stamp(_ url: URL, _ name: String) -> String? {
            guard let b = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            return "\(name) \((b[.size] as? NSNumber)?.intValue ?? 0) \(String(format: "%.3f", (b[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        }
        let folder = executable.deletingLastPathComponent()
        var stamps = upscalerLibraries(in: AntiCheat.installFolder(of: executable)).compactMap { stamp($0.url, $0.relative) }
        stamps += [stamp(folder.appendingPathComponent("UnityPlayer.dll"), "UnityPlayer.dll"),
                   stamp(folder.appendingPathComponent(".anvil-backup/anvil-injection.json"), ".anvil-backup/anvil-injection.json")]
            .compactMap { $0 }
        return Key(path: executable.path, size: (a[.size] as? NSNumber)?.intValue ?? 0,
                   modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                   runtimeID: runtimeID, backend: backend.rawValue,
                   libraries: stamps.joined(separator: "; "), reading: reading)
    }

    private nonisolated static func load() {
        if memory != nil { return }
        memory = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private nonisolated static func save() {
        guard let memory, let data = try? JSONEncoder().encode(memory) else { return }
        try? FileManager.default.createDirectory(at: DiskCache.directory, withIntermediateDirectories: true)
        DiskCache.writeReplacing(data, to: url)
    }

    /// The scan kept for a game, whatever build it was of.
    nonisolated static func stored(gameID: UUID) -> GraphicsScan? {
        lock.lock(); defer { lock.unlock() }
        load()
        return memory?[gameID.uuidString]?.scan
    }

    /// The scan of this build on this engine, if there is one.
    nonisolated static func current(gameID: UUID, key: Key) -> GraphicsScan? {
        lock.lock(); defer { lock.unlock() }
        load()
        guard let entry = memory?[gameID.uuidString], entry.key == key else { return nil }
        return entry.scan
    }

    nonisolated static func keep(_ scan: GraphicsScan, gameID: UUID, key: Key) {
        lock.lock(); defer { lock.unlock() }
        load()
        var scan = scan
        // What a session showed still holds for the same build on the same engine: kept when only
        // what is beside the game, or how it is read, changed.
        if scan.live == nil, let old = memory?[gameID.uuidString], old.key.sameBuild(as: key) {
            scan.live = old.scan.live
        }
        memory?[gameID.uuidString] = Entry(key: key, scan: scan)
        save()
    }

    nonisolated static func forget(gameID: UUID) {
        lock.lock(); defer { lock.unlock() }
        load()
        memory?[gameID.uuidString] = nil
        save()
    }

    /// The scan for a launch: the kept one when it is of this build and engine, otherwise a
    /// new one, said in the launch log. `fresh` is true for a new one.
    @MainActor
    static func forLaunch(game: Game, container: Container, runtime: Runtime) async -> (scan: GraphicsScan, fresh: Bool)? {
        let exe = game.executableURL, id = game.id
        let backend = game.backendOverride ?? container.backend
        return await Task.detached(priority: .userInitiated) { () -> (scan: GraphicsScan, fresh: Bool)? in
            guard let key = key(executable: exe, runtimeID: runtime.id, backend: backend) else { return nil }
            if let kept = current(gameID: id, key: key) { return (kept, false) }
            let s = GraphicsScan.scan(executable: exe, backend: backend, runtime: runtime)
            GraphicsScan.keep(s, gameID: id, key: key)
            return (s, true)
        }.value
    }

    /// Scan every game that has none for its current build, quietly, in the background — so
    /// a game's page shows its scan before its first start.
    @MainActor
    static func scanMissing() {
        let jobs: [(UUID, URL, GraphicsBackend, Runtime)] = Library.shared.games.compactMap { game in
            guard game.exists, let container = Library.shared.container(id: game.containerID),
                  let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) else { return nil }
            return (game.id, game.executableURL, game.backendOverride ?? container.backend, runtime)
        }
        Task.detached(priority: .background) {
            for (id, exe, backend, runtime) in jobs {
                guard let key = key(executable: exe, runtimeID: runtime.id, backend: backend),
                      current(gameID: id, key: key) == nil else { continue }
                keep(scan(executable: exe, backend: backend, runtime: runtime), gameID: id, key: key)
            }
            await MainActor.run { GraphicsScan.changed() }
        }
    }

    /// Scan one game again now, for its page.
    @MainActor
    static func rescan(_ game: Game) async {
        guard let container = Library.shared.container(id: game.containerID),
              let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) else { return }
        await rescan(game, container: container, runtime: runtime)
    }

    /// The same, in a given setup on a given engine.
    @MainActor
    static func rescan(_ game: Game, container: Container, runtime: Runtime) async {
        let exe = game.executableURL, id = game.id
        let backend = game.backendOverride ?? container.backend
        let live = stored(gameID: id)?.live
        let scanned = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let key = key(executable: exe, runtimeID: runtime.id, backend: backend) else { return false }
            var s = scan(executable: exe, backend: backend, runtime: runtime)
            s.live = live
            keep(s, gameID: id, key: key)
            return true
        }.value
        guard scanned else { return }
        AnvilLog.write("graphics scan: \(game.title) scanned again — \(stored(gameID: id)?.summary ?? "?")")
        changed()
    }

    @MainActor static func changed() {
        NotificationCenter.default.post(name: .graphicsScanChanged, object: nil)
    }
}

extension Notification.Name {
    static let graphicsScanChanged = Notification.Name("AnvilGraphicsScanChanged")
}

// MARK: - What the first session showed

extension GraphicsScan {
    /// Read a session's game.log lines into what was seen in play.
    nonisolated static func live(from lines: [Substring], at date: Date) -> Live? {
        var live = Live(at: date, drawnBy: [], gameSize: nil, shownSize: nil, pixelFormat: nil, fsrRan: false,
                        fsrWhyNot: nil, generated: 0, shown: 0, guardCorrections: 0)
        var any = false
        let sizer = "graphics: ", draws = "FSR to the display: the game draws "
        let off = "FSR to the display: off for this session — ", notFor = "FSR to the display: not for this game's frames ("
        for line in lines {
            guard let at = line.range(of: "[anvil] ") else { continue }
            let text = line[at.upperBound...]
            if text.hasPrefix(sizer), let sets = text.range(of: " sets a layer to ") {
                let name = String(text[text.index(text.startIndex, offsetBy: sizer.count)..<sets.lowerBound])
                if !live.drawnBy.contains(name) { live.drawnBy.append(name) }
                any = true
            } else if text.hasPrefix(draws), let semi = text.range(of: "; Anvil upscales it to the display's ") {
                live.fsrRan = true
                live.fsrWhyNot = nil
                live.gameSize = String(text[text.index(text.startIndex, offsetBy: draws.count)..<semi.lowerBound])
                live.shownSize = text[semi.upperBound...].split(separator: " ").first.map(String.init)
                any = true
            } else if text.hasPrefix(off) {
                let why = text.dropFirst(off.count)
                live.fsrWhyNot = String(why.split(separator: ";").first ?? why)
                any = true
            } else if text.hasPrefix(notFor), let close = text.firstIndex(of: ")") {
                if !live.fsrRan {
                    live.fsrWhyNot = String(text[text.index(text.startIndex, offsetBy: notFor.count)..<close])
                }
                any = true
            } else if text.hasPrefix("drawable "), let f = text.range(of: "format=") {
                live.pixelFormat = Int(text[f.upperBound...].prefix { $0.isNumber })
            } else if text.hasPrefix("metal guard: ") {
                live.guardCorrections += 1
            }
            // "| generated N of M shown" — the stats line's own count, last one wins.
            if let g = line.range(of: "| generated "), let of = line.range(of: " of ", range: g.upperBound..<line.endIndex),
               let generated = Int(line[g.upperBound..<of.lowerBound]),
               let shown = Int(line[of.upperBound...].prefix { $0.isNumber }) {
                live.generated = generated
                live.shown = shown
            }
        }
        return any ? live : nil
    }

    /// After a session: what it showed, kept with the game's scan. Only a session with
    /// something to say replaces what an earlier one said.
    nonisolated static func confirm(gameID: UUID, evidence: SessionEvidence) {
        guard let seen = live(from: evidence.gameLines, at: evidence.startedAt ?? Date()) else { return }
        lock.lock()
        load()
        if var entry = memory?[gameID.uuidString] {
            entry.scan.live = seen
            memory?[gameID.uuidString] = entry
            save()
        }
        lock.unlock()
    }

    /// The first session's findings, in words, for the game's page.
    var liveText: String? {
        guard let live else { return nil }
        var parts: [String] = []
        if live.fsrRan, let g = live.gameSize, let s = live.shownSize {
            parts.append("FSR ran: the game drew \(g.replacingOccurrences(of: "x", with: " × ")), shown at \(s.replacingOccurrences(of: "x", with: " × "))")
        } else if let why = live.fsrWhyNot {
            parts.append("FSR didn't run: \(why)")
        } else {
            parts.append("FSR didn't run")
        }
        if live.generated > 0 {
            parts.append("\(live.generated.formatted()) frames generated of \(live.shown.formatted()) shown")
        }
        let drawers = live.drawnBy.filter { !$0.lowercased().contains("winemac") }
        if !drawers.isEmpty { parts.append("drawn by \(drawers.joined(separator: ", "))") }
        if live.guardCorrections > 0 {
            parts.append("Anvil put right \(live.guardCorrections) invalid graphics state\(live.guardCorrections == 1 ? "" : "s") Metal would have stopped the game over")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reading Windows libraries

/// The version Windows shows for a DLL, from its version resource.
enum PEVersion {
    /// "3.7.10" from VS_FIXEDFILEINFO's file version, trailing zero dropped.
    static func fileVersion(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 64 else { return nil }
        let signature: [UInt8] = [0xBD, 0x04, 0xEF, 0xFE]
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            guard let hit = memmem(base, raw.count, signature, signature.count) else { return nil }
            let offset = base.distance(to: UnsafeRawPointer(hit))
            guard offset + 16 <= raw.count else { return nil }
            func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset + o, as: UInt32.self).littleEndian }
            let ms = u32(8), ls = u32(12)
            var parts = [ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF].map(Int.init)
            guard parts.contains(where: { $0 != 0 }) else { return nil }
            while parts.count > 2, parts.last == 0 { parts.removeLast() }
            return parts.map(String.init).joined(separator: ".")
        }
    }

    /// Whether a program carries a string, as ASCII or as Windows' UTF-16.
    static func contains(_ data: Data, _ needle: String) -> Bool {
        let ascii = Array(needle.utf8)
        var wide: [UInt8] = []
        for b in ascii { wide.append(b); wide.append(0) }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return memmem(base, raw.count, ascii, ascii.count) != nil || memmem(base, raw.count, wide, wide.count) != nil
        }
    }
}
