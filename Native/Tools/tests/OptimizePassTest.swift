// Optimize for This Mac (0.68, OptimizePass), in a throwaway home: what a game needs, decided from this Mac and its
// sessions; the progress bar's share and time left; the folder Rosetta keeps translated code in; and the whole pass
// for Hogwarts Legacy — its launcher, its 458 MB program, a copy of its setup's registry and Engine.ini, game.log —
// on a copy of Mythic Engine 3.0 and the real anvil-prep beside this harness (on the GPU where there is one). The
// game's own files must come out exactly as they went in.
//
//   cp anvil-prep libanvil.dylib AnvilShaders.metal $B/   # Bundle.main.resourceURL is the harness's folder
//   CFFIXED_USER_HOME=$T/home HOME=$T/home OptimizePassTest <Anvil's Runtimes folder> <its HogwartsLegacy.exe (the launcher)>
//     <its Engine.ini> <game.log> <its setup's folder (its system.reg and Microsoft's vcruntime140.dll copied from it)>
import Foundation

@MainActor
final class Samples { var all: [(Double, Double)] = [] }

@main
struct OptimizePassTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let a = CommandLine.arguments
        guard a.count >= 6 else { print("usage: see header"); exit(2) }
        let fm = FileManager.default
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
        guard !RuntimeManager.support.path.hasPrefix(realHome + "/Library") else { print("refusing: not in a throwaway home"); exit(2) }
        let runtimes = URL(fileURLWithPath: a[1]), exe = a[2], realIni = URL(fileURLWithPath: a[3]),
            realLog = URL(fileURLWithPath: a[4]), realPrefix = URL(fileURLWithPath: a[5])
        let gb: Int64 = 1_073_741_824

        print("— what it needs")
        var i = OptimizePass.Inputs(memoryFree: 12 * gb)
        i.memoryNeeded = 19 * gb
        i.biggestApps = ["Claude 1.1 GB"]
        var n = OptimizePass.needs(i)
        check(n.first?.id == "memory" && n.first?.kind == .act && n.first?.detail.contains("19.0 GB") == true && n.first?.detail.contains("Claude 1.1 GB") == true,
              "19 GB taken, 12 free: free memory first, naming what holds it")
        i.memoryFree = 22 * gb
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "memory" && $0.kind == .fine } && n.allSatisfy { $0.kind == .fine }, "22 free: enough, and nothing to do")
        i.lowPowerMode = true
        i.hot = true
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "power" && $0.kind == .act } && n.contains { $0.id == "heat" && $0.kind == .act } && !n.contains { $0.id == "power" && $0.kind == .fine },
              "Low Power Mode on and hot: both to act on")
        i.lowPowerMode = false; i.hot = false
        i.enhancementsOff = true
        i.diskFree = 3 * gb
        n = OptimizePass.needs(i)
        check(n.first?.id == "library" && n.contains { $0.id == "disk" && $0.kind == .act }, "Anvil's library off: first; 3 GB of disk: to act on")
        i.enhancementsOff = false; i.diskFree = 200 * gb
        i.unreal = true
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "unreal" && $0.kind == .act && $0.title.contains("from a store") }, "an Unreal game added from its program: install it from a store to tune it")
        i.fromStore = true; i.unrealTuning = false; i.tuningDeclined = true
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "unreal" && $0.kind == .act && $0.detail.contains("first start") }, "said no at its first start: off, and how to turn it on")
        i.unrealTuning = true; i.tuningSummary = ["No garbage collection forced as the world streams out: kept"]
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "unreal" && $0.kind == .fine && $0.detail.contains("kept") }, "tuned: fine, with what's kept")
        i.prepFailed = "the GPU test didn't finish"
        i.averageFPS = 47; i.shareAt80 = 0.06; i.rayTraced = true
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "prep" && $0.kind == .act } && n.contains { $0.id == "raytracing" && $0.kind == .act }, "Graphics Prep failed, ray tracing at 6% at 80: both to act on")
        let firstFine = n.firstIndex(where: { $0.kind == .fine }) ?? n.count, lastAct = n.lastIndex(where: { $0.kind == .act }) ?? -1
        check(firstFine > lastAct, "what to act on comes before what's fine")
        i.prepFailed = nil; i.rayTraced = false; i.shareAt80 = 0.9; i.averageFPS = 82
        n = OptimizePass.needs(i)
        check(n.contains { $0.id == "fps" && $0.kind == .fine } && !n.contains { $0.id == "raytracing" }, "holding 80 90% of the time: fine")

        print("— the progress bar")
        var steps: [OptimizePass.Step] = [.init(id: "a", title: "A", expected: 2), .init(id: "b", title: "B", expected: 60), .init(id: "c", title: "C", expected: 0.2)]
        var p = OptimizePass.progress(steps, within: 0)
        check(p.fraction == 0 && abs(p.remaining - 62.2) < 0.001, "nothing done: 0%, 62 s left")
        steps[0].state = .done; steps[1].state = .running
        p = OptimizePass.progress(steps, within: 0.5)
        check(abs(p.fraction - 32 / 62.2) < 0.001 && abs(p.remaining - 30.2) < 0.001, String(format: "the long step half way: %.0f%%, %.0f s left", p.fraction * 100, p.remaining))
        p = OptimizePass.progress(steps, within: 1.4)
        check(p.fraction < 1 && p.remaining > 0, "a running step never reads as finished")
        steps[1].state = .failed; steps[2].state = .skipped
        p = OptimizePass.progress(steps, within: 0)
        check(p.fraction == 1 && p.remaining == 0, "every step over, failed or skipped too: 100%")
        check(OptimizePass.remainingText(3) == "a few seconds left" && OptimizePass.remainingText(42) == "about 40 s left" && OptimizePass.remainingText(150) == "about 3 min left",
              "time left in words: \(OptimizePass.remainingText(42)), \(OptimizePass.remainingText(150))")

        print("— the whole pass, for Hogwarts Legacy")
        try? fm.createDirectory(at: RuntimeManager.runtimesDir, withIntermediateDirectories: true)
        let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-Rc", runtimes.appendingPathComponent("mythic-engine-3.0.0").path, RuntimeManager.runtimesDir.appendingPathComponent("mythic-engine-3.0.0").path]
        try? cp.run(); cp.waitUntilExit()
        RuntimeManager.shared.discover()
        guard let runtime = RuntimeManager.shared.runtime(id: "mythic-engine-3.0.0") else { print("FAIL Mythic Engine 3.0 copied"); exit(1) }
        var c = Container(name: "Hogwarts", runtimeID: runtime.id)
        c.id = UUID()
        try? fm.createDirectory(at: c.prefixURL, withIntermediateDirectories: true)
        try? fm.copyItem(at: realPrefix.appendingPathComponent("system.reg"), to: c.prefixURL.appendingPathComponent("system.reg"))
        for folder in ["drive_c/windows/system32", "drive_c/windows/syswow64"] {
            let dll = realPrefix.appendingPathComponent(folder).appendingPathComponent("vcruntime140.dll")
            guard fm.fileExists(atPath: dll.path) else { continue }
            try? fm.createDirectory(at: c.prefixURL.appendingPathComponent(folder), withIntermediateDirectories: true)
            try? fm.copyItem(at: dll, to: c.prefixURL.appendingPathComponent(folder).appendingPathComponent("vcruntime140.dll"))
        }
        let config = c.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/Config/WindowsNoEditor", isDirectory: true)
        try? fm.createDirectory(at: config, withIntermediateDirectories: true)
        let ini = config.appendingPathComponent("Engine.ini")
        try? fm.copyItem(at: realIni, to: ini)
        try? fm.removeItem(at: Launcher.gameLogURL)
        try? fm.copyItem(at: realLog, to: Launcher.gameLogURL)
        var game = Game(title: "Hogwarts Legacy", executablePath: exe, containerID: c.id)
        game.epicAppName = "fa4240e57a3c46b39f169041b7811293"
        let program = GameAnalysis.drawingProgram(for: game.executableURL)
        func stamp(_ u: URL) -> String { UnrealTuning.stamp(u) ?? "-" }
        let before = (stamp(game.executableURL), stamp(program), (try? Data(contentsOf: ini)) ?? Data())
        let rosetta = c.shaderCacheURL.appendingPathComponent("rosetta")
        check(!fm.fileExists(atPath: rosetta.path) && GraphicsScan.stored(gameID: game.id) == nil, "before: no scan, no folder for Rosetta")

        let box = Samples()
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                if let act = OptimizeRunner.shared.activity, act.finished == nil {
                    let q = OptimizePass.progress(act.steps, within: act.within)
                    box.all.append((q.fraction, q.remaining))
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let started = Date()
        let run = Task { await OptimizeRunner.shared.run(game, container: c, runtime: runtime) }
        try? await Task.sleep(for: .milliseconds(300))
        check(OptimizeRunner.shared.running, "running")
        await OptimizeRunner.shared.run(game, container: c, runtime: runtime)
        check(OptimizeRunner.shared.running, "a second press while it runs does nothing")
        await run.value
        watch.cancel()
        let samples = box.all
        let took = Date().timeIntervalSince(started)
        guard let act = OptimizeRunner.shared.activity, act.finished != nil else { print("FAIL the pass finished"); exit(1) }
        for s in act.steps { print("     \(s.state) \(s.title): \(s.result ?? "-")") }
        print(String(format: "     %.0f s; %d progress readings", took, samples.count))
        func state(_ id: String) -> OptimizePass.Step.State? { act.steps.first { $0.id == id }?.state }
        func result(_ id: String) -> String { act.steps.first { $0.id == id }?.result ?? "" }
        let tuned = Set(UnrealTuning.managed(hasProfile: false).map(\.0)).count
        check(state("program") == .done && result("program").contains("Unreal") && result("program").contains("\(tuned) of the \(tuned) Unreal settings"),
              "its program read: Unreal, all \(tuned) of the settings Anvil tunes in it")
        check(state("scan") == .done && GraphicsScan.stored(gameID: game.id) != nil, "scanned, and the scan kept")
        let gpu = GraphicsPrep.gpuName != "no GPU"
        check(gpu ? state("prep") == .done && GraphicsPrep.stored(gameID: game.id)?.status == .ready : state("prep") == .failed,
              gpu ? "Graphics Prep on the \(GraphicsPrep.gpuName): ready — \(result("prep"))" : "no GPU here: Graphics Prep failed cleanly")
        check(state("vc") == .done && result("vc") == "in its setup", "Microsoft's Visual C++ Runtime: found in its setup's registry, nothing installed")
        check(state("rosetta") == .done && fm.fileExists(atPath: rosetta.path), "Rosetta's folder made")
        check(state("shaders") == .done, "its shader cache looked at")
        check(state("unreal") == .done && result("unreal").contains("measuring"), "Unreal Engine tuning: on, measuring how it runs first")
        check(state("memory") == .done && result("memory").contains("free") && result("memory").contains("it took up to"),
              "memory read, with what it took in its sessions in game.log: \(result("memory"))")
        check(act.needs.contains { $0.id == "unreal" && $0.kind == .fine } && !act.needs.contains { $0.id == "library" || $0.id == "vc" || $0.id == "warm" },
              "what it needs: \(act.needs.filter { $0.kind == .act }.map(\.title).joined(separator: "; ").isEmpty ? "nothing" : act.needs.filter { $0.kind == .act }.map(\.title).joined(separator: "; "))")
        let after = (stamp(game.executableURL), stamp(program), (try? Data(contentsOf: ini)) ?? Data())
        check(before.0 == after.0 && before.1 == after.1 && before.2 == after.2 && !before.2.isEmpty,
              "the game's launcher, its program and its Engine.ini exactly as they were")
        let rising = zip(samples, samples.dropFirst()).allSatisfy { $1.0 >= $0.0 - 1e-9 }
        let falling = zip(samples, samples.dropFirst()).allSatisfy { $1.1 <= $0.1 + 1e-9 }
        check(samples.count >= 3 && rising && falling, "the bar only moves forward, the time left only down")
        check(OptimizePass.progress(act.steps, within: 0).fraction == 1, "and ends at 100%")
        if gpu, let firstLeft = samples.first?.1 {
            print(String(format: "     first estimate %.0f s left; it took %.0f s", firstLeft, took))
            check(firstLeft >= took * 0.3 && firstLeft <= took * 4 + 10, "the first estimate within reach of how long it took")
        }
        OptimizeRunner.shared.close()
        check(OptimizeRunner.shared.activity == nil, "Done closes it")

        print("— a game added from its program")
        var added = game
        added.id = UUID()
        added.epicAppName = nil
        added.prepareGraphics = false
        await OptimizeRunner.shared.run(added, container: c, runtime: runtime)
        let b = OptimizeRunner.shared.activity
        check(b?.steps.first { $0.id == "unreal" }?.state == .skipped && b?.needs.contains { $0.id == "unreal" && $0.title.contains("from a store") } == true,
              "Unreal Engine tuning skipped, and what it needs says why")
        check(UnrealTuning.record(for: added) == nil && (try? Data(contentsOf: ini)) == before.2, "nothing of its tuning written")

        print(failures == 0 ? "optimize pass: all checks passed" : "optimize pass: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
