import Foundation

/// 0.20.0's engine optimizer on copies of the real engines and library, in a throwaway home:
/// engine profiles read from the files, the retry rule, the baseline rule and display-mode
/// learning from the window libanvil reports.
/// CFFIXED_USER_HOME=…/opt/home engineoptimizertest <Runtimes folder> <library.json>
@main struct EngineOptimizerHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/opt/home/") else { print("refusing"); exit(2) }
        let args = CommandLine.arguments
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        try? fm.createDirectory(at: RuntimeManager.runtimesDir, withIntermediateDirectories: true)
        for id in ["mythic-engine-2.6.1", "mythic-engine-3.0.0", "whiskywine-2.5.0"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp")
            p.arguments = ["-Rc", URL(fileURLWithPath: args[1]).appendingPathComponent(id).path, RuntimeManager.runtimesDir.appendingPathComponent(id).path]
            try! p.run(); p.waitUntilExit()
        }
        RuntimeManager.shared.discover()

        // 1. Profiles, from the files alone.
        for r in RuntimeManager.shared.runtimes {
            let p = EngineProfile.of(r)
            print("\(r.id): \(p.title); game runs as \(p.gameBinary); loader path \(p.needsLoaderPath); msync \(p.msync); support \(p.supportLevel)")
        }
        let e2 = EngineProfile.of(RuntimeManager.shared.runtime(id: "mythic-engine-2.6.1")!)
        let e3 = EngineProfile.of(RuntimeManager.shared.runtime(id: "mythic-engine-3.0.0")!)
        check(e2.wineVersion == "7.7" && e2.gameBinary == "wine64-preloader" && !e2.needsLoaderPath && e2.proController && !e2.asyncCommit, "Engine 2.6.1: Wine 7.7, preloader, Pro Controller")
        check(e3.wineVersion == "9.0" && e3.gameBinary == "wine-preloader" && e3.needsLoaderPath && !e3.proController && e3.asyncCommit, "Engine 3.0: Wine 9.0, runs in wine-preloader, needs the loader path, async commit")
        check(e3.supportLevel > e2.supportLevel, "Wine 9 is at the newer support level")

        // 2. Retry rule.
        var c = Container(name: "T", runtimeID: "mythic-engine-2.6.1")
        let r3 = RuntimeManager.shared.runtime(id: "mythic-engine-3.0.0")!
        c.reject(r3.id, atSupport: 1)
        check(c.mayTry(r3), "rejected under the old Wine 9 support: one more trial now")
        c.reject(r3.id)
        check(!c.mayTry(r3), "rejected under today's support: not again")
        var d = Container(name: "U", runtimeID: "mythic-engine-2.6.1")
        d.reject(r3.id, byPlayer: true)
        check(!d.mayTry(r3), "switched back by the player: never by itself")

        // 3. The library: LEGO back on 2.6.1 with 3.0 rejected under the old support, no baseline yet.
        try? fm.removeItem(at: RuntimeManager.support.appendingPathComponent("library.json"))
        try! fm.copyItem(at: URL(fileURLWithPath: args[2]), to: RuntimeManager.support.appendingPathComponent("library.json"))
        Library.shared.load()
        var lego = Library.shared.games.first { $0.title.contains("LEGO") }!
        var box = Library.shared.container(id: lego.containerID)!
        box.runtimeID = "mythic-engine-2.6.1"
        box.engineTrial = nil
        box.reject(r3.id, atSupport: 1)
        Library.shared.update(box)
        lego.lastSession = nil
        Library.shared.update(lego)
        await Autopilot.shared.considerEngineUpgrade(gameID: lego.id)
        check(Library.shared.container(id: box.id)!.runtimeID == "mythic-engine-2.6.1", "no trial without a measured session on the current engine")

        // 4. Display mode learning, from the window line libanvil writes.
        try? fm.createDirectory(at: RuntimeManager.support, withIntermediateDirectories: true)
        func session(window: String) async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let text = "\n=== \(lego.title) — \(stamp) — Anvil \(AnvilVersion.current) ===\n"
                + "21:00:00.000 [anvil] drawable 1512x982 format=80 writable=1 srgb=0 -> ACTIVE\n"
                + "[anvil] window: \(window)\n"
            let launch = "\(stamp)  prepareAndLaunch: \(lego.title) container=\(box.name) runtime=x exe=y\n\(stamp)  exited: \(lego.title) code=0 after 40s\n"
            for (url, t) in [(Launcher.gameLogURL, text), (AnvilLog.url, launch)] {
                if !fm.fileExists(atPath: url.path) { try! Data().write(to: url) }
                let h = try! FileHandle(forWritingTo: url); _ = try? h.seekToEnd(); try! h.write(contentsOf: Data(t.utf8)); try! h.close()
            }
            await Autopilot.shared.check(gameID: lego.id, outcome: .init(status: 0, seconds: 40, userClosed: false), announce: false, considerEngine: false)
        }
        func mode(_ major: Int) -> GameTuning.DisplayMode { GameTuning.displayMode(for: Library.shared.games.first { $0.id == lego.id }!, wineMajor: major) }
        // From nothing learned yet: the real library has learned modes since 1 October.
        var unlearned = Library.shared.games.first { $0.id == lego.id }!
        unlearned.displayModes = nil
        Library.shared.update(unlearned)
        check(mode(7) == .fullscreen, "Wine 7: fullscreen to start with")
        await session(window: "1512x982 at (0, 0) on a 1512x982 screen — fills it")
        check(mode(7) == .fullscreen, "fills the screen: kept")
        // On Wine 9, as on 1 October.
        box = Library.shared.container(id: box.id)!
        box.runtimeID = "mythic-engine-3.0.0"; Library.shared.update(box)
        await session(window: "1636x1062 at (-62, -40) on a 1512x982 screen — larger than the screen — its edges are cut off")
        check(mode(9) == .borderless, "cut off in fullscreen on Wine 9: a borderless window next time")
        check(Autopilot.shared.report(for: lego)?.findings.contains { $0.id == "display-fit" } == true, "Health says so")
        await session(window: "1512x945 at (0, 0) on a 1512x982 screen — doesn't fill it — below the menu bar")
        check(mode(9) == .fullscreenWindow, "below the menu bar as a window: the game's own fullscreen window next")
        await session(window: "1512x982 at (0, 0) on a 1512x982 screen — fills it")
        check(mode(9) == .fullscreenWindow, "that one fills it: kept for Wine 9")
        check(mode(7) == .fullscreen, "and Wine 7 keeps its own")
        // What a launch on each engine writes.
        let config = box.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT")
        try? fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("ScreenWidth\t1512\nScreenHeight\t982\nWindowWidth\t1512\nWindowHeight\t982\nWindowLeft\t0\nWindowTop\t0\nWindowed\t0\nBorderlessWindow\t0\nFullscreenWindow\t0\nScreenRefreshRate\t120\n".utf8).write(to: config)
        let g = Library.shared.games.first { $0.id == lego.id }!
        print("Wine 9 launch:", GameTuning.fitDisplay(g, in: box, wineMajor: 9, screen: (1512, 982)) ?? "nothing")
        let v = GameTuning.values(in: try! String(contentsOf: config, encoding: .utf8))
        check(v["Windowed"] == "1" && v["BorderlessWindow"] == "1" && v["FullscreenWindow"] == "1", "a Wine 9 launch writes the mode that filled the screen there")
        print("Wine 7 launch:", GameTuning.fitDisplay(g, in: box, wineMajor: 7, screen: (1512, 982)) ?? "nothing")
        let v7 = GameTuning.values(in: try! String(contentsOf: config, encoding: .utf8))
        check(v7["Windowed"] == "0" && v7["FullscreenWindow"] == "0", "a Wine 7 launch writes fullscreen")

        // 5. The optimizer's bookkeeping: an engine that didn't start isn't offered.
        let opt = EngineOptimizer.shared
        check(opt.mayOffer(r3), "an engine not prepared yet may be offered")
        print("fingerprint:", EngineOptimizer.fingerprint(r3))
        check(EngineOptimizer.fingerprint(r3) != EngineOptimizer.fingerprint(RuntimeManager.shared.runtime(id: "mythic-engine-2.6.1")!), "engines told apart by their files")

        print(failures == 0 ? "engine optimizer: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
