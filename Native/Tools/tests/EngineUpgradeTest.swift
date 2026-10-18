// Autopilot's engine upgrade, end to end in a throwaway home: switch with a snapshot,
// keep after a faster session, go back after a slower one and don't try again.
//
// Needs a throwaway home (…/home) with copies of library.json (executables pointed at
// copies, an empty Containers/<id> per container), game.log, anvil.log, Tuning/ and
// Health/, and two engines in Runtimes/: Anvil's mythic-engine-2.6.1 and an unpacked
// Engine 3.0 as mythic-engine-3.0.0. The guard below refuses any other home.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/EngineUpgradeTest.swift -o $TMPDIR/EngineUpgradeTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/EngineUpgradeTest
import Foundation

/// Autopilot's engine upgrade, end to end in a throwaway home: switch, keep, go back.
@main struct EngineUpgradeHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/Library/Application Support/Anvil") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let lib = Library.shared
        guard let lego = lib.games.first(where: { $0.title.contains("LEGO") }) else { exit(3) }
        print("engines:", RuntimeManager.shared.runtimes.map { "\($0.id) [\($0.displayName), D3DMetal \($0.d3dMetalVersion ?? "-"), managed \($0.isManaged)]" })
        print("needs speed:", Autopilot.shared.needsSpeed(lego))

        // 1. The upgrade.
        await Autopilot.shared.considerEngineUpgrade(gameID: lego.id)
        var c = lib.container(id: lego.containerID)!
        print("container:", c.runtimeID, "trial:", c.engineTrial.map { "\($0.fromRuntimeID) → \($0.toRuntimeID), before \($0.before.map { String(format: "%.0f fps, %.0f%%, %.1f min", $0.fps, $0.shareAt80 * 100, $0.minutes) } ?? "none"), by autopilot \($0.byAutopilot)" } ?? "none")
        check(c.runtimeID == "mythic-engine-3.0.0", "LEGO's container switched to Engine 3.0")
        check(c.engineTrial?.before != nil, "the trial carries how the game ran before")
        check(Tuner.shared.state(for: lego) == nil, "Auto-Tune starts again on the new engine")
        check(SnapshotManager.shared.snapshots(for: c).count == 1, "a snapshot was taken first")
        check(Autopilot.shared.report(for: lego)?.findings.first?.id == "engine-switched", "Health says it switched")
        check(Autopilot.shared.banner != nil, "a banner says so")

        // 2. A faster session on it: kept.
        func appendSession(fps: Double, gpu: Int, minutes: Double) {
            let start = Date()
            let iso = ISO8601DateFormatter()
            let stamp = iso.string(from: start)
            var game = "\n=== \(lego.title) — \(stamp) — Anvil \(AnvilVersion.current) ===\n"
            let windows = Int(minutes * 60 * fps / 600) + 3
            for _ in 0..<windows {
                game += String(format: "10:00:00.000 [anvil] displayed %.1f fps | 1%% LOW %.1f fps | STEADY 99.0%% | shown as ready 0%% | EVENNESS 99.0%% on-beat (590 of 600 gaps) worst gap 16.7 ms | rendered %.1f fps (game could %.1f) | real=600 gen=0 | GPU %d%% busy | busiest threads 50%% and 30%% of a core\n",
                               fps, fps - 5, fps, fps + 5, gpu)
            }
            let launch = "\(stamp)  prepareAndLaunch: \(lego.title) container=Star Wars runtime=x exe=y\n\(stamp)  exited: \(lego.title) code=0 after \(Int(minutes * 60))s\n"
            for (file, text) in [(Launcher.gameLogURL, game), (AnvilLog.url, launch)] {
                let h = try! FileHandle(forWritingTo: file); _ = try? h.seekToEnd(); try! h.write(contentsOf: Data(text.utf8)); try! h.close()
            }
        }
        appendSession(fps: 96, gpu: 80, minutes: 4)
        await Autopilot.shared.check(gameID: lego.id, outcome: .init(status: 0, seconds: 260, userClosed: false), announce: false)
        c = lib.container(id: lego.containerID)!
        let kept = Autopilot.shared.report(for: lego)?.findings.first { $0.id == "engine-trial" }
        print("after a faster session:", c.runtimeID, "judged:", c.engineTrial?.judged ?? false, "—", kept.map { "[\($0.kind.rawValue)] \($0.title): \($0.detail)" } ?? "no finding")
        check(c.runtimeID == "mythic-engine-3.0.0" && c.engineTrial?.judged == true, "a faster session keeps Engine 3.0")
        check(kept?.kind == .good, "Health says it runs at least as well")
        let tune = Tuner.shared.state(for: lib.games.first { $0.id == lego.id }!)
        print("auto-tune after it:", tune.map { "\($0.mode) \($0.trials.map { "\($0.setup.shortTitle) \(String(format: "%.1f", $0.minutes)) min" })" } ?? "none")
        check(tune?.mode == .whilePlaying, "Auto-Tune measures again on the new engine")

        // 3. A slower session on a fresh trial: back to the old engine, not tried again.
        c.engineTrial?.judged = false
        lib.update(c)
        appendSession(fps: 55, gpu: 95, minutes: 4)
        await Autopilot.shared.check(gameID: lego.id, outcome: .init(status: 0, seconds: 260, userClosed: false), announce: false)
        c = lib.container(id: lego.containerID)!
        let back = Autopilot.shared.report(for: lego)?.findings.first { $0.id == "engine-trial" }
        print("after a slower session:", c.runtimeID, "rejected:", c.rejectedEngines, "—", back.map { "[\($0.kind.rawValue)] \($0.title)" } ?? "no finding")
        check(c.runtimeID == "mythic-engine-2.6.1" && c.engineTrial == nil, "a clearly slower session goes back to 2.6.1")
        check(c.rejectedEngines == ["mythic-engine-3.0.0"], "Engine 3.0 is remembered as slower here")
        await Autopilot.shared.considerEngineUpgrade(gameID: lego.id)
        check(lib.container(id: lego.containerID)!.runtimeID == "mythic-engine-2.6.1", "Autopilot doesn't try it again")

        print(failures == 0 ? "engine upgrade: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
