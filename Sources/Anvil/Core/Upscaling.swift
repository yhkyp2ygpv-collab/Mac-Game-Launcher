import Foundation

/// How a game gets upscaled.
///
/// AMD's own FSR 2/3 temporal passes take per-pixel motion vectors and a depth buffer from
/// the game's engine, which only a game built for them hands over — the two "only if" modes.
/// FSR 3 for every game (0.29) is Anvil's own temporal FSR: it measures the motion from the
/// game's finished frames instead, so it needs nothing from the engine and runs in any game
/// whose frames D3DMetal presents.
enum UpscalerMode: String, Codable, CaseIterable, Identifiable {
    case off
    case metalFX          // Apple's spatial upscaler, no game support needed
    case fsr1             // FSR 1 EASU+RCAS injected post-frame, no game support needed
    case fsr3Every        // Anvil's temporal FSR 3: motion measured from the frames, any game
    case fsr3Native       // game already ships FSR 2/3; swap in a newer DLL
    case fsr3Translated   // game ships DLSS/XeSS; route those calls into FSR 3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off (native rendering)"
        case .metalFX: "MetalFX — built in"
        case .fsr1: "FSR 1 — built in"
        case .fsr3Every: "FSR 3 — every game (recommended)"
        case .fsr3Native: "FSR 3 temporal — only if the game already has FSR"
        case .fsr3Translated: "FSR 3 temporal — only if the game has DLSS or XeSS"
        }
    }

    /// True when the mode works with nothing downloaded. Everything Anvil does by
    /// default is in this group; the FSR 3 modes are the only ones that ever need a
    /// file, and they are opt-in.
    var isBuiltIn: Bool {
        switch self {
        case .off, .metalFX, .fsr1, .fsr3Every: true
        case .fsr3Native, .fsr3Translated: false
        }
    }

    var detail: String {
        switch self {
        case .off:
            "Renders at full resolution. Sharpest, slowest."
        case .metalFX:
            "Apple's spatial upscaler, applied by the translation layer. Works in any game and needs nothing from it."
        case .fsr1:
            "AMD's own FSR 1 shaders, compiled into Anvil from the FidelityFX SDK — nothing to download and nothing to point at. Each frame is upscaled to the display on its own (EASU), then sharpened (RCAS). Works in every game, because it needs nothing from the engine."
        case .fsr3Every:
            "Anvil's FSR 3, in any game. Like AMD's FSR 3 it is temporal: each frame is blended with the ones before it, moved along their motion, so edges that shimmer and crawl settle down — and, with frame generation, it fills the display with frames made from that same motion. AMD's needs the game's own motion vectors; Anvil measures the motion from the game's frames instead, to a fraction of a pixel, and holds the blend to what each frame shows, so a wrong measurement falls back to the frame rather than smearing. Each frame is upscaled with AMD's EASU and sharpened with RCAS on the way. Graphics Prep compiles it for this Mac's GPU and tests it at the game's own sizes before its first start, against FSR 1 and a supersampled picture: it is used where it came out better, and FSR 1 where it didn't."
        case .fsr3Native:
            "Only useful when the game already ships FSR: Anvil swaps in a newer runtime. FSR 3's temporal path takes motion vectors, depth and a jittered projection as required inputs, and a game without FSR support renders none of them — which is why bundling the shader cannot make this work everywhere. Use the built-in mode instead."
        case .fsr3Translated:
            "Only useful when the game ships DLSS or XeSS. Those APIs already supply motion vectors and depth, so their calls can be routed into FSR 3. Cat Quest II and most games have neither — use the built-in mode."
        }
    }

    /// Whether this mode can be forced on regardless of what the game supports.
    var requiresGameSupport: Bool {
        switch self {
        case .off, .metalFX, .fsr1, .fsr3Every: false
        case .fsr3Native, .fsr3Translated: true
        }
    }

    /// Anvil's FSR to the display runs in this mode: FSR 1 alone, or FSR 3 on top of it.
    var anvilFSR: Bool { self == .fsr1 || self == .fsr3Every }

    /// Frame generation no longer depends on the game.
    ///
    /// Anvil synthesises the intermediate frame from optical flow measured between
    /// the two real frames it already has, so it needs no motion vectors from the
    /// engine. That makes it available in titles with no upscaler support at all —
    /// which was the whole point.
    var supportsFrameGeneration: Bool { self != .off }
}

/// Standard FSR quality modes. The render scale is the whole performance story —
/// everything else is image quality.
enum UpscaleQuality: String, Codable, CaseIterable, Identifiable {
    case nativeAA, ultraQuality, quality, balanced, performance, ultraPerformance
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeAA: "Native AA"
        case .ultraQuality: "Ultra Quality"
        case .quality: "Quality"
        case .balanced: "Balanced"
        case .performance: "Performance"
        case .ultraPerformance: "Ultra Performance"
        }
    }

    /// Linear render scale per axis.
    var renderScale: Double {
        switch self {
        case .nativeAA: 1.0
        case .ultraQuality: 0.77
        case .quality: 0.667
        case .balanced: 0.588
        case .performance: 0.5
        case .ultraPerformance: 0.333
        }
    }

    /// Fraction of native pixels actually rendered — the number that drives frame rate.
    var pixelFraction: Double { renderScale * renderScale }

    var summary: String {
        switch self {
        case .nativeAA: "Full resolution, anti-aliasing only. No speed gain."
        case .ultraQuality: "Nearly indistinguishable from native."
        case .quality: "The usual choice. Small softening, large gain."
        case .balanced: "Visible softening in motion, bigger gain."
        case .performance: "Half resolution per axis. Clearly softer."
        case .ultraPerformance: "For rescuing an unplayable game, not for looking good."
        }
    }
}

