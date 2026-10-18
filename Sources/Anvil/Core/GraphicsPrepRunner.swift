import Foundation

/// Runs Graphics Prep (see GraphicsPrep) for one game at a time — as the wait before a start,
/// or from Prepare Now on the game's page — and keeps GraphicsPrepPanel told where it is.
@MainActor
final class GraphicsPrepRunner: ObservableObject {
    static let shared = GraphicsPrepRunner()

    struct Step: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done, failed, skipped }
        let id: String
        var title: String
        var state: State = .waiting
        var result: String?
    }

    struct Activity: Equatable {
        var gameID: UUID
        var title: String
        var reason: String
        var beforeLaunch: Bool
        var steps: [Step]
        var finished = false
        var outcome: String?
        var seconds: Double?
    }

    @Published private(set) var active: Activity?
    /// The game whose page is open in a sheet, which shows the panel itself: the main window's
    /// copy would sit behind it.
    @Published var sheetGameID: UUID?

    private var process: Process?
    private var skipRequested = false

    private init() {}

    /// Stop now: whatever is running ends, nothing is kept, and the game starts as it would
    /// have without.
    func skip() {
        skipRequested = true
        process?.terminate()
    }

    /// Close the panel once a Prepare Now has finished.
    func close() {
        if active?.finished == true { active = nil }
    }

    /// Prepare a game. Returns what was kept, or nil if it was skipped or couldn't start.
    func run(game: Game, container: Container, runtime: Runtime, beforeLaunch: Bool, reason: String) async -> GraphicsPrep? {
        guard active == nil || active?.finished == true else { return nil }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("anvil-prep"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            AnvilLog.write("graphics prep: anvil-prep isn't in this copy of Anvil — skipped")
            return nil
        }
        skipRequested = false
        let started = Date()
        let id = game.id
        let picture = GraphicsPrep.picture(gameID: id)
        let key = GraphicsPrep.key(gameID: id)
        active = Activity(gameID: id, title: game.title, reason: reason, beforeLaunch: beforeLaunch, steps: [
            Step(id: "scan", title: "Looking at the game's graphics"),
            Step(id: "raytracing", title: "Ray tracing for this Mac"),
            Step(id: "cache", title: "The game's own compiled shaders"),
            Step(id: "compile", title: "Compiling Anvil's FSR and frame generation for the \(GraphicsPrep.gpuName)"),
            Step(id: "test", title: "Testing FSR at \(Self.pretty(picture.game)) → \(Self.pretty(picture.shown)) on the GPU"),
            Step(id: "fsr3", title: "Testing FSR 3 on a moving scene against a supersampled picture"),
            Step(id: "verify", title: "Checking the game finds them ready-made"),
        ])
        AnvilLog.write("graphics prep: \(game.title) — \(reason)")

        // 1. What the game is (kept from its scan when it has one for this build).
        set("scan", .running)
        if let (scan, fresh) = await GraphicsScan.forLaunch(game: game, container: container, runtime: runtime) {
            if fresh { GraphicsScan.changed() }
            set("scan", .done, [scan.api ?? "Graphics not known", scan.engine, "through \(scan.path.title)"].joined(separator: " · "))
        } else {
            set("scan", .skipped, "The game's file couldn't be read")
        }
        if skipRequested { return finish(nil, skipped: true, started: started) }

        // 1b. Its ray tracing, set for this Mac: the game's own screen-space ray-traced reflections (on or off as its
        // Ray Tracing switch and graphics level say, a step lighter on an entry-level GPU), or D3DMetal's hardware ray
        // tracing for a DirectX 12 game that has it. Written into the game's settings as it starts.
        set("raytracing", .running)
        if let plan = Self.rayTracingPlan(for: game, container: container) {
            set("raytracing", .done, plan)
            AnvilLog.write("graphics prep: \(game.title) — ray tracing: \(plan)")
        } else {
            set("raytracing", .skipped, "None of its own that Anvil knows of")
        }

        // 2. The game's own shaders, as D3DMetal compiled them in earlier sessions.
        set("cache", .running)
        let exe = game.executableURL.lastPathComponent
        let restore = container.protectShaderCache
        let cache = await Task.detached(priority: .userInitiated) { Self.gameCache(executable: exe, restore: restore) }.value
        let cacheText = GraphicsPrep.GameCache.text(cache)
        set("cache", .done, cacheText)
        if skipRequested { return finish(nil, skipped: true, started: started) }

        // 3 and 4. Anvil's shaders compiled into an archive, and FSR tested and timed.
        try? FileManager.default.createDirectory(at: GraphicsPrep.folder, withIntermediateDirectories: true)
        let fresh = GraphicsPrep.newArchiveURL(gameID: id)
        let upscaler = game.upscalerOverride ?? container.upscaler
        set("compile", .running)
        // A game smoothing its own edges over time is tested as it hands its frames over: drawn
        // anti-aliased, with FSR 3's shorter memory for it (see Launcher).
        let gameAA = GameTuning.smoothsItsOwnEdges(game, in: container)
        let prepared = await runHelper(helper, ["prepare", fresh.path, picture.game, picture.shown, String(picture.format),
                                                String(format: "%.2f", upscaler.sharpness > 0.001 ? upscaler.sharpness : 0.9)]
                                                + (gameAA ? ["aa"] : []),
                                       underRosetta: false) { [weak self] event in
            self?.prepareEvent(event)
        }
        if skipRequested {
            try? FileManager.default.removeItem(at: fresh)
            return finish(nil, skipped: true, started: started)
        }

        // 5. The archive opened by the game's architecture: under Rosetta, as wine runs.
        var verified: [GraphicsPrep.Event] = []
        let preparedOK = prepared.events.contains { $0.event == "done" } && !prepared.events.contains { $0.event == "failed" }
        if preparedOK, FileManager.default.fileExists(atPath: fresh.path) {
            set("verify", .running)
            verified = await runHelper(helper, ["verify", fresh.path], underRosetta: true) { _ in }.events
            if let v = verified.last(where: { $0.event == "verified" }) {
                let all = (v.ready ?? 0) == (v.of ?? -1)
                set("verify", all ? .done : .failed,
                    all ? "\(v.ready ?? 0) of \(v.of ?? 0) found under Rosetta, nothing to compile"
                        : "\(v.ready ?? 0) of \(v.of ?? 0) found — the game compiles its own, as before")
            } else {
                let why = verified.last { $0.event == "failed" }?.why
                set("verify", .failed, "Not checked\(why.map { " — \($0)" } ?? "") — the game compiles its own, as before")
            }
        } else {
            set("verify", .skipped, nil)
        }
        if skipRequested {
            try? FileManager.default.removeItem(at: fresh)
            return finish(nil, skipped: true, started: started)
        }

        let seconds = Date().timeIntervalSince(started)
        var prep = GraphicsPrep.from(prepare: prepared.events, verify: verified, key: key, gameSize: picture.game,
                                     shownSize: picture.shown, estimated: picture.estimated, gameCache: cache, seconds: seconds)
            ?? GraphicsPrep.failed(key: key, gameSize: picture.game, shownSize: picture.shown, estimated: picture.estimated,
                                   why: prepared.status == SIGTERM
                                       ? "it took longer than a minute and was stopped"
                                       : "anvil-prep stopped unexpectedly (code \(prepared.status))",
                                   gameCache: cache, seconds: seconds)
        // Keep the archive only where the game's side found every pipeline in it.
        let fm = FileManager.default
        let archive = GraphicsPrep.archiveURL(gameID: id)
        if prep.archiveKept {
            try? fm.removeItem(at: archive)
            if (try? fm.moveItem(at: fresh, to: archive)) == nil { prep.archiveKept = false }
        } else {
            try? fm.removeItem(at: fresh)
            try? fm.removeItem(at: archive)
        }
        // A crash with one pass is remembered across preps of the same game.
        if let before = GraphicsPrep.stored(gameID: id), before.onePassOff { prep.onePassOff = true }
        GraphicsPrep.keep(prep, gameID: id)
        NotificationCenter.default.post(name: .graphicsPrepChanged, object: nil)
        AnvilLog.write("graphics prep: \(game.title) — \(prep.summary) (\(String(format: "%.1f", seconds)) s)")
        return finish(prep, skipped: false, started: started)
    }

    /// A game's ray tracing on this Mac, in a line: its own screen-space ray-traced reflections (GameTuning), or
    /// D3DMetal's for a DirectX 12 game with ray-traced effects (Launcher). Nil where it has none Anvil knows of.
    static func rayTracingPlan(for game: Game, container: Container) -> String? {
        if let plan = GameTuning.rayTracingPlan(for: game, in: container, level: Tuner.shared.graphicsLevel(for: game)) { return plan }
        let analysis = GameAnalysis.cached(for: game.executableURL)
        guard analysis?.primary == .d3d12 || analysis?.apis.contains(.d3d12) == true,
              GameAnalysis.offersRayTracing(executable: game.executableURL) else { return nil }
        let rt = Launcher.rayTracing(for: game, container: container)
        return rt.on
            ? "Hardware ray tracing on: \(game.title)'s ray-traced effects are offered in its own graphics settings, traced by this Mac's GPU (\(MetalCapability.current.deviceName))."
            : "Hardware ray tracing off" + (game.rayTracing == false ? ", as switched." : ": this Mac's GPU traces rays in its shader cores, too slowly to be worth it (M3 and later do it in hardware).")
    }

    // MARK: Steps

    private func set(_ id: String, _ state: Step.State, _ result: String? = nil) {
        guard var a = active, let i = a.steps.firstIndex(where: { $0.id == id }) else { return }
        a.steps[i].state = state
        if result != nil || state == .running { a.steps[i].result = result }
        active = a
    }

    private func prepareEvent(_ e: GraphicsPrep.Event) {
        switch e.event {
        case "compiled":
            set("compile", .running, "Library compiled in \(Int(e.ms ?? 0)) ms")
        case "archived":
            set("compile", .done, "\(e.pipelines ?? 0) of \(e.of ?? 0) pipelines compiled for this GPU in \(Int(e.ms ?? 0)) ms"
                + ((e.missing ?? []).isEmpty ? "" : " — not: \((e.missing ?? []).joined(separator: ", "))"))
            set("test", .running)
        case "timed":
            var text = "Two passes: \(GraphicsPrep.ms(e.splitMs ?? 0)) a frame"
            if e.fusedOk == true, let f = e.fusedMs { text += " · one pass: \(GraphicsPrep.ms(f))" }
            else if e.fusedOk == false { text += " · one pass didn't match the two-pass picture — not used" }
            if let pass = e.pass {
                text += pass == "fused" ? " · one pass kept — the quicker here" : " · two passes kept — the quicker here"
                set("test", .done, text)
                set("fsr3", .running)
            } else {
                set("test", .running, text)
            }
        case "fsr3":
            if let t = e.fsr3Test {
                set("fsr3", t.better ? .done : .skipped, t.text(off: false))
            } else {
                set("fsr3", .skipped, e.fsr3Why.map { "Not tested: \($0)" })
            }
        case "done":
            guard let a = active, let test = a.steps.first(where: { $0.id == "test" }) else { return }
            if e.tested == false {
                set("test", .skipped, e.why.map { "Not tested: \($0)" })
                set("fsr3", .skipped, e.fsr3Why.map { "Not tested: \($0)" })
            } else if test.state != .done {
                let choice = e.pass == "fused" ? "One pass kept — the quicker here" : "Two passes kept — the quicker here"
                set("test", .done, [test.result, choice].compactMap { $0 }.joined(separator: " · "))
            }
        case "failed":
            let running = active?.steps.first { $0.state == .running }?.id ?? "compile"
            set(running, .failed, e.why)
        default:
            break
        }
    }

    private func finish(_ prep: GraphicsPrep?, skipped: Bool, started: Date) -> GraphicsPrep? {
        process = nil
        guard var a = active else { return prep }
        for i in a.steps.indices where a.steps[i].state == .waiting || a.steps[i].state == .running {
            a.steps[i].state = .skipped
        }
        a.finished = true
        a.seconds = Date().timeIntervalSince(started)
        if skipped {
            a.outcome = "Skipped — the game starts as it did before. Anvil prepares it before its next start."
            AnvilLog.write("graphics prep: \(a.title) — skipped")
        } else if let prep, prep.status == .ready {
            let fsr = prep.fsrText
            var outcome = "Ready in \(String(format: "%.1f", a.seconds ?? 0)) s. FSR: \(fsr.prefix(1).lowercased())\(fsr.dropFirst())."
            if let t = prep.fsr3 {
                outcome += t.better ? " FSR 3: on for this game." : " FSR 3: not used here — \(t.why ?? "it wasn't better")."
            }
            a.outcome = outcome
        } else {
            a.outcome = "Didn't finish: \(prep?.failure ?? "no reason given"). The game starts as it did before."
        }
        active = a
        if a.beforeLaunch {
            // The result on screen for a moment, then on into the game.
            let id = a.gameID
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(skipped ? 0.3 : 1.4))
                if self?.active?.gameID == id, self?.active?.finished == true { self?.active = nil }
            }
        }
        return prep
    }

    // MARK: anvil-prep

    /// What anvil-prep is given: where Anvil's shaders are, exactly as the game is told.
    nonisolated static func helperEnvironment() -> [String: String] {
        var env: [String: String] = ["PATH": "/usr/bin:/bin"]
        let mine = ProcessInfo.processInfo.environment
        for k in ["HOME", "TMPDIR", "USER", "LOGNAME"] { if let v = mine[k] { env[k] = v } }
        if let r = Bundle.main.resourceURL {
            env["ANVIL_METALLIB"] = r.appendingPathComponent("AnvilShaders.metallib").path
            env["ANVIL_METAL_SOURCE"] = r.appendingPathComponent("AnvilShaders.metal").path
            env["ANVIL_METAL_PACK"] = r.appendingPathComponent("AnvilShaders.pack").path
        }
        return env
    }

    private func runHelper(_ helper: URL, _ arguments: [String], underRosetta: Bool,
                           onEvent: @escaping (GraphicsPrep.Event) -> Void) async -> (events: [GraphicsPrep.Event], status: Int32) {
        let p = Process()
        if underRosetta {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            p.arguments = ["-x86_64", helper.path] + arguments
        } else {
            p.executableURL = helper
            p.arguments = arguments
        }
        p.environment = Self.helperEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            AnvilLog.write("graphics prep: anvil-prep didn't start — \(error.localizedDescription)")
            return ([], -1)
        }
        process = p
        // A minute at most, whatever the GPU does (anvil-prep also stops itself at 90 s).
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(60))
            if p.isRunning { p.terminate() }
        }
        var events: [GraphicsPrep.Event] = []
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let e = GraphicsPrep.Event.parse(Substring(line)) else { continue }
                events.append(e)
                onEvent(e)
            }
        } catch {}
        await Task.detached { p.waitUntilExit() }.value
        watchdog.cancel()
        return (events, p.terminationStatus)
    }

    /// D3DMetal's compiled shaders for the game: Anvil's kept copy put back if macOS cleared the
    /// live one (as every launch does), and how much there is.
    nonisolated static func gameCache(executable: String, restore: Bool) -> GraphicsPrep.GameCache {
        let live = ShaderCacheManager.liveRoot?.appendingPathComponent(executable, isDirectory: true)
        let before = live.map { ShaderCacheManager.size(of: $0) } ?? 0
        if restore { ShaderCacheManager.restore(executable: executable) }
        let after = live.map { ShaderCacheManager.size(of: $0) } ?? 0
        return GraphicsPrep.GameCache(executable: executable, bytes: after, restored: after > before)
    }

    nonisolated static func pretty(_ size: String) -> String { size.replacingOccurrences(of: "x", with: " × ") }
}

extension GraphicsPrep.GameCache {
    static func text(_ c: GraphicsPrep.GameCache) -> String {
        if c.bytes <= 0 { return "None yet — D3DMetal compiles them as the game meets them, once, and Anvil keeps them" }
        return ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
            + " compiled in earlier sessions" + (c.restored ? " — put back where D3DMetal reads them" : ", in place")
    }
}
