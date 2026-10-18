import Foundation

// MARK: - Graphics

enum GraphicsBackend: String, Codable, CaseIterable, Identifiable {
    case d3dmetal   // Apple's D3D11/12 -> Metal translation
    case dxvk       // D3D9/10/11 -> Vulkan -> MoltenVK -> Metal
    case wined3d    // D3D -> OpenGL, last resort
    var id: String { rawValue }

    var title: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        }
    }

    // What the engines actually hold (DXVKSetup): D3DMetal's DirectX 10, 11 and 12, Wine's own
    // DirectX 9 on OpenGL, and DXVK for macOS with DirectX 11 only.
    var subtitle: String {
        switch self {
        case .d3dmetal: "Apple's DirectX 10, 11 and 12 → Metal. The fastest path, and the only one for DirectX 12. DirectX 9 games are drawn by Wine's own renderer."
        case .dxvk: "DirectX 11 → Vulkan → MoltenVK → Metal, for a DirectX 11 game that doesn't look right on D3DMetal. Other games stay on D3DMetal. Anvil's FSR can't reach it."
        case .wined3d: "Wine's own renderer on OpenGL, for DirectX 9. These engines draw DirectX 10–12 with D3DMetal either way."
        }
    }

    var supportedAPIs: [String] {
        switch self {
        case .d3dmetal: ["DirectX 10", "DirectX 11", "DirectX 12"]
        case .dxvk: ["DirectX 11"]
        case .wined3d: ["DirectX 9"]
        }
    }
}

enum SyncPrimitive: String, Codable, CaseIterable, Identifiable {
    case msync, esync, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .msync: "MSync"
        case .esync: "ESync"
        case .none: "Off (wineserver)"
        }
    }
    var subtitle: String {
        switch self {
        case .msync: "Mach-port synchronisation. Fastest on Apple silicon; the default."
        case .esync: "eventfd-based. Fallback when a title deadlocks under MSync."
        case .none: "Every sync object round-trips through wineserver. Slowest."
        }
    }
}

enum WindowsVersion: String, Codable, CaseIterable, Identifiable {
    case win11, win10, win81, win7, winxp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        case .winxp: "Windows XP"
        }
    }
    var wineValue: String { rawValue }
}

enum ScalingMode: String, Codable, CaseIterable, Identifiable {
    case retina      // full backing-store resolution, sharpest
    case native      // 1:1 with the display's point size
    case custom      // explicit resolution
    var id: String { rawValue }
    var title: String {
        switch self {
        case .retina: "Retina (full resolution)"
        case .native: "Native (1× points)"
        case .custom: "Custom resolution"
        }
    }
}

// MARK: - HUD

/// Individual Metal Performance HUD widgets, so the overlay can show only FPS
/// instead of the whole wall of numbers.
enum HUDWidget: String, Codable, CaseIterable, Identifiable {
    case fps, frameInterval, frameIntervalGraph, gpuTime, cpuTime
    case memory, resourceCount, presentMode, deviceInfo, thermal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fps: "Frames per second"
        case .frameInterval: "Frame time (ms)"
        case .frameIntervalGraph: "Frame time graph"
        case .gpuTime: "GPU time"
        case .cpuTime: "CPU time"
        case .memory: "Memory in use"
        case .resourceCount: "Resource count"
        case .presentMode: "Present mode / VSync"
        case .deviceInfo: "GPU & driver info"
        case .thermal: "Thermal pressure"
        }
    }

    /// Element name understood by the Metal HUD's element-order list.
    var hudElement: String {
        switch self {
        case .fps: "fps"
        case .frameInterval: "frame-interval"
        case .frameIntervalGraph: "frame-interval-graph"
        case .gpuTime: "gpu-time"
        case .cpuTime: "cpu-time"
        case .memory: "memory"
        case .resourceCount: "resource-count"
        case .presentMode: "present-mode"
        case .deviceInfo: "device-info"
        case .thermal: "thermal-state"
        }
    }
}

