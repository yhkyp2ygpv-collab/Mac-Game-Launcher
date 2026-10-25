// Unreal Engine tuning (0.68, UnrealTuning), on copies of Hogwarts Legacy's own files: its Engine.ini as the game
// wrote it on 23 October (CRLF, its [SystemSettings] holding Anvil's r.WarnOfBadDrivers=0), its 458 MB program
// found from its launcher, and game.log with its session of 24 October — 1.7 hours, 37 minutes of them at its title
// screen at 9.6 GB, then its world at 15–17 GB with 279 of 319 stutters its own work — and its session of 06:10 that
// day, the garbage-collection trial (2.0 → 2.2 a minute, dropped), flying at 38–44 fps with the GPU 97–99% busy.
//
//   CFFIXED_USER_HOME=$T/home HOME=$T/home UnrealTuningTest <its HogwartsLegacy.exe (the launcher)> <its Engine.ini> <game.log>
import Foundation

@main
struct UnrealTuningTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func stats(_ fps: Double, memory: Int, behind: Int = 0, gap: Double = 30) -> String {
        "[anvil] displayed \(fps) fps | 1% LOW \(fps * 0.6) fps | STEADY 50% | shown as ready 100% (variable refresh, confirmed) | EVENNESS 40% on-beat (240 of 600 gaps) worst gap \(gap) ms | rendered \(fps) fps (game could \(fps)) | real=1000 gen=0 skipped=0 resyncs=0 | LATENCY 20 ms avg 30 ms max | in flight 2 | missed 0 | memory \(memory) MB | GPU 99% busy | busiest threads 80% and 40% of a core" + (behind > 0 ? " | behind \(behind)" : "")
    }

    @MainActor
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 4 else { print("usage: see header"); exit(2) }
        let fm = FileManager.default
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
        guard !RuntimeManager.support.path.hasPrefix(realHome + "/Library") else { print("refusing: not in a throwaway home"); exit(2) }
        let exe = a[1], realIni = URL(fileURLWithPath: a[2]), realLog = URL(fileURLWithPath: a[3])
        let tmp = RuntimeManager.support.appendingPathComponent("unreal-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        UnrealTuning.directory = tmp.appendingPathComponent("UnrealTuning", isDirectory: true)

        print("— who it's for")
        var c = Container(name: "Hogwarts", runtimeID: "none")
        c.id = UUID()
        var epic = Game(title: "Hogwarts Legacy", executablePath: exe, containerID: c.id)
        epic.epicAppName = "fa4240e57a3c46b39f169041b7811293"
        var steam = Game(title: "An Unreal game", executablePath: "/x/Game.exe", containerID: c.id)
        steam.steamAppID = "990080"
        let added = Game(title: "Added from its program", executablePath: "/x/Game.exe", containerID: c.id)
        check(UnrealTuning.eligibility(epic, unreal: true) == .tuned, "an Unreal game installed through Anvil's Epic: tuned")
        check(UnrealTuning.eligibility(steam, unreal: true) == .tuned, "…and through Anvil's Steam")
        check(UnrealTuning.eligibility(added, unreal: true) == .notFromStore, "a game added from its .exe: not tuned")
        check(UnrealTuning.eligibility(epic, unreal: false) == .notUnreal, "a game on another engine: not tuned")
        var off = epic
        off.unrealTuning = false
        check(UnrealTuning.eligibility(off, unreal: true) == .off, "switched off: not tuned")

        print("— the settings its program has")
        let fake = tmp.appendingPathComponent("fake.exe")
        var bytes = Data(repeating: 0x41, count: 4096)
        bytes.append(Data("s.ForceGCAfterLevelStreamedOut".utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }))
        bytes.append(Data(repeating: 0, count: 64))
        bytes.append(Data("foliage.LODDistanceScale".utf8))
        try? bytes.write(to: fake)
        let found = UnrealTuning.present(["s.ForceGCAfterLevelStreamedOut", "foliage.LODDistanceScale", "s.ContinuouslyIncrementalGCWhileLevelsPendingPurge"], in: fake)
        check(found == ["s.ForceGCAfterLevelStreamedOut", "foliage.LODDistanceScale"], "UTF-16 and ASCII names found, an absent one not: \(found.map { $0.sorted() } ?? [])")
        check(UnrealTuning.present(["x"], in: tmp.appendingPathComponent("none.exe")) == nil, "a program that can't be read: unknown, not empty")
        let program = GameAnalysis.drawingProgram(for: URL(fileURLWithPath: exe))
        let names = Array(Set(UnrealTuning.managed(hasProfile: false).map(\.0)))
        let started = Date()
        let real = UnrealTuning.present(names, in: program) ?? []
        check(program.path.hasSuffix("Phoenix/Binaries/Win64/HogwartsLegacy.exe") && real.count == names.count,
              String(format: "all %d of its settings in Hogwarts Legacy's own program (%@), looked for in %.2f s", real.count, program.lastPathComponent, Date().timeIntervalSince(started)))

        print("— its Engine.ini")
        let original = (try? String(contentsOf: realIni, encoding: .utf8)) ?? ""
        check(original.contains("[SystemSettings]\r\nr.WarnOfBadDrivers=0\r\n"), "its own file, CRLF, as the game wrote it")
        let managed = UnrealTuning.managed(hasProfile: true)
        let on = UnrealTuning.applying(UnrealTuning.streaming.keys(.init()), managed: managed, in: original)
        check(on.text.contains("[SystemSettings]\r\n") && on.text.contains("s.ForceGCAfterLevelStreamedOut=0\r\n")
              && on.text.contains("s.ContinuouslyIncrementalGCWhileLevelsPendingPurge=0\r\n") && on.text.contains("r.WarnOfBadDrivers=0\r\n")
              && !on.text.replacingOccurrences(of: "\r\n", with: "").contains("\n") && on.theirs.isEmpty,
              "both set in its [SystemSettings], CRLF kept, Anvil's driver line kept")
        check(on.text.hasPrefix("[Core.System]\r\nPaths=../../../Engine/Content\r\n") && on.text.utf8.count == original.utf8.count + 88,
              "the rest of the file as it was")
        let back = UnrealTuning.applying([], managed: managed, in: on.text)
        check(back.text == original, "taken out again: the file exactly as the game had it")
        let theirs = UnrealConfig.settingSystem("s.ForceGCAfterLevelStreamedOut", to: "1", in: original)
        let kept = UnrealTuning.applying(UnrealTuning.streaming.keys(.init()), managed: managed, in: theirs)
        check(kept.theirs == ["s.ForceGCAfterLevelStreamedOut"] && UnrealConfig.systemValue("s.ForceGCAfterLevelStreamedOut", in: kept.text) == "1"
              && UnrealConfig.systemValue("s.ContinuouslyIncrementalGCWhileLevelsPendingPurge", in: kept.text) == "0",
              "a value the player set themselves is theirs: left as set, the other written")
        check(UnrealTuning.applying([], managed: managed, in: kept.text).text == theirs, "…and kept when Anvil's are taken out")

        print("— how a session went")
        var log = ["=== Hogwarts Legacy — 2026-10-24T01:18:22Z — Anvil 0.68.0 ===",
                   "23:55:00.000 " + stats(56, memory: 9600), "23:55:10.000 " + stats(56, memory: 9600)]
        // Its title screen: 10 stretches at 9.6 GB, one stutter.
        var t = 23 * 3600 + 55 * 60 + 10.0
        func at(_ s: Double) -> String {
            let d = s.truncatingRemainder(dividingBy: 86_400)
            return String(format: "%02d:%02d:%06.3f", Int(d) / 3600, (Int(d) % 3600) / 60, d.truncatingRemainder(dividingBy: 60))
        }
        for i in 0..<10 {
            if i == 4 { log.append(at(t + 3) + " [anvil] guardian: stutter 70 ms (frames had been 17.0 ms) — mostly the game's own work: 0.0 MB of its data read in 0 ms") }
            t += 600 / 56
            log.append(at(t) + " " + stats(56, memory: 9600))
        }
        // Its world, over midnight: 60 stretches at 75 fps (8 s each) and 16 GB; 24 of its own stutters, 6 reading its
        // data; one stretch with a load stall; two behind another app.
        for i in 0..<60 {
            if i % 5 == 0 { log.append(at(t + 2) + " [anvil] guardian: stutter 85 ms (frames had been 18.0 ms) — mostly the game's own work: 0.1 MB of its data read in 0 ms") }
            if i % 10 == 0 { log.append(at(t + 4) + " [anvil] guardian: stutter 140 ms (frames had been 16.0 ms) — mostly reading its data: 300.0 MB of its data read in 200 ms") }
            if i % 20 == 7 { log.append(at(t + 5) + " [anvil] guardian: stutter 480 ms (frames had been 12.0 ms) — mostly the game's own work: 0.0 MB of its data read in 0 ms") }
            t += 8
            log.append(at(t) + " " + stats(75, memory: 16000, gap: i == 30 ? 600 : 30))
        }
        for _ in 0..<2 {
            log.append(at(t + 1) + " [anvil] guardian: stutter 90 ms (frames had been 33.0 ms) — mostly the game's own work: 0.0 MB")
            t += 20
            log.append(at(t) + " " + stats(30, memory: 16000, behind: 600))
        }
        log.append("=== Notepad — 2026-10-24T03:00:00Z — Anvil 0.68.0 ===")
        log.append(at(t + 30) + " " + stats(120, memory: 50))
        log.append(at(t + 31) + " [anvil] guardian: stutter 90 ms (frames had been 8.0 ms) — mostly the game's own work: 0.0 MB")
        let text = log.joined(separator: "\n") + "\n"
        let p = UnrealTuning.lastSession(of: "Hogwarts Legacy", in: text).flatMap { UnrealTuning.played(session: $0) }
        check(p?.ownStutters == 15 && abs((p?.minutes ?? 0) - 8.0) < 0.01,
              String(format: "its world alone, over midnight: %d of its own stutters in %.1f minutes — not its title screen's, not behind, not the next game's",
                     p?.ownStutters ?? -1, p?.minutes ?? 0))
        check(abs((p?.perMinute ?? 0) - 1.875) < 0.01 && p?.memoryMB == 16000 && abs((p?.shareAtGoal ?? 1) - 0) < 0.001,
              String(format: "%.2f a minute, 16 GB at its most, none of it at 80", p?.perMinute ?? 0))
        let short = UnrealTuning.history(of: "Hogwarts Legacy", in: text)
        check(short == nil, "8 minutes: too few to count as how it ran")

        let realText = (try? String(contentsOf: realLog, encoding: .utf8)) ?? ""
        let realSession = realText.range(of: "=== Hogwarts Legacy — 2026-10-24T01:18:22Z").flatMap { UnrealTuning.played(session: realText[$0.lowerBound...]) }
        if let r = realSession {
            print(String(format: "     its session of 24 October: %d of its own stutters in %.0f minutes of its world — %.2f a minute, %.1f GB at its most, 80 fps %.0f%% of it",
                         r.ownStutters, r.minutes, r.perMinute, (r.memoryMB ?? 0) / 1024, r.shareAtGoal * 100))
            check(r.minutes > 50 && r.minutes < 90 && r.perMinute > 1.5 && r.perMinute < 4, "the real session: its world's play counted, its title screen not")
        } else {
            check(false, "the real session read")
        }
        let realBase = UnrealTuning.history(of: "Hogwarts Legacy", in: realText)
        check(realBase != nil && (realBase?.minutes ?? 0) >= 50, String(format: "how it ran before, from game.log: %.2f a minute over %.0f minutes",
                                                                       realBase?.perMinute ?? 0, realBase?.minutes ?? 0))
        let tunedBefore = realText.replacingOccurrences(of: "framegen:game\n", with: "framegen:game unreal:streaming\n")
        check(tunedBefore != realText && UnrealTuning.history(of: "Hogwarts Legacy", in: tunedBefore) == nil,
              "a session that already ran with it on doesn't count as how it ran before")

        print("— dynamic resolution")
        check(realSession?.renderWidth == 756 && realSession?.renderWidths.count == 1,
              "the real session drew its scene at 756 pixels across, half its 1512, and nothing else: \(realSession?.renderWidths ?? [:])")
        let trialSession = realText.range(of: "=== Hogwarts Legacy — 2026-10-24T06:10:55Z").flatMap { UnrealTuning.played(session: realText[$0.lowerBound...]) }
        if let t = trialSession {
            print(String(format: "     its session of 06:10: 80 fps or more %.0f%% of its play, %.0f fps on average, %.1f of its own stutters a minute",
                         t.shareAtGoal * 100, t.averageFPS, t.perMinute))
        }
        check((trialSession?.averageFPS ?? 0) > 30 && (trialSession?.averageFPS ?? 99) < 70 && (trialSession?.shareAtGoal ?? 1) < 0.2,
              "its frame rate read from the session of 06:10")
        let latest = UnrealTuning.latestFrameRate(of: "Hogwarts Legacy", in: realText)
        check(latest?.renderWidth == 756 && abs((latest?.averageFPS ?? 0) - (trialSession?.averageFPS ?? -1)) < 0.01,
              "how it ran before a frame-rate trial: its last session without one, 06:10's")
        let dyn = UnrealTuning.dynamicResolution
        let own80 = UnrealTuning.Context(ownFrames: true, goal: 80), plain80 = UnrealTuning.Context(ownFrames: false, goal: 80)
        let own60 = UnrealTuning.Context(ownFrames: true, goal: 60), plain60 = UnrealTuning.Context(ownFrames: false, goal: 60)
        func budget(_ c: UnrealTuning.Context) -> String { dyn.keys(c).first { $0.0 == "r.DynamicRes.FrameTimeBudget" }?.1 ?? "-" }
        check(budget(own80) == "25.0" && budget(plain80) == "12.5" && budget(own60) == "33.3" && budget(plain60) == "16.7"
              && dyn.keys(own80).contains { $0 == ("r.DynamicRes.OperationMode", "2") },
              "its budget a frame the game draws: 25 ms with its own frame generation for 80 (40 drawn), 33.3 for 60 (30 drawn); 12.5 and 16.7 without")
        let allManaged = UnrealTuning.managed(hasProfile: true)
        check(["25.0", "12.5", "33.3", "16.7"].allSatisfy { v in allManaged.contains { $0 == ("r.DynamicRes.FrameTimeBudget", v) } }
              && allManaged.contains { $0 == ("r.ShaderPipelineCache.MaxPrecompileTime", "1") } && allManaged.contains { $0 == ("s.AsyncLoadingThreadEnabled", "1") },
              "every budget Anvil may write its own, so any is taken out again; and the loading settings")
        let at60 = realText.range(of: "=== Hogwarts Legacy — 2026-10-24T06:10:55Z").flatMap { UnrealTuning.played(session: realText[$0.lowerBound...], goal: 60) }
        check((at60?.shareAtGoal ?? 0) > (trialSession?.shareAtGoal ?? 1) && at60?.goal == 60,
              String(format: "its session of 06:10 against 60: %.0f%% of its play, against 80: %.0f%%", (at60?.shareAtGoal ?? 0) * 100, (trialSession?.shareAtGoal ?? 0) * 100))

        print("— its loading")
        check(trialSession?.startFreeze == 5.1 && trialSession?.loadStalls.count == 3 && abs((trialSession?.loadStall ?? 0) - 7.0 / 3) < 0.01,
              String(format: "06:10: its start stopped 5.1 s; three loading screens, %.1f s each on average (2.6, 2.6, 1.8)", trialSession?.loadStall ?? 0))
        check(realSession?.startFreeze == 5.3 && realSession?.loadStalls == [1.8, 1.8], "01:18: its start 5.3 s; its loading screens 1.8 s, the stops with nothing read not among them")
        let lb = UnrealTuning.latestLoading(of: "Hogwarts Legacy", in: realText)
        check(lb?.startFreeze == 5.1 && lb?.loadStall != nil, String(format: "how it loaded before: a %.1f s start, %.1f s loading screens", lb?.startFreeze ?? 0, lb?.loadStall ?? 0))
        var widthLog = ["=== Hogwarts Legacy — 2026-10-25T01:00:00Z — Anvil 0.68.0 ==="]
        var wt = 10 * 3600.0
        for i in 0..<40 {
            wt += 8
            let w = [756, 680, 604, 900, 1008][i % 5]
            widthLog.append(at(wt) + " " + stats(70, memory: 16000) + " | GPU work 20.1 ms a frame: scene 9.0 | heaviest passes (of a 20 ms frame): scene 6.0 ms (\(w)x\(Int(Double(w) / 1.5385)), 4 colour (8-bit) + depth); depth 2.0 ms (6144x2048, depth only); copies 0.5 ms (1512x982, 1 colour)")
        }
        let varied = UnrealTuning.played(session: Substring(widthLog.joined(separator: "\n")))
        check(varied?.renderWidths.count == 5 && UnrealTuning.engaged(varied!, before: latest) == true,
              "drawn at five widths, the shadow map and the window not counted: taking dynamic resolution")
        check(UnrealTuning.engaged(realSession!, before: latest) == false, "always 756 across, as before: not taking it")

        print("— deciding")
        let all = Set(names)
        var r = UnrealTuning.Record()
        var wanted = UnrealTuning.plan(&r, present: all, trimsDetail: false)
        check(wanted.isEmpty && r.states.isEmpty && r.active.isEmpty, "no measure of how it ran before: nothing tried, this session measures")
        r.baseline = .init(perMinute: 2.4, minutes: 70, memoryMB: 17_600)
        wanted = UnrealTuning.plan(&r, present: all, trimsDetail: false)
        check(r.states["streaming"] == .trial && r.active == ["streaming"] && wanted.count == 2, "2.4 a minute before: on trial")
        var rare = UnrealTuning.Record()
        rare.baseline = .init(perMinute: 0.1, minutes: 60, memoryMB: nil)
        check(UnrealTuning.plan(&rare, present: all, trimsDetail: false).isEmpty && rare.states["streaming"] == .notNeeded, "0.1 a minute: not needed")
        var lacks = UnrealTuning.Record()
        lacks.baseline = r.baseline
        check(UnrealTuning.plan(&lacks, present: ["r.StaticMeshLODDistanceScale"], trimsDetail: false).isEmpty && lacks.states["streaming"] == .notNeeded,
              "its program lacks the settings: none written")
        var unread = UnrealTuning.Record()
        unread.baseline = r.baseline
        check(UnrealTuning.plan(&unread, present: nil, trimsDetail: false).isEmpty && unread.states["streaming"] == nil,
              "its program unread: nothing written, nothing marked")

        func played(_ perMinute: Double, minutes: Double = 60, memory: Double = 17_800, at80: Double = 0.3) -> UnrealTuning.Played {
            UnrealTuning.Played(ownStutters: Int((perMinute * minutes).rounded()), minutes: minutes, memoryMB: memory, shareAtGoal: at80)
        }
        var better = r
        let saidBetter = UnrealTuning.judge(&better, played: played(1.0), endedBadly: nil, trimsDetail: false)
        check(better.states["streaming"] == .kept, "1.0 a minute against 2.4: kept — \(saidBetter.first ?? "-")")
        var same = r
        _ = UnrealTuning.judge(&same, played: played(2.3), endedBadly: nil, trimsDetail: false)
        check(same.states["streaming"] == .dropped, "2.3 against 2.4: no better, dropped")
        var memory = r
        let saidMemory = UnrealTuning.judge(&memory, played: played(1.0, memory: 19_900), endedBadly: nil, trimsDetail: false)
        check(memory.states["streaming"] == .dropped, "fewer stutters but 2.3 GB more memory: dropped — \(saidMemory.first ?? "-")")
        var crashed = r
        let saidCrash = UnrealTuning.judge(&crashed, played: played(0.5), endedBadly: "code 3", trimsDetail: false)
        check(crashed.states["streaming"] == .dropped && crashed.notes["streaming"]?.contains("code 3") == true,
              "ended unexpectedly with it on trial: dropped, whatever it measured — \(saidCrash.first ?? "-")")
        var brief = r
        _ = UnrealTuning.judge(&brief, played: played(0.5, minutes: 6), endedBadly: nil, trimsDetail: false)
        check(brief.states["streaming"] == .trial, "6 minutes: too few to judge, on trial again")
        var next = UnrealTuning.Record()
        next.acknowledged = Date()
        _ = UnrealTuning.judge(&next, played: played(2.0, minutes: 30), endedBadly: nil, trimsDetail: false)
        _ = UnrealTuning.judge(&next, played: played(3.0, minutes: 10), endedBadly: nil, trimsDetail: false)
        check(abs((next.baseline?.perMinute ?? 0) - 2.25) < 0.001 && next.baseline?.minutes == 40, "sessions with nothing on trial: how it runs without, by their minutes")
        var keptOn = better
        keptOn.active = ["streaming"]
        let before = keptOn.baseline
        _ = UnrealTuning.judge(&keptOn, played: played(1.2), endedBadly: nil, trimsDetail: false)
        check(keptOn.baseline == before && keptOn.states["streaming"] == .kept, "a session with it kept doesn't count as how it runs without")

        print("— a frame-rate trial")
        var f = UnrealTuning.Record()
        f.baseline = .init(perMinute: 2.0, minutes: 66, memoryMB: 20_000)
        f.states["streaming"] = .dropped
        f.fpsBaseline = latest
        let fWanted = UnrealTuning.plan(&f, present: all, trimsDetail: false, context: own80)
        check(f.states["dynamicres"] == .trial && f.active == ["dynamicres"] && fWanted.contains { $0 == ("r.DynamicRes.FrameTimeBudget", "25.0") },
              "garbage collection dropped, 80 a few % of the time: dynamic resolution on trial, at 25 ms — \(f.notes["dynamicres"] ?? "-")")
        var oneAtATime = UnrealTuning.Record()
        oneAtATime.baseline = f.baseline
        oneAtATime.fpsBaseline = latest
        oneAtATime.loadBaseline = lb
        _ = UnrealTuning.plan(&oneAtATime, present: all, trimsDetail: false, context: own60)
        check(oneAtATime.states["streaming"] == .trial && oneAtATime.states["dynamicres"] == .trial && oneAtATime.states["pipelines"] == .trial
              && oneAtATime.states["asyncloading"] == nil && oneAtATime.notes["dynamicres"]?.contains("60 fps") == true,
              "one trial of each kind at a time: stutters, frame rate (against 60), loading — its loading thread after its pipelines")
        var holding = UnrealTuning.Record()
        holding.fpsBaseline = .init(perMinute: 0.5, minutes: 30, memoryMB: nil, shareAtGoal: 0.9, averageFPS: 88)
        holding.states["streaming"] = .dropped
        _ = UnrealTuning.plan(&holding, present: all, trimsDetail: false)
        check(holding.states["dynamicres"] == .notNeeded, "a game holding 80 90% of the time: not needed")
        func fps(_ share: Double, _ avg: Double, widths: [Int: Int], stutters: Double = 2.0) -> UnrealTuning.Played {
            UnrealTuning.Played(ownStutters: Int(stutters * 30), minutes: 30, memoryMB: 20_000, shareAtGoal: share, averageFPS: avg, renderWidths: widths)
        }
        var won = f
        let wonSaid = UnrealTuning.judge(&won, played: fps(0.4, 68, widths: [756: 10, 640: 12, 900: 6]), endedBadly: nil, trimsDetail: false)
        check(won.states["dynamicres"] == .kept, "drawn at changing sizes, 80 fps 40% of the time against 2%: kept — \(wonSaid.first ?? "-")")
        var ignored = f
        let ignoredSaid = UnrealTuning.judge(&ignored, played: fps(0.4, 68, widths: [756: 30]), endedBadly: nil, trimsDetail: false)
        check(ignored.states["dynamicres"] == .dropped, "always 756 across: the game doesn't take it — dropped, whatever the frame rate — \(ignoredSaid.first ?? "-")")
        var flat = f
        _ = UnrealTuning.judge(&flat, played: fps(0.05, latest?.averageFPS ?? 50, widths: [756: 10, 640: 12, 900: 6]), endedBadly: nil, trimsDetail: false)
        check(flat.states["dynamicres"] == .dropped, "taking it but no faster: dropped")
        var choppy = f
        _ = UnrealTuning.judge(&choppy, played: fps(0.4, 68, widths: [756: 10, 640: 12, 900: 6], stutters: 3.5), endedBadly: nil, trimsDetail: false)
        check(choppy.states["dynamicres"] == .dropped, "faster but its own stutters 2.0 → 3.5 a minute: dropped")
        var crashedFR = f
        _ = UnrealTuning.judge(&crashedFR, played: nil, endedBadly: "code 3", trimsDetail: false)
        check(crashedFR.states["dynamicres"] == .dropped, "the game ended unexpectedly with it on: dropped")
        var stepHeld = f
        stepHeld.detail = 1
        stepHeld.detailNext = 3
        _ = UnrealTuning.plan(&stepHeld, present: all, trimsDetail: true, context: own80)
        check(stepHeld.detail == 1 && stepHeld.detailNext == 3 && stepHeld.active.contains("detail=1"),
              "distant detail held at its step through the trial, the next step kept for after")
        _ = UnrealTuning.judge(&stepHeld, played: fps(0.1, 50, widths: [756: 10, 640: 12, 900: 6]), endedBadly: nil, trimsDetail: true)
        check(stepHeld.detailNext == 3, "…and not stepped from the trial's session")

        print("— loading trials")
        var l = UnrealTuning.Record()
        l.baseline = .init(perMinute: 2.0, minutes: 66, memoryMB: 20_000)
        l.states = ["streaming": .dropped, "dynamicres": .dropped]
        l.loadBaseline = .init(perMinute: 2.0, minutes: 23, memoryMB: nil, startFreeze: 5.1, loadStall: 2.5, compilePerMinute: 0.1)
        _ = UnrealTuning.plan(&l, present: all, trimsDetail: false)
        check(l.states["pipelines"] == .trial && l.active == ["pipelines"], "its start stopped 5.1 s: pipelines in the background on trial — \(l.notes["pipelines"] ?? "-")")
        func loads(start: Double?, stalls: [Double], compiles: Int = 3, stutters: Double = 2.0) -> UnrealTuning.Played {
            UnrealTuning.Played(ownStutters: Int(stutters * 30), minutes: 30, memoryMB: 20_000, shareAtGoal: 0.3, averageFPS: 55,
                                startFreeze: start, loadStalls: stalls, compileStutters: compiles)
        }
        var quick = l
        let quickSaid = UnrealTuning.judge(&quick, played: loads(start: nil, stalls: [2.4]), endedBadly: nil, trimsDetail: false)
        check(quick.states["pipelines"] == .kept, "no stop of 1.5 s or more at its start, compiles as before: kept — \(quickSaid.first ?? "-")")
        var still = l
        _ = UnrealTuning.judge(&still, played: loads(start: 5.0, stalls: [2.4]), endedBadly: nil, trimsDetail: false)
        check(still.states["pipelines"] == .dropped, "still 5.0 s: dropped")
        var compiling = l
        _ = UnrealTuning.judge(&compiling, played: loads(start: nil, stalls: [2.4], compiles: 30), endedBadly: nil, trimsDetail: false)
        check(compiling.states["pipelines"] == .dropped, "its start quick but a stutter from compiling a minute in play: dropped")
        var thread = quick
        _ = UnrealTuning.plan(&thread, present: all, trimsDetail: false)
        check(thread.states["asyncloading"] == .trial && thread.active.contains("pipelines") && thread.active.contains("asyncloading"),
              "pipelines kept: its loading thread on trial next, both written")
        var faster = thread
        let fasterSaid = UnrealTuning.judge(&faster, played: loads(start: nil, stalls: [1.6, 1.5]), endedBadly: nil, trimsDetail: false)
        check(faster.states["asyncloading"] == .kept, "loading screens 2.5 → 1.55 s: kept — \(fasterSaid.first ?? "-")")
        var noShorter = thread
        _ = UnrealTuning.judge(&noShorter, played: loads(start: nil, stalls: [2.3]), endedBadly: nil, trimsDetail: false)
        check(noShorter.states["asyncloading"] == .dropped, "2.5 → 2.3 s: dropped")
        var noLoads = thread
        let noLoadsSaid = UnrealTuning.judge(&noLoads, played: loads(start: nil, stalls: []), endedBadly: nil, trimsDetail: false)
        check(noLoads.states["asyncloading"] == .trial, "no loading screen this session: on trial again — \(noLoadsSaid.first ?? "-")")
        var crashedLoad = thread
        _ = UnrealTuning.judge(&crashedLoad, played: nil, endedBadly: "signal 11", trimsDetail: false)
        check(crashedLoad.states["asyncloading"] == .dropped && crashedLoad.states["pipelines"] == .kept, "ended unexpectedly with it on: dropped, what was kept stays")

        print("— distant detail, for an Unreal game GameUpscaler has no profile of")
        var d = UnrealTuning.Record()
        d.detail = 0
        _ = UnrealTuning.judge(&d, played: played(1, minutes: 20, at80: 0.3), endedBadly: nil, trimsDetail: true)
        check(d.detailNext == 2, "under half the time at 80: two steps")
        let detailOnly = Set(UnrealTuning.detailLevels.flatMap { $0.map(\.0) })   // no trial of another kind to hold it
        let dWanted = UnrealTuning.plan(&d, present: detailOnly, trimsDetail: true)
        check(d.detail == 2 && d.active.contains("detail=2") && dWanted.contains { $0 == ("r.StaticMeshLODDistanceScale", "1.5") }, "written at step 2")
        _ = UnrealTuning.judge(&d, played: played(1, minutes: 20, at80: 0.97), endedBadly: nil, trimsDetail: true)
        check(d.detailNext == 1, "with room to spare: a step back")
        var asSet = d
        _ = UnrealTuning.plan(&asSet, present: all, trimsDetail: false)
        check(asSet.detail == nil && !asSet.active.contains { $0.hasPrefix("detail") }, "as the game has it: no step")

        print("— a start, on a copy of its folder")
        let config = c.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/Config/WindowsNoEditor", isDirectory: true)
        try? fm.createDirectory(at: config, withIntermediateDirectories: true)
        let ini = config.appendingPathComponent("Engine.ini")
        try? Data(original.utf8).write(to: ini)
        var asked = 0, refused = 0
        let first = UnrealTuning.prepare(epic, in: c, hasProfile: true, logs: { realText }, confirm: { _ in asked += 1; return true }, declined: { refused += 1 })
        first.forEach { print("     \($0)") }
        let afterFirst = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let rec = UnrealTuning.record(for: epic)
        check(asked == 1 && refused == 0 && rec?.acknowledged != nil, "asked once, before its first tuned start")
        check(rec?.states["streaming"] == .trial && UnrealConfig.systemValue("s.ForceGCAfterLevelStreamedOut", in: afterFirst) == "0"
              && UnrealConfig.systemValue("r.StaticMeshLODDistanceScale", in: afterFirst) == nil,
              "on trial against how it ran in game.log, written; its distant detail left to GameUpscaler")
        check((try? String(contentsOf: UnrealTuning.backupURL(for: epic), encoding: .utf8)) == original, "its Engine.ini backed up before the change")
        check(UnrealTuning.learnParts(epic) == ["unreal:streaming", "unreal:dynamicres", "unreal:pipelines"]
              && UnrealConfig.systemValue("r.ShaderPipelineCache.MaxPrecompileTime", in: afterFirst) == "1"
              && UnrealConfig.systemValue("r.DynamicRes.FrameTimeBudget", in: afterFirst) == "12.5",
              "one trial of each kind from its first tuned start, Learn told: \(UnrealTuning.learnParts(epic))")
        check(UnrealTuning.frameRateTrial(epic), "a frame-rate trial among them: the even-80 steps hold")
        _ = UnrealTuning.prepare(epic, in: c, hasProfile: true, logs: { realText }, confirm: { _ in asked += 1; return true }, declined: {})
        check(asked == 1 && (try? String(contentsOf: ini, encoding: .utf8)) == afterFirst, "the next start: not asked again, the file as it was")
        print("— a record from before Anvil looked for dynamic resolution")
        var upgraded = epic
        upgraded.id = UUID()
        var before68 = UnrealTuning.Record()
        before68.acknowledged = Date()
        before68.present = ["s.ContinuouslyIncrementalGCWhileLevelsPendingPurge", "s.ForceGCAfterLevelStreamedOut"]
        before68.programStamp = UnrealTuning.stamp(program)
        before68.states = ["streaming": .dropped, "dynamicres": .notNeeded]
        before68.notes = ["dynamicres": "its program doesn't have these settings"]
        before68.baseline = .init(perMinute: 2.0, minutes: 188, memoryMB: 20_052)
        before68.fpsBaseline = latest
        UnrealTuning.save(before68, for: upgraded)
        try? Data(original.utf8).write(to: ini)
        let up = UnrealTuning.prepare(upgraded, in: c, hasProfile: true, context: own80, logs: { realText }, confirm: { _ in false }, declined: {})
        up.forEach { print("     \($0)") }
        let upRec = UnrealTuning.record(for: upgraded)
        let upIni = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        check(upRec?.states["dynamicres"] == .trial && upRec?.lookedFor?.contains("r.DynamicRes.FrameTimeBudget") == true
              && UnrealConfig.systemValue("r.DynamicRes.FrameTimeBudget", in: upIni) == "25.0" && UnrealConfig.systemValue("s.ForceGCAfterLevelStreamedOut", in: upIni) == nil,
              "its program looked at again for the settings it wasn't: dynamic resolution on trial at 25 ms, garbage collection left dropped")
        check(UnrealTuning.frameRateTrial(upgraded) && UnrealTuning.learnParts(upgraded) == ["unreal:dynamicres", "unreal:pipelines"], "a frame-rate trial: the even-80 steps hold, Learn told")
        _ = UnrealTuning.prepare(upgraded, in: c, hasProfile: true, context: own80, logs: { realText }, confirm: { _ in false }, declined: {})
        var sixty = upgraded
        sixty.fpsGoal = 60
        _ = UnrealTuning.prepare(sixty, in: c, hasProfile: true, context: .init(ownFrames: true, goal: UnrealTuning.goal(of: sixty)), logs: { realText }, confirm: { _ in false }, declined: {})
        check(UnrealTuning.record(for: sixty)?.fpsBaseline?.goal == 60 && UnrealConfig.systemValue("r.DynamicRes.FrameTimeBudget", in: (try? String(contentsOf: ini, encoding: .utf8)) ?? "") == "33.3",
              "its goal set to 60: how it ran before measured again against 60, and the budget 33.3 ms")
        _ = UnrealTuning.prepare(upgraded, in: c, hasProfile: true, context: own80, logs: { realText }, confirm: { _ in false }, declined: {})
        check(UnrealTuning.record(for: upgraded)?.lookedFor == upRec?.lookedFor && (try? String(contentsOf: ini, encoding: .utf8)) == upIni,
              "the next start: not looked for again, the file as it was")
        try? Data(afterFirst.utf8).write(to: ini)

        var switchedOff = epic
        switchedOff.unrealTuning = false
        _ = UnrealTuning.prepare(switchedOff, in: c, hasProfile: true, logs: { "" }, confirm: { _ in true }, declined: {})
        check((try? String(contentsOf: ini, encoding: .utf8)) == original, "switched off: Anvil's settings taken out, the file as the game had it")

        var addedHere = added
        addedHere.executablePath = exe
        let playerOwn = UnrealConfig.settingSystem("s.ForceGCAfterLevelStreamedOut", to: "0", in: original)
        try? Data(playerOwn.utf8).write(to: ini)
        _ = UnrealTuning.prepare(addedHere, in: c, hasProfile: true, logs: { realText }, confirm: { _ in asked += 1; return true }, declined: {})
        check(asked == 1 && (try? String(contentsOf: ini, encoding: .utf8)) == playerOwn && UnrealTuning.record(for: addedHere) == nil,
              "a game added from its program: not asked, not tuned, and the same setting the player put there left alone")

        var saysNo = epic
        saysNo.id = UUID()
        let noLines = UnrealTuning.prepare(saysNo, in: c, hasProfile: true, logs: { realText }, confirm: { _ in false }, declined: { refused += 1 })
        check(refused == 1 && (try? String(contentsOf: ini, encoding: .utf8)) == original && UnrealTuning.record(for: saysNo) == nil,
              "said no at the first start: nothing written, and the same settings already there taken out — \(noLines.first ?? "-")")

        try? Data(afterFirst.utf8).write(to: ini)
        check(UnrealTuning.restore(epic, in: c) && (try? String(contentsOf: ini, encoding: .utf8)) == original && UnrealTuning.record(for: epic) == nil,
              "Put Its Own Settings Back: Anvil's out, the record forgotten")

        try? fm.removeItem(at: tmp)
        print(failures == 0 ? "unreal tuning: all checks passed" : "unreal tuning: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