/// What a specific game can actually accept, determined by looking at its files.
struct UpscalerCapability: Codable, Hashable {
    /// Key-by-key decoding so a file from another build stays readable. See
    /// `Tolerant.swift` for why this must live in the type and not an extension.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var v = UpscalerCapability()
        v.hasFSR = c.value("hasFSR", v.hasFSR)
        v.fsrVersionFound = c.optional("fsrVersionFound")
        v.hasDLSS = c.value("hasDLSS", v.hasDLSS)
        v.hasXeSS = c.value("hasXeSS", v.hasXeSS)
        v.scanned = c.value("scanned", v.scanned)
        self = v
    }
    init() {}

    var hasFSR: Bool = false
    var fsrVersionFound: String?
    var hasDLSS: Bool = false
    var hasXeSS: Bool = false
    var scanned: Bool = false

    var bestAvailableMode: UpscalerMode {
        if hasFSR { return .fsr3Native }
        if hasDLSS || hasXeSS { return .fsr3Translated }
        return .fsr3Every
    }

    /// Whether the game's own files give a mode something to hook into, as scanned. The modes
    /// that need nothing from the game always have it.
    func supports(_ mode: UpscalerMode) -> Bool {
        switch mode {
        case .fsr3Native: hasFSR
        case .fsr3Translated: hasDLSS || hasXeSS
        case .off, .metalFX, .fsr1, .fsr3Every: true
        }
    }

    var explanation: String {
        guard scanned else { return "Not scanned yet." }
        if hasFSR {
            let v = fsrVersionFound.map { " (found \($0))" } ?? ""
            return "This game integrates FSR\(v). Anvil can substitute a newer FSR 3.1 runtime for a better image at the same frame rate."
        }
        if hasDLSS || hasXeSS {
            let which = hasDLSS ? "DLSS" : "XeSS"
            return "This game integrates \(which) but not FSR. Because \(which) already supplies motion vectors, its calls can be translated into FSR 3 — you get real temporal upscaling here."
        }
        return "This game has no upscaler of its own, so AMD's FSR 3 has no motion vectors from it to work with. Anvil's FSR 3 for every game measures the motion from the game's frames instead, and works here."
    }
}

