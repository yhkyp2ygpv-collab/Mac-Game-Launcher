// 0.28.0 and 0.29.0, in a throwaway home: Graphics Prep. anvil-prep's real output read into a
// prep, for LEGO's 8-bit picture and a 16-bit float one, with FSR 3's test; when a game is
// prepared again; what a launch is given, FSR 3 included; what a session showed, read from a
// real game.log; the crashes that turn one pass and FSR 3 off; and the whole run against the
// real anvil-prep beside this harness — on the GPU when there is one, or failing cleanly when
// there isn't.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/GraphicsPrepTest.swift -o $B/GraphicsPrepTest
//   cp anvil-prep libanvil.dylib AnvilShaders.metal $B/   # Bundle.main.resourceURL is the harness's folder
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $B/GraphicsPrepTest <game.log with libanvil's shader lines>
// (On the GPU in a terminal; without one in a sandbox, where the run must fail cleanly.)
import Foundation

@main struct GraphicsPrepHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/") else { print("refusing: not in a throwaway home"); exit(2) }
        let args = CommandLine.arguments
        let gameLog = URL(fileURLWithPath: args[1])
        let gpuRun = GraphicsPrep.gpuName != "no GPU"
        print("info: \(gpuRun ? "on the \(GraphicsPrep.gpuName)" : "no GPU here: the run must fail cleanly")")
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default

        // 1. anvil-prep's own lines, as it printed them on the M4 (LEGO's sizes, BGRA8).
        let fsr3Fields = #""fsr3":true,"fsr3_native":false,"fsr3_ms":3.62,"fsr1_ms":1.44,"fsr3_error":6.71,"fsr1_error":8.0,"fsr3_flicker":11.42,"fsr1_flicker":14.12,"fsr3_still_error":6.75,"fsr1_still_error":8.02,"fsr3_trail":0.998"#
        let legoPrepare = """
        {"event":"device","gpu":"Apple M4","arch":"arm64"}
        {"event":"compiled","ms":707}
        {"of":18,"missing":[],"ms":50,"event":"archived","pipelines":18}
        {"pixels_apart":1,"max_diff":29,"mean_diff":0.481,"event":"timed","pass":"split","split_ms":1.438,"fused_ms":1.519,"fused_ok":true}
        {"event":"fsr3",\(fsr3Fields)}
        {"tested":true,"frame_generation":7,"frame_generation_of":7,"event":"done","pass":"split","tile":"32x32",\(fsr3Fields)}
        """.split(separator: "\n").compactMap(GraphicsPrep.Event.parse)
        let verifyAll = ["{\"arch\":\"x86_64\",\"of\":18,\"event\":\"verified\",\"made\":18,\"compile_ms\":706,\"pipelines_ms\":1.8,\"ready\":18}"]
            .map { Substring($0) }.compactMap(GraphicsPrep.Event.parse)
        check(legoPrepare.count == 6 && verifyAll.count == 1, "anvil-prep's lines all read (6 and 1)")
        check(legoPrepare[3].splitMs == 1.438 && legoPrepare[3].fusedOk == true && legoPrepare[3].pixelsApart == 1, "snake_case keys read: split_ms, fused_ok, pixels_apart")
        let key80 = GraphicsPrep.Key(shaders: GraphicsPrep.shaderHash, os: GraphicsPrep.osBuild, gpu: GraphicsPrep.gpuName, pixelFormat: 80)
        let lego = GraphicsPrep.from(prepare: legoPrepare, verify: verifyAll, key: key80, gameSize: "1512x982", shownSize: "3024x1934",
                                     estimated: false, gameCache: .init(executable: "LEGO.exe", bytes: 84_000_000, restored: true), seconds: 2.1)
        check(lego?.status == .ready && lego?.archiveKept == true && lego?.verifiedReady == 18, "LEGO: ready, archive kept, 18 found under Rosetta")
        check(lego?.pass == "split" && lego?.onePass == false, "LEGO: two passes kept (quicker in 8-bit)")
        print("info: LEGO FSR: \(lego?.fsrText ?? "-")")
        check(lego?.fsrText == "Two passes, 1.44 ms a frame — quicker here than one (1.52 ms)", "LEGO: FSR said plainly")
        check(lego?.pipelinesText == "18 of 18 ready-made for the Apple M4", "LEGO: pipelines said plainly")
        print("info: LEGO summary: \(lego?.summary ?? "-")")
        check(lego?.fsr3?.better == true && lego?.fsr3?.native == false && lego?.fsr3?.ms == 3.62, "LEGO: FSR 3's test read (better, upscaled, 3.62 ms)")
        print("info: LEGO FSR 3: \(lego?.fsr3Text ?? "-")")
        check(lego?.fsr3Text == "In motion 16% closer to a supersampled picture than FSR 1, 19% less flicker, 16% closer standing still · 3.62 ms a frame against FSR 1's 1.44 ms",
              "LEGO: FSR 3 said plainly")
        check(lego?.summary.contains("FSR 3: in motion 16% closer") == true, "LEGO: FSR 3 in the launch log's summary")

        // FSR 3 at the display's own size, as the test found it: not better there.
        let nativeLines = """
        {"event":"device","gpu":"Apple M4","arch":"arm64"}
        {"of":18,"missing":[],"ms":50,"event":"archived","pipelines":18}
        {"tested":true,"frame_generation":7,"frame_generation_of":7,"event":"done","pass":"split","tile":"32x32","fsr3":false,"fsr3_why":"in motion it came out no closer to the reference than FSR 1 (5.53 against 4.18)","fsr3_native":true,"fsr3_ms":3.25,"fsr1_ms":0,"fsr3_error":5.53,"fsr1_error":4.18,"fsr3_flicker":9.74,"fsr1_flicker":7.7,"fsr3_still_error":3.86,"fsr1_still_error":4.16,"fsr3_trail":1.43}
        """.split(separator: "\n").compactMap(GraphicsPrep.Event.parse)
        let native = GraphicsPrep.from(prepare: nativeLines, verify: verifyAll, key: key80, gameSize: "3024x1964", shownSize: "3024x1964",
                                       estimated: false, gameCache: nil, seconds: 2)
        check(native?.fsr3?.better == false && native?.fsr3?.native == true, "native: FSR 3 not better, at the display's own size")
        print("info: native FSR 3: \(native?.fsr3Text ?? "-")")
        check(native?.fsr3Text?.hasPrefix("Not used for this game: in motion it came out no closer") == true
              && native?.fsr3Text?.hasSuffix("the game's frames are shown as it draws them") == true, "native: why it isn't used, said")

        // 2. A 16-bit float picture: one pass, 17% less.
        let f16 = """
        {"event":"device","gpu":"Apple M4","arch":"arm64"}
        {"event":"compiled","ms":1}
        {"of":18,"missing":[],"ms":116,"event":"archived","pipelines":18}
        {"pixels_apart":0,"max_diff":4.4,"mean_diff":0.073,"event":"timed","split_ms":1.884,"fused_ms":1.568,"fused_ok":true}
        {"tested":true,"frame_generation":7,"frame_generation_of":7,"event":"done","pass":"fused","tile":"32x32"}
        """.split(separator: "\n").compactMap(GraphicsPrep.Event.parse)
        let key115 = GraphicsPrep.Key(shaders: GraphicsPrep.shaderHash, os: GraphicsPrep.osBuild, gpu: GraphicsPrep.gpuName, pixelFormat: 115)
        let hdr = GraphicsPrep.from(prepare: f16, verify: verifyAll, key: key115, gameSize: "1512x982", shownSize: "3024x1934",
                                    estimated: false, gameCache: nil, seconds: 0.6)
        check(hdr?.onePass == true && hdr?.tile == "32x32", "16-bit float: one pass, 32x32")
        print("info: 16F FSR: \(hdr?.fsrText ?? "-")")
        check(hdr?.fsrText == "One pass, 1.57 ms a frame — 17% less than two (1.88 ms)", "16-bit float: the saving said")

        // 3. What goes wrong: a miss under Rosetta, a failure, a helper that died.
        let verifyMiss = ["{\"arch\":\"x86_64\",\"of\":18,\"event\":\"verified\",\"made\":18,\"ready\":17}"].map { Substring($0) }.compactMap(GraphicsPrep.Event.parse)
        let miss = GraphicsPrep.from(prepare: legoPrepare, verify: verifyMiss, key: key80, gameSize: "a", shownSize: "b", estimated: true, gameCache: nil, seconds: 1)
        check(miss?.status == .ready && miss?.archiveKept == false, "one pipeline missing under Rosetta: the archive isn't kept, the timing is")
        let unverified = GraphicsPrep.from(prepare: legoPrepare, verify: [], key: key80, gameSize: "a", shownSize: "b", estimated: true, gameCache: nil, seconds: 1)
        check(unverified?.archiveKept == false, "not checked under Rosetta: the archive isn't kept")
        let failedLines = ["{\"event\":\"device\",\"gpu\":\"Apple M4\",\"arch\":\"arm64\"}", "{\"event\":\"failed\",\"why\":\"the GPU stopped FSR: x\"}"]
            .map { Substring($0) }.compactMap(GraphicsPrep.Event.parse)
        let failed = GraphicsPrep.from(prepare: failedLines, verify: [], key: key80, gameSize: "a", shownSize: "b", estimated: true, gameCache: nil, seconds: 1)
        check(failed?.status == .failed && failed?.failure == "the GPU stopped FSR: x" && failed?.onePass == false && failed?.archiveKept == false,
              "a failure: kept as failed, with its reason, two passes, no archive")
        check(GraphicsPrep.from(prepare: Array(legoPrepare.prefix(3)), verify: [], key: key80, gameSize: "a", shownSize: "b",
                                estimated: true, gameCache: nil, seconds: 1) == nil, "a helper that stopped mid-way: no prep from it")

        // 4. When a game is prepared again, and what its launch is given.
        let game = UUID()
        check(GraphicsPrep.reason(gameID: game) == "it hasn't been prepared yet", "a new game: prepared before its first start")
        check(GraphicsPrep.picture(gameID: game).estimated && GraphicsPrep.picture(gameID: game).format == 80, "no session yet: the display's sizes, BGRA8")
        check(GraphicsPrep.usable(gameID: game) == nil, "a new game: nothing for its launch")
        try? fm.createDirectory(at: GraphicsPrep.folder, withIntermediateDirectories: true)
        GraphicsPrep.keep(lego!, gameID: game)
        check(GraphicsPrep.reason(gameID: game) == "its compiled shaders were removed", "kept, but its archive gone: prepared again")
        try? Data("archive".utf8).write(to: GraphicsPrep.archiveURL(gameID: game))
        check(GraphicsPrep.reason(gameID: game) == nil, "kept with its archive: no wait")
        let use = GraphicsPrep.usable(gameID: game)
        check(use?.archive == GraphicsPrep.archiveURL(gameID: game) && use?.onePass == false, "LEGO's launch: the archive, two passes")
        var older = lego!; older.key.shaders = "0123456789abcdef"
        GraphicsPrep.keep(older, gameID: game)
        check(GraphicsPrep.reason(gameID: game) == "Anvil's shaders changed" && GraphicsPrep.usable(gameID: game) == nil,
              "after an Anvil update: prepared again, and the old archive not used")
        var otherOS = lego!; otherOS.key.os = "Version 26.0 (Build 25A1)"
        GraphicsPrep.keep(otherOS, gameID: game)
        check(GraphicsPrep.reason(gameID: game) == "macOS changed", "after a macOS update: prepared again")
        GraphicsPrep.keep(hdr!, gameID: game)
        check(GraphicsPrep.reason(gameID: game) == "the game's colour format turned out different", "prepared for 16-bit, the game draws 8-bit: again")
        check(GraphicsPrep.usable(gameID: game)?.onePass == false, "…and its launch doesn't get one pass meanwhile")
        GraphicsPrep.keep(failed!, gameID: game)
        check(GraphicsPrep.reason(gameID: game) == nil && GraphicsPrep.usable(gameID: game) == nil,
              "a failed prep: no wait at every start, nothing for the launch (Prepare Now tries again)")
        check(GraphicsPrep.fsr3Verdict(gameID: game).use == nil, "a failed prep: FSR 3 not tested")

        // 4b. FSR 3 at launch, by Graphics Prep's verdict.
        let runtime0 = Runtime(id: "test-engine", displayName: "Test", version: "1", root: URL(fileURLWithPath: "/nonexistent"), isManaged: false)
        var fsr3Container = Container(name: "FSR 3 test", runtimeID: runtime0.id)
        fsr3Container.upscaler.mode = .fsr3Every
        fsr3Container.upscaler.fsrToDisplay = false
        var fsr3Game = Game(title: "FSR 3 Test", executablePath: "/nonexistent/game.exe", containerID: fsr3Container.id)
        fsr3Game.id = game
        func env() -> [String: String] { Launcher.shared.environment(for: fsr3Game, in: fsr3Container, runtime: runtime0) }
        var e = env()
        check(e["ANVIL_FSR3"] == "1" && e["ANVIL_FSR3_NATIVE"] == "0" && e["ANVIL_OUTPUT"] == "1",
              "not tested yet: FSR 3 on wherever the game is upscaled, not at the display's size; FSR to the display on with it")
        GraphicsPrep.keep(lego!, gameID: game)
        check(GraphicsPrep.fsr3Verdict(gameID: game) == (true, false), "LEGO's verdict: better, upscaled")
        e = env()
        check(e["ANVIL_FSR3"] == "1" && e["ANVIL_FSR3_NATIVE"] == "0", "LEGO: FSR 3 on")
        // Its cost over FSR 1, for the budget that eases it when the GPU can't hold an even 80.
        let extra = lego!.fsr3.map { $0.ms - $0.fsr1Ms } ?? 0
        check(e["ANVIL_FSR3_EXTRA_MS"] == String(format: "%.2f", min(max(extra, 0.3), 8.0)),
              "LEGO: FSR 3's cost over FSR 1 passed on (\(e["ANVIL_FSR3_EXTRA_MS"] ?? "none"), measured \(String(format: "%.2f", extra)))")
        check(["auto", "1", "0"].contains(e["ANVIL_ENDURANCE"] ?? ""), "long sessions passed on (\(e["ANVIL_ENDURANCE"] ?? "none"))")
        GraphicsPrep.keep(native!, gameID: game)
        e = env()
        check(e["ANVIL_FSR3"] == "0" && e["ANVIL_FSR3_NATIVE"] == "0", "native, not better: FSR 3 off — the game's frames as it draws them")
        check(e["ANVIL_FSR3_EXTRA_MS"] == nil, "native, not better: no FSR 3 cost to pass on")
        var nativeBetter = native!; nativeBetter.fsr3?.better = true
        GraphicsPrep.keep(nativeBetter, gameID: game)
        e = env()
        check(e["ANVIL_FSR3"] == "1" && e["ANVIL_FSR3_NATIVE"] == "1", "native, better: FSR 3 at the display's size too")
        GraphicsPrep.keep(lego!, gameID: game)
        GraphicsPrep.fsr3OffAfterCrash(gameID: game)
        check(GraphicsPrep.fsr3Verdict(gameID: game).use == false && env()["ANVIL_FSR3"] == "0", "after a crash with FSR 3: off for the game")
        check(GraphicsPrep.stored(gameID: game)?.fsr3Text?.hasPrefix("Off for this game — it closed unexpectedly") == true, "…and the page says why")
        var fsr1Container = fsr3Container; fsr1Container.upscaler.mode = .fsr1
        check(Launcher.shared.environment(for: fsr3Game, in: fsr1Container, runtime: runtime0)["ANVIL_FSR3"] == nil, "FSR 1 chosen: nothing of FSR 3")

        // 5. What a session showed, from a real game.log (libanvil on the GPU bench).
        let text = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        let ready = lines.firstIndex { $0.contains("pipelines ready-made from Graphics Prep") }
        check(ready != nil, "the game.log has a session with a Graphics Prep archive")
        if let ready {
            let session = Array(lines[max(0, ready - 3)...min(lines.count - 1, ready + 1)])
            let seen = GraphicsPrep.seen(in: session, at: Date())
            print("info: seen: \(session.map { String($0.dropFirst(13)) }.joined(separator: " | "))")
            check(seen?.readyMade == seen?.of && (seen?.of ?? 0) >= 14, "seen: all ready-made (\(seen?.readyMade ?? 0) of \(seen?.of ?? 0))")
            check(seen?.firstFrameWaitMs != nil, "seen: how long the first frame waited (\(seen?.firstFrameWaitMs.map(String.init) ?? "-") ms)")
        }
        let onePassSeen = GraphicsPrep.seen(in: lines.filter { $0.contains("FSR: one pass") }.prefix(1).map { $0 }, at: Date())
        check(onePassSeen?.onePass == true, "seen: FSR in one pass")
        check(GraphicsPrep.seen(in: ["12:00:00.000 [anvil] FSR to the display: the game draws 1512x982"], at: Date()) == nil,
              "a session with nothing of Graphics Prep: nothing replaced")
        let fsr3Session: [Substring] = [
            "16:19:17.585 [anvil] FSR 3: first frame — 1512x982 to 3024x1964, motion matched per 16x16 pixels, up to 10 frames blended",
            "16:19:27.798 [anvil] displayed 120.0 fps | 1% LOW 98.0 fps | rendered 56.2 fps | FSR 1512x982 to 3024x1964 | FSR 3 on 600",
            "16:19:38.714 [anvil] displayed 120.0 fps | 1% LOW 98.0 fps | generated 597 of 1197 shown | FSR 1512x982 to 3024x1964 | FSR 3 on 599",
            "16:19:40.000 [anvil] FSR 3: off for this session — its pass couldn't be encoded; FSR 1, as before",
        ]
        let f3seen = GraphicsPrep.seen(in: fsr3Session, at: Date())
        check(f3seen?.fsr3Frames == 1199 && f3seen?.fsr3Stopped == "its pass couldn't be encoded", "seen: FSR 3's frames counted, and why it stopped")
        print("info: seen FSR 3: \(GraphicsPrep(key: key80, at: Date(), status: .ready, failure: nil, gameSize: "", shownSize: "", estimated: false, gpu: "", compileMs: 0, pipelines: 0, pipelinesOf: 0, verifiedReady: nil, archiveKept: false, pass: "split", tile: nil, splitMs: nil, fusedMs: nil, tested: false, untestedWhy: nil, frameGeneration: 0, frameGenerationOf: 0, gameCache: nil, seconds: 0, seen: f3seen).seenText ?? "-")")

        // 6. A crash with one pass on: two passes from then on, and said.
        GraphicsPrep.keep(hdr!, gameID: game)
        GraphicsPrep.onePassOffAfterCrash(gameID: game)
        let after = GraphicsPrep.stored(gameID: game)
        check(after?.onePassOff == true && after?.onePass == false, "after a crash: one pass off")
        print("info: after a crash: \(after?.fsrText ?? "-")")
        check(after?.fsrText.contains("off after the game closed unexpectedly") == true, "…and the page says why")

        // 7. The whole run, against the real anvil-prep beside this harness.
        let helper = Bundle.main.resourceURL!.appendingPathComponent("anvil-prep")
        check(fm.isExecutableFile(atPath: helper.path), "anvil-prep is beside the harness")
        let runtime = runtime0
        let container = Container(name: "Prep test", runtimeID: runtime.id)
        let exe = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("prep-\(UUID().uuidString).exe")
        try? Data("MZ".utf8).write(to: exe)
        var g = Game(title: "Prep Test", executablePath: exe.path, containerID: container.id)
        g.id = UUID()
        let started = Date()
        let prep = await GraphicsPrepRunner.shared.run(game: g, container: container, runtime: runtime, beforeLaunch: false, reason: "test")
        let steps = GraphicsPrepRunner.shared.active?.steps ?? []
        for s in steps { print("info: step \(s.id): \(s.state) — \(s.result ?? "")") }
        print("info: outcome: \(GraphicsPrepRunner.shared.active?.outcome ?? "-") (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        check(GraphicsPrepRunner.shared.active?.finished == true, "the run finished")
        if gpuRun {
            // 22 since 0.52 (from 18): Smooth Motion's check and its verdict among them; 26 since 0.54, with the pan's four.
            check(prep?.status == .ready && prep?.archiveKept == true && prep?.verifiedReady == 26,
                  "on the GPU: ready, 26 of 26 found under Rosetta, archive kept (\(prep?.verifiedReady ?? -1))")
            check(fm.fileExists(atPath: GraphicsPrep.archiveURL(gameID: g.id).path) && !fm.fileExists(atPath: GraphicsPrep.newArchiveURL(gameID: g.id).path),
                  "the archive moved into place, nothing half-made left")
            check(prep?.tested == true && (prep?.splitMs ?? 0) > 0, "FSR timed (\(prep?.splitMs.map { String($0) } ?? "-") ms)")
            check(prep?.fsr3 != nil && (prep?.fsr3?.ms ?? 0) > 0, "FSR 3 tested on the moving scene (\(prep?.fsr3Text ?? "-"))")
            check(prep?.fsr3?.better == true, "FSR 3 better than FSR 1 at the display's half size")
            // Ray tracing (0.52) is skipped for a game with none of its own, as this one.
            check(steps.allSatisfy { $0.state == .done || ($0.id == "raytracing" && $0.state == .skipped) }, "every step done")
            // What the game is then told.
            let env = Launcher.shared.environment(for: g, in: container, runtime: runtime)
            check(env["ANVIL_SHADER_ARCHIVE"] == GraphicsPrep.archiveURL(gameID: g.id).path, "the launch is given the archive")
            // One pass or two, as timed here. For BGRA8 two until 0.55; at twice the size one pass fills its tile a 2x2 at a
            // time since (fsrEasuTileTwice), and on an M4 is the quicker: 1.29 ms against 1.46.
            let onePass = prep?.pass == "fused"
            let quicker = (prep?.fusedMs ?? .infinity) < 0.97 * (prep?.splitMs ?? 0)   // anvil-prep's rule: clearly quicker
            check((env["ANVIL_FSR_PASS"] == "fused") == onePass && onePass == quicker,
                  "and the pass timed quicker here, for the BGRA8 it was tested in (\(onePass ? "one" : "two"): one \(prep?.fusedMs.map { String($0) } ?? "-") ms, two \(prep?.splitMs.map { String($0) } ?? "-") ms)")
        } else {
            check(prep?.status == .failed && prep?.archiveKept == false, "without a GPU: kept as failed, nothing half-made kept")
            check(!fm.fileExists(atPath: GraphicsPrep.newArchiveURL(gameID: g.id).path), "no half-made archive left")
            let env = Launcher.shared.environment(for: g, in: container, runtime: runtime)
            check(env["ANVIL_SHADER_ARCHIVE"] == nil && env["ANVIL_FSR_PASS"] == nil, "the launch is given nothing from it")
        }
        try? fm.removeItem(at: exe)

        print(failures == 0 ? "graphics prep: all checks passed" : "graphics prep: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
