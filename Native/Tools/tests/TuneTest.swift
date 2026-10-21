// Auto-Tune, the game analysis, the graphics levels, the container advice and the disk
// cache, run on the app's own code in a throwaway home folder.
//
// Reads (never writes) the real game.log, a copy of LEGO Star Wars' PCCONFIG.TXT and a copy
// of library.json, and the LEGO and Cat Quest II executables under /Applications/Games.
//
//   T=$TMPDIR/tunetest; mkdir -p $T/home $T/data
//   cp ~/Library/Application\ Support/Anvil/{game.log,library.json} $T/data/
//   cp <LEGO container>/drive_c/users/crossover/AppData/Roaming/Warner\ Bros.\ Interactive\ Entertainment/LEGO\ Star\ Wars\ -\ The\ Skywalker\ Saga/PCCONFIG.TXT $T/data/
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil -name '*.swift' ! -name AnvilApp.swift) \
//     Native/Tools/tests/TuneTest.swift -o $T/TuneTest
//   CFFIXED_USER_HOME=$T/home HOME=$T/home $T/TuneTest $T/data/game.log $T/data/PCCONFIG.TXT $T/data/library.json
import Foundation
import AppKit

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL line \(line): \(msg)") }
}
func trial(_ setup: TuneSetup, share80: Double, capacity: Double, displayedLow: Double = 70, minutes: Double = 5, hitchesPerMin: Double = 0) -> TuneTrial {
    // Build windows that produce the wanted stats: share80 of the time at 90 fps, the rest at displayedLow.
    var t = TuneTrial(setup: setup)
    let totalSeconds = minutes * 60
    var windows: [FrameWindow] = []
    var fast = totalSeconds * share80, slow = totalSeconds - fast
    while fast > 0.1 { let w = FrameWindow(displayed: 90, onePercentLow: 70, worstGapMs: 20, rendered: 90, capacity: capacity, latencyMs: 20, gpuBusy: 90, topThread: 60); windows.append(w); fast -= w.seconds }
    while slow > 0.1 { let w = FrameWindow(displayed: displayedLow, onePercentLow: 50, worstGapMs: 30, rendered: displayedLow, capacity: capacity * 0.8, latencyMs: 25, gpuBusy: 99, topThread: 60); windows.append(w); slow -= w.seconds }
    t.add(windows, hitches: Int(hitchesPerMin * minutes))
    t.sessions = 1
    return t
}