/// Per-game upscaler settings.
struct UpscalerConfig: Codable, Hashable {
    /// Key-by-key decoding. A game saved before `flowDivisor` existed used to fail
    /// the entire library file; now the missing key simply takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var v = UpscalerConfig()
        v.mode = c.value("mode", v.mode)
        v.quality = c.value("quality", v.quality)
        v.sharpness = c.value("sharpness", v.sharpness)
        v.frameGeneration = c.value("frameGeneration", v.frameGeneration)
        v.capability = c.value("capability", v.capability)
        v.useMetalFXFrameGen = c.value("useMetalFXFrameGen", v.useMetalFXFrameGen)
        v.interpolationScale = c.value("interpolationScale", v.interpolationScale)
        v.flowDivisor = c.value("flowDivisor", v.flowDivisor)
        v.forceInjection = c.value("forceInjection", v.forceInjection)
        v.fsrToDisplay = c.value("fsrToDisplay", v.fsrToDisplay)
        v.sharpTextures = c.value("sharpTextures", v.sharpTextures)
        v.smoothMotion = c.value("smoothMotion", v.smoothMotion)
        v.guardian = c.value("guardian", v.guardian)
        v.lowLatencyAtLowFPS = c.value("lowLatencyAtLowFPS", v.lowLatencyAtLowFPS)
        v.injectedPayloadID = c.optional("injectedPayloadID")
        self = v
    }
    init() {}

    var mode: UpscalerMode = .off
    var quality: UpscaleQuality = .quality
    var sharpness: Double = 0.5           // FSR RCAS strength
    var frameGeneration: Bool = false
    var capability: UpscalerCapability = UpscalerCapability()

    /// Inject the payload whether or not the capability scan found support.
    /// The scan then describes what actually happened rather than blocking the attempt.
    /// Use Apple's MTLFXFrameInterpolator, driven by Anvil's optical flow, instead
    /// of Anvil's own interpolation pass.
    /// How the synthesised frame is produced.
    ///
    /// Projected predicts forward from the two frames already shown: correct
    /// ordering, nothing held back, no added latency. Interpolated uses MetalFX to
    /// build the midpoint between them, which is a better image but can only be
    /// shown in order if the real frame is delayed — a whole frame of latency.
    var useMetalFXFrameGen: Bool = false

    /// Resolution the interpolator runs at, as a fraction of the drawable. Half is
    /// the default: full resolution costs 12.27 ms at 3024×1964 against 4.35 ms at
    /// half, for a frame that is on screen for about eight milliseconds.
    var interpolationScale: Double = 0.5

    /// Coarseness of the motion field. Cost falls with the square of this, since it
    /// is one threadgroup per vector: 2.19 ms at 4, 0.73 ms at 8.
    var flowDivisor: Int = 8

    var forceInjection: Bool = false
    var injectedPayloadID: String?

    /// AMD FSR 1 draws the final picture at the display's own resolution, in any game: the
    /// game draws at its window's size as before, and EASU then RCAS — rather than macOS's
    /// bilinear stretch — take it to the panel's pixels. See anvil_inject.mm, "FSR to the
    /// display". On by default; measured at 1.47 ms a frame at 3024x1964 on an M4.
    var fsrToDisplay: Bool = true

    /// Textures as sharp as the display's own size would make them, while FSR upscales: the
    /// game's filtered, mipmapped textures sampled a mip level sharper (log2 of drawn ÷ shown,
    /// −1 at half size) with 8× anisotropic filtering, as AMD's FSR guidance asks (libanvil's
    /// anvil_gpuwork.mm, ANVIL_LOD_BIAS and ANVIL_ANISOTROPY). On by default.
    var sharpTextures: Bool = true

    /// Smooth Motion, with frame generation on: in a heavy scene (the game at 15 fps of its own up to half the
    /// display's rate — 60 on a 120 Hz ProMotion panel, 30 on a 60 Hz display), a frame made between each two of
    /// the game's, from both, shown halfway — 30 fps of the game's is 60 on the screen. With FSR 3 to the display;
    /// otherwise, on a variable-refresh display, frames guessed ahead, from 24 fps. libanvil's genDecide and
    /// presenter (ANVIL_SMOOTH_MOTION). On by default.
    var smoothMotion: Bool = true

    /// Guardian (see Guardian.swift): checks every few seconds while a game plays that what Anvil does is
    /// working, and learns where Smooth Motion pays for itself on this Mac. On by default.
    var guardian: Bool = true

    /// Lower latency at a low frame rate: where the GPU sets a game's pace below 55 fps, its next frame is started
    /// only as the GPU is about to finish the last, so it's made from the controls then (libanvil's jitHold,
    /// ANVIL_JIT). Measured on Anvil's stand-in at 18–19 fps: 15–25% less from a frame's start to the screen (10–12%
    /// with Smooth Motion), 7–12% fewer frames of the game's own. Off by default.
    var lowLatencyAtLowFPS: Bool = false

    /// Frame generation as one choice: off, projected forward (no frame held back), or
    /// Apple's MetalFX interpolation (a better frame, one frame later).
    enum FrameGenChoice: String, CaseIterable, Identifiable {
        case off, lowLatency, smoothest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .lowLatency: "On — lowest latency"
            case .smoothest: "On — smoothest (MetalFX)"
            }
        }
    }

    var frameGenChoice: FrameGenChoice {
        get { !frameGeneration ? .off : (useMetalFXFrameGen ? .smoothest : .lowLatency) }
        set {
            frameGeneration = newValue != .off
            useMetalFXFrameGen = newValue == .smoothest
        }
    }

    /// Frame generation roughly doubles presented frames but does not reduce input
    /// latency — it is deliberately reported separately from real rendered frames.
    ///
    /// The mode a launch uses. One the game's files don't support runs as FSR 3 for every game,
    /// as the Upscaling page says it will. Before 0.29 that held only for a game never scanned:
    /// one scanned without FSR, DLSS or XeSS launched set up for an upscaler that wasn't there.
    var effectiveMode: UpscalerMode {
        if forceInjection { return mode }
        if mode.requiresGameSupport && !(capability.scanned && capability.supports(mode)) { return .fsr3Every }
        return mode
    }
}

// MARK: - Runtime management

/// How an injected payload gets the game to load it.
///
/// A game only loads a DLL it asks for by name. So injection works by supplying a
/// library the game already loads — dxgi, d3d11, winmm — which forwards every call
/// on to the real system one and takes the opportunity to install itself in the
/// swapchain on the way past. This is the same mechanism every upscaler mod uses.
enum InjectionVector: String, Codable, CaseIterable, Identifiable {
    case dxgi, d3d11, d3d12, winmm, version, dinput8, none
    var id: String { rawValue }

    var proxyFilename: String? {
        switch self {
        case .none: nil
        default: rawValue + ".dll"
        }
    }

    var title: String {
        switch self {
        case .dxgi: "dxgi.dll (most reliable for D3D11/12)"
        case .d3d11: "d3d11.dll"
        case .d3d12: "d3d12.dll"
        case .winmm: "winmm.dll (loads early)"
        case .version: "version.dll (loads earliest)"
        case .dinput8: "dinput8.dll"
        case .none: "None — game loads it natively"
        }
    }
}