struct HUDConfig: Codable, Hashable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var v = HUDConfig()
        v.enabled = c.value("enabled", v.enabled)
        // A widget name from a newer build is dropped rather than failing the file.
        if let names: [String] = c.optional("widgets") {
            v.widgets = Set(names.compactMap(HUDWidget.init(rawValue:)))
        }
        v.opacity = c.value("opacity", v.opacity)
        v.scale = c.value("scale", v.scale)
        v.position = c.value("position", v.position)
        self = v
    }
    init(enabled: Bool = false, widgets: Set<HUDWidget> = [.fps],
         opacity: Double = 0.8, scale: Double = 1.0, position: String = "top-left") {
        self.enabled = enabled; self.widgets = widgets
        self.opacity = opacity; self.scale = scale; self.position = position
    }

    var enabled: Bool = false
    var widgets: Set<HUDWidget> = [.fps]
    var opacity: Double = 0.8
    var scale: Double = 1.0
    var position: String = "top-left"   // top-left | top-right | bottom-left | bottom-right

    static let fpsOnly = HUDConfig(enabled: true, widgets: [.fps])
    static let full = HUDConfig(enabled: true, widgets: Set(HUDWidget.allCases))
}

// MARK: - Container

/// A Wine prefix plus every knob Anvil turns when launching into it.
struct Container: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var runtimeID: String
    var createdAt: Date = Date()

    // Graphics
    var backend: GraphicsBackend = .d3dmetal
    var dxvkAsync: Bool = true
    var metalHUDInherit: Bool = true
    var scaling: ScalingMode = .retina
    var customWidth: Int = 2560
    var customHeight: Int = 1440
    var dpi: Int = 192
    var fullscreen: Bool = true
    var tripleBuffering: Bool = true
    var vsync: Bool = false
    var metalFXUpscaling: Bool = false

    /// D3DMetal's DXR support. Off by default: a DirectX 12 title that finds ray
    /// tracing available will use it, and on this translation layer that is the most
    /// expensive thing it can do.
    var raytracing: Bool = false

    /// Mip-selection bias handed to D3DMetal. Negative is sharper. This is what keeps
    /// textures crisp when the frame is rendered below native and sharpened back up,
    /// instead of the whole image going soft together.
    var lodBias: Double = 0

    /// Keep D3DMetal's compiled-shader cache outside `/var/folders`, where macOS
    /// purges it. See `ShaderCacheManager`.
    var protectShaderCache: Bool = true

    /// Hold every frame to the display's own refresh grid.
    ///
    /// This is what makes a frame rate *stable* rather than merely high. A game
    /// presenting whenever it finishes lands between refreshes: at 67 fps on a 120 Hz
    /// panel a frame arrives every 1.79 refreshes, so gaps alternate between one
    /// refresh and two. The average reads 120 and it looks like stutter.
    var lockToRefresh: Bool = true

    /// Keep one frame in flight instead of two while the game fills every refresh.
    ///
    /// Off by default because it was measured and lost. On Cat Quest II at 3024x1964
    /// the game missed 79 and 10 of ~600 refreshes with one frame in flight, and the
    /// latency was no better — 16.8–20.0 ms against 16.3–16.4 ms with two — so every
    /// session began with five seconds of stutter for nothing. It stays available for
    /// games with more headroom. Renamed from `lowLatency` so containers that saved
    /// the old default of on pick up the new default instead.
    var lowLatencyQueue: Bool = false

    /// Let a Unity game write its own Player.log. Off by default, because of what it
    /// costs under Wine 7.7: every controller report reaches the game as a raw-input
    /// message whose data is empty, and Unity rejects each one by walking the stack
    /// and writing about 26 lines to that log, on the main thread. Measured: up to
    /// ~1,100 controller events a second while the sticks move, and a 32-second
    /// session that logged 2,004 rejections while the game fell below 30 fps.
    /// Unity's own -nolog option turns the log off. On only for troubleshooting.
    var keepGameLog: Bool = false

    /// Frames per second to hold to. 0 shows every frame as it is ready, up to the
    /// display's own rate. 80 is Steady: the display's rate while the game can hold it,
    /// an even 80 while it can't (ProMotion only; elsewhere it follows the display).
    var targetFPS: Int = 80

    // CPU / scheduling
    var sync: SyncPrimitive = .msync
    var avx2: Bool = true
    var rosettaAOT: Bool = true          // persist Rosetta's translated-code cache
    var cpuCoreLimit: Int = 0            // 0 = all cores
    /// Run the game's threads at interactive priority. This existed from early on and
    /// was never read by anything; it now drives ANVIL_THREAD_QOS.
    var highPriority: Bool = true
    /// Run the game through Anvil's copy of the engine that tells macOS it is a game,
    /// so Game Mode turns on. See GameModeEngine.
    var gameMode: Bool = true

    // Memory
    var videoMemoryMB: Int = 0           // 0 = auto from recommendedMaxWorkingSetSize
    var heapReserveMB: Int = 0           // 0 = Wine default
    var largeAddressAware: Bool = true

    // Windows environment
    var windowsVersion: WindowsVersion = .win11
    var dpiAware: Bool = true
    var enableGamepad: Bool = true
    /// Milliseconds Wine's controller loop is allowed to wait between polls.
    /// Wine asks SDL for 10; the pad reports every 4.
    var controllerPollMs: Int = 1
    /// Most stick updates per axis per second that reach the game. The pad produces up
    /// to ~1,100 events a second; under Wine each becomes a message the game must
    /// handle before it can draw, and it stopped drawing when they came faster than
    /// it could. 125 is one update per frame at 120 fps. Buttons are never limited.
    var controllerAxisHz: Int = 125

    // Overlay
    var hud: HUDConfig = HUDConfig(enabled: true, widgets: [.fps])

    // Shader caching — the single biggest lever against traversal stutter.
    var persistentShaderCache: Bool = true

    /// Presentation-queue depth. CAMetalLayer defaults to 3, meaning a finished
    /// frame can wait two whole frame intervals before it is shown. 2 trades a
    /// little throughput headroom for a frame of latency.
    /// Three, not two. Two drawables is the lower-latency choice, but it leaves no
    /// slack: a single frame that runs long has nothing queued behind it and the
    /// display repeats, which reads as a stutter. Three costs one frame of latency
    /// and a little memory, and absorbs the spikes.
    var profile: PerformanceProfile = .balanced
    var maxQueuedFrames: Int = 3
    var measureLatency: Bool = false
    var pacing: Bool = true

    /// Total memory this game may use, in MB. 0 means no budget.
    /// See `MemoryBudget` for what "may" means here — macOS grants no hard cap.
    var memoryBudgetMB: Int = 0

    var metal: Metal4Config = Metal4Config()
    var upscaler: UpscalerConfig = UpscalerConfig()
    var controllerProfile: ControllerProfile = ControllerProfile()
    var activePreset: PresetKind = .balanced

    var extraEnvironment: [String: String] = [:]

    /// A newer engine being tried: which one to go back to if a game won't start on it.
    /// Set when Anvil switches the engine; ended after three good sessions.
    var engineTrial: EngineTrial?
    /// Engines tried here that a game wouldn't start on, crashed on, or ran slower on.
    /// Autopilot doesn't offer them again; choosing one by hand still works.
    var rejectedEngines: [String] = []
    /// How fully Anvil supported each rejected engine's kind when it was rejected (see
    /// EngineProfile.supportLevel). Once Anvil supports that kind better, the engine gets one
    /// more measured trial.
    var rejectedAtSupport: [String: Int]?
    /// The other app's Wine setup this container was copied from (its drive_c), when it
    /// was — so a second program from the same bottle joins it instead of copying again.
    var sourceSetup: String?
    /// The storefront client this container was made for — "steam" or "epic" — by the
    /// Stores page or the first-run setup.
    var storefront: String?

    // Trackpad and keyboard, for playing on a MacBook — written to Wine's Mac driver
    // (Prefix.applyInput). Optional so libraries from before 0.22 read as the defaults.
    /// Scroll in whole mouse-wheel steps. Wine otherwise hands a game the trackpad's fine,
    /// smooth scrolling as fractions of a wheel step, which many Windows games read as
    /// nothing at all or as a flood of steps. On unless turned off.
    var scrollInSteps: Bool?
    /// The left Option key is Alt, as on a Windows keyboard; the right one still types
    /// accented letters. On unless turned off.
    var optionIsAlt: Bool?
    /// Both Command keys are Ctrl — far easier to reach on a laptop than Control. Off unless
    /// turned on — with it on, ⌘Q reaches the game as Ctrl+Q — except in a container that holds
    /// a store's app (`holdsStoreApp`): there ⌘V has to paste into its sign-in.
    var commandIsCtrl: Bool?

    /// Steam or Epic's own launcher is installed here. Their sign-in windows are Windows text
    /// boxes: with ⌘ as the Windows key, ⌘V pasted nothing, or a "v", and Steam answered every
    /// pasted password with “Please check your password and account name” (8–9 October).
    var holdsStoreApp: Bool {
        let fm = FileManager.default
        return ["Program Files (x86)/Steam/steam.exe", "Program Files/Steam/steam.exe",
                "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                "Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"]
            .contains { fm.fileExists(atPath: driveC.appendingPathComponent($0).path) }
    }

    /// Whether the ⌘ keys are Ctrl: as chosen, else on where a store's app is installed.
    var commandKeysAreCtrl: Bool { commandIsCtrl ?? holdsStoreApp }

    /// A store's own window (Steam's) drawn at full Retina resolution rather than the
    /// display's point size. Off unless turned on: see Prefix.setWindowScale.
    var storeWindowSharp: Bool?
    var storeWindowSmooth: Bool { !(storeWindowSharp ?? false) }

    /// Not offered by Autopilot again here — until Anvil's support for its kind improves.
    /// `byPlayer`: switched back by hand, which Autopilot respects for good.
    /// `atSupport`: the support it lost under, when that was an older Anvil's.
    mutating func reject(_ runtimeID: String, byPlayer: Bool = false, atSupport: Int? = nil) {
        if !rejectedEngines.contains(runtimeID) { rejectedEngines.append(runtimeID) }
        let level = byPlayer ? Int.max : (atSupport ?? EngineProfile.supportLevel(ofManaged: runtimeID))
        var levels = rejectedAtSupport ?? [:]
        levels[runtimeID] = level
        rejectedAtSupport = levels
    }

    /// Whether Autopilot may try this engine here: never rejected, or rejected when Anvil
    /// supported its kind less well than it does now.
    func mayTry(_ runtime: Runtime) -> Bool {
        guard rejectedEngines.contains(runtime.id) else { return true }
        return EngineProfile.of(runtime).supportLevel > (rejectedAtSupport?[runtime.id] ?? 1)
    }

    var prefixURL: URL {
        RuntimeManager.containersDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    var driveC: URL { prefixURL.appendingPathComponent("drive_c", isDirectory: true) }

    var shaderCacheURL: URL {
        RuntimeManager.shaderCacheDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The performance preset Anvil applies to a brand-new container on this Mac.
    static func performanceDefault(name: String, runtimeID: String) -> Container {
        var c = Container(name: name, runtimeID: runtimeID)
        let sys = SystemInfo.current
        c.videoMemoryMB = min(sys.recommendedVRAMMB, sys.maxAssignableMemoryMB)
        c.cpuCoreLimit = 0
        c.hud = HUDConfig(enabled: false, widgets: [.fps])
        c.lodBias = -0.5    // pairs with Anvil's sharpening pass
        c.lockToRefresh = true
        return c
    }
}


/// An engine switch on probation. The container's prefix was snapshotted first; a game
/// that exits straight away on the new engine, or crashes on it, sends the container
/// back to the old one by itself.
struct EngineTrial: Codable, Hashable {
    var fromRuntimeID: String
    var toRuntimeID: String
    var startedAt: Date = Date()
    /// Sessions that ran properly on the new engine.
    var goodSessions: Int = 0
    /// How the game ran on the old engine, with the setup it will run with next.
    var before: Baseline?
    /// Whether a session long enough to compare has been played on the new engine.
    var judged: Bool = false
    /// Switched by Autopilot rather than by hand.
    var byAutopilot: Bool = false

    struct Baseline: Codable, Hashable {
        /// Typical frames per second, as displayed.
        var fps: Double
        var shareAt80: Double
        var minutes: Double
    }

    static let sessionsToKeep = 3
    /// Play on the new engine needed before it is compared with the old one.
    static let minutesToJudge = 3.0

    /// Clearly slower: both the typical rate and the time at 80 well below the old
    /// engine's. Scenes differ from session to session, so anything closer is kept.
    static func isClearlySlower(fps: Double, shareAt80: Double, than before: Baseline) -> Bool {
        fps < before.fps * 0.92 && shareAt80 < before.shareAt80 - 0.10
    }

    /// Whether the new engine stays. Not when it is clearly slower; and when the switch
    /// costs the game something it was using on the old engine — the Switch Pro mode a
    /// Nintendo-style pad gets on Wine 7.7 — only when it is clearly faster as well. On
    /// 1 October Engine 3.0 was kept for LEGO Star Wars at 83 fps typical against 95, as
    /// smooth at 80 but with the PowerA pad back to an Xbox-style pad.
    static func keeps(fps: Double, shareAt80: Double, than before: Baseline, losesFeatures: Bool) -> Bool {
        if isClearlySlower(fps: fps, shareAt80: shareAt80, than: before) { return false }
        guard losesFeatures else { return true }
        return fps >= before.fps * 1.05 || shareAt80 >= before.shareAt80 + 0.05
    }
}
