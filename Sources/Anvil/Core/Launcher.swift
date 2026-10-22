import Foundation
import AppKit

/// Builds the exact process environment for a launch and runs it.
///
/// Everything Anvil does for performance lands here as environment variables on a
/// `wine64` invocation — there is no hidden renderer. The value Anvil adds over
/// setting these by hand is choosing them correctly per title and keeping them
/// reproducible.
/// Lets only the first of several racing callers through (Launcher.firstOf).
final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

@MainActor
final class Launcher: ObservableObject {

    struct Session: Identifiable {
        let id = UUID()
        let game: Game
        let process: Process
        let startedAt: Date
        /// The system's awake time at the start. Play time is measured with this, not
        /// the clock: a Mac asleep with the game open is not being played — 22 of the
        /// 52 minutes of LEGO Star Wars on 29 September were sleep.
        let startedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        let container: Container
        let runtime: Runtime
        /// The container's own engine; `runtime` can be Anvil's Game Mode copy of it.
        var baseRuntime: Runtime
        /// Anvil's library was loaded into the game.
        var enhanced: Bool
        /// This is the one retry without Anvil's library after a failed start.
        var isRetry: Bool
        /// What any other Wine program started into this prefix while the game runs must
        /// share with it. Above all the sync mode: a process whose WINEMSYNC differs from
        /// the server's exits at once — "Server is running with WINEMSYNC but this
        /// process is not", in both engines' ntdll.
        var helperEnvironment: [String: String]
        /// Where Anvil's library keeps pictures of the game's screen this session (ScreenReader).
        var screens: URL?
    }

    @Published private(set) var sessions: [Session] = []
    /// Sessions the user has asked to close, so every Quit button can say “Closing…”
    /// and a game closed on purpose is not mistaken for one that failed to start.
    @Published private(set) var closing: Set<UUID> = []
    /// Sessions that are Offline Tests (OfflineTest): not play, nothing learned from them as play.
    @Published private(set) var offlineTests: Set<UUID> = []

    /// Everything the games and the launch steps print, for the Activity screen. An
    /// object of its own: as a property here, every line a game printed redrew every
    /// view with a Play button in it — the whole library grid, while the game ran.
    let output = LaunchOutput()

    /// What Anvil is doing between the Play button and the game appearing. A launch
    /// has real work in front of it — preparing the prefix, writing display settings,
    /// starting wine — and with nothing on screen to say so, a slow launch is
    /// indistinguishable from a broken one.
    @Published private(set) var launching: String?
    /// How long each game has taken to load before, for the Now Playing bar: a game that
    /// is still loading must not look stuck, and must be left in front to finish.
    @Published private(set) var loadEstimates: [UUID: LoadTime.Estimate] = [:]
    /// Games running with their own keep-running switch: they load behind other apps.
    @Published private(set) var runsBehind: Set<UUID> = []
    /// Games that have reached their first scene this session, and when.
    @Published private(set) var readyAt: [UUID: Date] = [:]
    /// The game being launched, from the moment its settings for this launch are chosen
    /// until it is running. Autopilot and Auto-Tune leave a game alone in that window:
    /// on 1 October Auto-Tune was started four seconds into a launch whose settings were
    /// already chosen, so the six minutes played were never counted.
    private(set) var launchingGameID: UUID?

