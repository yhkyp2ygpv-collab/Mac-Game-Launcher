import Foundation

/// The best container settings for one game on this Mac, for a goal — with a reason
/// for every change.
///
/// Rules rather than measurements, because every one of them has been measured
/// already: the refresh lock (900 of 900 gaps on the grid), three frames in flight
/// (two missed up to 79 refreshes), one frame in flight (no latency gained), MSync
/// (the fastest synchronisation Wine has on Apple silicon), no generated frames (every
/// session with them drew a report of distorted motion). What is left to decide per
/// game — which DirectX it uses, which engine suits that, how the goal wants frames
/// paced — is read from the game's own files and the engines on this Mac, so the advice
/// needs no connection. Auto-Tune then measures what only the game can tell.
enum ContainerAdvisor {
    struct Change: Identifiable, Hashable {
        var id: String { title }
        var title: String
        var from: String
        var to: String
        var reason: String
    }

    struct EngineChoice: Hashable {
        var runtimeID: String
        var name: String
        var reason: String
    }

    struct Advice {
        /// The container as recommended, engine left as it is.
        var recommended: Container
        var changes: [Change]
        /// A better engine for this game, when one is installed. Switched only by hand.
        var engine: EngineChoice?
        /// What is already right, and what Anvil can't change for this game.
        var notes: [String]
        /// Other games that share the container and would get the same settings.
        var sharedWith: [String]

        var isOptimal: Bool { changes.isEmpty && engine == nil }
    }

    struct Engine: Hashable {
        var id: String
        var name: String
        var d3dMetal: String?
        var rank: [Int]
        var usable: Bool
    }

    static func engines(_ runtimes: [Runtime]) -> [Engine] {
        runtimes.map { Engine(id: $0.id, name: $0.displayName, d3dMetal: $0.d3dMetalVersion, rank: $0.d3dMetalRank, usable: $0.isUsable) }
    }

