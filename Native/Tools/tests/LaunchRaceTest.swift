import Foundation

/// 0.21.0's fixes, in a throwaway home, through the real launcher, Auto-Tune and engine
/// optimizer:
/// 1. a game being launched is busy, and Auto-Tune doesn't start on it mid-launch — on
///    1 October it started four seconds into LEGO's launch, so six measured minutes were lost;
/// 2. a warm-up ended for a game — by the launch itself, or seen by the warm-up — is paused,
///    never recorded as an engine that doesn't start (which Autopilot would never offer);
/// 3. a paused warm-up carries on once nothing is running, and a warm-up waits while a game
///    is starting.
/// The launches are on a fake engine whose files changed since it was sealed, so each stops
/// at the engine check: no Wine, no game. The fake engines' "Wine" is a shell script.
/// CFFIXED_USER_HOME=…/race/home launchracetest <library.json> <LEGO's PCCONFIG.TXT>
@main struct LaunchRaceHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/race/home/") else { print("refusing"); exit(2) }
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: launchracetest <library.json> <PCCONFIG.TXT>"); exit(2) }
        let fm = FileManager.default
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        func log() -> String { (try? String(contentsOf: AnvilLog.url, encoding: .utf8)) ?? "" }

        // A fake engine: a loader that makes its "Windows setup" after a while, and a wineserver.
        func makeEngine(_ dir: URL, seconds: Double,
                        loader: String? = nil, server: String = "#!/bin/sh\nexit 0\n") {
            let bin = dir.appendingPathComponent("bin")
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try! Data((loader ?? "#!/bin/sh\nsleep \(seconds)\n: > \"$WINEPREFIX/system.reg\"\n").utf8).write(to: bin.appendingPathComponent("wine64"))
            try! Data(server.utf8).write(to: bin.appendingPathComponent("wineserver"))
            for f in ["wine64", "wineserver"] {
                try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(f).path)
            }
        }

        // A verdict from 0.20–0.21.0's check, which read every engine as not starting:
        // written before the optimizer first loads its records.
        try? fm.createDirectory(at: EngineOptimizer.dir, withIntermediateDirectories: true)
        let oldRecord = EngineOptimizer.dir.appendingPathComponent("old-engine-1.0.json")
        try! Data("""
            {"runtimeID":"old-engine-1.0","fingerprint":"x","preparedAt":"2026-10-01T19:22:22Z","starts":false,"steps":["didn't start (22 s)"],"warmUpSeconds":21.6,
             "profile":{"runtimeID":"old-engine-1.0","wineMajor":7,"gameBinary":"wine64-preloader","needsLoaderPath":false,"asyncCommit":false,"msync":true,"proController":true}}
            """.utf8).write(to: oldRecord)
        let warmUps = RuntimeManager.support.appendingPathComponent("Cache/EngineWarmUp")
        func warmUpRunning() async -> Bool {
            for _ in 0..<100 {
                if let items = try? fm.contentsOfDirectory(atPath: warmUps.path), !items.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))   // and its loader started
                    return true
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }

        // The library and LEGO's settings file, copied.
        try? fm.createDirectory(at: RuntimeManager.support, withIntermediateDirectories: true)
        try? fm.removeItem(at: RuntimeManager.support.appendingPathComponent("library.json"))
        try! fm.copyItem(at: URL(fileURLWithPath: args[1]), to: RuntimeManager.support.appendingPathComponent("library.json"))
        Library.shared.load()
        guard var lego = Library.shared.games.first(where: { $0.title.contains("LEGO") }),
              let box = Library.shared.container(id: lego.containerID) else { print("no LEGO"); exit(3) }
        let config = box.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT")
        try? fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: config)
        try! fm.copyItem(at: URL(fileURLWithPath: args[2]), to: config)
        lego.autopilot = true
        lego.graphicsTuning = .automatic
        Library.shared.update(lego)

        // An engine changed since it was sealed: a launch on it begins, then stops at the
        // engine check, before anything runs.
        let broken = RuntimeManager.support.appendingPathComponent("broken-engine")
        makeEngine(broken, seconds: 0)
        _ = try! EngineSeal.seal(root: broken, id: "broken-engine-1.0")
        try! Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken.appendingPathComponent("bin/wine64"))
        let brokenEngine = Runtime(id: "broken-engine-1.0", displayName: "Broken Engine", version: "1.0", root: broken, isManaged: true)
        func launch() -> Task<String, Never> {
            Task { @MainActor in
                do { _ = try await Launcher.shared.prepareAndLaunch(game: lego, container: box, runtime: brokenEngine); return "launched" }
                catch { return String(describing: error) }
            }
        }

        // 1. Mid-launch: busy, and Auto-Tune stays off.
        check(Launcher.shared.isIdle && !Launcher.shared.isBusy(lego), "idle before the launch")
        let first = launch()
        for _ in 0..<50 where !Launcher.shared.isBusy(lego) { await Task.yield() }
        check(Launcher.shared.isBusy(lego) && !Launcher.shared.isRunning(lego), "mid-launch: busy, not running yet")
        check(!Launcher.shared.isIdle, "mid-launch: Anvil isn't idle")
        check(!Tuner.shared.autoStart(lego, container: box, played: nil), "mid-launch: Auto-Tune doesn't start (1 October)")
        check(Tuner.shared.state(for: lego) == nil, "mid-launch: nothing was started")
        let outcome = await first.value
        check(outcome.contains("engineChanged"), "the launch stopped at the changed engine (\(outcome.prefix(40)))")
        check(Launcher.shared.isIdle && !Launcher.shared.isBusy(lego), "after the launch: idle again")
        check(Tuner.shared.autoStart(lego, container: box, played: nil), "after the launch: Auto-Tune can start")
        Tuner.shared.reset(lego)

        // 2. A warm-up ended through yieldToGame — the launcher's own call — and nothing
        //    left running to see: paused, not judged.
        let optimizer = EngineOptimizer.shared
        makeEngine(RuntimeManager.runtimesDir.appendingPathComponent("slow-engine-1.0"), seconds: 3)
        RuntimeManager.shared.discover()
        guard let slow = RuntimeManager.shared.runtime(id: "slow-engine-1.0") else { print("no fake engine"); exit(3) }
        let preparing = Task { @MainActor in await optimizer.prepare(slow) }
        check(await warmUpRunning(), "the warm-up started")
        optimizer.yieldToGame()
        await preparing.value
        check(!optimizer.isPrepared(slow), "ended for a game: not recorded as a verdict")
        check(optimizer.mayOffer(slow), "…so Autopilot may still offer the engine")
        check(log().contains("paused — a game started"), "…and logged as paused")
        check(((try? fm.contentsOfDirectory(atPath: warmUps.path)) ?? []).isEmpty, "…its throwaway setup removed")

        // 3. It carries on once idle, and the engine starts.
        optimizer.prepareWhenIdle(after: .milliseconds(50))
        for _ in 0..<150 where !optimizer.isPrepared(slow) { try? await Task.sleep(for: .milliseconds(100)) }
        check(optimizer.isPrepared(slow), "carried on once idle: prepared")
        check(optimizer.records[slow.id]?.starts == true, "…and it made its Windows setup")

        // 4. A real launch during a warm-up — one that fails at once, so the warm-up may never
        //    see it under way: still paused, not judged.
        makeEngine(RuntimeManager.runtimesDir.appendingPathComponent("slow-engine-2.0"), seconds: 3)
        RuntimeManager.shared.discover()
        let slow2 = RuntimeManager.shared.runtime(id: "slow-engine-2.0")!
        let preparing2 = Task { @MainActor in await optimizer.prepare(slow2) }
        check(await warmUpRunning(), "a second warm-up started")
        let second = launch()
        _ = await second.value
        await preparing2.value
        check(!optimizer.isPrepared(slow2), "a launch during the warm-up: not recorded as a verdict")

        // 5. While a game is starting, preparing waits.
        let third = launch()
        for _ in 0..<50 where !Launcher.shared.isBusy(lego) { await Task.yield() }
        await optimizer.prepareAll()
        _ = await third.value
        check(log().contains("waits — a game is running or starting"), "preparing waits while a game starts")
        check(!optimizer.isPrepared(slow2), "…and did nothing meanwhile")
        optimizer.prepareWhenIdle(after: .milliseconds(50))
        for _ in 0..<150 where !optimizer.isPrepared(slow2) { try? await Task.sleep(for: .milliseconds(100)) }
        check(optimizer.isPrepared(slow2) && optimizer.records[slow2.id]?.starts == true, "…then carried on and prepared it")

        // 6. Verdicts (0.21.1).
        check(optimizer.records["old-engine-1.0"] == nil && !fm.fileExists(atPath: oldRecord.path),
              "a verdict from the old check is dropped, so the engine is prepared again")
        func verdict(_ id: String, loader: String, server: String = "#!/bin/sh\nexit 0\n") async -> EngineOptimizer.Record? {
            makeEngine(RuntimeManager.runtimesDir.appendingPathComponent(id), seconds: 0, loader: loader, server: server)
            RuntimeManager.shared.discover()
            guard let r = RuntimeManager.shared.runtime(id: id) else { return nil }
            await optimizer.prepare(r)
            return optimizer.records[id]
        }
        // Wine writes its registry when its server finishes, after the run: the server is
        // waited for. (This stand-in even exits with 1, so only the registry can say it started.)
        let late = await verdict("late-engine-1.0",
            loader: "#!/bin/sh\n( sleep 2; : > \"$WINEPREFIX/system.reg\" ) &\nexit 1\n",
            server: "#!/bin/sh\n[ \"$1\" = -w ] && for i in $(seq 1 50); do [ -f \"$WINEPREFIX/system.reg\" ] && break; sleep 0.2; done\nexit 0\n")
        print("late:", late?.steps.last ?? "-")
        check(late?.starts == true && late?.failure == nil, "registry written after the run, as Wine does: started (1 October's mistake)")
        let folder = await verdict("folder-engine-1.0", loader: "#!/bin/sh\nmkdir -p \"$WINEPREFIX/drive_c/windows/system32\"\nexit 0\n")
        check(folder?.starts == true && folder?.failure == nil, "made its Windows folder: started")
        let broken2 = await verdict("failing-engine-1.0", loader: "#!/bin/sh\nexit 3\n")
        print("failing:", broken2?.failure ?? "-")
        check(broken2?.failure != nil && !optimizer.mayOffer(RuntimeManager.shared.runtime(id: "failing-engine-1.0")!),
              "failed at once, made nothing: not offered")
        check(optimizer.mayOffer(RuntimeManager.shared.runtime(id: "late-engine-1.0")!), "…while the others are")
        check(optimizer.records.values.allSatisfy { $0.check == EngineOptimizer.checkVersion }, "every record made by the new check")

        // 7. Offline Mode (0.21.1).
        let net = Connectivity.shared
        check(!net.offlineMode && !Connectivity.offlineModeNow, "Offline Mode is off to start with")
        net.setOfflineMode(true)
        check(net.offlineMode && Connectivity.offlineModeNow && !Connectivity.isOnlineNow && !net.isOnline,
              "Offline Mode on: Anvil counts itself offline, whatever the network")
        check(net.summary.hasPrefix("Offline Mode"), "…and says so (\(net.summary.prefix(40)))")
        check(UserDefaults.standard.bool(forKey: Connectivity.offlineModeKey), "…and remembers it")
        net.setOfflineMode(false)
        try? await Task.sleep(for: .milliseconds(300))   // the network monitor's last word in
        check(!net.offlineMode && !Connectivity.offlineModeNow && Connectivity.isOnlineNow == net.networkUp,
              "Offline Mode off: back to the network's own state")
        check(log().contains("offline mode: on") && log().contains("offline mode: off"), "both logged")

        // 8. Epic out of reach while connected: found out within the timeout.
        let t0 = Date()
        let reached = await Connectivity.reaches(URL(string: "http://127.0.0.1:9/")!, timeout: 3)
        check(!reached && Date().timeIntervalSince(t0) < 4.5, String(format: "an address that doesn't answer: not reached, in %.1f s", Date().timeIntervalSince(t0)))

        // 9. Trackpad and keyboard (0.22.0): the settings, the file Wine imports, one Wine run.
        var pad = Library.shared.container(id: box.id)!
        pad.scrollInSteps = nil; pad.optionIsAlt = nil; pad.commandIsCtrl = nil
        let defaults = Dictionary(uniqueKeysWithValues: Prefix.inputSettings(pad).map { ($0.name, $0.value) })
        check(defaults["UsePreciseScrolling"] == "n" && defaults["LeftOptionIsAlt"] == "y" && defaults["RightOptionIsAlt"] == "n"
              && defaults["LeftCommandIsCtrl"] == "n", "defaults: scroll in steps, left Option as Alt, Command left alone")
        let reg = Prefix.inputRegFile(pad)
        check(reg.hasPrefix("REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n") && reg.contains("\"UsePreciseScrolling\"=\"n\"\r\n"),
              "the .reg file is what Wine's reg import reads")
        let recorder = RuntimeManager.support.appendingPathComponent("input-engine")
        makeEngine(recorder, seconds: 0, loader: "#!/bin/sh\nprintf '%s|' \"$@\" > \"$WINEPREFIX/input-args.txt\"\ncp \"$WINEPREFIX/drive_c/anvil-input.reg\" \"$WINEPREFIX/input-copy.reg\"\nexit 0\n")
        let inputEngine = Runtime(id: "input-engine-1.0", displayName: "Input Engine", version: "1.0", root: recorder, isManaged: false)
        try? fm.createDirectory(at: pad.driveC, withIntermediateDirectories: true)
        check(Prefix.needsInput(pad), "a container without them needs them")
        let applied = await Prefix.applyInput(container: pad, runtime: inputEngine)
        let ranWith = (try? String(contentsOf: pad.prefixURL.appendingPathComponent("input-args.txt"), encoding: .utf8)) ?? ""
        let imported = (try? String(contentsOf: pad.prefixURL.appendingPathComponent("input-copy.reg"), encoding: .utf8)) ?? ""
        check(applied && ranWith == "reg|import|C:\\anvil-input.reg|", "one Wine run: reg import C:\\anvil-input.reg (\(ranWith))")
        check(imported == reg, "…of exactly that file")
        check(!fm.fileExists(atPath: pad.driveC.appendingPathComponent("anvil-input.reg").path), "…which is removed afterwards")
        check(!Prefix.needsInput(pad), "applied: not again")
        let again = await Prefix.applyInput(container: pad, runtime: inputEngine)
        check(!again, "…a second launch runs no Wine for it")
        pad.commandIsCtrl = true
        check(Prefix.needsInput(pad) && Prefix.inputRegFile(pad).contains("\"LeftCommandIsCtrl\"=\"y\""), "a changed setting is written again")

        // 10. Anti-cheat (0.22.0): nothing of Anvil's into such a game's folder.
        let acGame = RuntimeManager.support.appendingPathComponent("Games/Protected/Binaries/Win64")
        try? fm.createDirectory(at: acGame, withIntermediateDirectories: true)
        try? fm.createDirectory(at: RuntimeManager.support.appendingPathComponent("Games/Protected/EasyAntiCheat"), withIntermediateDirectories: true)
        try! Data().write(to: acGame.appendingPathComponent("Protected.exe"))
        let plainGame = RuntimeManager.support.appendingPathComponent("Games/Plain")
        try? fm.createDirectory(at: plainGame, withIntermediateDirectories: true)
        try! Data().write(to: plainGame.appendingPathComponent("Plain.exe"))
        check(AntiCheat.detect(forExecutable: acGame.appendingPathComponent("Protected.exe")) == [.easyAntiCheat], "Easy Anti-Cheat found above Binaries/Win64")
        var refused = ""
        do { try UpscalerManager.refuseAntiCheatGame(at: acGame.appendingPathComponent("Protected.exe").path) }
        catch { refused = error.localizedDescription }
        check(refused.contains("Easy Anti-Cheat") && refused.contains("never puts files"), "upscaler files refused there")
        check(!fm.fileExists(atPath: acGame.appendingPathComponent(".anvil-backup").path), "…and nothing was created in its folder")
        check((try? UpscalerManager.refuseAntiCheatGame(at: plainGame.appendingPathComponent("Plain.exe").path)) != nil,
              "a game without anti-cheat is unaffected")

        print(failures == 0 ? "launch race: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
