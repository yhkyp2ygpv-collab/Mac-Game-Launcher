import Foundation

/// Optimize for This Mac, from a game's Performance tab: everything Anvil does to make a game run its best here, done
/// now rather than at its next start, each step real work with its progress and the time it should take; then what the
/// game still needs from this Mac and its last sessions, plainly. No connection needed: nothing here is fetched, except
/// Microsoft's Visual C++ Runtime when a game needs it and the Mac has no copy (and then only with a connection).
enum OptimizePass {
    struct Step: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done, skipped, failed }
        let id: String
        let title: String
        var state: State = .waiting
        var result: String?
        /// How long it should take, in seconds: what it took before where Anvil measured it.
        var expected: Double
    }

    /// Something the game needs, or that's as it should be.
    struct Need: Identifiable, Equatable {
        enum Kind: Int { case act = 0, fine }
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        /// Its row's identity beside the steps' in one list: "memory" is both a step and a need.
        var rowID: String { "need-" + id }
    }

    /// What `needs` decides from: this Mac now, the game's settings here and how its sessions went.
    struct Inputs: Equatable {
        var memoryNeeded: Int64?
        var memoryFree: Int64
        var biggestApps: [String] = []
        var lowPowerMode = false
        var hot = false
        var diskFree: Int64?
        var unreal = false
        var fromStore = false
        var unrealTuning = true
        var tuningDeclined = false
        var tuningSummary: [String] = []
        var prepFailed: String?
        var prepareGraphics = true
        var warmMemory = true
        var enhancementsOff = false
        var visualCMissing: String?
        var averageFPS: Double?
        var shareAt80: Double?
        var rayTraced = false
        var ownStuttersPerMinute: Double?
    }

    static func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    /// What the game needs, most important first, then what's fine.
    static func needs(_ i: Inputs) -> [Need] {
        var act: [Need] = []
        var fine: [Need] = []
        if i.enhancementsOff {
            act.append(Need(id: "library", kind: .act, title: "Anvil's library is off for this game",
                            detail: "No frame pacing, FSR, frame generation or controller fixes run in it. Turn Anvil's enhancements on in its settings, unless it failed to start with them."))
        }
        if let need = i.memoryNeeded {
            if need + (1 << 30) > i.memoryFree {
                act.append(Need(id: "memory", kind: .act, title: "Free memory before playing",
                                detail: "The game took up to \(gb(need)) in its recent sessions and \(gb(i.memoryFree)) is free now, so macOS will move memory to the SSD as it plays — felt as hitches, most of all while it streams the world in."
                                    + (i.biggestApps.isEmpty ? "" : " Using the most now: \(i.biggestApps.joined(separator: ", ")).")
                                    + " A step lower Texture Quality in its own settings frees the most memory for no frame rate."))
            } else {
                fine.append(Need(id: "memory", kind: .fine, title: "Enough memory free",
                                 detail: "It took up to \(gb(need)) in its recent sessions; \(gb(i.memoryFree)) is free."))
            }
        }
        if i.lowPowerMode {
            act.append(Need(id: "power", kind: .act, title: "Turn Low Power Mode off",
                            detail: "It slows the GPU and CPU down to save the battery. System Settings › Battery."))
        }
        if i.hot {
            act.append(Need(id: "heat", kind: .act, title: "The Mac is hot",
                            detail: "macOS slows it down until it cools. Give it a hard, flat surface and room to breathe."))
        }
        if !i.lowPowerMode && !i.hot {
            fine.append(Need(id: "power", kind: .fine, title: "Full power", detail: "Low Power Mode off, and the Mac cool."))
        }
        if let free = i.diskFree, free < 5 * 1_073_741_824 {
            act.append(Need(id: "disk", kind: .act, title: "Free some disk space",
                            detail: "Only \(gb(free)) free: games, their shader caches and the SSD's swap need room."))
        }
        if let missing = i.visualCMissing {
            act.append(Need(id: "vc", kind: .act, title: "Microsoft's Visual C++ Runtime isn't in its setup", detail: missing))
        }
        if let failed = i.prepFailed {
            act.append(Need(id: "prep", kind: .act, title: "Graphics Prep didn't finish", detail: failed))
        } else if !i.prepareGraphics {
            act.append(Need(id: "prep", kind: .act, title: "Graphics Prep is off",
                            detail: "Anvil's FSR and frame generation are compiled for this Mac only at its start, a stutter each. Turn Graphics Prep on in its Graphics section."))
        }
        if !i.warmMemory {
            act.append(Need(id: "warm", kind: .act, title: "The memory warm-up is off",
                            detail: "With it on, the parts of the game played most are read into memory as it starts, so fewer stutters come from reading its data."))
        }
        if i.unreal {
            if !i.fromStore {
                act.append(Need(id: "unreal", kind: .act, title: "Unreal Engine tuning needs the game from a store",
                                detail: "It's only for games bought on Steam or Epic and installed through Anvil. Install it from Steam or Epic in Anvil to have its engine tuned for this Mac."))
            } else if !i.unrealTuning {
                act.append(Need(id: "unreal", kind: .act, title: "Unreal Engine tuning is off",
                                detail: i.tuningDeclined ? "Turned off at its first start. Turn Tune Unreal Engine for this Mac on in Unreal Engine Tuning to have its settings tried here."
                                                         : "Turn Tune Unreal Engine for this Mac on in Unreal Engine Tuning."))
            } else {
                fine.append(Need(id: "unreal", kind: .fine, title: "Unreal Engine tuned for this Mac",
                                 detail: i.tuningSummary.isEmpty ? "Measuring how it runs first; settings are tried from its next start." : i.tuningSummary.joined(separator: " · ")))
            }
        }
        if let at80 = i.shareAt80, let avg = i.averageFPS {
            if at80 < 0.5 && i.rayTraced {
                act.append(Need(id: "raytracing", kind: .act, title: "Ray tracing costs the frame rate it's short of",
                                detail: String(format: "Its last session held 80 fps or more %.0f%% of the time, %.0f fps on average, with ray tracing on. Off frees the most GPU time of any setting — Ray tracing on The Game's Own Upscaler.", at80 * 100, avg)))
            } else if at80 >= 0.8 {
                fine.append(Need(id: "fps", kind: .fine, title: "Holding 80",
                                 detail: String(format: "80 fps or more %.0f%% of its last session, %.0f on average.", at80 * 100, avg)))
            }
        }
        if let s = i.ownStuttersPerMinute, s >= 1, i.unreal, i.fromStore, i.unrealTuning {
            fine.append(Need(id: "stutters", kind: .fine, title: "Its own stutters are being worked on",
                             detail: String(format: "%.1f a minute of play last session, its own work rather than loading or shaders — what Unreal Engine tuning tries to bring down.", s)))
        }
        return act + fine
    }

    /// How far a pass is, by the time each step should take — the running step's own progress counted — and about how
    /// many seconds are left.
    static func progress(_ steps: [Step], within: Double) -> (fraction: Double, remaining: Double) {
        let total = steps.reduce(0) { $0 + max($1.expected, 0.1) }
        guard total > 0 else { return (1, 0) }
        var done = 0.0, left = 0.0
        for s in steps {
            let e = max(s.expected, 0.1)
            switch s.state {
            case .done, .skipped, .failed: done += e
            case .running: done += e * min(max(within, 0), 0.95); left += e * (1 - min(max(within, 0), 0.95))
            case .waiting: left += e
            }
        }
        return (min(done / total, 1), left)
    }

    static func remainingText(_ seconds: Double) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "about \(Int((seconds / 5).rounded()) * 5) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }

    /// Rosetta's translations of the game's code kept for its next start: the folder Anvil asks Rosetta to keep them
    /// in, made if it isn't there (Rosetta doesn't make it), and how much is in it.
    static func rosettaFolder(_ container: Container) -> (url: URL, bytes: Int64)? {
        guard container.rosettaAOT else { return nil }
        let url = container.shaderCacheURL.appendingPathComponent("rosetta", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, ShaderCacheManager.size(of: url))
    }
}