    static func advise(game: Game, container: Container, goal: TuneGoal, analysis: GameAnalysis?,
                       engines: [Engine], otherGames: [String], displayIsProMotion: Bool = true) -> Advice {
        var c = container
        var changes: [Change] = []
        var notes: [String] = []
        func on(_ b: Bool) -> String { b ? "On" : "Off" }
        func set<T: Equatable>(_ keyPath: WritableKeyPath<Container, T>, _ value: T, _ title: String,
                               _ describe: (T) -> String, _ reason: String) {
            guard c[keyPath: keyPath] != value else { return }
            changes.append(Change(title: title, from: describe(c[keyPath: keyPath]), to: describe(value), reason: reason))
            c[keyPath: keyPath] = value
        }
        let api = analysis?.primary
        let current = engines.first { $0.id == container.runtimeID }

        // Graphics backend.
        switch api {
        case .d3d10?, .d3d11?, .d3d12?:
            if current?.d3dMetal != nil {
                set(\.backend, .d3dmetal, "Graphics", { $0.title },
                    "\(api!.title) runs natively on Metal through D3DMetal, the fastest path this Mac has for it, and the one Anvil's FSR reaches.")
            }
        case .d3d9?:
            notes.append("DirectX 9 isn't something D3DMetal or DXVK for macOS translates; Wine's own renderer draws it on OpenGL whichever graphics setting is chosen, and Anvil's FSR can't reach it.")
        case .vulkan?:
            notes.append("Vulkan goes through MoltenVK to Metal; the graphics setting doesn't change it.")
        case .opengl?:
            notes.append("OpenGL goes through macOS's own OpenGL; the graphics setting doesn't change it.")
        case nil:
            break
        }
        if api == .d3d12 && goal == .quality {
            set(\.raytracing, true, "Ray tracing", on,
                "For Best graphics, a DirectX 12 game that offers ray tracing may use it. It is the most expensive thing D3DMetal can be asked to do.")
        } else {
            set(\.raytracing, false, "Ray tracing", on,
                "The most expensive thing D3DMetal can be asked to do; kept for the Best graphics goal in DirectX 12 games.")
        }

        // Presentation: the settings measured on this Mac.
        set(\.lockToRefresh, true, "Lock to the display's refresh", on,
            "Every frame on the panel's own grid — measured here as 900 of 900 gaps exactly one refresh apart — with three frames in flight to absorb one that runs long. Also what lets Anvil measure the game.")
        set(\.lowLatencyQueue, false, "One frame in flight", on,
            "Measured: no lower latency than two, and dozens of missed refreshes at the start of every session.")
        // Generated frames are the player's choice (Upscaling): on for every game since 0.26.0,
        // as asked for on 3 October. This used to set them off after every session, which put
        // a container straight back to real frames only.
        let pacing = displayIsProMotion ? goal.pacing : 0
        set(\.targetFPS, pacing, "Frame pacing", { $0 == 80 ? "Steady 80+" : $0 == 0 ? "Up to 120" : "Held at \($0)" },
            goal == .maxFPS ? "Every frame as soon as it's ready, for the most frames and the least delay."
                            : "120 while the game can hold it, an even 80 while it can't — steady instead of moving with the scene.")

        // CPU and caches.
        set(\.sync, .msync, "Synchronisation", { $0.title }, "Mach-port synchronisation is the fastest Wine has on Apple silicon.")
        set(\.avx2, true, "AVX for Rosetta", on, "Games built for AVX run their fast paths instead of falling back or refusing to start.")
        set(\.rosettaAOT, true, "Keep Rosetta's translations", on, "Translated code is kept between sessions, so the first minutes of play don't hitch.")
        set(\.persistentShaderCache, true, "Keep compiled shaders", on, "Shaders compiled once stay compiled — the biggest lever against stutter in new areas.")
        set(\.protectShaderCache, true, "Protect the shader cache", on, "macOS clears its own cache folder on a schedule; Anvil keeps a copy and puts it back.")
        set(\.gameMode, true, "Game Mode", on, "macOS gives the game priority on the CPU and GPU, and lowers Bluetooth latency.")
        set(\.highPriority, true, "Game threads at interactive priority", on, "Keeps a busy game's threads off the efficiency cores.")
        set(\.keepGameLog, false, "Unity's own log", on, "Under Wine every controller report is rejected into it on the game's main thread; it cost Cat Quest II frames.")

        // Resolution, for a game that draws at its window's size.
        if analysis?.rendersAtWindowSize == true {
            let half = container.profile.renderScale() < 1.5
            let wantHalf = goal == .maxFPS
            if half != wantHalf {
                let profile: PerformanceProfile = wantHalf ? .smoothest : .sharpest
                changes.append(Change(title: "Resolution", from: half ? "Half, upscaled" : "Full",
                                      to: wantHalf ? "Half, upscaled" : "Full",
                                      reason: wantHalf ? "Rendering a quarter of the pixels is the largest frame-rate gain a game like this has."
                                                       : "Every pixel the display has; this game draws at its window's size, so it is Anvil's to choose."))
                profile.apply(to: &c)
            }
        } else if analysis != nil {
            notes.append("This game sets its own resolution, so it is chosen in the game's options — or by Auto-Tune's graphics levels where Anvil knows the game.")
        }

        // Engine: the newest D3DMetal installed, for a DirectX 11 or 12 game.
        var engineChoice: EngineChoice?
        if api == .d3d11 || api == .d3d12 {
            let candidates = engines.filter { $0.usable && $0.d3dMetal != nil }
            let currentRank = current?.d3dMetal != nil ? (current?.rank ?? []) : []
            if let best = candidates.max(by: { $0.rank.lexicographicallyPrecedes($1.rank) }),
               best.id != container.runtimeID, currentRank.lexicographicallyPrecedes(best.rank) {
                engineChoice = EngineChoice(
                    runtimeID: best.id, name: best.name,
                    reason: "Its D3DMetal is \(best.d3dMetal ?? "newer")"
                        + (current?.d3dMetal.map { " against \($0) in \(current?.name ?? "the current engine")" } ?? "")
                        + " — the part that decides how a DirectX \(api == .d3d12 ? "12" : "11") game runs.")
            } else if let current, current.d3dMetal != nil {
                notes.append("\(current.name) already has the newest D3DMetal installed (\(current.d3dMetal!)).")
            }
        }

        return Advice(recommended: c, changes: changes, engine: engineChoice, notes: notes, sharedWith: otherGames)
    }
}