@main
struct TuneTestMain {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "/nonexistent")
        print("home:", home.path, "support:", RuntimeManager.support.path)
        guard RuntimeManager.support.path.contains("tunetest") else { print("support is not the test home — refusing to run"); exit(2) }

        // ---------- 1. game.log parsing on the real log ----------
        let realLog = URL(fileURLWithPath: CommandLine.arguments[1])
        let text = try! String(contentsOf: realLog, encoding: .utf8)
        var best: (title: String, windows: [FrameWindow])? = nil
        for header in text.components(separatedBy: "\n=== ").dropFirst() {
            let title = header.components(separatedBy: " — ").first ?? ""
            let windows = header.split(separator: "\n").compactMap { FrameLog.parse($0) }
            if windows.count > (best?.windows.count ?? 0) { best = (title, windows) }
        }
        let windows = best!.windows
        print("longest session:", best!.title, windows.count, "windows")
        check(windows.count > 100, "expected a long session")
        let w0 = windows[3]
        print("sample window:", w0)
        check(w0.displayed > 10 && w0.capacity > 10 && w0.worstGapMs > 0, "fields parsed")
        let split = Gameplay.split(windows)
        let stats = TrialStats.from(play: split.play, hitches: split.hitches)!
        print(String(format: "gameplay %.1f min, 80+ %.0f%%, 60+ %.0f%%, 120 %.0f%%, typical %.0f, low %.0f, capacity %.0f (low %.0f), 1%% low %.0f, hitches %.2f/min, gpu %@, cpu-bound %.0f%%",
                     stats.minutes, stats.shareAt80*100, stats.shareAt60*100, stats.shareAt120*100, stats.typicalFPS, stats.lowFPS,
                     stats.capacity, stats.capacityLow, stats.onePercentLow, stats.hitchesPerMinute, stats.gpuBusy.map { String(format: "%.0f%%", $0) } ?? "n/a", stats.cpuBoundShare*100))
        check(stats.minutes > 5, "minutes of play")
        // SessionStats read the same session as 80+ 81% over 28.9 min; the play-only split leaves out loads.
        check(stats.shareAt80 > 0.6 && stats.shareAt80 < 0.95, "80+ share plausible")
        // The newest session with GPU numbers, if any
        let lastLego = FrameLog.lastSession(of: "LEGO® Star Wars™: The Skywalker Saga", text: text)
        print("last LEGO session windows:", lastLego?.windows.count ?? -1, "started", lastLego?.startedAt as Any)

        // ---------- 2. Game analysis on the real executables (read-only) ----------
        // Mythic's install until 17 October; downloaded again into Anvil's own Games folder on 19 October.
        // (The real home: the test runs in a throwaway one.)
        let lego = ["/Applications/Games/Mythic/LEGOStarWarsTSS",
                    (getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/") + "/Games/Anvil/LEGOStarWarsTSS"]
            .map { URL(fileURLWithPath: $0 + "/LEGOSTARWARSSKYWALKERSAGA_DX11.exe") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/Applications/Games/Mythic/LEGOStarWarsTSS/LEGOSTARWARSSKYWALKERSAGA_DX11.exe")
        let cat = URL(fileURLWithPath: "/Applications/Games/Mythic/CatQuestII/Cat Quest II.exe")
        var t0 = Date()
        let la = GameAnalysis.analyze(executable: lego)
        print(String(format: "LEGO: %@ apis=%@ (%.2f s)", la.summary, la.apis.map(\.rawValue).sorted().joined(separator: ","), Date().timeIntervalSince(t0)))
        check(la.primary == .d3d11 && la.engine == .ttGames && la.is64Bit && !la.rendersAtWindowSize, "LEGO analysis")
        t0 = Date()
        let ca = GameAnalysis.analyze(executable: cat)
        print(String(format: "Cat Quest II: %@ apis=%@ (%.2f s)", ca.summary, ca.apis.map(\.rawValue).sorted().joined(separator: ","), Date().timeIntervalSince(t0)))
        check(ca.engine == .unity && ca.rendersAtWindowSize && ca.primary == .d3d11, "Cat Quest analysis")
        let pe = PEImports.read(try! Data(contentsOf: lego, options: .mappedIfSafe))
        check(pe.dlls.contains("dxgi.dll") && pe.dlls.contains("XAudio2_8.dll") && pe.is64Bit == true, "LEGO imports: \(pe.dlls)")
        // Cached: second read is instant and the same.
        t0 = Date()
        let c1 = GameAnalysis.cached(for: lego); let c2 = GameAnalysis.cached(for: lego)
        print(String(format: "cached twice in %.2f s", Date().timeIntervalSince(t0)))
        check(c1 == la && c2 == la, "cache returns the same analysis")
        check(FileManager.default.fileExists(atPath: DiskCache.directory.appendingPathComponent("GameAnalysis.json").path), "analysis cache written")

        // ---------- 3. Planner ----------
        let levels = GraphicsLevel.allCases
        func setup(_ l: GraphicsLevel, _ pacing: Int = 80) -> TuneSetup { TuneSetup(graphics: l, halfResolution: nil, pacing: pacing) }
        var space = TunePlanner.Space(levels: levels, canHalveResolution: false, baseline: setup(.medium), goal: .smooth)
        check(TunePlanner.next(space, trials: [], minMinutes: 4) == setup(.medium), "smooth starts at the baseline")
        // medium holds 80 → try full
        var trials = [trial(setup(.medium), share80: 0.99, capacity: 105)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.full), "medium holds → full next")
        trials.append(trial(setup(.full), share80: 0.80, capacity: 90))
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == nil, "full fails → decided")
        check(TunePlanner.winner(space, trials: trials, minMinutes: 4)?.setup == setup(.medium), "winner medium")
        // medium fails → light next; light holds → decided light
        trials = [trial(setup(.medium), share80: 0.85, capacity: 95)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.light), "medium fails → light")
        trials.append(trial(setup(.light), share80: 0.99, capacity: 110))
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == nil, "light holds → decided")
        let w = TunePlanner.winner(space, trials: trials, minMinutes: 4)
        check(w?.setup == setup(.light), "winner light"); print("smooth winner:", w?.setup.title ?? "-", "—", w?.reason ?? "")
        // nothing holds → closest
        trials = [trial(setup(.medium), share80: 0.70, capacity: 85), trial(setup(.light), share80: 0.80, capacity: 92)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == nil, "bottom reached → decided")
        check(TunePlanner.winner(space, trials: trials, minMinutes: 4)?.setup == setup(.light), "closest wins")
        // …but only when it is clearly closer: a few points don't cost the better look.
        trials = [trial(setup(.medium), share80: 0.70, capacity: 85), trial(setup(.light), share80: 0.74, capacity: 88)]
        check(TunePlanner.winner(space, trials: trials, minMinutes: 4)?.setup == setup(.medium), "nearly as close keeps the better look")
        // hitches disqualify
        trials = [trial(setup(.medium), share80: 0.99, capacity: 110, hitchesPerMin: 3)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.light), "hitchy medium counts as failing")
        // not enough minutes → same setup again
        trials = [trial(setup(.medium), share80: 0.98, capacity: 110, minutes: 2)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.medium), "short trial measured again")
        // maxFPS
        space.goal = .maxFPS; space.baseline = setup(.medium, 0)
        check(TunePlanner.next(space, trials: [], minMinutes: 4) == setup(.light, 0), "maxFPS starts light")
        trials = [trial(setup(.light, 0), share80: 0.99, capacity: 120)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.medium, 0), "then medium")
        trials.append(trial(setup(.medium, 0), share80: 0.99, capacity: 118.5))
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.full, 0), "medium free → full")
        trials.append(trial(setup(.full, 0), share80: 0.9, capacity: 100))
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == nil, "full costs → decided")
        check(TunePlanner.winner(space, trials: trials, minMinutes: 4)?.setup == setup(.medium, 0), "maxFPS keeps the free quality")
        // quality
        space.goal = .quality
        check(TunePlanner.next(space, trials: [], minMinutes: 4) == setup(.full), "quality starts at full")
        trials = [trial(setup(.full), share80: 0.6, capacity: 85, displayedLow: 65)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == nil, "full plays well → decided")
        check(TunePlanner.winner(space, trials: trials, minMinutes: 4)?.setup == setup(.full), "quality winner full")
        trials = [trial(setup(.full), share80: 0.5, capacity: 70, displayedLow: 45)]
        check(TunePlanner.next(space, trials: trials, minMinutes: 4) == setup(.medium), "full too slow → medium")
        // balanced
        space.goal = .balanced
        check(TunePlanner.expectedCount(space) == 3, "balanced measures all")
        // Unity half/full
        let unity = TunePlanner.Space(levels: [], canHalveResolution: true, baseline: TuneSetup(graphics: nil, halfResolution: true, pacing: 80), goal: .smooth)
        let ladder = TunePlanner.ladder(unity)
        check(ladder.map(\.halfResolution) == [true, false], "unity ladder half then full")
        check(TunePlanner.start(unity) == ladder[0], "unity smooth starts at its current half")
        // Nothing to vary
        check(TunePlanner.start(TunePlanner.Space(levels: [], canHalveResolution: false, baseline: TuneSetup(graphics: nil, halfResolution: nil, pacing: 80), goal: .smooth)) == nil, "nothing to test")

        // ---------- 4. Graphics levels on a copy of LEGO's settings ----------
        let support = RuntimeManager.support
        var container = Container(name: "Star Wars", runtimeID: "mythic-engine-2.6.1")
        let cfgDir = container.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga")
        try! FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        let cfg = cfgDir.appendingPathComponent("PCCONFIG.TXT")
        // From the game's own defaults for the effects the levels turn off, so each level shows in
        // the file whatever Anvil had set in the copy (the real file changes as the game is tuned).
        let original = GameTuning.replacing(["WaterDistortionEnabled": "1", "SSAOEnabled": "1", "SoftShadowsEnabled": "1",
                                             "ScreenSpaceReflectionsEnabled": "1", "DoFEnabled": "1"],
                                            in: try! String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), encoding: .utf8))
        try! original.write(to: cfg, atomically: false, encoding: .utf8)
        let fakeExeDir = home.appendingPathComponent("Games/LEGO")
        try! FileManager.default.createDirectory(at: fakeExeDir, withIntermediateDirectories: true)
        let fakeExe = fakeExeDir.appendingPathComponent("LEGOSTARWARSSKYWALKERSAGA_DX11.exe")
        try! Data("MZ fake nttAudioHAL d3d11.dll".utf8).write(to: fakeExe)
        var game = Game(title: "LEGO® Star Wars™: The Skywalker Saga", executablePath: fakeExe.path, containerID: container.id)
        func values() -> [String: String] { GameTuning.values(in: try! String(contentsOf: cfg, encoding: .utf8)) }
        // The game's own values, as the copied file has them: the real one changes as the game is
        // played and tuned (Light had turned SSAO and water distortion off by 5 October).
        let own = GameTuning.values(in: original)
        print(GameTuning.prepare(game, in: container, level: .medium) ?? "nil")
        var v = values()
        // 0.52: Medium keeps the game's reflections and turns its water distortion off.
        check(v["ScreenSpaceReflectionsEnabled"] == own["ScreenSpaceReflectionsEnabled"] && v["DoFEnabled"] == "0" && v["WaterDistortionEnabled"] == "0"
              && v["ShadowQuality"] == own["ShadowQuality"] && v["SoftShadowsEnabled"] == "1" && v["SSAOEnabled"] == "1",
              "medium applied — reflections and shadows and ambient occlusion as the game has them (0.38, 0.52)")
        check(GameTuning.prepare(game, in: container, level: .medium) == nil, "medium again: nothing")
        print(GameTuning.prepare(game, in: container, level: .light) ?? "nil")
        v = values()
        check(v["WaterDistortionEnabled"] == "0" && v["ScreenSpaceReflectionsEnabled"] == "0"
              && v["ShadowQuality"] == own["ShadowQuality"] && v["SoftShadowsEnabled"] == "1" && v["SSAOEnabled"] == "1",
              "light applied — shadows and ambient occlusion still the game's")
        print(GameTuning.prepare(game, in: container, level: .medium) ?? "nil")
        v = values()
        check(v["WaterDistortionEnabled"] == "0" && v["ScreenSpaceReflectionsEnabled"] == own["ScreenSpaceReflectionsEnabled"], "back to medium restores light-only keys (the reflections)")
        // The player changes shadows in the game's menu: kept through a level change.
        try! GameTuning.replacing(["ShadowQuality": "2"], in: try! String(contentsOf: cfg, encoding: .utf8)).write(to: cfg, atomically: false, encoding: .utf8)
        print(GameTuning.prepare(game, in: container, level: .light) ?? "nil")
        v = values()
        check(v["ShadowQuality"] == "2" && v["WaterDistortionEnabled"] == "0", "player's own shadow setting kept")
        print(GameTuning.prepare(game, in: container, level: .full) ?? "nil")
        let restored = try! String(contentsOf: cfg, encoding: .utf8)
        let diff = zip(original.components(separatedBy: "\n"), restored.components(separatedBy: "\n")).filter { $0 != $1 }
        print("after Full, lines differing from the original:", diff)
        check(diff.count == 0 || (diff.count == 1 && diff[0].1.contains("ShadowQuality")), "full restores (except the player's own change... which equals the original here)")
        check(!GameTuning.isTuned(game), "record removed at full")
        // A 0.14.0 record (no level) counts as medium.
        try! FileManager.default.createDirectory(at: GameTuning.recordsDirectory, withIntermediateDirectories: true)
        try! original.write(to: cfg, atomically: false, encoding: .utf8)
        _ = GameTuning.prepare(game, in: container, level: .medium)
        let recURL = GameTuning.recordsDirectory.appendingPathComponent("\(game.id.uuidString).json")
        var rec = try! JSONSerialization.jsonObject(with: Data(contentsOf: recURL)) as! [String: Any]
        rec.removeValue(forKey: "level")
        try! JSONSerialization.data(withJSONObject: rec).write(to: recURL)
        check(GameTuning.prepare(game, in: container, level: .medium) == nil, "0.14.0 record reads as medium")
        check(GameTuning.appliedLevel(for: game) == .medium, "applied level medium")
        _ = GameTuning.prepare(game, in: container, level: .full)
        // 0.31: a record from version 1, and the game's two motion blurs back on in its menu (as on
        // 7 October) — off again, once; the player's other changes stay, and so does a blur turned on after.
        try! original.write(to: cfg, atomically: false, encoding: .utf8)
        _ = GameTuning.prepare(game, in: container, level: .medium)
        rec = try! JSONSerialization.jsonObject(with: Data(contentsOf: recURL)) as! [String: Any]
        rec["version"] = 1
        try! JSONSerialization.data(withJSONObject: rec).write(to: recURL)
        try! GameTuning.replacing(["MotionBlurEnabled": "1", "SpeedBlurEnabled": "1", "ShadowQuality": "3"],
                                  in: try! String(contentsOf: cfg, encoding: .utf8)).write(to: cfg, atomically: false, encoding: .utf8)
        let again = GameTuning.prepare(game, in: container, level: .medium)
        print(again ?? "nil")
        v = values()
        check(v["MotionBlurEnabled"] == "0" && v["SpeedBlurEnabled"] == "0", "0.31: the game's motion blurs off again, once")
        check(v["ShadowQuality"] == "3", "the player's other change stays")
        check(again?.contains("again") == true, "said in the launch log")
        try! GameTuning.replacing(["MotionBlurEnabled": "1"], in: try! String(contentsOf: cfg, encoding: .utf8)).write(to: cfg, atomically: false, encoding: .utf8)
        _ = GameTuning.prepare(game, in: container, level: .medium)
        _ = GameTuning.prepare(game, in: container, level: .light)
        // 0.41: the game turns them back on by itself, so at Light and Medium they're kept off.
        check(values()["MotionBlurEnabled"] == "0", "turned on in the game after that: off again at the next start (0.41)")
        _ = GameTuning.prepare(game, in: container, level: .full)

        // ---------- 5. A whole Auto-Tune run, while playing ----------
        let library = Library.shared
        library.containers = [container]
        library.games = [game]
        library.save()
        let tuner = Tuner.shared
        do {
            let started = try tuner.start(game, goal: .smooth, quickTest: false)
            check(started, "tuning started")
        } catch { check(false, "start threw \(error)") }
        check(tuner.state(for: game)?.current == setup(.medium), "first setup is the baseline, medium")
        let log = Launcher.gameLogURL
        try? FileManager.default.removeItem(at: log)
        // Scene model: medium holds 80 88% of the time; light 97%.
        func session(for level: GraphicsLevel, minutes: Double) -> String {
            var s = "\n=== \(game.title) — \(ISO8601DateFormatter().string(from: Date())) — Anvil test ===\n"
            s += "[anvil] injected into pid 1\n"
            func line(_ d: Double, _ gap: Double, _ could: Double) -> String {
                String(format: "12:00:00.000 [anvil] displayed %.1f fps | 1%% LOW %.1f fps | STEADY 90.0%% | shown as ready 0%% | EVENNESS 90.0%% on-beat (500 of 500 gaps) worst gap %.1f ms | rendered %.1f fps (game could %.1f) | real=1 gen=0 skipped=0 resyncs=0 | LATENCY 20.0 ms avg 30.0 ms max | in flight 2 | missed 0 | memory 2000 MB | GPU 95%% busy | busiest threads 70%% and 40%% of a core\n", d, d * 0.8, gap, d, could)
            }
            s += line(120, 40, 150) + line(120, 30, 150)          // start-up
            s += line(120, 20, 148) + line(60, 380, 60)           // menu, then the load
            let share = level == .light ? 0.97 : level == .medium ? 0.88 : 0.7
            var t = 0.0
            var i = 0
            while t < minutes * 60 {
                let fast = Double(i % 20) < share * 20
                let d = fast ? 88.0 : 72.0
                s += line(d, 30, fast ? 100 : 76)
                t += 600 / d; i += 1
            }
            return s
        }
        for round in 1...6 {
            guard let st = tuner.state(for: game), st.isActive else { break }
            let prepared = tuner.prepareLaunch(game: library.games[0], container: library.containers[0])
            let level = tuner.graphicsLevel(for: prepared.game)
            print("round \(round): launching with \(prepared.game.graphicsTuning.rawValue) → \(level.title); log line: \(prepared.logLine ?? "nil")")
            check(prepared.container.lockToRefresh, "measuring needs the frame library")
            _ = GameTuning.prepare(prepared.game, in: prepared.container, level: level)
            let now = values()
            let written = level == .light ? now["WaterDistortionEnabled"] == "0" && now["ScreenSpaceReflectionsEnabled"] == "0"
                : level == .medium ? now["WaterDistortionEnabled"] == "0" && now["ScreenSpaceReflectionsEnabled"] == own["ScreenSpaceReflectionsEnabled"]
                : now["ScreenSpaceReflectionsEnabled"] == "1"
            check(written && now["SoftShadowsEnabled"] == "1", "trial level written to the game's settings")
            // Stored game untouched by the trial.
            check(library.games[0].graphicsTuning == .automatic, "stored game unchanged")
            if !FileManager.default.fileExists(atPath: log.path) { try! Data().write(to: log) }
            let handle = FileHandle(forWritingAtPath: log.path)!
            handle.seekToEndOfFile(); handle.write(Data(session(for: level, minutes: 4.5).utf8)); handle.closeFile()
            tuner.sessionEnded(game: library.games[0], userClosed: true)
            try? await Task.sleep(for: .milliseconds(400))
            print("  notes:", tuner.state(for: game)?.notes.last ?? "")
        }
        let end = tuner.state(for: game)!
        print("final mode:", end.mode, "winner:", end.winner?.title ?? "-", "—", end.winnerReason ?? "")
        check(end.mode == .finished && end.winner == setup(.light), "smooth picks light (medium failed, light held)")
        check(tuner.graphicsLevel(for: library.games[0]) == .light, "game now runs light")
        check(values()["WaterDistortionEnabled"] == "0" && values()["SSAOEnabled"] == "1", "light written into the game's settings at the end")
        check(library.containers[0].targetFPS == 80, "pacing steady")
        check(tuner.announcement != nil, "announced")
        check(FileManager.default.fileExists(atPath: Tuner.directory.appendingPathComponent("\(game.id.uuidString).json").path), "results kept on disk")
        // A later start for another goal reuses the measured setups.
        game = library.games[0]
        _ = try? tuner.start(game, goal: .maxFPS, quickTest: false)
        print("maxFPS reuse: current", tuner.state(for: game)?.current?.title ?? "-", "trials", tuner.state(for: game)?.trials.count ?? 0)
        check(tuner.state(for: game)?.current == setup(.light, 0), "maxFPS measures its own (unpaced) setups")
        tuner.stop(game)
        check(tuner.graphicsLevel(for: library.games[0]) == .light, "a stopped run keeps the earlier choice (light)")
        _ = try? tuner.start(game, goal: .quality, quickTest: false)
        print("quality reuse: current", tuner.state(for: game)?.current?.title ?? "-", "trials", tuner.state(for: game)?.trials.count ?? 0)
        check((tuner.state(for: game)?.trials.count ?? 0) >= 2, "quality reuses the 80-paced setups")
        print("quality mode:", tuner.state(for: game)?.mode as Any, "carried winner:", tuner.state(for: game)?.winner?.title ?? "-")
        check(tuner.state(for: game)?.current == setup(.full) || tuner.state(for: game)?.mode == .finished, "quality measures full next, or decided from what it had")
        tuner.stop(game)
        tuner.reset(game)
        check(tuner.graphicsLevel(for: library.games[0]) == .medium, "cleared results → medium")
        check(values()["ScreenSpaceReflectionsEnabled"] == own["ScreenSpaceReflectionsEnabled"] && values()["WaterDistortionEnabled"] == "0", "clearing writes medium back into the game's settings")

        // ---------- 6. Container advice ----------
        let engines = [ContainerAdvisor.Engine(id: "mythic-engine-2.6.1", name: "Mythic Engine 2.6.1", d3dMetal: "2.1", rank: [2, 1], usable: true),
                       ContainerAdvisor.Engine(id: "whiskywine-2.5.0", name: "WhiskyWine 2.5.0", d3dMetal: "2.0", rank: [2, 0], usable: true)]
        let realLibrary = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
        // Through the library's own migration, as the app reads it: fields newer than the
        // file get their defaults.
        // LEGO's and Cat Quest II's containers; a Steam container added since is neither.
        for c in Migration.salvage(Container.self, from: realLibrary["containers"], default: Container(name: "", runtimeID: "")).kept
        where c.storefront != "steam" {
            let isLego = c.runtimeID.hasPrefix("mythic")
            let g = Game(title: isLego ? "LEGO" : "Cat Quest II", executablePath: (isLego ? lego : cat).path, containerID: c.id)
            let advice = ContainerAdvisor.advise(game: g, container: c, goal: .smooth, analysis: isLego ? la : ca, engines: engines, otherGames: [])
            print("\nadvice for “\(c.name)” (\(c.runtimeID)) — optimal: \(advice.isOptimal)")
            for ch in advice.changes { print("  • \(ch.title): \(ch.from) → \(ch.to)") }
            if let e = advice.engine { print("  • engine → \(e.name): \(e.reason)") }
            for n in advice.notes { print("  i \(n)") }
            if isLego { check(advice.engine == nil, "LEGO already on the newest D3DMetal") }
            else { check(advice.engine?.runtimeID == "mythic-engine-2.6.1", "Cat Quest offered Mythic's newer D3DMetal") }
            // Applying the advice leaves nothing to change.
            let again = ContainerAdvisor.advise(game: g, container: advice.recommended, goal: .smooth, analysis: isLego ? la : ca, engines: engines, otherGames: [])
            check(again.changes.isEmpty, "advice is stable once applied: \(again.changes.map(\.title))")
        }

        // ---------- 7. Disk cache ----------
        let name = "test-entry.bin"
        DiskCache.store(Data("hello".utf8), name: name, url: URL(string: "https://example.invalid/x")!, etag: "\"abc\"")
        check(DiskCache.cached(name)?.data == Data("hello".utf8), "cache round trip")
        do {
            let r = try await DiskCache.fetch(URL(string: "https://anvil-test.invalid/nothing")!, name: name, timeout: 5)
            check(r.fromCache && r.data == Data("hello".utf8), "unreachable host answers from the cache")
            print("unreachable fetch answered from cache:", r.fromCache)
        } catch { check(false, "fetch with a cached copy must not throw: \(error)") }
        do {
            _ = try await DiskCache.fetch(URL(string: "https://anvil-test.invalid/nothing")!, name: "never-cached", timeout: 5)
            check(false, "uncached unreachable fetch should throw")
        } catch { print("uncached unreachable fetch throws:", error.localizedDescription) }
        print("connectivity now:", Connectivity.isOnlineNow)

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
