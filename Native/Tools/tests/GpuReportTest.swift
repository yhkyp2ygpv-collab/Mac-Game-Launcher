// 0.46.0: game.log's new fields read back — libanvil's timing of a frame's passes ("| GPU work …")
// and the game's shader compiles ("| shaders compiled …") — with the rest of a stats line intact.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/GpuReportTest.swift -o $T/GpuReportTest && $T/GpuReportTest
import Foundation

@main struct GpuReportHarness {
    static func main() {
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } }
        let line: Substring = "10:20:06.165 [anvil] displayed 32.4 fps | 1% LOW 26.7 fps | STEADY 91.2% | shown as ready 100% (variable refresh, confirmed) | EVENNESS 0.0% on-beat (0 of 602 gaps) worst gap 91.7 ms | rendered 32.1 fps (game could 38.2) | real=2999 gen=0 skipped=0 resyncs=2 | LATENCY 34.0 ms avg 87.0 ms max | in flight 2 | missed 542 | memory 4062 MB | GPU 100% busy | busiest threads 28% and 20% of a core | steady 80: below 80, as ready (0 held) | FSR 1512x982 to 3024x1964 | FSR 3 on 600 | shaders compiled 14 (310 ms, longest 120 ms, 2 failed) | GPU work 27.1 ms a frame: scene 11.2, shadows 6.3, effects 4.1, smaller effects 1.0, compute 0.8, Anvil 3.7"
        guard let w = FrameLog.parse(line) else { print("FAIL: not parsed"); exit(1) }
        check(w.displayed == 32.4 && w.capacity == 38.2 && w.gpuBusy == 100, "the usual fields still read")
        check(w.gpuWorkMs == 27.1, "GPU work: \(String(describing: w.gpuWorkMs))")
        check(w.gpuKinds?["scene"] == 11.2 && w.gpuKinds?["smaller effects"] == 1.0 && w.gpuKinds?["Anvil"] == 3.7 && w.gpuKinds?.count == 6,
              "kinds: \(String(describing: w.gpuKinds))")
        check(w.compiles == 14 && w.compileMs == 310 && w.compileLongestMs == 120, "compiles: \(String(describing: w.compiles)) \(String(describing: w.compileMs)) \(String(describing: w.compileLongestMs))")
        // GPU work in the middle of a line, followed by another field.
        let mid: Substring = "[anvil] displayed 80.0 fps | rendered 80.0 fps (game could 95.0) | GPU work 12.5 ms a frame: scene 8.0, Anvil 2.5 | long session (battery)"
        let m = FrameLog.parse(mid)
        check(m?.gpuKinds == ["scene": 8.0, "Anvil": 2.5], "kinds before another field: \(String(describing: m?.gpuKinds))")
        check(m?.compiles == nil, "no compiles field, none read")
        // A line from before 0.46 reads as it did.
        let old: Substring = "[anvil] displayed 120.0 fps | 1% LOW 59.7 fps | rendered 120.1 fps (game could 122.1) | GPU 82% busy"
        check(FrameLog.parse(old)?.gpuWorkMs == nil && FrameLog.parse(old)?.capacity == 122.1, "an older line")
        // 0.48: frames between, how evenly frames were shown, and the heaviest passes named.
        let between: Substring = "01:33:58.003 [anvil] displayed 80.9 fps | 1% LOW 34.2 fps | STEADY 52.5% | rendered 34.6 fps (game could 38.9) | real=1798 gen=1001 skipped=0 resyncs=0 | GPU 100% busy | generated 600 of 1201 shown | frames between: the game waited 3.2 ms a frame for its frames in flight, the presenter 1.5 ms for drawables | FSR 1512x982 to 3024x1964 | FSR 3 on 600 | gaps: half under 12.4 ms, 90% under 20.9 ms | GPU work 42.9 ms a frame: scene 27.9, Anvil 8.3, effects 2.5 | heaviest passes (of a 45.1 ms frame): scene 14.2 ms (1512x982, 4 colour (8-bit) + depth); effects 6.0 ms (1512x982, 1 colour (16-bit float)); shadows 3.1 ms (2048x2048 x4, depth only)"
        let b = FrameLog.parse(between)
        check(b?.gapMedianMs == 12.4 && b?.gap90Ms == 20.9, "gaps: \(String(describing: b?.gapMedianMs)) \(String(describing: b?.gap90Ms))")
        check(b?.betweenWaitMs == 3.2, "frames between wait: \(String(describing: b?.betweenWaitMs))")
        check(b?.gpuKinds == ["scene": 27.9, "Anvil": 8.3, "effects": 2.5], "kinds before the heaviest passes: \(String(describing: b?.gpuKinds))")
        check(b?.heaviestFrameMs == 45.1 && b?.heaviestPasses?.count == 3
              && b?.heaviestPasses?.first == "scene 14.2 ms (1512x982, 4 colour (8-bit) + depth)"
              && b?.heaviestPasses?.last == "shadows 3.1 ms (2048x2048 x4, depth only)",
              "heaviest: \(String(describing: b?.heaviestFrameMs)) \(String(describing: b?.heaviestPasses))")
        check(b.map { abs(($0.generatedShare ?? 0) - 600.0 / 1201.0) < 1e-9 } == true, "generated share")
        check(GameDoctor.heaviestText([b!]).contains("scene 14.2 ms (1512x982, 4 colour (8-bit) + depth); effects 6.0 ms"),
              "the Doctor names them: \(GameDoctor.heaviestText([b!]))")
        check(GameDoctor.heaviestText([w]).isEmpty, "none named where the line has none")

        // 0.49: Guardian's lines, as libanvil writes them, read by the Doctor; and its file, as libanvil keeps it.
        let guardian = [
            "15:37:07.084 [anvil] guardian: on — checks every few seconds that what Anvil does is working, and learns what runs best here | on this Mac so far: nothing yet (a first session)",
            "15:37:21.368 [anvil] guardian: checking Smooth Motion's worth here — 4 s of the game's own frames alone (22.4 fps of its own with frames between)",
            "15:37:25.439 [anvil] guardian: at 20–25 fps of the game's own, frames between were +39% against its own frames alone (1 check here, +39% on average) — frames between here on this Mac",
            "15:37:37.585 [anvil] guardian: at 20–25 fps of the game's own, frames between were +45% against its own frames alone (2 checks here, +42% on average) — frames between here on this Mac",
            "15:38:02.111 [anvil] guardian: at 50–60 fps of the game's own, frames between were −8% against its own frames alone (1 check here, −8% on average) — frames between here on this Mac",
            "15:38:40.000 [anvil] guardian: Smooth Motion started 5 times in two minutes — for the next three it waits three times as long to start and twice as long to stop, so a scene at the edge of its range doesn't flicker between the two",
            "15:42:07.100 [anvil] guardian: 30 check-ups, 1 fixes, 3 checks of Smooth Motion's worth this session | on this Mac: frames between help at 20–25 fps (+42%, 3 checks); still learning 50–60 fps (-8%, 1 check)",
        ]
        let found = GameDoctor.guardianFinding(guardian, paused: 1) ?? ""
        check(found.contains("checked 30 times") && found.contains("put 1 thing right"), "check-ups: \(found)")
        check(found.contains("Smooth Motion switching on and off often was slowed down") && found.contains("paused 1 time"), "handled: \(found)")
        check(found.contains("3 times") && found.contains("20–25 fps +42%") && found.contains("50–60 fps -8%"), "its checks, by band: \(found)")
        check(found.contains("Learned on this Mac: frames between help at 20–25 fps"), "learned: \(found)")
        check(GameDoctor.guardianFinding([], paused: 0) == nil, "nothing without its lines")
        let first = GameDoctor.guardianFinding([guardian[0]], paused: 0) ?? ""
        check(first.contains("every few seconds") && !first.contains("Learned"), "a first session, nothing learned yet: \(first)")
        let bands = Guardian.parse("anvil-guardian 1\nband 20 25 4 0.4400 0.004000\nband 25 30 3 -0.3400 0.000300\nband 50 60 1 -0.0800 0.000000\n")
        check(bands.count == 3 && bands[0].wanted && !bands[1].wanted && bands[2].wanted && !bands[2].settled,
              "learned: \(bands)")
        let words = Guardian.summary(of: bands) ?? ""
        check(words == "Smooth Motion helps at 20–25 fps (+44%); the game's own frames are better at 25–30 fps (−34%); still learning 50–60 fps (−8%)",
              "in words: \(words)")
        check(Guardian.parse("something else\nband 20 25 4 0.4 0.1\n").isEmpty, "not its file: nothing")

        // 0.50: the memory warm-up — libanvil's file read, what the Mac can spare, and the pieces chosen.
        let heat = MemoryWarmup.parse("anvil-warm 1\nfile 104857600 /games/LEGO/GAME1.DAT\nc 0 1.0\nc 5 9.5\nc 24 3.0\nfile 8000000 /games/LEGO/GAME2 with space.DAT\nc 1 4.0\nfile 5 /empty.dat\n")
        check(heat.count == 2 && heat[0].path == "/games/LEGO/GAME1.DAT" && heat[0].pieces.count == 3 && heat[0].pieces[1].count == 9.5
              && heat[1].path == "/games/LEGO/GAME2 with space.DAT" && heat[1].size == 8000000,
              "warm-up file read: \(heat)")
        check(MemoryWarmup.parse("anvil-guardian 1\nfile 1 /x\nc 0 1\n").isEmpty, "not its file")
        let gb: Int64 = 1 << 30
        check(MemoryWarmup.budget(availableBytes: 13 * gb, onBattery: false) == 4 * gb + gb / 2, "13 GB free: 4.5 GB")
        check(MemoryWarmup.budget(availableBytes: 13 * gb, onBattery: true) == 2 * gb + gb / 4, "on battery: half")
        check(MemoryWarmup.budget(availableBytes: 40 * gb, onBattery: false) == 8 * gb, "at most 8 GB")
        check(MemoryWarmup.budget(availableBytes: 4 * gb + 100 << 20, onBattery: false) == 0, "little to spare: none")
        let piece = MemoryWarmup.pieceBytes
        let chosen = MemoryWarmup.plan(heat, budget: 2 * piece + 1) { _, _ in true }
        check(chosen.count == 2 && chosen[0].path == "/games/LEGO/GAME1.DAT" && chosen[0].offset == 5 * piece
              && chosen[1].path == "/games/LEGO/GAME2 with space.DAT" && chosen[1].offset == piece && chosen[1].length == 8000000 - piece,
              "the two most read that fit, in file order, the last piece only as long as the file: \(chosen)")
        check(MemoryWarmup.plan(heat, budget: 100 * piece) { p, _ in p != "/games/LEGO/GAME1.DAT" }.count == 1, "a file gone or changed: skipped")
        let all = MemoryWarmup.plan(heat, budget: 100 * piece) { _, _ in true }
        check(all.map(\.offset) == [0, 5 * piece, 24 * piece, piece], "everything, each file front to back: \(all.map(\.offset))")

        // Stutters, as Guardian counts them, and the warm-up's line from the launch.
        let stutLines = [
            "20:41:02.100 [anvil] guardian: stutter 142 ms (frames had been 12.5 ms) — mostly reading its data: 38.0 MB of its data read in 96 ms, 3 shaders compiled in 8 ms, 2 ms waiting on the GPU or the display",
            "20:46:07.100 [anvil] guardian: 30 check-ups, 0 fixes, 2 checks of Smooth Motion's worth this session | stutters: 9 (6 reading its data, 2 compiling shaders, 0 waiting on the GPU or the display, 1 the game's own work; longest 233 ms) | the game read 3.4 GB of its data, 1.8 ms a read on average, 12 reads of 20 ms or more | on this Mac: frames between help at 20–25 fps (+42%, 3 checks)",
        ]
        let warmLine = "2026-10-15T03:31:12Z  memory warm-up: LEGO® Star Wars™: The Skywalker Saga — 3.2 GB of the data played most read ahead into memory in 4.1 s (800 pieces of 7 files; up to 4.5 GB spare)"
        if let (kind, text) = GameDoctor.stutterFinding(stutLines, launch: [warmLine]) {
            check(kind == .good && text.contains("9 stutters") && text.contains("longest 233 ms") && text.hasPrefix("9 stutters")
                  && text.contains("6 reading the game's data, 2 compiling shaders, 1 the game's own work"), "stutters: \(text)")
            check(text.contains("3.4 GB of its data, 1.8 ms a read") && text.contains("Before the start: 3.2 GB of the data played most"),
                  "reads and the warm-up: \(text)")
        } else { check(false, "a stutter finding") }
        if let (kind, text) = GameDoctor.stutterFinding([stutLines[0]], launch: []) {
            check(kind == .advice && text.contains("1 stutter ") && text.contains("memory warm-up"), "short session, no warm-up yet: \(kind) \(text)")
        } else { check(false, "from the stutter lines alone") }
        check(GameDoctor.stutterFinding([], launch: []) == nil, "nothing to say")
        // The read itself, on a real file: every byte of the pieces chosen, below the disk's usual priority.
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let tmp = tmpDir.appendingPathComponent("warm-\(getpid()).dat")
        try? Data(repeating: 3, count: Int(piece) * 2 + 1000).write(to: tmp)
        let real = MemoryWarmup.parse("anvil-warm 1\nfile \(Int(piece) * 2 + 1000) \(tmp.path)\nc 0 2\nc 2 5\n")
        let toRead = MemoryWarmup.plan(real, budget: 8 * piece) { p, s in
            ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value == s
        }
        let (bytes, pieces) = MemoryWarmup.read(toRead)
        check(pieces == 2 && bytes == piece + 1000, "read: \(pieces) pieces, \(bytes) bytes")
        try? FileManager.default.removeItem(at: tmp)

        // 0.51: the look check — LEGO Star Wars at Light graphics has its reflections off, and is offered them back;
        // 0.52: Medium has them on with water and heat distortion off; the game's own look has that on, which is
        // flagged, with Medium offered; its blurs are off while FSR upscales at every level.
        MainActor.assumeIsolated {
            let container = Container(name: "T", runtimeID: "mythic-engine-2.6.1")
            var lego = Game(title: "LEGO Star Wars", executablePath: "/nowhere/LEGOSTARWARSSKYWALKERSAGA_DX11.exe", containerID: container.id)
            lego.graphicsTuning = .light
            let light = LookCheck.items(for: lego, container: container)
            let reflections = light.first { $0.id == "reflections" }
            check(reflections?.kind == .off && reflections?.fix == .rayTracing(true) && reflections?.detail.contains("Light graphics") == true,
                  "Light: reflections off, with the Ray Tracing switch offered: \(String(describing: reflections))")
            check(light.first { $0.id == "water" }?.kind == .good, "Light: water distortion off, as it should be")
            check(light.first?.kind == .off, "what's off comes first")
            check(light.contains { $0.id == "shadows" && $0.kind == .good } && light.contains { $0.id == "blur" && $0.kind == .good },
                  "shadows as drawn, blurs off for FSR")
            lego.graphicsTuning = .medium
            let medium = LookCheck.items(for: lego, container: container)
            check(medium.first { $0.id == "reflections" }?.kind == .good && medium.first { $0.id == "water" }?.kind == .good,
                  "Medium: reflections on, water distortion off")
            check(medium.first { $0.id == "depth-of-field" }?.fix == .graphics(.gameDefault, "Use the Game's Own Look"),
                  "Medium: the game's own look offered for its depth of field")
            check(!medium.contains { $0.kind == .off }, "Medium: nothing flagged")
            lego.graphicsTuning = .gameDefault
            let own = LookCheck.items(for: lego, container: container)
            check(own.first { $0.id == "reflections" }?.kind == .good && own.first { $0.id == "depth-of-field" }?.kind == .good,
                  "the game's own look: reflections and depth of field on")
            let water = own.first { $0.id == "water" }
            check(water?.kind == .off && water?.fix == .graphics(.medium, "Use Medium (Reflections Kept)"), "the game's own look: its distortion flagged: \(String(describing: water))")
            check(own.contains { $0.id == "prep" }, "no Graphics Prep yet: said so")
            // 0.52: the Ray Tracing switch, off at Medium: the reflections off and said so; on at Light: on.
            lego.graphicsTuning = .medium
            lego.rayTracing = false
            check(LookCheck.items(for: lego, container: container).first { $0.id == "reflections" }?.kind == .off, "switched off at Medium")
            lego.graphicsTuning = .light
            lego.rayTracing = true
            check(LookCheck.items(for: lego, container: container).first { $0.id == "reflections" }?.kind == .good, "switched on at Light")
            lego.rayTracing = nil
            let other = Game(title: "Cat Quest II", executablePath: "/nowhere/CatQuestII.exe", containerID: container.id)
            check(!LookCheck.items(for: other, container: container).contains { $0.id == "reflections" }, "a game Anvil doesn't tune: no effects listed")
        }
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("gpu report: all checks passed")
    }
}