enum PayloadKind: String, Codable, CaseIterable, Identifiable {
    case fidelityFX      // AMD's own FSR SDK libraries
    case optiScaler      // upscaler translation shim
    case xess            // Intel XeSS
    case dlssEnabler
    case other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fidelityFX: "AMD FidelityFX (FSR)"
        case .optiScaler: "OptiScaler / upscaler shim"
        case .xess: "Intel XeSS"
        case .dlssEnabler: "DLSS enabler"
        case .other: "Other upscaler"
        }
    }
}

/// An upscaler payload (a set of DLLs) that Anvil can install into a game.
struct FSRRuntime: Identifiable, Codable, Hashable {
    var id: String
    var version: String           // read from the files supplied, not hardcoded
    var installedAt: Date
    var libraryNames: [String]
    var kind: PayloadKind = .fidelityFX
    var vector: InjectionVector = .none
    var configFileNames: [String] = []

    var root: URL {
        UpscalerManager.runtimesDir.appendingPathComponent(id, isDirectory: true)
    }

    /// Semantic comparison so "3.1.10" sorts above "3.1.5" rather than below it.
    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

@MainActor
final class UpscalerManager: ObservableObject {
    @Published private(set) var runtimes: [FSRRuntime] = []
    @Published var status: String?

    static let shared = UpscalerManager()

    nonisolated static var runtimesDir: URL {
        RuntimeManager.support.appendingPathComponent("FSR", isDirectory: true)
    }
    private var indexURL: URL { Self.runtimesDir.appendingPathComponent("index.json") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.runtimesDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([FSRRuntime].self, from: data) {
            runtimes = list
        }
    }

    /// Highest version Anvil holds, which is what a game gets unless pinned.
    var latest: FSRRuntime? {
        runtimes.max { FSRRuntime.newer($1.version, than: $0.version) }
    }

    // MARK: Detection

    private static let fsrMarkers = ["ffx_fsr", "amd_fidelityfx", "ffx_backend", "amdxcffx", "ffx_frameinterpolation"]
    private static let dlssMarkers = ["nvngx_dlss", "nvngx.dll", "_nvngx"]
    private static let xessMarkers = ["libxess", "libxell"]

    /// Look at what the game actually ships. This is the only reliable way to know
    /// which tier applies — a title list would be wrong the week it was written.
    ///
    /// What the game ships, not what Anvil put beside it: the FidelityFX payload force-injected
    /// into LEGO Star Wars' folder made it "integrate FSR" here, as it did in the Graphics Scan
    /// before 0.29. A library Anvil injected counts only as the game's original it set aside, if
    /// there is one, and the version is read from that.
    func scan(gameAt executablePath: String) -> UpscalerCapability {
        var cap = UpscalerCapability()
        cap.scanned = true

        let root = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return cap }

        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 40_000 { break }        // don't walk a 200 GB install forever
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".dll") || name.hasSuffix(".so") else { continue }