    static let shared = Launcher()
    private init() {
        // Which app is in front while a game runs. A game that loses focus stops
        // drawing and stops reading the controller, which looks exactly like lag.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard !Launcher.shared.sessions.isEmpty else { return }
                AnvilLog.write("focus: \(app?.localizedName ?? "?") came to the front"
                               + ((app?.bundleURL?.path.contains("GameModeEngines") ?? false)
                                  ? " (as \(app?.bundleIdentifier ?? "?"), bundle \(app?.bundleURL?.lastPathComponent ?? "?"))" : ""))
            }
        }
    }

    // MARK: Environment

    /// Resolve container + per-game overrides into the final variable set.
    /// Exposed so the UI can show the user exactly what will be applied.
    /// Whether Anvil's frame pipeline (libanvil) goes into the game. It is also what draws the
    /// overlay, so it is needed whenever any of its features are on — and the refresh lock and
    /// the one-frame queue live in it too: a condition that left those out made "Lock to the
    /// display's refresh" silently do nothing with upscaling, generation and the overlay off.
    nonisolated static func interceptorWanted(game: Game, container: Container) -> Bool {
        let upscaler = game.upscalerOverride ?? container.upscaler
        let overlayWanted = (game.hudOverride ?? container.hud).enabled
        return upscaler.mode != .off || upscaler.frameGeneration || upscaler.fsrToDisplay || overlayWanted
            || container.lockToRefresh
    }

    func environment(for game: Game, in container: Container, runtime: Runtime) -> [String: String] {
        var env: [String: String] = [:]
        let sys = SystemInfo.current

        env["WINEPREFIX"] = container.prefixURL.path
        env["WINEDEBUG"] = "-all"          // logging is the most common silent framerate tax
        env["WINEESYNC"] = "0"
        env["WINEMSYNC"] = "0"

        switch game.syncOverride ?? container.sync {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }

        // --- Graphics backend ---
        // As chosen, unless the game can't be drawn that way (DXVKSetup).
        let backend = DXVKSetup.backend(for: game, in: container, runtime: runtime)
        switch backend {
        case .d3dmetal:
            env["WINEDLLOVERRIDES"] = "d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=n,b"
            // Every D3DM_* variable below was read out of the D3DMetal binary in the
            // selected runtime, not guessed. Anvil previously set DXMT_METALFX_SPATIAL
            // here, which appears nowhere in D3DMetal and did nothing.
            //
            // Letting the translation layer submit from more than one thread is the
            // single largest D3DMetal win on a title that records command lists in
            // parallel, which is most DirectX 12 engines.
            env["D3DM_MULTITHREADED_INTERFACE_ENABLE"] = "1"
            // Ray tracing: D3DMetal's DXR, for a DirectX 12 game that has ray-traced effects to offer. On by
            // itself (0.51) where this Mac's GPU traces rays in hardware (M3 and later): the game then offers its
            // ray-traced reflections, shadows and lighting in its own settings, and uses them only where those turn
            // them on. Chosen per game, or by the container's profile (Best graphics) on an earlier Mac.
            let rayTracing = Self.rayTracing(for: game, container: container)
            env["D3DM_SUPPORT_DXR"] = rayTracing.on ? "1" : "0"
            if let line = rayTracing.line { AnvilLog.write("  " + line) }
            // D3DM_BOUNDS_CHECK and D3DM_LOD_BIAS are deliberately left alone.
            //
            // Both are switches in D3DMetal's shader converter, read with atoi and on
            // unless set to 0 — checked in the D3DMetal of Mythic Engine 2.6.1 and of
            // Whisky 2.5, where they become IRCompilerSetCompatibilityFlags bits.
            //
            // Bounds checking is what makes a translated shader behave as DirectX
            // promises: a read past the end of a buffer returns zero and a write past
            // it is dropped. Games rely on that. Anvil set it to 0 as a "debug aid",
            // so an out-of-range read returned whatever memory followed and a stray
            // write landed in another resource — corruption that comes and goes with
            // how full the buffers are, which is heaviest in fights and cutscenes.
            //
            // D3DM_LOD_BIAS is not a bias. It switches support for the sampler LOD
            // bias the game itself sets; Anvil wrote its slider value there, so
            // "-0.50" parsed as 0 and turned the game's own bias off.
            //
            // Multithreaded submission above matches D3DMetal's own default for every
            // game, listed or not, so setting it changes nothing.
        case .dxvk:
            // DXVK's own DLLs, put in the container before the start (DXVKSetup). d3d9 stays
            // Wine's: DXVK for macOS has none, and "native only" left DirectX 9 games with nothing.
            env["WINEDLLOVERRIDES"] = DXVKSetup.overrides
            env["DXVK_ASYNC"] = container.dxvkAsync ? "1" : "0"
            env["DXVK_STATE_CACHE"] = container.persistentShaderCache ? "1" : "0"
            env["DXVK_STATE_CACHE_PATH"] = container.shaderCacheURL.path
            env["DXVK_FRAME_RATE"] = "0"
        case .wined3d:
            env["WINEDLLOVERRIDES"] = "d3d9,d3d10core,d3d11,dxgi=b"
        }

        // --- Memory budget ---
        // Reported downward so the game sizes its own pools to it. This is the only
        // lever that actually shapes a game's appetite: macOS will not enforce a
        // per-process cap, so being told a smaller number is what makes a game ask
        // for less in the first place.
        if container.memoryBudgetMB > 0 {
            let mb = container.memoryBudgetMB
            // Read by Anvil's own injector, which is the only thing that honours it.
            // WINE_HEAP_LIMIT_MB and WINE_REPORTED_MEMORY_MB used to be set here and
            // appear nowhere in the Wine tree; they were doing nothing.
            env["ANVIL_MEMORY_BUDGET_MB"] = String(mb)
        }
        // Real, and it matters for 32-bit titles: without it a game is capped at 2 GB
        // of address space regardless of how much memory it is given.
        if container.largeAddressAware {
            env["WINE_LARGE_ADDRESS_AWARE"] = "1"
        }

        // --- Video memory budget ---
        let vram = game.videoMemoryOverrideMB ?? container.videoMemoryMB
        if vram > 0 && backend == .dxvk {
            // DXVK reads this one. D3DMetal has no video-memory variable at all —
            // it reports the unified pool — so the D3DM_VRAM_MB and WINE_VK_VRAM_MB
            // that used to be set here were inert.
            let clamped = min(vram, sys.maxAssignableMemoryMB)
            env["DXVK_MEMORY_LIMIT"] = String(clamped)
        }

        // --- CPU ---
        env["ROSETTA_ADVERTISE_AVX"] = container.avx2 ? "1" : "0"
        if container.rosettaAOT {
            // Persisting translated code removes the first-run JIT hitching that reads
            // as "stutter" on launch and on first entry to a new area.
            env["ROSETTA_AOT_CACHE_ENABLED"] = "1"
            env["ROSETTA_AOT_CACHE_PATH"] = container.shaderCacheURL.appendingPathComponent("rosetta").path
        }
        // WINE_CPU_TOPOLOGY is a Proton variable, not a Wine one, and this build has
        // no equivalent — core count is left to the scheduler.

        // --- Metal / presentation ---
        // Of the MTL_* variables Anvil sets, MTL_HUD_ENABLED and MTL_SHADER_VALIDATION
        // are proven real — both appear in the D3DMetal binary. The rest could not be
        // verified either way: Metal lives in the dyld shared cache, and scanning it
        // finds none of these names, including the two that are certainly real. They
        // are left set because an unread variable costs nothing, but nothing in the UI
        // claims they do something.
        env["MTL_CAPTURE_ENABLED"] = "0"
        env["MTL_SHADER_VALIDATION"] = "0"
        env["MTL_DEBUG_LAYER"] = "0"
        // D3DMetal's real shader cache is a directory under DARWIN_USER_CACHE_DIR,
        // not an environment variable, and macOS purges that directory on its own
        // schedule — which is why shader stutter returns in a game that had already
        // run smoothly. ShaderCacheManager keeps a copy outside the sweep and puts it
        // back before launch. See restore(executable:) on the launch path below.
        //
        // WINE_PRESENT_MODE, D3DM_TRIPLE_BUFFER and D3DM_SHADER_CACHE_SIZE_MB were
        // set here and exist in neither binary; presentation mode is decided by the
        // swapchain the game creates.

        // --- Scaling ---
        switch container.scaling {
        case .retina:
            // The real fix for a soft picture. A game window on a Retina display is
            // handed a drawable sized in *points*, so it renders at half resolution
            // and the compositor stretches it — measured as 1512x982 on a 3024x1964
            // screen. Anvil enlarges the drawable so the game renders every pixel.
            env["ANVIL_RENDER_SCALE"] = "2.0"
        case .native:
            break
        case .custom:
            break
        }
        // Retina mode and DPI are registry settings inside the prefix
        // (HKCU\Software\Wine\Mac Driver\RetinaMode and Control Panel\Desktop\
        // LogPixels), not environment variables. WINE_RETINA_MODE, WINEDPI and
        // WINE_RESOLUTION were set here and read by nothing. Prefix.prepare() writes
        // the real keys, so the game's own resolution list now includes the HiDPI
        // modes instead of Anvil having to enlarge the drawable alone.

        // --- Overlay ---
        // Anvil draws its own, because Apple's Metal HUD reports everything it knows
        // and has no supported way to ask for less: choosing "FPS only" still
        // produced device name, Rosetta mode, memory and draw counts.
        let hud = game.hudOverride ?? container.hud
        if hud.enabled {
            // The frame rate, and the Mac running hot, Anvil's own counter shows: its plate turns red when the Mac
            // is hot. Until 0.59 "thermal" sent a game to Apple's HUD — on Game Porting Toolkit 3.0 its whole panel,
            // whatever was asked for, and at 2× it covered most of Hogwarts Legacy's screen (17 October).
            if hud.anvilDrawsIt {
                env["ANVIL_OVERLAY"] = "1"
                env["ANVIL_OVERLAY_SCALE"] = String(min(max(Int((3 * hud.scale).rounded()), 2), 9))
                env["ANVIL_OVERLAY_THERMAL"] = hud.widgets.contains(.thermal) ? "1" : "0"
                env["ANVIL_OVERLAY_CORNER"] = {
                    switch hud.position {
                    case "top-right": "1"
                    case "bottom-left": "2"
                    case "bottom-right": "3"
                    default: "0"
                    }
                }()
                env["MTL_HUD_ENABLED"] = "0"
            } else {
                // More than the frame rate was asked for, which only Apple's HUD
                // can supply — so it is used, wall of numbers and all.
                env["ANVIL_OVERLAY"] = "0"
                env.merge(hud.environment()) { _, new in new }
            }
        } else {
            env["ANVIL_OVERLAY"] = "0"
            env["MTL_HUD_ENABLED"] = "0"
        }

        // --- Runtime paths ---
        env["DYLD_FALLBACK_LIBRARY_PATH"] = [
            runtime.root.appendingPathComponent("lib").path,
            runtime.externalLibs.path,
            "/usr/lib"
        ].joined(separator: ":")
        if runtime.hasD3DMetal, backend == .d3dmetal {
            env["DYLD_FRAMEWORK_PATH"] = runtime.externalLibs.path
        }

        // --- Metal generation ---

        // --- Upscaling ---
        let upscaler = game.upscalerOverride ?? container.upscaler
        // The game's own upscaler and frame generation, as its settings file has them for this start (GameUpscaler).
        let ownUpscaler = GameUpscaler.inGame(game, in: container)
        // Its DLL overrides join the graphics backend's rather than replacing them: until 0.58.2 a game
        // FSR 3 reached through its own upscaler (Hogwarts Legacy) lost D3DMetal's "d3d11,dxgi…=n,b".
        var upscalerEnv = UpscalerManager.shared.environment(for: upscaler, container: container)
        if let theirs = upscalerEnv.removeValue(forKey: "WINEDLLOVERRIDES") {
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + theirs
        }
        env.merge(upscalerEnv) { _, new in new }

        // DLSS through Apple's MetalFX, for a game the graphics scan found DLSS in, once its
        // pieces are in place (prepareAndLaunch puts them there; see DLSSThroughMetalFX).
        if backend == .d3dmetal, game.dlssThroughMetalFX,
           GraphicsScan.stored(gameID: game.id)?.plan.dlssThroughMetalFX == true,
           let folder = DLSSThroughMetalFX.ready(container: container, runtime: runtime) {
            env["D3DM_ENABLE_METALFX"] = "1"
            env["WINEDLLPATH"] = folder.path
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + "nvngx=b"
        }

        // An injected proxy library must be loaded as native, or Wine's own builtin
        // wins the name and the payload is never reached.
        if upscaler.forceInjection,
           let id = upscaler.injectedPayloadID,
           let payload = UpscalerManager.shared.runtimes.first(where: { $0.id == id }),
           let override = UpscalerManager.overrides(for: payload) {
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + override
        }

        // Microsoft's Visual C++ Runtime ahead of Wine's own, in a container Anvil installed it into
        // (VCRuntime) — unless a game that ran before stopped starting with it there.
        if VCRuntime.loadsMicrosofts(container) {
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + VCRuntime.overrides
        }

        // --- Anvil's own frame pipeline ---
        // Injected into the game process, where it hooks presentDrawable: and runs
        // Anvil's Metal passes on the finished frame. Needs no cooperation from the
        // game and no third-party library.
        if Self.interceptorWanted(game: game, container: container),
           let resources = Bundle.main.resourceURL {
            let dylib = resources.appendingPathComponent("libanvil.dylib")
            let metallib = resources.appendingPathComponent("AnvilShaders.metallib")
            if FileManager.default.fileExists(atPath: dylib.path) {
                let existing = env["DYLD_INSERT_LIBRARIES"]
                env["DYLD_INSERT_LIBRARIES"] = existing.map { $0 + ":" + dylib.path } ?? dylib.path
                env["ANVIL_METALLIB"] = metallib.path
                // Where the interceptor writes its frame rate, 1% low, latency and
                // pacing decisions. Anvil never set this, so in a real launch every one
                // of those numbers went nowhere — the only runs that produced them were
                // test scripts that set it by hand. A file of its own rather than the
                // launch log: every Wine process appends to it, and appends from
                // several processes are only safe on a file they all open for append.
                env["ANVIL_LOG"] = Self.gameLogURL.path
                // Where the game reads its large data files, kept for the memory warm-up at its next start.
                env.merge(MemoryWarmup.environment(gameID: game.id, on: game.warmMemory)) { _, new in new }
                // Shipped beside the precompiled library. Used only if that library
                // is missing — which is what a build on Xcode 27 without the separate
                // Metal toolchain download produces.
                env["ANVIL_METAL_SOURCE"] = resources.appendingPathComponent("AnvilShaders.metal").path
                // The public edition's shaders, packed instead of as readable source.
                env["ANVIL_METAL_PACK"] = resources.appendingPathComponent("AnvilShaders.pack").path
                env["ANVIL_HOOK_ENABLED"] = "1"
                env["ANVIL_SHARPNESS"] = String(format: "%.2f", upscaler.sharpness)
                // Over a game's own temporal upscaler, half strength at most: DLSS, XeSS and FSR hand over a picture
                // already reconstructed, and RCAS at full strength on top of it is what made Hogwarts Legacy's edges
                // grainy (21 October).
                if let own = ownUpscaler, own.temporal, upscaler.sharpness > 0.5 {
                    env["ANVIL_SHARPNESS"] = "0.50"
                    AnvilLog.write(String(format: "  sharpening: %.0f%% over %@'s own %@ — half the %.0f%% set, so the picture isn't sharpened twice over",
                                          50.0, game.title, own.brand?.short ?? "upscaler", upscaler.sharpness * 100))
                }
                // Graphics Prep's work for this game: Anvil's pipelines ready-made for this Mac's
                // GPU, and FSR in one pass where that was measured quicker in its colour format.
                if let prep = GraphicsPrep.usable(gameID: game.id) {
                    if let archive = prep.archive { env["ANVIL_SHADER_ARCHIVE"] = archive.path }
                    if prep.onePass {
                        env["ANVIL_FSR_PASS"] = "fused"
                        env["ANVIL_FSR_TILE"] = prep.tile
                    }
                }
                // A profile owns the render scale outright. Composing scaling with a
                // quality mode let "native" and an upscaler multiply to below the
                // game's own resolution — 1512×982 became 889×577 on a 3024×1964
                // display — which is worse than doing nothing, and nothing in the UI
                // prevented it.
                if container.profile != .custom {
                    env["ANVIL_RENDER_SCALE"] = String(format: "%.3f", container.profile.renderScale())
                } else if upscaler.mode != .off {
                    let retina = container.scaling == .retina ? 2.0 : 1.0
                    env["ANVIL_RENDER_SCALE"] =
                        String(format: "%.3f", max(retina * upscaler.quality.renderScale, 1.0))
                }
                // FSR to the display: the final picture at the display's own pixels, through
                // AMD FSR 1, in any game whose frames D3DMetal presents.
                env["ANVIL_OUTPUT"] = upscaler.fsrToDisplay ? "1" : "0"
                // FSR 3 for every game: Anvil's temporal FSR on top of it — wherever the game is
                // upscaled, unless Graphics Prep's test at its sizes found FSR 1 better there; at
                // the display's own size, only where the test found it better.
                if upscaler.effectiveMode == .fsr3Every {
                    let verdict = GraphicsPrep.fsr3Verdict(gameID: game.id)
                    let use = verdict.use != false
                    let native = verdict.use == true && verdict.native
                    env["ANVIL_FSR3"] = use ? "1" : "0"
                    env["ANVIL_FSR3_NATIVE"] = native ? "1" : "0"
                    if use { env["ANVIL_OUTPUT"] = "1" }
                    // What it costs over FSR 1 here, so the budget that eases it to FSR 1 when the
                    // GPU can't hold an even 80 starts from this Mac's own measure.
                    if use, let extra = GraphicsPrep.fsr3ExtraMs(gameID: game.id) {
                        env["ANVIL_FSR3_EXTRA_MS"] = String(format: "%.2f", extra)
                    }
                    // A game smoothing its own edges over time hands over frames already blended:
                    // FSR 3 adds only a few more, so the two don't stack into a smear.
                    if use && GameTuning.smoothsItsOwnEdges(game, in: container) {
                        env["ANVIL_FSR3_FRAMES"] = "3"
                        AnvilLog.write("  FSR 3: \(game.title) smooths its own edges over time (its temporal AA is on), so FSR 3 blends at most 3 frames on top")
                    } else if use, let own = ownUpscaler, own.temporal {
                        env["ANVIL_FSR3_FRAMES"] = "3"
                        AnvilLog.write("  FSR 3: \(game.title) upscales with \(own.brand?.short ?? "its own upscaler"), which blends its frames over time already, so FSR 3 blends at most 3 frames on top")
                    }
                    switch verdict.use {
                    case true?: AnvilLog.write("  FSR 3: on — Graphics Prep found it better than FSR 1 at \(game.title)'s sizes\(native ? ", at the display's own size too" : "")")
                    case false?: AnvilLog.write("  FSR 3: not this session — Graphics Prep's test found FSR 1 better at \(game.title)'s sizes; FSR 1 runs")
                    case nil: AnvilLog.write("  FSR 3: on wherever the game is upscaled — not tested for \(game.title) yet; at the display's own size its frames are left as they are")
                    }
                }
                // Textures as sharp as the display's size would make them while FSR upscales: a mip
                // level sharper for every halving (log2 of drawn ÷ shown), with 8× anisotropic
                // filtering — on the game's filtered, mipmapped textures (anvil_gpuwork.mm).
                let upscaling = env["ANVIL_OUTPUT"] == "1" && (GraphicsPrep.drawnRatio(gameID: game.id) ?? 0.5) < 0.9
                if upscaling, upscaler.sharpTextures, let own = ownUpscaler, own.temporal {
                    // The game's own upscaler sets its textures' sharpness for the size it upscales to; a mip level
                    // more on top samples them finer than its frames can hold, and they shimmer (Hogwarts Legacy,
                    // 21 October: −1 of Anvil's over its FSR 3's own).
                    env["ANVIL_ANISOTROPY"] = "8"
                    AnvilLog.write("  textures: 8× anisotropic filtering; their sharpness left to \(game.title)'s own \(own.brand?.short ?? "upscaler"), which sets it for the size it upscales to")
                } else if upscaling, upscaler.sharpTextures, let ratio = GraphicsPrep.drawnRatio(gameID: game.id), ratio < 0.9 {
                    let bias = max(-2.0, log2(ratio))
                    env["ANVIL_LOD_BIAS"] = String(format: "%.2f", bias)
                    env["ANVIL_ANISOTROPY"] = "8"
                    AnvilLog.write(String(format: "  textures: sharpened for FSR — mip bias %.2f (the game draws at %.0f%% of the display's width) and 8× anisotropic filtering", bias, ratio * 100))
                } else if upscaling, upscaler.sharpTextures {
                    env["ANVIL_ANISOTROPY"] = "8"
                    AnvilLog.write("  textures: 8× anisotropic filtering while FSR upscales — the mip bias waits for a session to show the game's size")
                }
                if let line = GameTuning.prepareForFSR(game, in: container, upscaling: upscaling,
                                                       level: Tuner.shared.graphicsLevel(for: game)) {
                    AnvilLog.write("  " + line)
                }
                // Long sessions: an even 80 with no looking for 120, and FSR 3 only in the GPU's
                // spare time — by default on battery, in Low Power Mode or with the Mac hot.
                let long = PowerState.longSessions
                env["ANVIL_ENDURANCE"] = long.environmentValue
                AnvilLog.write("  long sessions: \(long.launchLine)")
                // 3D sound: Apple's spatial audio for whatever the Mac plays through.
                env.merge(SpatialSound.environment()) { _, new in new }
                AnvilLog.write("  3D sound: \(SpatialSound.launchLine)")
                AnvilLog.write("  sound output: \(SpatialSound.outputLine)")
                // Frame generation is the player's choice, Autopilot or not — except in Auto-Tune's
                // quick test, which needs the game's own frames alone. Measuring while the player
                // plays, it counts the game's own frames (generated ones are told apart in
                // game.log since 0.41): until 0.47 that switched frame generation off for every
                // session Auto-Tune was still deciding — all of LEGO Star Wars' on 12 October.
                let measuring = Tuner.shared.state(for: game)?.mode == .quickTest
                // Never on top of the game's own: frames made from frames it made itself warp. Hogwarts Legacy had
                // AMD's frame generation on in its menu and Anvil's as well on 21 October.
                let gamesOwnFrames = ownUpscaler?.frameGen
                let generate = upscaler.frameGeneration && !measuring && gamesOwnFrames == nil
                if upscaler.frameGeneration && measuring {
                    AnvilLog.write("  frame generation: off for Auto-Tune's quick test of \(game.title)'s own frames; on again after it")
                } else if upscaler.frameGeneration, let theirs = gamesOwnFrames {
                    AnvilLog.write("  frame generation: \(game.title)'s own (\(theirs)) is on in its settings, so Anvil's and Smooth Motion are off for this start — not one on top of the other")
                }
                env["ANVIL_FRAME_GEN"] = generate ? "1" : "0"
                env["ANVIL_SMOOTH_MOTION"] = generate && upscaler.smoothMotion ? "1" : "0"
                // Lower latency at a low frame rate, where asked for: each frame started just in time (libanvil's jitHold).
                env["ANVIL_JIT"] = upscaler.lowLatencyAtLowFPS ? "1" : "0"
                if upscaler.lowLatencyAtLowFPS {
                    AnvilLog.write("  lower latency at low frame rates: on — below 55 fps with the GPU setting the pace, each frame started as the GPU is about to finish the last")
                }
                if generate && upscaler.smoothMotion {
                    let top = Int((DisplayProfile.maxHz / 2).rounded())
                    AnvilLog.write("  Smooth Motion: on — in a heavy scene (15–\(top) fps of the game's own on this \(Int(DisplayProfile.maxHz.rounded())) Hz display) a frame made between each two of its own, from both, on long sessions too")
                }
                // Guardian: every few seconds, that what Anvil does in the game is working; and what runs best
                // here, learned and kept for this game on this Mac.
                env.merge(Guardian.environment(gameID: game.id, on: upscaler.guardian)) { _, new in new }
                AnvilLog.write("  " + Guardian.launchLine(gameID: game.id, on: upscaler.guardian))
                // Chosen, it runs whatever the display — on a variable-refresh panel two to one, only
                // for a game holding every second refresh but not an even 80 (libanvil's genDecide).
                env["ANVIL_FRAME_GEN_FORCE"] = generate ? "1" : "0"
                // Apple's frame interpolator, fed with motion Anvil measures itself.
                // The engine supplies neither motion vectors nor depth, and does not
                // need to.
                env["ANVIL_FLOW_DIVISOR"] = String(upscaler.flowDivisor)
                env["ANVIL_INTERP_SCALE"] = String(format: "%.2f", upscaler.interpolationScale)
                let interpolated = upscaler.useMetalFXFrameGen
                    && MetalCapability.current.hasFrameInterpolation
                env["ANVIL_FRAMEGEN_MODE"] = interpolated ? "interpolated" : "projected"
                env["ANVIL_METALFX_FRAMEGEN"] = interpolated ? "1" : "0"
                // Frames are projected forward from the two most recent real frames
                // rather than interpolated between them, so nothing is held back and
                // no queue latency is added.
                env["ANVIL_FRAME_GEN_MODE"] = "extrapolate"
                env["ANVIL_FRAME_GEN_LATENCY_FRAMES"] = "0"
                // Queue depth dominates felt latency far more than shader cost does.
                //
                // With frame generation on, the queue must be three deep: generation
                // takes a second drawable while the game still holds its own, and a
                // two-deep pool has none to give — nextDrawable then blocks the
                // game's thread, which in Unity is the thread reading the controller.
                // That stall is felt as input arriving late, or a stick that keeps
                // travelling because its release was never read.
                // With the refresh lock on, the pool is always three and "fewer
                // queued frames" goes through the adaptive one-frame mode, which backs
                // off by itself if the game misses refreshes. A plain two-deep pool had
                // no way back: it is what the Lowest Latency profile asked for, and on
                // this Mac it missed up to 79 refreshes in five seconds.
                let queue: Int
                if container.lockToRefresh {
                    queue = 3
                } else {
                    queue = upscaler.frameGeneration ? max(container.maxQueuedFrames, 3)
                                                     : container.maxQueuedFrames
                }
                env["ANVIL_MAX_DRAWABLES"] = String(queue)
                // Wine's threads at interactive priority, so a CPU-bound game is not
                // scheduled onto efficiency cores. See anvil_input.mm.
                env["ANVIL_THREAD_QOS"] = container.highPriority ? "1" : "0"
                // Always measured. It costs one callback per frame, and a latency
                // setting whose effect cannot be read back is a setting on faith.
                env["ANVIL_MEASURE"] = "1"
                // Only the explicit switch. The Lowest Latency profile used to turn this
                // on too, and on this Mac it missed 7–79 refreshes at the start of every
                // one of four measured sessions before backing off — a stutter each time
                // for no latency gain.
                env["ANVIL_LOW_LATENCY"] = container.lowLatencyQueue ? "1" : "0"
                // Hold frames to the display's refresh grid. Measured on Cat Quest II
                // at 3024x1964: without it, 100% of displayed gaps were uneven and the
                // game's render rate wandered between 65 and 120 while the average
                // still read 120. With it, 900 of 900 gaps landed exactly one refresh
                // apart and the worst gap in a window was 8.3 ms.
                env["ANVIL_PACING"] = (container.lockToRefresh && container.pacing) ? "1" : "0"
                // A display already seen following games' frame rates (variable refresh): taken
                // as following from the first frame, rather than judged afresh on a loading screen.
                let confirmed = DisplayProfile.followsGamesConfirmed(log: Self.gameLogURL)
                if confirmed >= 3 {
                    env["ANVIL_VRR_KNOWN"] = "1"
                    AnvilLog.write("  display: follows games' own frame rates (confirmed \(confirmed) times before) — frames shown as they're ready from the first second")
                }
                env["ANVIL_TARGET_FPS"] = String(game.targetFPSOverride ?? container.targetFPS)
                env["ANVIL_ADAPTIVE"] = "1"
                if container.memoryBudgetMB > 0 {
                    env["ANVIL_MEMORY_BUDGET_MB"] = String(container.memoryBudgetMB)
                }
            }
        }

        // --- Controllers ---
        if container.enableGamepad {
            // Re-scan now. The list is otherwise only refreshed at app start and on
            // GameController notifications, which never fire for a pad macOS has no
            // profile for — so a controller plugged in after Anvil launched produced
            // no mapping at all, and Wine saw a generic joystick.
            ControllerManager.shared.refresh()

            // Wine drives controllers from an SDL_WaitEventTimeout loop and asks for
            // a 10 ms wait, which is the floor on controller latency — and the reason
            // keyboard and mouse feel instant while the pad does not: those arrive as
            // events through Wine's Mac driver and never touch this path. Anvil
            // intercepts the call and shortens it.
            env["ANVIL_INPUT_POLL_MS"] = String(container.controllerPollMs)
            // Drops exact repeats and values resting inside a small zone around centre
            // before Wine turns them into reports. Measured on the PowerA it removes
            // little — the pad sends nothing at true rest — but what it removes is
            // pure cost, and it counts every event so game.log shows the rate.
            env["ANVIL_INPUT_FILTER"] = "1"
            // One stick update per axis per interval, newest value kept, buttons never
            // held. Tested with a scripted stick: 301 events became 79 at 125 Hz, each
            // axis at least 8 ms apart, and a released stick always returned to centre.
            env["ANVIL_INPUT_AXIS_HZ"] = String(container.controllerAxisHz)
            // Wine 7.7's server sends queued controller reports to a game without their
            // data (it advances past each message's header only), so whenever input
            // backs up a game reading raw input in batches — Rewired, in many Unity
            // games — sees garbage as buttons and sticks. Anvil's library replaces that
            // one request handler with Wine 8's, in a wineserver whose code matches the
            // build it was checked against. Run against Wine's own handler from both
            // installed engines: 60 queued reports, 0 readable before, 60 after.
            env["ANVIL_RAWINPUT_FIX"] = "1"
            // The fix lives in Anvil's library, so it goes in even when no video
            // feature asked for it — with the frame hook left off.
            if let resources = Bundle.main.resourceURL {
                let dylib = resources.appendingPathComponent("libanvil.dylib").path
                let inserted = env["DYLD_INSERT_LIBRARIES"] ?? ""
                if FileManager.default.fileExists(atPath: dylib), !inserted.contains(dylib) {
                    env["DYLD_INSERT_LIBRARIES"] = inserted.isEmpty ? dylib : inserted + ":" + dylib
                    env["ANVIL_HOOK_ENABLED"] = "0"
                    env["ANVIL_LOG"] = Self.gameLogURL.path
                }
            }

            let profile = game.controllerProfileOverride ?? container.controllerProfile
            let pads = ControllerManager.shared.controllers
            // A game with its own Switch Pro support gets a Pro Controller it can drive:
            // the pad is hidden and one made by Anvil, speaking Nintendo's protocol,
            // takes its place (anvil_switchpro.mm, in winedevice).
            let identity = NativeControllerSupport.resolve(game, pads: pads)
            if let rule = identity.rule { env["ANVIL_VIRTUAL_PRO"] = rule }
            AnvilLog.write("  controller identity: \(identity.identity.title) — \(identity.reason)")
            // Nintendo prints A and B the other way round from Xbox, so a Switch pad read
            // as an Xbox pad matches its prompts by letter or by position, never both.
            let faceButtons = NativeControllerSupport.resolveFaceButtons(game, pads: pads,
                                                                         identity: identity.identity)
            AnvilLog.write("  face buttons: \(faceButtons.layout == .letters ? "by letter" : "by position") — \(faceButtons.reason)")
            // The engine's own libSDL2, so Anvil can tell which pads SDL already
            // maps correctly and leave those alone.
            let sdl = runtime.root.appendingPathComponent("lib/libSDL2-2.0.0.dylib")
            env.merge(ControllerManager.shared.environment(
                profile: profile,
                controllers: pads,
                sdlLibrary: FileManager.default.fileExists(atPath: sdl.path) ? sdl : nil,
                faceButtons: faceButtons.layout)) { _, new in new }
        } else {
            env["SDL_JOYSTICK_DISABLE"] = "1"
        }

        // Windows' table of connections, with each one's owner, for the Wine before 10 — which
        // on this macOS listed none (anvil_net.mm). Steam's window and other launchers' are
        // only let in once their owner shows; it costs nothing where nobody asks.
        env["ANVIL_TCP_OWNER_FIX"] = "1"

        env.merge(container.extraEnvironment) { _, new in new }
        return env
    }

    /// A store's own client, Steam: Anvil's library goes into it for what Wine needs fixed
    /// underneath — the connection table Steam checks its own window by, so it can sign in —
    /// and nothing of a game's: no frame hook, pacing, controller or sound changes. Steam
    /// started without it turned its window away on every try (4 October: "WebUITransport:
    /// Connection rejected"); with it on 7 October, the window's connection was taken at once.
    nonisolated static func storeClientEnvironment(_ base: [String: String]) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("ANVIL_") || $0.key == "ANVIL_OFFLINE_FLAG" }
        guard let dylib = Bundle.main.resourceURL?.appendingPathComponent("libanvil.dylib").path,
              FileManager.default.fileExists(atPath: dylib) else {
            env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            return env
        }
        let others = (env["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
            .filter { !$0.hasSuffix("/libanvil.dylib") }
        env["DYLD_INSERT_LIBRARIES"] = (others + [dylib]).joined(separator: ":")
        env["ANVIL_HOOK_ENABLED"] = "0"
        env["ANVIL_TCP_OWNER_FIX"] = "1"
        env["ANVIL_LOG"] = gameLogURL.path
        return env
    }

    // MARK: Launch

    /// `wineserver -w` returns once the prefix's server has exited, i.e. once nothing
    /// else is running in it. Bounded, so a stuck server cannot hold a launch forever.
    nonisolated static func waitForWineserver(container: Container, runtime: Runtime,
                                              timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let p = Process()
            p.executableURL = runtime.wineserver
            p.arguments = ["-w"]
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = container.prefixURL.path
            env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Resumed exactly once, from whichever of exit or timeout comes first.
            final class Once: @unchecked Sendable {
                private let lock = NSLock(); private var done = false
                private let cont: CheckedContinuation<Void, Never>
                init(_ c: CheckedContinuation<Void, Never>) { cont = c }
                func fire() { lock.lock(); defer { lock.unlock() }; if !done { done = true; cont.resume() } }
            }
            let once = Once(cont)
            p.terminationHandler = { _ in once.fire() }
            do { try p.run() } catch { once.fire(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                once.fire()
            }
        }
    }

    /// The interceptor's own log: frame statistics and latency from inside the game.
    /// A Unity player keeps UnityPlayer.dll beside the executable. Checked on disk, not
    /// guessed from the name.
    nonisolated static func isUnityGame(_ executable: URL) -> Bool {
        FileManager.default.fileExists(atPath: executable.deletingLastPathComponent()
            .appendingPathComponent("UnityPlayer.dll").path)
    }

    nonisolated(unsafe) static var rawInputRejections = 0

    nonisolated static var gameLogURL: URL {
        RuntimeManager.support.appendingPathComponent("game.log")
    }

    /// One line into game.log, after the session's header.
    private func appendGameLog(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: Self.gameLogURL) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        }
    }

    /// Start each session with a header, and keep the file from growing without end.
    /// Where the session being started keeps its pictures of the screen; taken by `launch`.
    private var screensFolder: URL?

    private func beginGameLog(for game: Game) {
        let url = Self.gameLogURL
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        // The session's pictures of the screen are named by the same second (see ScreenReader).
        let started = Date()
        screensFolder = ScreenReader.folder(gameID: game.id, startedAt: started)
        let gameID = game.id
        Task.detached(priority: .utility) { ScreenReader.prune(gameID: gameID) }
        let header = "\n=== \(game.title) — \(ISO8601DateFormatter().string(from: started)) — Anvil \(AnvilVersion.current) ===\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(header.utf8)); try? handle.close()
        } else {
            try? Data(header.utf8).write(to: url)
        }
    }

    /// Prepare the prefix, then launch. This is the entry point the UI uses.
    ///
    /// Preparation writes the registry keys that Retina mode and DPI actually live
    /// in, and it only does real work the first time or after those settings change,
    /// so it costs nothing on a normal launch.
    @discardableResult
    func prepareAndLaunch(game stored: Game, container storedContainer: Container, runtime: Runtime,
                          plainRetry: Bool = false, offlineTest: Bool = false) async throws -> Session {
        // One launch at a time, and never a second copy of a running game. Two
        // launches into the same prefix in the same second — a double-click on Play,
        // or two copies of Anvil — started two games that fought over wineserver and
        // both exited within 0.3 seconds. That is in the launch log from 27 September.
        if let running = sessions.first(where: { $0.game.id == stored.id }) {
            GameFocus.handOff(to: stored, startedAt: running.startedAt)
            return running
        }
        guard launching == nil else { throw LaunchError.alreadyStarting }
        launchingGameID = stored.id
        defer { launchingGameID = nil }
        // Auto-Tune measuring a setup: applied to this launch only, never saved. Not for a start
        // with no connection of a game that needs internet to start (OfflineStarts): it stays on
        // its loading screen, and on 10 October one such start was measured as 0.6 minutes of
        // play at 78 fps.
        let waitsOffline = offlineTest || (!Connectivity.networkUpNow
            && (Library.shared.games.first(where: { $0.id == stored.id }).map(OfflineStarts.needsConnection) ?? false))
        var tuning: (game: Game, container: Container, logLine: String?) = (stored, storedContainer, nil)
        if !waitsOffline { tuning = Tuner.shared.prepareLaunch(game: stored, container: storedContainer) }
        var game = tuning.game, container = tuning.container
        AnvilLog.write("prepareAndLaunch: \(game.title) container=\(container.name) runtime=\(runtime.displayName) exe=\(game.executablePath)")
        AnvilLog.write("  runtime usable=\(runtime.isUsable) at \(runtime.wine64.path)")
        AnvilLog.write("  memory at launch: \(SystemInfo.memory().summary)")
        AnvilLog.write("  power: \(PowerState.shared.summary)")
        // The memory warm-up: the game's data played most read into memory while the rest of the start runs
        // (Wine's setup, a store's sign-in), in the background. Not for an offline test, which isn't play.
        if !offlineTest {
            MemoryWarmup.start(gameID: game.id, title: game.title, on: game.warmMemory, onBattery: MemoryWarmup.onBattery)
        }
        if offlineTest {
            AnvilLog.write("  \(OfflineTest.logMark) started as with no connection — its own connections held back while the Mac stays online, watched for \(OfflineTest.watchSeconds) s, then closed; not counted as play")
        } else if waitsOffline {
            AnvilLog.write("  auto-tune: not measuring this start — \(game.title) needs internet to start, and there's none")
        }
        // A game whose starts with no connection don't get going here (OfflineStarts), started
        // with Offline Mode on while the Mac has a connection: online, this once — the start that
        // works — with Offline Mode left on for everything else.
        let onlineThisOnce = !offlineTest && Connectivity.offlineModeNow && Connectivity.networkUpNow
            && (Library.shared.games.first(where: { $0.id == stored.id })?.offlineRecord?.doesntGetGoing ?? false)
        if onlineThisOnce {
            AnvilLog.write("  network: Offline Mode is on, but \(game.title)'s starts with no connection don't get going here — started online this once, the way that works; Offline Mode stays on for everything else")
            append("\(game.title) needs internet to start, so it starts online this once. Once it's past its loading screen you can go offline — it keeps playing. Offline Mode stays on for everything else.")
        }
        // Read after the session (OfflineStarts): how starts with no connection go for each game.
        if offlineTest {
            AnvilLog.write("  network: offline at the start — an Offline Test: the game's own connections are held back")
        } else if !Connectivity.isOnlineNow && !onlineThisOnce {
            AnvilLog.write("  network: offline at the start — \(Connectivity.offlineModeNow ? "Offline Mode is on" : "this Mac has no connection")")
        }
        AnvilLog.write("  exe exists=\(game.exists)")
        launching = "Preparing \(game.title)…"
        defer { launching = nil }
        // An engine being prepared in the background gives way to the game.
        EngineOptimizer.shared.yieldToGame()
        // The engine as it was sealed: nothing in it changed, added or removed.
        if runtime.isManaged {
            let verdict = await Task.detached(priority: .userInitiated) {
                EngineSeal.check(root: runtime.root, id: runtime.id, full: false)
            }.value
            switch verdict {
            case .changed(let files):
                AnvilLog.write("  engine seal: \(files.count) file(s) in \(runtime.displayName) differ from its seal — not launching: \(files.prefix(5).joined(separator: ", "))")
                RuntimeManager.shared.noteSealProblem(runtime.id, files: files)
                throw LaunchError.engineChanged(runtime.displayName, files)
            case .notSealed:
                Task.detached(priority: .utility) { _ = try? EngineSeal.seal(root: runtime.root, id: runtime.id) }
                AnvilLog.write("  engine seal: \(runtime.displayName) wasn't sealed yet — sealing it now")
            case .intact, .resealed:
                AnvilLog.write("  engine seal: \(runtime.displayName) intact")
            case .unverified:
                AnvilLog.write("  engine seal: \(runtime.displayName) not checked — Anvil's protection key isn't available this run")
            }
        }
        // A game with anti-cheat: nothing of Anvil's goes into its folder — no upscaler
        // libraries this launch, and any Anvil put there before are taken out, putting the
        // game's own files back. A library in a game's folder that isn't the game's own is
        // what anti-cheat flags, and that can cost an account. Anvil never works around
        // anti-cheat itself: online play runs only where the game's maker allows it.
        let exe = game.executableURL
        let antiCheat = await Task.detached(priority: .userInitiated) { AntiCheat.detect(forExecutable: exe) }.value
        if !antiCheat.isEmpty {
            game.upscalerOverride?.forceInjection = false
            container.upscaler.forceInjection = false
            var removed = ""
            if UpscalerManager.shared.injectionManifest(forGameAt: game.executablePath) != nil {
                removed = (try? UpscalerManager.shared.removeInjection(fromGameAt: game.executablePath)) != nil
                    ? "; the upscaler files Anvil put there before were taken out and the game's own put back"
                    : "; upscaler files Anvil put there before couldn't be taken out — Remove them on the Upscaling page"
            }
            AnvilLog.write("  anti-cheat: \(antiCheat.map(\.name).joined(separator: ", ")) — nothing of Anvil's goes into the game's folder\(removed)")
        }
        // The game's graphics: read once per build of it and engine, before that build's first
        // start (see GraphicsScan) — what it ships, what draws it, and what Anvil does for it.
        launching = "Looking at \(game.title)'s graphics…"
        var dlssWanted = false
        if let (scan, fresh) = await GraphicsScan.forLaunch(game: game, container: container, runtime: runtime) {
            AnvilLog.write("  graphics scan\(fresh ? "" : ", from \(scan.scannedAt.formatted(date: .abbreviated, time: .shortened))"): \(scan.summary)")
            if fresh {
                for line in scan.plan.inGame { AnvilLog.write("    in the game: \(line)") }
                GraphicsScan.changed()
            }
            dlssWanted = scan.plan.dlssThroughMetalFX && game.dlssThroughMetalFX
                && DXVKSetup.backend(for: game, in: container, runtime: runtime) == .d3dmetal
        }
        // Graphics Prep, the wait before a start that needs it (see GraphicsPrep): Anvil's FSR and
        // frame generation compiled for this Mac and tested on its GPU. Only where Anvil's frame
        // pipeline goes into the game, never for Steam's own window, and never while Auto-Tune
        // measures the game. Skippable; whatever happens, the game starts.
        if game.prepareGraphics, Self.interceptorWanted(game: game, container: container),
           !SteamSupport.isSteamClient(game), Tuner.shared.state(for: game)?.isActive != true,
           let why = GraphicsPrep.reason(gameID: game.id) {
            launching = "Preparing \(game.title)'s graphics…"
            if await GraphicsPrepRunner.shared.run(game: game, container: container, runtime: runtime,
                                                   beforeLaunch: true, reason: why) == nil {
                AnvilLog.write("  graphics prep: skipped this start")
            }
        } else if let prep = GraphicsPrep.stored(gameID: game.id), GraphicsPrep.usable(gameID: game.id) != nil {
            AnvilLog.write("  graphics prep, from \(prep.at.formatted(date: .abbreviated, time: .shortened)): \(prep.summary)")
        }
        launching = "Preparing \(game.title)…"
        // A save written onto a full disk is a broken save: below 1 GB free the game waits
        // until there is room.
        let prefixURL = container.prefixURL
        if let free = await Task.detached(priority: .userInitiated, operation: { SaveGuard.freeSpace(at: prefixURL) }).value {
            if free < SaveGuard.launchMinimum {
                AnvilLog.write("  disk: only \(SaveGuard.sizeText(free)) free — not launching, so no save is written onto a full disk")
                throw LaunchError.diskFull(SaveGuard.sizeText(free))
            }
            if free < SaveGuard.launchWarning {
                AnvilLog.write("  disk: \(SaveGuard.sizeText(free)) free")
                append("This Mac has only \(SaveGuard.sizeText(free)) free. Games need room to save — free some space soon.")
            }
        }
        let clock = ContinuousClock()
        let began = clock.now
        var steps: [String] = []
        func step<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
            let t = clock.now
            let result = try await work()
            steps.append("\(name) \(Self.format(clock.now - t))")
            return result
        }
        // A game back after being deleted and downloaded again, or moved to another Windows setup, with saves from
        // before it (an export, or the setup it was in): the player chooses which to play on before it starts.
        // LEGO Star Wars, downloaded again on 19 October into a new setup, started over with its export unused.
        launching = "Checking for \(game.title)'s saves from before…"
        await SaveChoice.shared.askIfNeeded(game)
        // A game whose saves are in the Mac's own Documents (Cat Quest II's): macOS asks once
        // whether Anvil may open that folder — again after each new build of Anvil — and until
        // it's answered every read there waits, the game's own load of its save included. On
        // 10 October Cat Quest II sat on its loading screen with the question hidden behind it.
        // So Anvil asks first, in front, says why, and starts the game once it's answered.
        let names = [game.title, game.executableURL.deletingPathExtension().lastPathComponent]
        if SaveGuard.keptInDocuments(containerID: container.id, games: names),
           let documents = SaveGuard.linkedDocuments(in: container.driveC) {
            let probe = Task.detached(priority: .userInitiated) { SaveGuard.documentsAllowed(documents, games: names) }
            var allowed = await Self.firstOf(probe, orNilAfter: .seconds(1))
            if allowed == nil {
                AnvilLog.write("  saves: macOS is asking whether Anvil may open Documents, where \(game.title) keeps its saves — the start waits for the answer")
                launching = "Waiting for macOS — allow Anvil into your Documents folder…"
                append("macOS is asking whether Anvil may open your Documents folder, where \(game.title) keeps its saves. Choose Allow: the game starts as soon as it's answered, with its saves.")
                NSApp.activate()
                allowed = await Self.firstOf(probe, orNilAfter: .seconds(180))
                if allowed == nil { AnvilLog.write("  saves: no answer from macOS after 3 minutes — starting \(game.title) anyway") }
            }
            if allowed == false {
                AnvilLog.write("  saves: Anvil isn't allowed into Documents — \(game.title) can't read or write the saves it keeps there")
                append("Anvil isn't allowed into your Documents folder, so \(game.title) can't open the saves it keeps there. Turn Anvil on under System Settings › Privacy & Security › Files and Folders, then start it again.")
            }
        }
        // The saves as they are before the game runs, beside everything below and done
        // before Anvil writes the game's settings. Unchanged since the last copy, nothing
        // is copied.
        let saveBackup = Task.detached(priority: .userInitiated) { [id = container.id, name = container.name, title = game.title,
                                                                    names = SaveGuard.gameNames(in: container)] in
            SaveGuard.backUp(prefix: prefixURL, containerID: id, containerName: name,
                             reason: "Before playing \(title)", games: names)
        }

        // Started first and run alongside everything below. Neither needs the prefix:
        // the Epic sign-in is a network round trip in legendary, and the Game Mode copy
        // is a check of four files. Run one after the other they added up to two
        // seconds to a LEGO Star Wars launch (launch log, 28 September).
        let epicLink = game.epicSignIn ? EpicLink.find(for: game) : nil
        // Offline, the way this game's record has got to (OfflineRecord): the next one along when
        // the one before didn't get it going.
        let offlineWay = Library.shared.games.first(where: { $0.id == stored.id })?.offlineRecord?.currentWay ?? .keptArguments
        let signInTask: Task<SignIn, Never>? = epicLink.map { link in
            Task { await Self.signIn(link, wine: runtime.wine64, ignoringOfflineMode: onlineThisOnce, offlineWay: offlineWay,
                                     offlineTest: offlineTest) }
        }
        // The game's own switch for carrying on behind other apps, read from its program
        // once per version (see KeepRunning).
        let keepRunningTask: Task<String?, Never>? = game.keepRunningBehind
            ? Task.detached(priority: .userInitiated) { KeepRunning.supportedSwitch(for: exe) }
            : nil
        let gameModeTask: Task<Result<Runtime, Error>, Never>? = container.gameMode
            ? Task.detached(priority: .userInitiated) { Result { try GameModeEngine.prepared(for: runtime) } }
            : nil

        do {
        var ranWine = try await step("prefix") {
            try await Prefix.prepare(container: container, runtime: runtime) { [weak self] line in
                Task { @MainActor in self?.append(line) }
            }
        }
        // The trackpad and keyboard settings, when they changed: one short Wine run, once.
        if Prefix.needsInput(container) {
            launching = "Setting up the trackpad and keyboard…"
            let applied = await step("input") { await Prefix.applyInput(container: container, runtime: runtime) }
            if applied {
                let s = Prefix.inputSettings(container).map { "\($0.name)=\($0.value)" }.joined(separator: " ")
                AnvilLog.write("  input: trackpad and keyboard set for “\(container.name)” — \(s)")
            }
            ranWine = ranWine || applied
        }
        // A store's window at the display's point size, a game at the container's own
        // resolution — in a container that holds a store, each as it starts (see
        // Prefix.setWindowScale). A Steam game's Steam is started at point size below.
        let storeClient = StoreArt.store(of: game) != nil
        if storeClient || container.holdsStoreApp {
            let points = storeClient && container.storeWindowSmooth
            if await step("scale", { await Prefix.setWindowScale(points: points, container: container, runtime: runtime) }) {
                AnvilLog.write("  scale: “\(container.name)” at \(points ? "the display's point size for \(game.title)'s window — drawn on the CPU, it is smoother there than at Retina" : "its own resolution for \(game.title)")")
                ranWine = true
            }
        }
        // The DirectX files the graphics setting needs: DXVK's for DXVK, the engine's own (D3DMetal's)
        // for anything else (DXVKSetup). Off the main thread; usually nothing to do.
        let chosenBackend = game.backendOverride ?? container.backend
        let analysis = GameAnalysis.cached(for: game.executableURL)
        let backend = DXVKSetup.effective(chosen: chosenBackend, api: analysis?.primary, is64Bit: analysis?.is64Bit ?? true,
                                          runtime: runtime)
        if let why = backend.why { AnvilLog.write("  graphics: \(chosenBackend.title) was chosen, \(backend.backend.title) draws it — \(why)") }
        let files = await step("graphics files") {
            await Task.detached(priority: .userInitiated) { [backend = backend.backend] in
                DXVKSetup.apply(backend, container: container, runtime: runtime)
            }.value
        }
        if let line = files.line { AnvilLog.write("  \(line)") }
        if !files.ok, backend.backend == .dxvk {
            append("DXVK couldn't be set up for \(game.title), so its engine's own DirectX files draw it this time.")
        }
        // Microsoft's Visual C++ Runtime, once, for a game that needs it (VCRuntime): Hogwarts Legacy's
        // launcher wouldn't start the game without it on 17 October. Its progress is on the Play button.
        if let line = await step("visual c++", {
            await VCRuntimeSetup.shared.prepare(game, container: container, runtime: runtime) { [weak self] text in
                Task { @MainActor in self?.launching = text }
            }
        }) {
            AnvilLog.write("  " + line)
            if line.contains(" installed into ") { append("Installed Microsoft's Visual C++ Runtime, which \(game.title) needs, into “\(container.name)” — once.") }
            ranWine = true
        }
        // Fullscreen, written where the engine actually reads it. Borderless rather
        // than exclusive: it never changes the display mode, which is the path that
        // crashed, and it alt-tabs cleanly.
        AnvilLog.write("  prefix prepared")
        if container.fullscreen {
            launching = "Setting display mode…"
            let applied = await step("display") {
                await UnitySettings.applyFullscreen(.borderless, game: game, container: container, runtime: runtime)
            }
            AnvilLog.write("  fullscreen preference written=\(applied)")
            if applied { append("Set borderless fullscreen at the display's own resolution.") }
            ranWine = ranWine || applied
        }
        // Let Wine finish before the game starts. Preparation leaves wineserver and
        // the services wineboot started still running, without the game's environment:
        // no controller mappings for the device host, no WINEMSYNC for the server. A
        // game started into that prefix a moment later exited with code 1 after 0.2 s
        // (launch log, 27 Sept, 07:09:48). Only paid when preparation actually ran.
        // Not while Steam runs there for another game: Wine would never go idle.
        if ranWine && !SteamSupport.shared.clientRunning(in: container) {
            launching = "Letting Wine finish setting up…"
            await step("wine settle") {
                await Self.waitForWineserver(container: container, runtime: runtime, timeout: 20)
            }
            AnvilLog.write("  wineserver idle before launch")
        }
        // Half a second at most: no game writes a save in its first seconds, and the copy
        // is dated from its start, so finishing beside the game loses nothing.
        // Not a task group: one waits for all its children, and awaiting the copy's value can't be
        // cancelled — so the start waited for the whole copy. On 10 October Cat Quest II's (its saves
        // are in Documents) waited on macOS's "access your Documents folder?" prompt, and the game
        // didn't start until it was answered.
        let backedUp: SaveGuard.Outcome? = await step("saves") {
            await Self.firstOf(saveBackup, orNilAfter: .milliseconds(500))
        }
        if let backedUp {
            AnvilLog.write("  " + backedUp.logLine)
            if case .failed(let why) = backedUp {
                append("Anvil couldn't back up this game's saves before it started (\(why)). The game runs as usual.")
            }
        } else {
            AnvilLog.write("  saves: still being copied — finished beside the game")
            Task { AnvilLog.write("  " + (await saveBackup.value).logLine + " (finished after the start)") }
        }
        // The game's own heavy graphics options, for a game Anvil knows how to tune.
        // Before the game starts, because it reads its settings file once, at start.
        if let line = GameTuning.fitDisplay(game, in: container, wineMajor: EngineProfile.of(runtime).wineMajor) {
            AnvilLog.write("  " + line)
            append(line.replacingOccurrences(of: "display: ", with: ""))
        }
        let level = Tuner.shared.graphicsLevel(for: game)
        // The Ray Tracing switch on Automatic: reflections as Learn found them worth it here, for this start.
        var tuned = game
        if let learned = LearnStore.shared.reflections(for: game, level: level) {
            tuned.rayTracing = learned.on
            AnvilLog.write("  " + learned.line)
        }
        if let line = GameTuning.prepare(tuned, in: container, level: level) {
            AnvilLog.write("  " + line)
        }
        // An Unreal game: its driver warning off, which D3DMetal always trips (UnrealConfig).
        if GameAnalysis.cached(for: game.executableURL)?.engine == .unreal, let line = UnrealConfig.prepare(game, in: container) {
            AnvilLog.write("  " + line)
        }
        // What this session runs with, for Learn to file it under (game.log, under the header).
        let learnParts = LearnStore.parts(for: tuned, in: container, level: level)
        // An Epic game started from its .exe is not signed in, and cannot see the DLC
        // its owner has. Its launcher's legendary gives the arguments Epic's own
        // launcher would pass — the same call Mythic makes on Play — and it has been
        // working since the start of this launch.
        var signIn: [String] = []
        var startedOffline = false
        if let signInTask {
            launching = "Signing in to Epic…"
            let waited = clock.now
            let result = await signInTask.value
            steps.append("Epic \(Self.format(clock.now - waited)) after the rest")
            signIn = result.arguments
            startedOffline = result.startedOffline
            for line in result.logLines { AnvilLog.write("  " + line) }
            if let note = result.note { append(note) }
        }
        // Started offline: the game's own connections are held back too. Given its account
        // but no sign-in code, a game on a connected Mac reaches Epic and tries to sign in
        // with nothing — LEGO Star Wars sat on its loading screen doing that on 3 October —
        // while on a Mac with no connection it finds none at once and carries on offline.
        // An Offline Test holds back every game's connections, Epic's or not.
        Self.setOffline(startedOffline || offlineTest, for: container)
        if startedOffline || offlineTest {
            AnvilLog.write("  network: held back for the game this session — it starts as on a Mac with no connection, so a sign-in to Epic can't keep it on its loading screen")
        }
        if let keep = await keepRunningTask?.value,
           !game.arguments.contains(where: { $0.caseInsensitiveCompare(keep) == .orderedSame }) {
            signIn.append(keep)
            runsBehind.insert(game.id)
            AnvilLog.write("  behind other apps: keeps running (its own \(keep) switch), so loading carries on while another app is in front — held to 30 fps until it's back")
        }
        do {
            let up = game.upscalerOverride ?? container.upscaler
            AnvilLog.write("  FSR to the display: \(up.fsrToDisplay ? "on" : "off") · frame generation: \(up.frameGenChoice.title.lowercased())")
        }
        // Game Mode: the same engine, through Anvil's copy of it that tells macOS this
        // is a game. Made once per engine version; anything short of success leaves
        // the engine as it is.
        var engine = runtime
        if let gameModeTask {
            launching = "Turning on Game Mode…"
            switch await gameModeTask.value {
            case .success(let copy):
                engine = copy
                AnvilLog.write("  Game Mode: through Anvil's copy of \(runtime.displayName), which tells macOS this is a game")
            case .failure(let error):
                AnvilLog.write("  Game Mode unavailable (\(error.localizedDescription)) — \(runtime.displayName) used as it is")
            }
        }
        // DLSS through MetalFX, for the engine the game runs on — Anvil's Game Mode copy when
        // it is used: the translation has to be the D3DMetal the game itself loads.
        if dlssWanted {
            let c = container, e = engine
            switch await Task.detached(priority: .userInitiated, operation: { DLSSThroughMetalFX.prepare(container: c, runtime: e) }).value {
            case .success:
                AnvilLog.write("  DLSS through MetalFX: ready — DLSS chosen in the game runs as Apple's MetalFX, from the game's own motion vectors")
            case .failure(let error):
                AnvilLog.write("  DLSS through MetalFX: not set up — \(error.localizedDescription)")
            }
        }
        // The game's own upscaler, for a game whose settings Anvil knows (GameUpscaler): DLSS run by MetalFX or Intel's
        // XeSS, at a quality fitted to this Mac, and nothing done twice. After DLSS's pieces, which decide if it can run.
        do {
            let up = game.upscalerOverride ?? container.upscaler
            let dlssReady = dlssWanted && DLSSThroughMetalFX.ready(container: container, runtime: engine) != nil
            let measuring = Tuner.shared.state(for: game)?.mode == .quickTest
            let ours = Self.interceptorWanted(game: game, container: container)
            for line in GameUpscaler.prepare(game, in: container, dlssReady: dlssReady,
                                             anvilFrameGen: ours && up.frameGeneration && !measuring,
                                             anvilToDisplay: ours && (up.fsrToDisplay || up.effectiveMode == .fsr3Every),
                                             tier: DeviceProfile.current?.tier) {
                AnvilLog.write("  \(game.title): " + line)
            }
        }
        // A Steam game: Steam running and signed in beside it first, as on Windows.
        if game.steamAppID != nil {
            launching = "Starting Steam…"
            let env = environment(for: game, in: container, runtime: engine)
            // Steam, if it has to start, at point size; the game after it at Retina.
            let startsSteam = SteamSupport.isInstalled(in: container) && !SteamSupport.shared.clientRunning(in: container)
            if startsSteam, container.storeWindowSmooth {
                await Prefix.setWindowScale(points: true, container: container, runtime: runtime)
            }
            let line = await step("Steam") {
                await SteamSupport.shared.prepareClient(for: game, container: container, runtime: engine, environment: env)
            }
            if !line.isEmpty { AnvilLog.write("  " + line); append(line) }
            if startsSteam, container.storeWindowSmooth {
                await Prefix.setWindowScale(points: false, container: container, runtime: runtime)
                AnvilLog.write("  scale: Steam started at the display's point size, \(game.title) at “\(container.name)”'s own resolution")
            }
        }
        // Steam through a VPN: it picks servers by where the connection seems to come from,
        // and often can't sign in. Said up front rather than left to Steam's own error.
        if SteamSupport.isSteamClient(game) || game.steamAppID != nil, Connectivity.isOnlineNow,
           let vpn = await Task.detached(priority: .userInitiated, operation: { Connectivity.activeVPN() }).value {
            AnvilLog.write("  network: through \(vpn) — Steam often can't sign in through a VPN")
            append("This Mac is connected through \(vpn). Steam often can't sign in through a VPN — if it says it can't connect, turn the VPN off or choose a server in your own country.")
        }
        launching = "Starting \(game.title)…"
        do {
            let title = game.title, id = game.id, log = Self.gameLogURL
            Task.detached(priority: .utility) {
                guard let estimate = LoadTime.estimate(of: title, in: log) else { return }
                await MainActor.run { self.loadEstimates[id] = estimate }
            }
        }
        beginGameLog(for: game)
        appendGameLog(Learn.setupLine(learnParts))
        let logStart = (try? FileManager.default.attributesOfItem(atPath: Self.gameLogURL.path))?[.size] as? UInt64 ?? 0
        if let line = tuning.logLine {
            appendGameLog(line)
            AnvilLog.write("  " + line.replacingOccurrences(of: "[anvil] ", with: ""))
            append(line.replacingOccurrences(of: "[anvil] auto-tune: ", with: "Auto-Tune: "))
        }
        let plain = plainRetry || game.anvilEnhancementsOff
        let session = try await step("start") {
            try launch(game: game, container: container, runtime: engine, extraArguments: signIn,
                       plain: plain, isRetry: plainRetry, baseRuntime: runtime)
        }
        AnvilLog.write("  Anvil's part of the launch took \(Self.format(clock.now - began)): "
                       + steps.joined(separator: ", "))
        if plainRetry {
            // Still running after half a minute without Anvil's library, having failed
            // with it: remember that for this game rather than failing every time.
            let id = session.id, gameID = game.id, title = game.title
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard self.sessions.contains(where: { $0.id == id }),
                      var stored = Library.shared.games.first(where: { $0.id == gameID }) else { return }
                stored.anvilEnhancementsOff = true
                Library.shared.update(stored)
                AnvilLog.write("  \(title) runs without Anvil's library and did not with it — enhancements now off for this game")
                self.append("\(title) only starts without Anvil's enhancements, so they are now off for it. They can be switched back on in its settings.")
            }
        }
        if offlineTest { offlineTests.insert(session.id) }
        AnvilLog.write("  launch returned, pid=\(session.process.processIdentifier)")
        watchLoading(session, logFrom: logStart)
        return session
        } catch {
            AnvilLog.write("  FAILED: \(error.localizedDescription)")
            Tuner.shared.launchFailed(game, reason: error.localizedDescription)
            throw error
        }
    }

    /// What the Epic sign-in produced: the game's arguments, lines for the launch log,
    /// and what the Activity screen should say about it.
    struct SignIn: Sendable {
        var arguments: [String] = []
        var logLines: [String] = []
        var note: String?
        /// Started with Epic's offline arguments: the game is then kept off the network
        /// for the session, as on a Mac with no connection (see anvil_net.mm).
        var startedOffline = false
    }

    /// Ask the game's launcher's legendary for the arguments Epic's own launcher would
    /// pass; offline as the same account when Epic cannot be reached.
    /// Epic's account service, which legendary signs in through. Any answer means Epic can
    /// be reached.
    nonisolated static let epicAccounts = URL(string: "https://account-public-service-prod03.ol.epicgames.com/")!

    nonisolated static func signIn(_ link: EpicLink, wine: URL, ignoringOfflineMode: Bool = false,
                                   offlineWay way: EpicOfflineWay = .keptArguments, offlineTest: Bool = false) async -> SignIn {
        var out = SignIn()
        let owned = link.installedDLC.map(\.title)
        // Offline — chosen, or for want of a connection — or connected but unable to reach
        // Epic: straight to Epic's own offline start, instead of waiting up to 15 seconds for
        // legendary to give up. On 1 October a VPN connecting made the Mac look online for
        // seconds at a time while nothing got through.
        let offlineBecause: String?
        // Online, the sign-in starts beside the look at whether Epic can be reached rather
        // than after it: that look is a round trip, a second through a VPN, and the sign-in
        // is a run of legendary of several seconds that needs the same answer anyway.
        var online: Task<[String], Error>?
        if offlineTest {
            offlineBecause = "this is an Offline Test"
        } else if Connectivity.offlineModeNow && !ignoringOfflineMode {
            offlineBecause = "Offline Mode is on"
        } else if !(ignoringOfflineMode ? Connectivity.networkUpNow : Connectivity.isOnlineNow) {
            offlineBecause = "this Mac is offline"
        } else {
            online = Task { try await link.signInArguments(wine: wine, timeout: 15) }
            offlineBecause = await Connectivity.reaches(epicAccounts, timeout: 3) ? nil : "Epic can't be reached right now"
        }
        if let why = offlineBecause {
            let note = why.prefix(1).uppercased() + why.dropFirst()
                + ", so the game starts in Epic's offline mode as your account: your saves are there; DLC unlocks again once Epic can be reached."
            // The game's own program, nothing from Epic: the way of last resort, for a game whose
            // other offline starts didn't get going (OfflineRecord).
            if way == .programAlone {
                online?.cancel()
                out.startedOffline = true
                out.logLines.append("Epic: \(why) — started offline as its program on its own, with no Epic arguments, after Epic's offline starts didn't get it going (\(way.logMark))")
                out.note = why.prefix(1).uppercased() + why.dropFirst()
                    + ", so the game starts on its own, without Epic's arguments — the way left to try after Epic's offline starts didn't get it going."
                return out
            }
            // From the last online start, sealed: no legendary run, no wait.
            if let kept = EpicOfflineStart.arguments(appName: link.appName) {
                out.arguments = way.arguments(from: kept)
                out.startedOffline = true
                out.logLines.append("Epic: \(why) — started offline as the signed-in account, from Anvil's sealed copy of its last online start (no legendary run), as \(way.title); DLC ownership unchecked this session (\(way.logMark))")
                out.note = note
                return out
            }
            // An online run already under way goes first: two runs of legendary at once
            // would share one sign-in. If it got through after all, it is used as it is.
            if let online, let args = try? await online.value {
                out.arguments = args
                EpicOfflineStart.remember(args, appName: link.appName)
                out.logLines.append("Epic: signed in through \(link.launcher)'s legendary (\(link.appName)) although Epic looked out of reach")
                out.note = "Signed in to Epic through \(link.launcher): DLC, cloud saves and achievements are available."
                return out
            }
            do {
                out.arguments = way.arguments(from: try await link.signInArguments(wine: wine, offline: true, timeout: 15))
                out.startedOffline = true
                out.logLines.append("Epic: \(why) — started offline as the signed-in account, as \(way.title); DLC ownership unchecked this session (\(way.logMark))")
                out.note = note
            } catch {
                out.logLines.append("Epic: offline start failed (\(why)): \(error.localizedDescription)")
                out.note = "The offline Epic start didn't work (\(error.localizedDescription)). Starting without it — saves tied to your account may not appear."
            }
            return out
        }
        do {
            out.arguments = try await (online ?? Task { try await link.signInArguments(wine: wine, timeout: 15) }).value
            // Kept, sealed and without the one-time code, for the next offline start.
            EpicOfflineStart.remember(out.arguments, appName: link.appName)
            out.logLines.append("Epic: signed in through \(link.launcher)'s legendary (\(link.appName)); "
                                + "\(owned.count) DLC installed\(owned.isEmpty ? "" : ": " + owned.joined(separator: ", "))")
            out.note = "Signed in to Epic through \(link.launcher): DLC, cloud saves and achievements are available."
        } catch EpicLink.SignInError.notSignedIn(let launcher) {
            // Nothing to start offline as either: said plainly, once, without trying again.
            let why = EpicLink.SignInError.notSignedIn(launcher).localizedDescription
            out.logLines.append("Epic: not signed in — the game starts without an Epic account")
            out.note = why + " Until then the game starts without your Epic account, so its saves tied to the account and DLC don't appear."
            // The Epic page has the sign-in ready, right where it opens.
            if launcher == "Anvil" { Task { @MainActor in EpicAccount.shared.signInExpired = true } }
        } catch {
            out.logLines.append("Epic sign-in failed: \(error.localizedDescription)")
            // Still tell the game whose it is. Without an account id a game that keeps
            // saves per account — LEGO Star Wars does — has no profile to open.
            do {
                out.arguments = try await link.signInArguments(wine: wine, offline: true)
                out.startedOffline = true
                out.logLines.append("Epic: started offline as the signed-in account — saves found; DLC ownership unchecked this session (\(EpicOfflineWay.keptArguments.logMark))")
                out.note = "Couldn't reach Epic (\(error.localizedDescription)), so the game starts offline as your account: your saves are there, but DLC may not unlock until Epic can be reached."
            } catch let offline {
                out.logLines.append("Epic offline start failed too: \(offline.localizedDescription)")
                out.note = "Couldn't sign in to Epic (\(error.localizedDescription)). Starting without it — DLC and saves tied to your account may not appear."
            }
        }
        return out
    }

    /// Until the game reaches its first scene: then it says so in the Now Playing bar, and
    /// with a notice when the player is in another app (see GameReady). Only for a game whose
    /// sessions have always gone on into one; a load that runs far past its usual time is
    /// written down for the checks after the session.
    private func watchLoading(_ session: Session, logFrom offset: UInt64) {
        let game = session.game, title = game.title, log = Self.gameLogURL, id = session.id
        Task { @MainActor in
            let known = await Task.detached(priority: .utility) { () -> LoadTime.Estimate? in
                guard let text = try? String(contentsOf: log, encoding: .utf8),
                      Gameplay.loadsIntoHeavy(title: title, text: text) else { return nil }
                return LoadTime.estimate(of: title, text: text)
            }.value
            guard let known else { return }
            var read = offset
            var saidLong = false
            while self.sessions.contains(where: { $0.id == id }) {
                try? await Task.sleep(for: .seconds(2))
                let from = read
                let (lines, end) = await Task.detached(priority: .utility) { () -> ([String], UInt64) in
                    guard let handle = try? FileHandle(forReadingFrom: log) else { return ([], from) }
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEnd()) ?? from
                    // A log set aside for growing too big starts again from its beginning.
                    guard size > from else { return ([], size < from ? 0 : from) }
                    try? handle.seek(toOffset: from)
                    let data = (try? handle.readToEnd()) ?? Data()
                    // Only whole lines; a half-written one is read next time.
                    guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], from) }
                    let whole = data[data.startIndex..<lastNewline]
                    let lines = String(decoding: whole, as: UTF8.self).split(separator: "\n").map(String.init)
                    return (lines, from + UInt64(whole.count + 1))
                }.value
                read = end
                let elapsed = Date().timeIntervalSince(session.startedAt)
                if lines.contains(where: { FrameLog.parse(Substring($0)).flatMap(\.gpuBusy).map { $0 >= LoadTime.heavyGPU } ?? false }) {
                    self.readyAt[game.id] = Date()
                    // An Offline Test says nothing until it's over: a notice — or macOS asking whether
                    // Anvil may show them — would come up in front of the game being tested.
                    let front = GameReady.inFront(session) || self.offlineTests.contains(session.id)
                    AnvilLog.write("  loading: \(title) reached its first scene after \(LoadTime.text(elapsed))"
                                   + (front ? "" : " — behind another app; told the player"))
                    GameReady.shared.announce(game, after: elapsed, inFront: front)
                    return
                }
                if !saidLong, elapsed > max(3 * known.typical, 120) {
                    saidLong = true
                    AnvilLog.write("  loading: \(title) still loading after \(LoadTime.text(elapsed)) — it usually takes about \(LoadTime.text(known.typical))")
                }
                if elapsed > 900 { return }
            }
        }
    }

    /// Present while a game in this container was started offline. See anvil_net.mm.
    nonisolated static func offlineFlag(for container: Container) -> URL {
        RuntimeManager.support.appendingPathComponent("Cache/Offline/\(container.id.uuidString)")
    }

    nonisolated static func setOffline(_ offline: Bool, for container: Container) {
        let flag = offlineFlag(for: container)
        if offline {
            try? FileManager.default.createDirectory(at: flag.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: flag.path) { try? Data().write(to: flag) }
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    nonisolated static func format(_ duration: Duration) -> String {
        let (seconds, atto) = duration.components
        let ms = Double(seconds) * 1000 + Double(atto) / 1e15
        return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", ms / 1000)
    }

    @discardableResult
    func launch(game: Game, container: Container, runtime: Runtime,
                extraArguments: [String] = [], plain: Bool = false, isRetry: Bool = false,
                baseRuntime: Runtime? = nil) throws -> Session {
        guard runtime.isUsable else { throw LaunchError.runtimeMissing(runtime.displayName) }
        guard game.exists else { throw LaunchError.executableMissing(game.executablePath) }
        // Checked at every launch, not once at startup: a macOS update can remove
        // Rosetta, and installing it again should work without restarting Anvil.
        // Without this the only message was "Bad CPU type in executable".
        if SystemInfo.needsRosetta(runtime.wine64) && !SystemInfo.rosettaWorks() {
            AnvilLog.write("  Rosetta is not available — \(runtime.displayName) is Intel-only")
            throw LaunchError.rosettaMissing(runtime.displayName)
        }

        try FileManager.default.createDirectory(at: container.shaderCacheURL, withIntermediateDirectories: true)

        // Put D3DMetal's compiled shaders back before the game asks for them. macOS
        // purges its own cache directory on a schedule Anvil does not control, and a
        // purged cache is a game recompiling every pipeline it meets — felt as the
        // stutter that returns in a title that had already run smoothly.
        if container.protectShaderCache {
            ShaderCacheManager.restore(executable: game.executableURL.lastPathComponent)
        }

        // No fullscreen switch is appended here any more, and that is the fix for
        // the game closing a second after loading in.
        //
        // Anvil used to add `-screen-fullscreen 1`. Unity acts on that by asking
        // Windows to change the display mode, which under Wine goes through win32u —
        // and the game crashed there, right after the first scene finished loading.
        // A control run with the flag removed survived 6m40s; the same run with it
        // died every time. Every earlier control run had carried the flag too, which
        // is why the crash looked like the game's own and was reported as such twice.
        //
        // Fullscreen is set through the game's own preferences instead, in
        // UnitySettings, which does not touch the display mode.
        var launchArguments = game.arguments
        // Unity games: no Player.log unless asked for. See Container.keepGameLog —
        // under Wine 7.7 the log is where every controller report goes to be rejected.
        if !container.keepGameLog, Self.isUnityGame(game.executableURL),
           !launchArguments.contains(where: { $0.lowercased() == "-nolog" || $0.lowercased() == "-logfile" }) {
            launchArguments.append("-nolog")
        }
        // Steam's own window opens on its Library. On its Store page it never stopped
        // drawing — carousels and trailers, every pixel on the CPU — and took 80–88% of a core
        // sitting behind other windows; on its Library, 5–6% (9 October). Steam started
        // beside a game opens no window and isn't given it.
        if SteamSupport.isSteamClient(game), !launchArguments.contains(where: { $0.lowercased().hasPrefix("steam://") }) {
            // Or a game's install window, asked for on the Stores page with Steam closed.
            launchArguments.append(SteamSupport.shared.nextLink ?? SteamSupport.libraryURL)
            SteamSupport.shared.nextLink = nil
        }
        launchArguments += extraArguments

        let process = Process()
        // By its real path. Anvil's Game Mode copy keeps the engine's bin/ as a link to
        // Contents/MacOS, and a program started through the link is outside the app as far
        // as macOS is concerned — so it got no Game Mode, and Engine 3.0's games showed as
        // "CrossOver-Hosted Application" (1 October).
        let loader = runtime.wine64.resolvingSymlinksInPath()
        let profile = EngineProfile.of(runtime)
        process.executableURL = loader
        process.arguments = [game.executablePath] + launchArguments
        process.currentDirectoryURL = URL(fileURLWithPath: game.workingDirectory ?? game.executableURL.deletingLastPathComponent().path)

        var env = ProcessInfo.processInfo.environment
        env.merge(environment(for: game, in: container, runtime: runtime)) { _, new in new }
        // Looked at by Anvil's library in every Wine process of the session, the wineserver
        // that makes its connections included: the file is there while it starts offline.
        env["ANVIL_OFFLINE_FLAG"] = Self.offlineFlag(for: container).path
        let anvilLibrary = Bundle.main.resourceURL?.appendingPathComponent("libanvil.dylib").path ?? "libanvil.dylib"
        // Small pictures of what the game shows, for the check-up after it (ScreenReader) —
        // where Anvil's library goes in with its frame hook.
        if let screens = screensFolder {
            screensFolder = nil
            if !plain, env["ANVIL_HOOK_ENABLED"] != "0", env["DYLD_INSERT_LIBRARIES"]?.contains(anvilLibrary) == true {
                try? FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
                env["ANVIL_SCREENS"] = screens.path
            }
        }
        if plain, SteamSupport.isSteamClient(game), !isRetry {
            env = Self.storeClientEnvironment(env)
            AnvilLog.write("  Steam: with Anvil's library for Wine's connection table only — no frame hook, pacing or input changes — so Steam can tell its own sign-in window is the one connecting")
        } else if plain, let inserted = env["DYLD_INSERT_LIBRARIES"] {
            let others = inserted.split(separator: ":").map(String.init).filter { $0 != anvilLibrary }
            if others.isEmpty { env.removeValue(forKey: "DYLD_INSERT_LIBRARIES") }
            else { env["DYLD_INSERT_LIBRARIES"] = others.joined(separator: ":") }
            AnvilLog.write("  starting without Anvil's library\(isRetry ? " (retry after a failed start)" : " (switched off for this game)")")
        }
        // Wine 9 starts the game's own process with the loader it is told about, or one it
        // finds through bin/ — the link.
        if profile.needsLoaderPath { env["WINELOADER"] = loader.path }
        // That still wasn't enough for Game Mode. Engine 3.0's Wine copies its program into a
        // temporary folder (…/T/winetemp-…/wine, services.exe, …) and runs every process from
        // there, so each shows under its Windows name — and outside any app, whatever Anvil's
        // copy names: lsappinfo showed bundleID NULL for Steam on 1 October. CoreFoundation
        // takes the process's own path from CFProcessPath when it is set, so the game is
        // registered as Anvil's Game Mode app wherever Wine runs it from: tried on this Mac,
        // lsappinfo then gave dev.anvil.game.mythic-engine-3.0.0 and the bundle's path.
        if let appPath = GameModeEngine.processPath(for: runtime), profile.needsLoaderPath {
            env["CFProcessPath"] = appPath.path
        }
        // A Steam game finds the running Steam client by its app id, as when Steam starts it.
        if let appID = game.steamAppID {
            env["SteamAppId"] = appID
            env["SteamGameId"] = appID
        }
        let enhanced = env["DYLD_INSERT_LIBRARIES"]?.contains(anvilLibrary) ?? false
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let steamContainer = SteamSupport.isSteamClient(game) ? container.id : nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let steamContainer, SteamSupport.isWebHelperCrash(text) {
                Task { @MainActor in SteamSupport.shared.webHelperCrashed(containerID: steamContainer) }
            }
            // Also to disk. The in-app log dies with the window, and a game that
            // fails in the first fraction of a second says why exactly once.
            // Unity's rejection of Wine's empty raw-input messages arrives here once
            // per controller report. Counted, not copied — one line per report would
            // make the launch log the busiest file on the Mac.
            var kept: [Substring] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.contains("Invalid raw input data size") {
                    Self.rawInputRejections += 1
                    if Self.rawInputRejections % 500 == 1 {
                        AnvilLog.write("    game| Unity rejected an empty raw-input message from Wine (\(Self.rawInputRejections) so far)")
                    }
                } else if !line.contains("failed to reserve range") {
                    // A game that echoes its command line would otherwise write Epic's
                    // one-time sign-in code into the launch log.
                    kept.append(line.localizedCaseInsensitiveContains("auth_password")
                                ? Substring(Self.redactingSecrets(String(line))) : line)
                }
            }
            if !kept.isEmpty {
                AnvilLog.write("    game| " + kept.joined(separator: "\n    game| "))
                // The in-app log gets the same lines, not the rejections: one per
                // controller report would keep the main thread redrawing it all game.
                let shown = kept.joined(separator: "\n")
                Task { @MainActor in self?.append(shown) }
            }
        }

        var helper = ["WINEPREFIX": container.prefixURL.path, "WINEDEBUG": "-all"]
        for key in ["WINEMSYNC", "WINEESYNC"] { helper[key] = env[key] }
        let session = Session(game: game, process: process, startedAt: Date(),
                              container: container, runtime: runtime,
                              baseRuntime: baseRuntime ?? runtime, enhanced: enhanced, isRetry: isRetry,
                              helperEnvironment: helper,
                              screens: env["ANVIL_SCREENS"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        let exeName = game.executableURL.lastPathComponent
        let keepShaders = container.protectShaderCache
        process.terminationHandler = { [weak self] _ in
            // Take the grown cache back while it still exists. Doing this on exit
            // rather than periodically means a cache is only ever kept once the run
            // that produced it finished.
            if keepShaders { ShaderCacheManager.capture(executable: exeName) }
            Task { @MainActor in self?.finish(session) }
        }

        AnvilLog.write("  running: \(loader.path) \(Self.redacted(process.arguments ?? []).joined(separator: " "))")
        AnvilLog.write("  engine: \(profile.title) — " + profile.adjustments.joined(separator: "; "))
        AnvilLog.write("  cwd: \(process.currentDirectoryURL?.path ?? "?")")
        // Every variable Anvil itself contributes, so a launch can be reproduced
        // outside the app exactly as it ran inside it.
        let inherited = ProcessInfo.processInfo.environment
        for (key, value) in env.sorted(by: { $0.key < $1.key })
        where inherited[key] != value || key.hasPrefix("WINE") || key.hasPrefix("ANVIL") {
            AnvilLog.write("  env \(key)=\(value)")
        }
        do { try process.run() }
        catch {
            AnvilLog.write("  process.run threw: \(error.localizedDescription)")
            throw error
        }
        sessions.append(session)
        append("▶︎ Launched \(game.title) in “\(container.name)” via \(runtime.displayName)")
        // Steam itself: its own download, if it is updating, shown while it runs.
        if SteamSupport.isSteamClient(game) { SteamSupport.shared.watchUpdate(in: container) }
        // Recently played goes to the front of every quick-launch list straight away,
        // not only once the session ends.
        if var stored = Library.shared.games.first(where: { $0.id == game.id }) {
            stored.lastPlayed = session.startedAt
            Library.shared.update(stored)
        }
        PowerState.shared.gamesRunning(sessions.map(\.game.title))

        // Step aside so the game can take the screen and the controller. Without
        // this the game opens behind Anvil and stays there: macOS will not let a
        // process launched by the active app pull focus from it, and a borderless
        // window does not force its way forward the way exclusive fullscreen did.
        GameFocus.handOff(to: game, startedAt: session.startedAt)
        return session
    }

    /// Arguments as they may be written down. Epic's sign-in carries a one-time
    /// exchange code — a credential — and the account's name and id; none of those
    /// belong in a log file.
    nonisolated static func redacted(_ arguments: [String]) -> [String] {
        arguments.map { arg in
            let lower = arg.lowercased()
            for key in ["-auth_password=", "-epicusername=", "-epicuserid="] where lower.hasPrefix(key) {
                return String(arg.prefix(key.count)) + "<hidden>"
            }
            return arg
        }
    }

    /// `redacted`, for free text rather than an argument list.
    nonisolated static func redactingSecrets(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { redacted([String($0)])[0] }
            .joined(separator: " ")
    }

    // MARK: Quitting

    func session(for game: Game) -> Session? { sessions.first { $0.game.id == game.id } }
    func isRunning(_ game: Game) -> Bool { session(for: game) != nil }

    /// Whether D3DMetal offers a game ray tracing, and the launch log's line about it (nil when there's nothing
    /// to say: not a DirectX 12 game, or one without ray-traced effects).
    nonisolated static func rayTracing(for game: Game, container: Container) -> (on: Bool, line: String?) {
        let analysis = GameAnalysis.cached(for: game.executableURL)
        guard analysis?.primary == .d3d12 || analysis?.apis.contains(.d3d12) == true else { return (container.raytracing, nil) }
        let offers = GameAnalysis.offersRayTracing(executable: game.executableURL)
        let hardware = MetalCapability.current.hardwareRayTracing
        if let chosen = game.rayTracing {
            return (chosen, "ray tracing: \(chosen ? "on" : "off"), as chosen for \(game.title)")
        }
        guard offers else { return (container.raytracing, nil) }
        if hardware {
            return (true, "ray tracing: on — \(game.title) has ray-traced effects, and this Mac's GPU (\(MetalCapability.current.deviceName)) traces rays in hardware; they're the game's to turn on in its own graphics settings")
        }
        return (container.raytracing, "ray tracing: \(container.raytracing ? "on, as its profile chose" : "off") — \(game.title) has ray-traced effects, but this Mac's GPU traces rays in its shader cores, too slowly to be worth them (M3 and later do it in hardware)")
    }
    /// Running, or on its way: what Autopilot and Auto-Tune must not change under.
    func isBusy(_ game: Game) -> Bool { isRunning(game) || launchingGameID == game.id }
    /// Nothing running and nothing starting.
    var isIdle: Bool { sessions.isEmpty && launching == nil }
    func isClosing(_ game: Game) -> Bool { session(for: game).map { closing.contains($0.id) } ?? false }

    /// How long a game gets to close by itself before it is forced.
    nonisolated static let quitGrace: Duration = .seconds(8)

    /// Close a game the way its own close box would: WM_CLOSE to its windows, through
    /// Wine's taskkill (no /F — checked in Wine 7.7's source, it posts WM_CLOSE to every
    /// top-level window of the process). A game that saves on exit gets to. Still
    /// running after `quitGrace`, it is force-quit.
    ///
    /// The old Force Quit sent SIGTERM to the game's process, which Wine turns into
    /// ending the one thread that receives it — so it often closed nothing.
    func quit(_ game: Game, grace: Duration = quitGrace) {
        guard let session = session(for: game), !closing.contains(session.id) else { return }
        closing.insert(session.id)
        AnvilLog.write("quit: asking \(game.title) to close")
        append("Closing \(game.title)…")
        let exe = game.executableURL.lastPathComponent
        let wine = session.baseRuntime.wine64
        let env = session.helperEnvironment
        let id = session.id
        Task.detached(priority: .userInitiated) {
            let status = Self.runHelper(wine, ["taskkill", "/IM", exe], environment: env, timeout: 10)
            AnvilLog.write("  taskkill /IM \(exe): \(status.map { "exit \($0)" } ?? "timed out")")
        }
        let prefix = session.container.prefixURL
        Task { @MainActor in
            try? await Task.sleep(for: grace)
            // Still writing its save: not forced in the middle of it. Up to half a minute
            // more, for as long as anything in its saves keeps changing.
            var waited = 0
            while waited < 30, self.sessions.contains(where: { $0.id == id }),
                  await Task.detached(priority: .userInitiated, operation: { SaveGuard.isWriting(prefix: prefix, within: 3) }).value {
                if waited == 0 { AnvilLog.write("  \(game.title) is still saving — waiting for it before forcing") }
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
            guard let still = self.sessions.first(where: { $0.id == id }) else { return }
            AnvilLog.write("  \(still.game.title) still running after \(grace)\(waited > 0 ? " and \(waited) s of saving" : "") — forcing")
            self.forceQuit(still.game)
        }
    }

    /// End a game now. `wineserver -k` ends every process in the prefix — the game,
    /// anything it started, and Wine's own services — then saves the registry before
    /// the server exits (Wine 7.7, server/process.c shutdown_master_socket). If another
    /// game shares the prefix, only this game's process is ended.
    func forceQuit(_ game: Game) {
        guard let session = session(for: game) else { return }
        closing.insert(session.id)
        AnvilLog.write("force quit: \(game.title)")
        append("Force quitting \(game.title)…")
        let shared = sessions.contains { $0.id != session.id && $0.container.id == session.container.id }
        let pid = session.process.processIdentifier
        let server = session.baseRuntime.wineserver, prefix = session.container.prefixURL
        let id = session.id
        Task.detached(priority: .userInitiated) {
            if shared { kill(pid, SIGKILL) } else { Self.killPrefix(wineserver: server, prefix: prefix) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard let s = self.sessions.first(where: { $0.id == id }), s.process.isRunning else { return }
            kill(s.process.processIdentifier, SIGKILL)
            AnvilLog.write("  \(s.game.title) outlived wineserver -k — killed its process")
        }
    }

    func quitAll() { for s in sessions { quit(s.game) } }

    /// Run a Wine program into a running prefix and wait for it, at most `timeout`.
    nonisolated static func runHelper(_ wine: URL, _ arguments: [String],
                                      environment: [String: String], timeout: TimeInterval) -> Int32? {
        let p = Process()
        p.executableURL = wine
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        return p.terminationStatus
    }

    /// `wineserver -k` for one prefix. Waits up to ~10 s, as wineserver itself does.
    nonisolated static func killPrefix(wineserver: URL, prefix: URL) {
        let p = Process()
        p.executableURL = wineserver
        p.arguments = ["-k"]
        p.environment = ["WINEPREFIX": prefix.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Waiting on a process that never started raises rather than returns.
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    /// Ask wineserver to shut the prefix down cleanly. Killing wine64 alone can leave
    /// a wineserver holding the registry mid-write, which is how prefixes get corrupted.
    /// Off the main thread: wineserver -k can wait up to ten seconds.
    func shutdown(container: Container, runtime: Runtime) {
        let server = runtime.wineserver, prefix = container.prefixURL
        Task.detached(priority: .utility) { Self.killPrefix(wineserver: server, prefix: prefix) }
    }

    /// How the exit line marks a game ended by SIGKILL from outside (GameDoctor.crashCause).
    nonisolated static let killedMark = "(ended from outside: SIGKILL)"

    /// `task`'s value if it is ready within `limit`, else nil at once — the task carries on.
    nonisolated static func firstOf<T: Sendable>(_ task: Task<T, Never>, orNilAfter limit: Duration) async -> T? {
        let once = FirstOnly()
        return await withCheckedContinuation { (result: CheckedContinuation<T?, Never>) in
            Task { let value = await task.value; if once.claim() { result.resume(returning: value) } }
            Task { try? await Task.sleep(for: limit); if once.claim() { result.resume(returning: nil) } }
        }
    }

    private func finish(_ session: Session) {
        AnvilLog.write("  memory after \(session.game.title): \(SystemInfo.memory().summary)")
        let userClosed = closing.remove(session.id) != nil
        let wasTest = offlineTests.remove(session.id) != nil
        sessions.removeAll { $0.id == session.id }
        runsBehind.remove(session.game.id)
        readyAt[session.game.id] = nil
        Tuner.shared.sessionEnded(game: session.game, userClosed: userClosed)
        if !wasTest { LearnStore.shared.sessionEnded(game: session.game) }
        PowerState.shared.gamesRunning(sessions.map(\.game.title))
        if sessions.isEmpty {
            GameFocus.reclaim()
            // An engine whose warm-up gave way to this game carries on now, after
            // Autopilot's look at the session and the prefix shutting down.
            EngineOptimizer.shared.prepareWhenIdle()
        }

        // Play time. Game.totalPlaySeconds and lastPlayed existed from the start and
        // nothing ever wrote them, so every game read "0 min".
        let played = ProcessInfo.processInfo.systemUptime - session.startedUptime
        if played >= 10, !wasTest, var stored = Library.shared.games.first(where: { $0.id == session.game.id }) {
            stored.totalPlaySeconds += played
            stored.lastPlayed = Date()
            Library.shared.update(stored)
            // And how it ran, from the library's own frame statistics. Not for a store's own window:
            // Anvil's frame hook isn't in it, so it has none.
            let gameID = session.game.id, title = session.game.title, log = Self.gameLogURL
            if StoreArt.store(of: session.game) == nil { Task.detached(priority: .utility) {
                guard let stats = SessionStats.read(log: log, title: title) else { return }
                await MainActor.run {
                    guard var game = Library.shared.games.first(where: { $0.id == gameID }) else { return }
                    game.lastSession = stats
                    Library.shared.update(game)
                    AnvilLog.write(String(format: "  frame rate: %.0f fps on average over %@; 80 or more %.0f%% of the time, 120 %.0f%%; lowest 1%% low %.0f fps",
                                          stats.averageFPS, GameDoctor.minutesText(stats.minutes), stats.shareAt80 * 100, stats.shareAt120 * 100, stats.lowestOnePercent))
                }
            } }
        }

        // The game's own upscaler: what the session showed, and Automatic's quality for its next start (GameUpscaler).
        if played >= 60, !wasTest, GameUpscaler.profile(for: session.game) != nil {
            let game = session.game, container = session.container, log = Self.gameLogURL
            Task.detached(priority: .utility) {
                let play = FrameLog.lastSession(of: game.title, in: log).map { Gameplay.split($0.windows).play } ?? []
                for line in GameUpscaler.afterSession(game, in: container, play: play) { AnvilLog.write("\(game.title): " + line) }
            }
        }

        // Shut the prefix down once nothing is using it. A wineserver outlives the
        // game it served, and one left holding a prefix is why a relaunch a few
        // seconds later can fail — observed here as launches that died after 0.2 s,
        // 15 s and 21 s in a row, then worked once things had settled. Asking
        // wineserver to stop is also the documented way to avoid a half-written
        // registry, which is how prefixes get corrupted.
        let stillUsingPrefix = sessions.contains { $0.container.id == session.container.id }
        if !stillUsingPrefix {
            // The session's own network rule ends with it.
            Self.setOffline(false, for: session.container)
            let container = session.container, runtime = session.runtime
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !self.sessions.contains(where: { $0.container.id == container.id }) else { return }
                // Steam started for the game closes properly first, finishing its cloud saves.
                await SteamSupport.shared.closeHelper(in: container, runtime: runtime)
                guard !self.sessions.contains(where: { $0.container.id == container.id }) else { return }
                self.shutdown(container: container, runtime: runtime)
                AnvilLog.write("wineserver shut down for “\(container.name)”")
                // Save files the session left empty — a game ended while writing one — put
                // back from the copy taken before it started.
                try? await Task.sleep(for: .seconds(3))
                guard !self.sessions.contains(where: { $0.container.id == container.id }), self.launching == nil else { return }
                let prefix = container.prefixURL, id = container.id, began = session.startedAt
                let repairs = await Task.detached(priority: .utility) { () -> [SaveGuard.Repair] in
                    guard let backup = SaveGuard.backup(for: id, before: began) else { return [] }
                    return SaveGuard.repairEmptied(prefix: prefix, since: backup)
                }.value
                if !repairs.isEmpty {
                    let names = repairs.map { ($0.path as NSString).lastPathComponent }
                    AnvilLog.write("saves: \(repairs.count) save file(s) of \(session.game.title) were left empty — put back from before the session: " + repairs.map(\.path).joined(separator: ", "))
                    self.append("\(session.game.title) left \(repairs.count == 1 ? "a save file" : "\(repairs.count) save files") empty (\(names.prefix(3).joined(separator: ", "))) — put back as they were before this session.")
                }
            }
        }
        append(userClosed ? "■ \(session.game.title) closed"
                          : "■ \(session.game.title) exited (code \(session.process.terminationStatus))")
        // Ended by SIGKILL from another process: a force quit from outside Anvil, or macOS freeing
        // memory. Nothing inside the game can cause it, so it isn't a crash to blame FSR for — on
        // 10 October one such end of LEGO Star Wars turned its FSR 3 off.
        let killed = session.process.terminationReason == .uncaughtSignal && session.process.terminationStatus == SIGKILL
        AnvilLog.write("exited: \(session.game.title) code=\(session.process.terminationStatus) after \(String(format: "%.1f", Date().timeIntervalSince(session.startedAt)))s"
                       + String(format: ", %.0f s of it awake", played)
                       + (userClosed ? " (closed from Anvil)" : killed ? " \(Self.killedMark)" : ""))

        // A game that fails to start with Anvil's library loaded gets one more try
        // without it. If that one runs, the library is switched off for the game (see
        // prepareAndLaunch); if it fails too, the library was not the cause. A game the
        // user closed did not fail, however soon it was closed.
        let ran = Date().timeIntervalSince(session.startedAt)
        let status = session.process.terminationStatus
        Autopilot.shared.sessionEnded(game: session.game,
                                      outcome: .init(status: status, seconds: ran, userClosed: userClosed))

        // An engine on trial. A game that won't start on it, or crashes on it, sends the
        // container back to the engine it came from — that one is known to work, and the
        // snapshot taken before the switch is there if anything else is wanted back.
        var revertedEngine = false
        if var fresh = Library.shared.container(id: session.container.id), let trial = fresh.engineTrial,
           fresh.runtimeID == trial.toRuntimeID, session.baseRuntime.id == trial.toRuntimeID {
            if !userClosed && status != 0 {
                fresh.runtimeID = trial.fromRuntimeID
                fresh.engineTrial = nil
                // Not offered by Autopilot again here; it can still be chosen by hand.
                fresh.reject(trial.toRuntimeID)
                Library.shared.update(fresh)
                revertedEngine = true
                let old = RuntimeManager.shared.runtime(id: trial.fromRuntimeID)
                let what = ran < 25 ? "didn't start" : "closed unexpectedly"
                AnvilLog.write("  engine trial: \(session.game.title) \(what) on \(trial.toRuntimeID) (code \(status)) — “\(fresh.name)” is back on \(trial.fromRuntimeID)")
                append("\(session.game.title) \(what) on \(session.baseRuntime.displayName), so “\(fresh.name)” is back on \(old?.displayName ?? trial.fromRuntimeID).")
                if ran < 25, let old {
                    let game = session.game, oldServer = session.baseRuntime
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        await Self.waitForWineserver(container: fresh, runtime: oldServer, timeout: 15)
                        do { _ = try await self.prepareAndLaunch(game: game, container: fresh, runtime: old) }
                        catch { AnvilLog.write("  start on \(old.displayName) after the engine trial failed: \(error.localizedDescription)") }
                    }
                }
            } else if ran >= 60 {
                var t = trial
                t.goodSessions += 1
                // Kept only once a measured session has compared it with the old engine.
                // Sessions spent in menus, or too short to measure, show only that it
                // starts: on 1 October Engine 3.0 was kept for LEGO Star Wars after three
                // such sessions, the first measured play on it at 58 fps against 81.
                fresh.engineTrial = (t.judged && t.goodSessions >= EngineTrial.sessionsToKeep) ? nil : t
                Library.shared.update(fresh)
                if fresh.engineTrial == nil {
                    AnvilLog.write("  engine trial: \(trial.toRuntimeID) kept for “\(fresh.name)” after \(t.goodSessions) good sessions")
                }
            }
        }

        // Steam restarts itself after an update: it exits with 42 and expects to be
        // started again. Steam from a Whisky bottle did exactly that on 30 September,
        // after four minutes of updating, and stayed closed.
        let steamRestart = !userClosed && status == 42
            && session.game.executableURL.lastPathComponent.lowercased() == "steam.exe"
        if steamRestart {
            AnvilLog.write("  Steam updated itself and asked to be started again — starting it")
            append("Steam updated itself; starting it again…")
            let game = session.game, container = session.container, runtime = session.baseRuntime
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await Self.waitForWineserver(container: container, runtime: runtime, timeout: 15)
                if let fresh = Library.shared.games.first(where: { $0.id == game.id }),
                   let freshContainer = Library.shared.container(id: fresh.containerID) {
                    do { _ = try await self.prepareAndLaunch(game: fresh, container: freshContainer, runtime: runtime) }
                    catch { AnvilLog.write("  Steam's restart could not start: \(error.localizedDescription)") }
                }
            }
        }

        if userClosed || revertedEngine || steamRestart || wasTest {
            // Nothing to retry: an Offline Test says how its start went itself.
        } else if session.enhanced && !session.isRetry && status != 0 && ran < 25 {
            AnvilLog.write("  \(session.game.title) failed to start with Anvil's library (code \(status) after \(String(format: "%.1f", ran)) s) — trying once without it")
            append("\(session.game.title) closed straight away. Trying once more without Anvil's enhancements…")
            let game = session.game, container = session.container, runtime = session.baseRuntime
            Task { @MainActor in
                // Let the prefix finish shutting down first.
                try? await Task.sleep(for: .seconds(2))
                await Self.waitForWineserver(container: container, runtime: runtime, timeout: 15)
                do { _ = try await self.prepareAndLaunch(game: game, container: container, runtime: runtime, plainRetry: true) }
                catch { AnvilLog.write("  retry without Anvil's library could not start: \(error.localizedDescription)") }
            }
        } else if session.isRetry && status != 0 && ran < 25 {
            AnvilLog.write("  \(session.game.title) fails without Anvil's library too — not caused by it; enhancements left on")
            append("\(session.game.title) also closes without Anvil's enhancements, so they aren't the cause. The launch log has the details.")
        }
    }

    private func append(_ text: String) { output.append(text) }
    /// A line in the in-app log from elsewhere in Anvil.
    func note(_ text: String) { append(text) }

    enum LaunchError: LocalizedError {
        case runtimeMissing(String)
        case executableMissing(String)
        case rosettaMissing(String)
        case alreadyStarting
        case engineChanged(String, [String])
        case diskFull(String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing(let name): "Runtime “\(name)” is not installed or not executable."
            case .executableMissing(let path): "No executable at \(path)."
            case .alreadyStarting: "A game is already starting."
            case .engineChanged(let name, let files):
                "\(files.count) file\(files.count == 1 ? "" : "s") in \(name) changed since Anvil sealed it (\(files.prefix(3).joined(separator: ", "))\(files.count > 3 ? ", …" : "")), so Anvil won't run games on it. Open Engines and choose Repair: the changed copy goes to the Trash and a clean one is installed."
            case .diskFull(let free):
                "This Mac has only \(free) free. A game saving onto a full disk can lose its save, so Anvil won't start one until at least 1 GB is free. Empty the Trash or remove files you don't need, then press Play again."
            case .rosettaMissing(let name): "Rosetta isn't installed, and \(name) is an Intel program, so no Windows game can start. macOS updates can remove it. Reinstall it by running this in Terminal, then press Play again:\n\nsoftwareupdate --install-rosetta --agree-to-license"
            }
        }
    }
}

extension HUDConfig {
    /// Anvil's own counter covers it: the frame rate, and whether the Mac is hot.
    var anvilDrawsIt: Bool { widgets.contains(.fps) && widgets.isSubset(of: [.fps, .thermal]) }

    /// Metal's HUD is driven entirely by environment variables, which is why Anvil can
    /// offer per-widget control instead of one on/off switch.
    func environment() -> [String: String] {
        guard enabled, !widgets.isEmpty else { return ["MTL_HUD_ENABLED": "0"] }
        var env: [String: String] = [
            "MTL_HUD_ENABLED": "1",
            "MTL_HUD_ALPHA": String(format: "%.2f", opacity),
            // Apple's panel at more than its own size covers much of a game's screen on a Retina display.
            "MTL_HUD_SCALE": String(format: "%.2f", min(scale, 1.0)),
            "MTL_HUD_ALIGNMENT": position
        ]
        // Ordering follows the canonical widget order so the overlay layout is stable
        // whichever subset the user picked.
        let ordered = HUDWidget.allCases.filter { widgets.contains($0) }
        env["MTL_HUD_ELEMENT_ORDER"] = ordered.map(\.hudElement).joined(separator: ",")
        return env
    }
}