@MainActor
final class OptimizeRunner: ObservableObject {
    static let shared = OptimizeRunner()

    struct Activity: Equatable {
        var gameID: UUID
        var steps: [OptimizePass.Step]
        var started: Date
        var finished: Date?
        var within: Double = 0
        var needs: [OptimizePass.Need] = []
    }

    @Published private(set) var activity: Activity?

    private init() {}

    var running: Bool { activity != nil && activity?.finished == nil }

    /// Every step for one game, in order: in its own setup on its own engine, or those given.
    func run(_ game: Game, container given: Container? = nil, runtime engine: Runtime? = nil) async {
        guard !running, !Launcher.shared.isRunning(game),
              let container = given ?? Library.shared.container(id: game.containerID),
              let runtime = engine ?? RuntimeManager.shared.runtime(id: container.runtimeID) ?? RuntimeManager.shared.defaultRuntime else { return }
        let exe = game.executableURL
        let program = GameAnalysis.drawingProgram(for: exe)
        let prepNeeded = game.prepareGraphics && GraphicsPrep.reason(gameID: game.id) != nil
        let vcNeed = VCRuntime.need(for: game)
        let vcMissing = vcNeed.map { VCRuntime.missing($0, in: container) } ?? []
        var steps: [OptimizePass.Step] = [
            .init(id: "program", title: "Reading the game's program", expected: 2),
            // About a second for Hogwarts Legacy's 458 MB program on a base M4 (24 October).
            .init(id: "scan", title: "Graphics Scan", expected: GraphicsScan.stored(gameID: game.id) == nil ? 3 : 0.2),
            .init(id: "prep", title: "Graphics Prep — Anvil's shaders compiled and tested on this Mac's GPU",
                  // What it took last time, or the longest any game's took here: about 3 s on a base M4; 8 before any.
                  expected: prepNeeded ? max(GraphicsPrep.stored(gameID: game.id)?.seconds ?? GraphicsPrep.longestSeconds() ?? 8, 2) : 0.2),
            .init(id: "vc", title: "Microsoft's Visual C++ Runtime", expected: vcMissing.isEmpty ? 0.2 : 45),
            .init(id: "rosetta", title: "Rosetta's translations of its code kept", expected: 0.2),
            .init(id: "shaders", title: "Its shader cache", expected: 0.5),
            .init(id: "unreal", title: "Unreal Engine tuning", expected: 0.5),
            .init(id: "memory", title: "Memory, power and heat", expected: 0.5),
        ]
        activity = Activity(gameID: game.id, steps: steps, started: Date())
        AnvilLog.write("optimize: \(game.title) — started from its Performance tab")

        func step(_ id: String, _ work: () async -> (OptimizePass.Step.State, String)) async {
            guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[i].state = .running
            activity?.steps = steps
            activity?.within = 0
            let started = Date()
            let (state, result) = await work()
            steps[i].state = state
            steps[i].result = result
            activity?.steps = steps
            AnvilLog.write(String(format: "optimize: %@ — %@: %@ (%.1f s)", game.title, steps[i].title, result, Date().timeIntervalSince(started)))
        }

        var unreal = false
        await step("program") {
            let analysis = await Task.detached(priority: .userInitiated) { GameAnalysis.cached(for: exe) }.value
            unreal = analysis?.engine == .unreal
            var words = analysis.map { $0.summary } ?? "couldn't be read"
            if unreal {
                let names = Array(Set(UnrealTuning.managed(hasProfile: false).map(\.0)))
                let found = await Task.detached(priority: .userInitiated) { UnrealTuning.present(names, in: program) }.value
                if let found { words += " — \(found.count) of the \(names.count) Unreal settings Anvil tunes are in it" }
            }
            return (analysis == nil ? .failed : .done, words)
        }
        await step("scan") {
            if GraphicsScan.stored(gameID: game.id) == nil { await GraphicsScan.rescan(game, container: container, runtime: runtime) }
            guard let scan = GraphicsScan.stored(gameID: game.id) else { return (.failed, "couldn't scan it") }
            return (.done, scan.summary)
        }
        await step("prep") {
            guard game.prepareGraphics else { return (.skipped, "off for this game") }
            guard prepNeeded else {
                let p = GraphicsPrep.stored(gameID: game.id)
                return (.skipped, p?.status == .ready ? "ready-made for this Mac already" : "nothing to prepare")
            }
            // Its own steps, as the running step's progress.
            let watch = Task { @MainActor in
                while !Task.isCancelled {
                    if let a = GraphicsPrepRunner.shared.active, a.gameID == game.id, !a.steps.isEmpty {
                        let done = a.steps.filter { [.done, .skipped, .failed].contains($0.state) }.count
                        self.activity?.within = Double(done) / Double(a.steps.count)
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            let prep = await GraphicsPrepRunner.shared.run(game: game, container: container, runtime: runtime, beforeLaunch: false,
                                                           reason: "Optimize for This Mac")
            watch.cancel()
            GraphicsPrepRunner.shared.close()
            guard let prep else { return (.failed, "stopped, or couldn't start") }
            return prep.status == .ready ? (.done, "\(prep.pipelines) of \(prep.pipelinesOf) ready-made for \(prep.gpu)")
                                         : (.failed, prep.failure ?? "failed")
        }
        var vcLine: String?
        await step("vc") {
            guard let vcNeed else { return (.skipped, "not needed") }
            guard !vcMissing.isEmpty else { return (.done, "in its setup") }
            let line = await VCRuntimeSetup.shared.prepare(game, container: container, runtime: runtime, progress: { _ in })
            let still = VCRuntime.missing(vcNeed, in: container)
            if !still.isEmpty { vcLine = line ?? "It needs it (\(vcNeed.reasons.joined(separator: "; "))) and it couldn't be installed." }
            return (still.isEmpty ? .done : .failed, still.isEmpty ? "installed" : (line ?? "couldn't be installed"))
        }
        await step("rosetta") {
            guard let kept = OptimizePass.rosettaFolder(container) else { return (.skipped, "off for its setup") }
            return (.done, kept.bytes > 0 ? "\(ShaderCacheManager.sizeText(kept.bytes)) kept"
                                          : "its folder ready — whether Rosetta keeps code there is checked after its next session")
        }
        await step("shaders") {
            ShaderCacheManager.shared.refresh()
            let name = program.lastPathComponent
            guard let e = ShaderCacheManager.shared.entries.first(where: { $0.executable.caseInsensitiveCompare(name) == .orderedSame }) else {
                return (.done, "none yet — D3DMetal's are kept after its first session")
            }
            return (.done, "\(ShaderCacheManager.sizeText(max(e.storedBytes, e.liveBytes))) kept for \(name)")
        }
        var tuning: [String] = []
        await step("unreal") {
            guard unreal else { return (.skipped, "not an Unreal game") }
            guard UnrealTuning.fromStore(game) else { return (.skipped, "only for games from Steam or Epic installed through Anvil") }
            guard game.unrealTuning else { return (.skipped, "off for this game") }
            tuning = UnrealTuning.record(for: game).map { UnrealTuning.summary($0).map { "\($0.title): \($0.text)" } } ?? []
            return (.done, tuning.isEmpty ? "measuring how it runs first; settings are tried from its next start" : tuning.joined(separator: "; "))
        }
        var inputs = OptimizePass.Inputs(memoryFree: 0)
        await step("memory") {
            let title = game.title
            let m = await Task.detached(priority: .utility) { () -> (Int64?, Int64, [String], Int64?, Double?) in
                let logs = Launcher.gameLogs()
                let needs = FrameLog.peakMemory(of: title, text: logs)
                let own = UnrealTuning.lastSession(of: title, in: logs).flatMap { UnrealTuning.played(session: $0) }
                let apps = SystemInfo.largestApps().map { "\($0.name) \(OptimizePass.gb(Int64($0.bytes)))" }
                return (needs, MemoryWarmup.availableBytes(), apps, SaveGuard.freeSpace(at: RuntimeManager.support), own?.perMinute)
            }.value
            inputs.memoryNeeded = m.0
            inputs.memoryFree = m.1
            inputs.biggestApps = m.2
            inputs.diskFree = m.3
            inputs.ownStuttersPerMinute = m.4
            inputs.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            inputs.hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            return (.done, OptimizePass.gb(m.1) + " free" + (m.0.map { ", it took up to " + OptimizePass.gb($0) } ?? "")
                    + (inputs.lowPowerMode ? ", Low Power Mode on" : "") + (inputs.hot ? ", the Mac hot" : ""))
        }
        let current = Library.shared.games.first { $0.id == game.id } ?? game
        inputs.unreal = unreal
        inputs.fromStore = UnrealTuning.fromStore(current)
        inputs.unrealTuning = current.unrealTuning
        inputs.tuningSummary = tuning
        inputs.prepFailed = steps.first { $0.id == "prep" && $0.state == .failed }?.result
        inputs.prepareGraphics = current.prepareGraphics
        inputs.warmMemory = current.warmMemory
        inputs.enhancementsOff = current.anvilEnhancementsOff
        inputs.visualCMissing = vcLine
        inputs.averageFPS = current.lastSession?.averageFPS
        inputs.shareAt80 = current.lastSession?.shareAt80
        inputs.rayTraced = !(GameUpscaler.inGame(current, in: container)?.rayTraced.isEmpty ?? true)
        activity?.needs = OptimizePass.needs(inputs)
        activity?.finished = Date()
        let acts = activity?.needs.filter { $0.kind == .act }.map(\.title) ?? []
        AnvilLog.write(String(format: "optimize: %@ — done in %.0f s; ", game.title, Date().timeIntervalSince(activity?.started ?? Date()))
                       + (acts.isEmpty ? "nothing it needs" : "it needs: " + acts.joined(separator: "; ")))
    }

    func close() {
        if activity?.finished != nil { activity = nil }
    }
}