            let fsr = Self.fsrMarkers.contains { name.contains($0) }
            let dlss = Self.dlssMarkers.contains { name.contains($0) }
            let xess = Self.xessMarkers.contains { name.contains($0) }
            guard fsr || dlss || xess, let own = Self.gamesOwn(url) else { continue }
            if fsr {
                cap.hasFSR = true
                if cap.fsrVersionFound == nil {
                    cap.fsrVersionFound = Self.readVersion(from: own) ?? Self.versionFromName(name)
                }
            }
            if dlss { cap.hasDLSS = true }
            if xess { cap.hasXeSS = true }
        }
        return cap
    }

    /// Pull a dotted version out of a PE file's embedded strings. Crude, but it reads
    /// the real binary rather than trusting a filename.
    private static func readVersion(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024) else { return nil }
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let pattern = #"FSR[_ ]?(\d+\.\d+(\.\d+)?)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func versionFromName(_ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(\d+\.\d+(\.\d+)?)"#),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return String(name[r])
    }

    // MARK: Deep payload scanning

    /// What a folder actually contains, after walking all of it.
    struct PayloadScan {
        var libraries: [URL] = []          // injectable, already-compiled DLLs
        var configs: [URL] = []
        var sourceFiles: Int = 0           // .cpp/.h/.hlsl — an SDK, not a payload
        var archives: [URL] = []           // zips the user hasn't unpacked
        var kind: PayloadKind = .other
        var vector: InjectionVector = .none
        var version: String?
        var is32Bit = false

        var isInjectable: Bool { !libraries.isEmpty }

        /// The one thing the user needs to read.
        var verdict: String {
            if isInjectable {
                var s = "Found \(libraries.count) ready-to-inject librar\(libraries.count == 1 ? "y" : "ies")"
                if let v = version { s += " · version \(v)" }
                if let proxy = vector.proxyFilename { s += " · loads via \(proxy)" }
                if !configs.isEmpty { s += " · \(configs.count) config file\(configs.count == 1 ? "" : "s")" }
                return s + "."
            }
            if sourceFiles > 200 {
                return """
                    This is the FidelityFX SDK source, not a payload. It's \(sourceFiles) source files that                     have to be compiled on Windows with Visual Studio to produce the DLLs — there is nothing                     here Anvil can inject. Download a prebuilt upscaler shim instead (OptiScaler and similar                     ship an already-compiled DLL with FSR inside, plus the .ini it needs).
                    """
            }
            if !archives.isEmpty {
                return "Found \(archives.count) archive\(archives.count == 1 ? "" : "s") but no libraries. Unpack the .zip first, then point Anvil at the unpacked folder."
            }
            return "No compiled .dll files anywhere in that folder."
        }
    }

    /// Libraries an upscaler SDK bundles for its samples that are never part of the
    /// runtime, and that a game may well ship its own copy of.
    static let sdkSupportLibraries: Set<String> = [
        "amd_ags_x64.dll", "amd_ags_arm64.dll", "amd_acs_x64.dll", "amd_acs_arm64.dll",
        "d3d12core.dll", "d3d12sdklayers.dll", "dxcompiler.dll", "dxil.dll",
        "winpixeventruntime.dll", "winpixgpucapturer.dll", "renderdoc.dll",
    ]

    /// Walk a folder — however deeply nested — and work out what is in it.
    ///
    /// Release zips are laid out inconsistently: DLLs at the top, or under `bin/`, or
    /// under `x64/release/`. Requiring a flat folder would just make the user hunt, so
    /// Anvil goes and finds them.
    func scanPayloadFolder(_ folder: URL) -> PayloadScan {
        var scan = PayloadScan()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder,
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return scan }

        var names: [String] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 60_000 { break }
            let name = url.lastPathComponent.lowercased()
            let ext = url.pathExtension.lowercased()

            switch ext {
            case "dll":
                // A 32-bit build in a folder of 64-bit ones is a common trap.
                if url.path.lowercased().contains("x86") || url.path.lowercased().contains("win32") {
                    scan.is32Bit = true
                    continue
                }
                // An SDK folder carries the libraries its samples need — AMD's GPU
                // services, the D3D12 runtime, the shader compiler, PIX, RenderDoc.
                // They are not upscalers, and games ship their own copies: injecting
                // the FidelityFX SDK into LEGO Star Wars replaced the game's own
                // amd_ags_x64.dll, which it links against, with the SDK's.
                if Self.sdkSupportLibraries.contains(name) { continue }
                // The same file under several of the SDK's folders counts once.
                if names.contains(name) { continue }
                scan.libraries.append(url)
                names.append(name)
            case "ini", "cfg", "toml", "json":
                // Only configs sitting beside a library matter; ignore stray json.
                scan.configs.append(url)
            case "cpp", "h", "hpp", "hlsl", "c", "cmake":
                scan.sourceFiles += 1
            case "zip", "7z", "rar":
                scan.archives.append(url)
            default:
                break
            }
        }

        // Keep only configs that share a directory with a library, so an SDK's
        // hundreds of build files don't come along.
        let libDirs = Set(scan.libraries.map { $0.deletingLastPathComponent().path })
        scan.configs = scan.configs.filter { libDirs.contains($0.deletingLastPathComponent().path) }

        if names.contains(where: { $0.contains("optiscaler") }) { scan.kind = .optiScaler }
        else if names.contains(where: { $0.contains("libxess") }) { scan.kind = .xess }
        else if names.contains(where: { $0.contains("nvngx") }) { scan.kind = .dlssEnabler }
        else if names.contains(where: { $0.contains("ffx") || $0.contains("fidelityfx") }) { scan.kind = .fidelityFX }

        scan.vector = InjectionVector.allCases.first { v in
            guard let proxy = v.proxyFilename else { return false }
            return names.contains(proxy)
        } ?? .none

        scan.version = scan.libraries.compactMap { Self.readVersion(from: $0) }.first
            ?? names.compactMap { Self.versionFromName($0) }.first

        return scan
    }

    // MARK: Installing a runtime

    /// Register a folder of FidelityFX libraries the user supplied.
    ///
    /// Anvil ships no FSR binaries of its own — they are AMD's, under AMD's licence,
    /// and silently bundling or auto-downloading someone else's redistributable is
    /// how a launcher ends up shipping a backdoor. You point Anvil at them.
    @discardableResult
    func installRuntime(from folder: URL, version: String? = nil) throws -> FSRRuntime {
        let fm = FileManager.default
        let scan = scanPayloadFolder(folder)
        guard scan.isInjectable else { throw UpscalerError.notAPayload(scan.verdict) }

        let resolved = version ?? scan.version ?? "unknown"
        let runtime = FSRRuntime(id: "\(scan.kind.rawValue)-\(resolved)",
                                 version: resolved,
                                 installedAt: Date(),
                                 libraryNames: scan.libraries.map(\.lastPathComponent),
                                 kind: scan.kind,
                                 vector: scan.vector,
                                 configFileNames: scan.configs.map(\.lastPathComponent))

        // Flatten into one directory: whatever nesting the release used, a game
        // needs these files sitting next to its executable.
        try? fm.removeItem(at: runtime.root)
        try fm.createDirectory(at: runtime.root, withIntermediateDirectories: true)
        for file in scan.libraries + scan.configs {
            let dest = runtime.root.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }
            try fm.copyItem(at: file, to: dest)
        }

        runtimes.removeAll { $0.id == runtime.id }
        runtimes.append(runtime)
        persist()
        return runtime
    }

    func remove(_ runtime: FSRRuntime) {
        try? FileManager.default.removeItem(at: runtime.root)
        runtimes.removeAll { $0.id == runtime.id }
        persist()
    }

    /// Nothing of Anvil's goes into the folder of a game with anti-cheat. Removing files Anvil
    /// put there before is still allowed — that only puts the game's own back.
    nonisolated static func refuseAntiCheatGame(at executablePath: String) throws {
        let kinds = AntiCheat.detect(forExecutable: URL(fileURLWithPath: executablePath))
        if !kinds.isEmpty { throw UpscalerError.antiCheat(kinds) }
    }

    /// Put a newer FSR runtime into a game's folder, keeping the originals.
    ///
    /// Every file replaced is first moved aside to `.anvil-backup`, so uninstalling
    /// restores exactly what the game shipped. Anvil never overwrites a game file it
    /// cannot put back.
    func install(_ runtime: FSRRuntime, intoGameAt executablePath: String) throws {
        try Self.refuseAntiCheatGame(at: executablePath)
        let fm = FileManager.default
        let gameDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let backupDir = gameDir.appendingPathComponent(".anvil-backup", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        for name in runtime.libraryNames {
            let source = runtime.root.appendingPathComponent(name)
            let target = gameDir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                let backup = backupDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: backup.path) {
                    try fm.copyItem(at: target, to: backup)
                }
                try fm.removeItem(at: target)
            }
            do { try fm.copyItem(at: source, to: target) }
            catch {
                // The game is never left without its file.
                let backup = backupDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: backup, to: target) }
                throw error
            }
        }
    }

    /// Install a payload into a game **regardless of what the game supports**, using a
    /// proxy library the game already loads.
    ///
    /// Anvil does not gate this on the capability scan. What the scan changes is the
    /// result, not the permission: with motion vectors present the payload can run its
    /// temporal path, and without them it falls back to its spatial path. Anvil reports
    /// which one engaged after the first launch rather than deciding for you.
    func forceInject(_ payload: FSRRuntime, intoGameAt executablePath: String) throws -> InjectionReport {
        try Self.refuseAntiCheatGame(at: executablePath)
        let fm = FileManager.default
        let gameDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let backupDir = gameDir.appendingPathComponent(".anvil-backup", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        var copied: [String] = []
        var replaced: [String] = []

        // Once per name, and never an SDK support library, whatever an older payload
        // record lists. Listing a name twice made the second copy back up the first —
        // Anvil's own file — as if it were the game's.
        var seen = Set<String>()
        for name in payload.libraryNames + payload.configFileNames
        where seen.insert(name.lowercased()).inserted && !Self.sdkSupportLibraries.contains(name.lowercased()) {
            let source = payload.root.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = gameDir.appendingPathComponent(name)

            if fm.fileExists(atPath: target.path) {
                let backup = backupDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: backup.path) {
                    try fm.copyItem(at: target, to: backup)
                }
                try fm.removeItem(at: target)
                replaced.append(name)
            }
            do { try fm.copyItem(at: source, to: target) }
            catch {
                let backup = backupDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: backup, to: target) }
                throw error
            }
            copied.append(name)
        }

        // Record what was done so uninstall is exact even months later.
        let manifest = InjectionManifest(payloadID: payload.id,
                                         version: payload.version,
                                         vector: payload.vector,
                                         copied: copied,
                                         replaced: replaced,
                                         installedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(manifest).write(to: backupDir.appendingPathComponent("anvil-injection.json"))

        return InjectionReport(
            copied: copied,
            replaced: replaced,
            vector: payload.vector,
            dllOverrides: Self.overrides(for: payload))
    }

    /// A proxy library must be loaded as *native* — Wine's builtin dxgi would win
    /// otherwise and the payload would never be reached.
    static func overrides(for payload: FSRRuntime) -> String? {
        guard let proxy = payload.vector.proxyFilename else { return nil }
        return proxy.replacingOccurrences(of: ".dll", with: "") + "=n,b"
    }

    struct InjectionReport {
        var copied: [String]
        var replaced: [String]
        var vector: InjectionVector
        var dllOverrides: String?

        var summary: String {
            var s = "Injected \(copied.count) file\(copied.count == 1 ? "" : "s")"
            if !replaced.isEmpty { s += ", \(replaced.count) backed up first" }
            if let proxy = vector.proxyFilename { s += ", loading via \(proxy)" }
            return s + "."
        }
    }

    struct InjectionManifest: Codable {
        var payloadID: String
        var version: String
        var vector: InjectionVector
        var copied: [String]
        var replaced: [String]
        var installedAt: Date
    }

    /// Read back what was injected into a game, if anything.
    func injectionManifest(forGameAt executablePath: String) -> InjectionManifest? {
        let url = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".anvil-backup/anvil-injection.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InjectionManifest.self, from: data)
    }

    /// Remove an injection exactly, using the manifest written at install time.
    func removeInjection(fromGameAt executablePath: String) throws {
        let fm = FileManager.default
        let gameDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let backupDir = gameDir.appendingPathComponent(".anvil-backup", isDirectory: true)
        guard let manifest = injectionManifest(forGameAt: executablePath) else {
            throw UpscalerError.nothingInjected
        }
        // A backup is the game's own file unless it is a copy of what Anvil put there.
        // An injection repeated over an earlier one backs up the earlier one's files, and
        // its manifest no longer says which names the game never had: Cat Quest II's
        // backups were all the SDK's, byte for byte and with the SDK's dates, and
        // counting names would have put every one of them back into its folder. So the
        // test is the file itself — the same contents and the same modification date
        // as the injected copy beside it. A game's own copy of a redistributable carries
        // its install date, not the SDK's.
        let replacedNames = Set(manifest.replaced)
        var ownBackups: [String] = []
        for name in replacedNames {
            let backup = backupDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: backup.path) else { continue }
            if Self.isCopy(backup, of: gameDir.appendingPathComponent(name)) {
                try? fm.removeItem(at: backup)
            } else {
                ownBackups.append(name)
            }
        }
        // Only Anvil's own copies come out. A game updated since the injection may have put
        // a newer file of its own under the same name: that one stays, and the older backup
        // of it goes to the Trash rather than over it — putting it back would leave the game
        // with one file from before its update.
        let payloadRoot = runtimes.first { $0.id == manifest.payloadID }?.root
        var replacedByGame = Set<String>()
        for name in Set(manifest.copied) {
            let target = gameDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: target.path) else { continue }
            if let payloadRoot, fm.fileExists(atPath: payloadRoot.appendingPathComponent(name).path),
               !fm.contentsEqual(atPath: payloadRoot.appendingPathComponent(name).path, andPath: target.path) {
                replacedByGame.insert(name)
                continue
            }
            try? fm.removeItem(at: target)
        }
        for name in ownBackups {
            let backup = backupDir.appendingPathComponent(name)
            if replacedByGame.contains(name) {
                try? fm.trashItem(at: backup, resultingItemURL: nil)
            } else {
                try? fm.moveItem(at: backup, to: gameDir.appendingPathComponent(name))
            }
        }
        if !replacedByGame.isEmpty {
            AnvilLog.write("upscaler: \(replacedByGame.sorted().joined(separator: ", ")) in \(gameDir.lastPathComponent) were updated by the game since — left as they are")
        }
        try? fm.removeItem(at: backupDir.appendingPathComponent("anvil-injection.json"))
        // The folder goes too once nothing of the game's is left in it.
        if let rest = try? fm.contentsOfDirectory(atPath: backupDir.path), rest.allSatisfy({ $0.hasPrefix(".") }) {
            try? fm.removeItem(at: backupDir)
        }
    }

    /// The same file: equal size, modification date and contents.
    nonisolated static func isCopy(_ a: URL, of b: URL) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a.path), let y = try? fm.attributesOfItem(atPath: b.path),
              (x[.size] as? Int) == (y[.size] as? Int),
              let dx = x[.modificationDate] as? Date, let dy = y[.modificationDate] as? Date,
              abs(dx.timeIntervalSince(dy)) < 2 else { return false }
        return fm.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// The game's own copy of a library in its folder: the file itself, unless an injection put
    /// it there and it is still Anvil's copy — then the game's original that the injection set
    /// aside under the same name, or nil when the game had none. Told from the injection's record
    /// and the file, never from the bytes alone: a game may ship AMD's library unchanged, byte
    /// for byte the payload's.
    nonisolated static func gamesOwn(_ file: URL) -> URL? {
        let fm = FileManager.default
        let name = file.lastPathComponent
        let backupDir = file.deletingLastPathComponent().appendingPathComponent(".anvil-backup", isDirectory: true)
        guard let data = try? Data(contentsOf: backupDir.appendingPathComponent("anvil-injection.json")),
              let manifest = try? JSONDecoder().decode(InjectionManifest.self, from: data),
              manifest.copied.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return file }
        // Still Anvil's: the payload's bytes, or — that payload no longer in Anvil — no newer than
        // the injection. A game that updates the file since writes a newer one (as removeInjection
        // leaves such a file where it is).
        let ours = runtimesDir.appendingPathComponent(manifest.payloadID).appendingPathComponent(name)
        let stillOurs: Bool
        if fm.fileExists(atPath: ours.path) {
            stillOurs = fm.contentsEqual(atPath: ours.path, andPath: file.path)
        } else {
            let modified = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            stillOurs = modified.map { $0 <= manifest.installedAt.addingTimeInterval(2) } ?? false
        }
        guard stillOurs else { return file }
        let aside = backupDir.appendingPathComponent(name)
        return fm.fileExists(atPath: aside.path) && !isCopy(aside, of: file) ? aside : nil
    }

    /// Files Anvil injected into a game's folder for an upscaler that isn't in use — the
    /// game runs with them without calling them. Nil when there are none.
    nonisolated static func unusedInjection(for game: Game, config: UpscalerConfig) -> (files: Int, replacedOwn: [String])? {
        if config.effectiveMode == .fsr3Native || config.effectiveMode == .fsr3Translated { return nil }
        let gameDir = game.executableURL.deletingLastPathComponent()
        let backupDir = gameDir.appendingPathComponent(".anvil-backup", isDirectory: true)
        guard let data = try? Data(contentsOf: backupDir.appendingPathComponent("anvil-injection.json")),
              let manifest = try? JSONDecoder().decode(InjectionManifest.self, from: data) else { return nil }
        let present = Set(manifest.copied).filter { FileManager.default.fileExists(atPath: gameDir.appendingPathComponent($0).path) }
        let own = Set(manifest.replaced).filter { name in
            let backup = backupDir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: backup.path) && !isCopy(backup, of: gameDir.appendingPathComponent(name))
        }
        guard !present.isEmpty || !own.isEmpty else { return nil }
        return (present.count, own.sorted())
    }

    /// Undo an install, restoring the game's own libraries.
    func uninstall(fromGameAt executablePath: String, runtime: FSRRuntime) throws {
        let fm = FileManager.default
        let gameDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let backupDir = gameDir.appendingPathComponent(".anvil-backup", isDirectory: true)

        for name in runtime.libraryNames {
            let target = gameDir.appendingPathComponent(name)
            let backup = backupDir.appendingPathComponent(name)
            let ours = runtime.root.appendingPathComponent(name)
            // A file the game has replaced since is the game's: left alone.
            if fm.fileExists(atPath: ours.path), fm.fileExists(atPath: target.path),
               !fm.contentsEqual(atPath: ours.path, andPath: target.path) { continue }
            if fm.fileExists(atPath: backup.path) {
                // Swapped in one step, so the game is never without the file.
                _ = try fm.replaceItemAt(target, withItemAt: backup)
            } else {
                try? fm.removeItem(at: target)
            }
        }
    }

    // MARK: Launch environment

    func environment(for config: UpscalerConfig, container: Container) -> [String: String] {
        var env: [String: String] = [:]
        let mode = config.effectiveMode

        switch mode {
        case .off:
            env["ANVIL_UPSCALER"] = "off"

        case .metalFX:
            env["ANVIL_UPSCALER"] = "metalfx"
            env["DXMT_METALFX_SPATIAL"] = "1"
            env["MTL_FX_RENDER_SCALE"] = String(format: "%.3f", config.quality.renderScale)

        case .fsr1:
            // Anvil's own pass: FSR 1's sharpening on a frame rendered below the
            // display's size (ANVIL_RENDER_SCALE), done by libanvil at present.
            //
            // WINE_FULLSCREEN_FSR*, and DXVK_FSR*, used to be set here too. They are
            // Proton's and a patched DXVK's: no winemac.drv and no DXVK on this Mac reads
            // them — checked in Mythic Engine 2.6.1 and 3.0, Whisky 2.5 and both DXVK
            // builds — so every launch carried an "ultraperformance" mode that did nothing.
            env["ANVIL_UPSCALER"] = "fsr1"

        case .fsr3Every:
            // libanvil's own: ANVIL_FSR3 and ANVIL_OUTPUT are set where the frame pipeline is
            // (Launcher.environment), from Graphics Prep's test for the game.
            env["ANVIL_UPSCALER"] = "fsr3"

        case .fsr3Native, .fsr3Translated:
            env["ANVIL_UPSCALER"] = mode.rawValue
            env["FFX_FSR_QUALITY_MODE"] = config.quality.rawValue
            env["FFX_FSR_SHARPNESS"] = String(format: "%.2f", config.sharpness)
            env["FFX_FRAME_INTERPOLATION"] = config.frameGeneration ? "1" : "0"
            if config.forceInjection {
                env["ANVIL_FORCE_INJECT"] = "1"
                // Without motion vectors the payload's temporal path can't initialise,
                // so ask it to fall back rather than fail the device.
                env["FFX_ALLOW_SPATIAL_FALLBACK"] = "1"
                env["FFX_REQUIRE_MOTION_VECTORS"] = "0"
            }
            if mode == .fsr3Translated {
                // Let the translation shim take over the vendor upscaler's entry points.
                env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "")
                    + "nvngx,_nvngx,libxess=n,b"
                env["ANVIL_UPSCALER_TRANSLATE"] = "1"
            }
        }
        return env
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(runtimes) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    enum UpscalerError: LocalizedError {
        case noLibrariesFound
        case notAPayload(String)
        case nothingInjected
        case antiCheat([AntiCheat])
        var errorDescription: String? {
            switch self {
            case .antiCheat(let kinds):
                return "This game uses \(kinds.map(\.name).joined(separator: " and ")). Anvil never puts files into the folder of a game with anti-cheat: a library that isn't the game's own is what anti-cheat looks for, and that can get an account banned. Use “FSR — built in”, which changes no files."
            case .noLibrariesFound:
                return "No .dll files in that folder. Point Anvil at the folder containing the upscaler's libraries."
            case .notAPayload(let why):
                return why
            case .nothingInjected:
                return "Anvil has nothing recorded as injected into this game."
            }
        }
    }
}
