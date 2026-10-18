// Anvil Learn: what each part of a setup costs, learned across sessions at the same scene load, and what any
// setup would do over the play seen — checked on LEGO Star Wars' twelve sessions of 13–17 October (base M4),
// each predicted from the others. Also the parts a session is filed under, Unreal's own settings, the program an
// Unreal launcher starts, and the choices Learn makes from it.
//
//   CFFIXED_USER_HOME=$T/home HOME=$T/home LearnTest <game.old.log> <game.log> <a Windows program> <a DLL that uses msvcp140>
import Foundation


/// A stand-in Unreal Engine game, made from any two small Windows programs: its launcher at the top of its folder
/// (reading Microsoft's Visual C++ key, as Unreal's does) beside Engine/, and the game under Project/Binaries/Win64
/// (using the runtime's DLLs, naming DirectX 12 and Unreal's ray tracing). Hogwarts Legacy's own files were used
/// until it was uninstalled on 17 October; this has the same layout and the same tells.
func makeStandInUnrealGame(launcherFrom: URL, programFrom: URL) -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("unreal-\(UUID().uuidString)/StandIn", isDirectory: true)
    let bin = root.appendingPathComponent("Phoenix/Binaries/Win64", isDirectory: true)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent("Engine/Binaries", isDirectory: true), withIntermediateDirectories: true)
    var launcher = (try? Data(contentsOf: launcherFrom)) ?? Data()
    launcher += Data("SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    try? launcher.write(to: root.appendingPathComponent("HogwartsLegacy.exe"))
    var program = (try? Data(contentsOf: programFrom)) ?? Data()
    program += Data("\u{0}d3d12.dll\u{0}D3D12CreateDevice\u{0}r.RayTracing\u{0}".utf8)
    try? program.write(to: bin.appendingPathComponent("HogwartsLegacy.exe"))
    return root.appendingPathComponent("HogwartsLegacy.exe")
}

@main
struct LearnTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    /// What each LEGO session ran with, from anvil.log's graphics lines (before 0.59 sessions didn't say).
    static func legoParts(_ start: String) -> [String] {
        if start < "2026-10-15T04:41" { return [] }                                   // Light, reflections off
        if start < "2026-10-16T02:15" { return ["level:full", "reflections"] }       // the game's own look
        if start < "2026-10-16T18:28" { return ["level:medium"] }                    // Medium, its switch off
        if start < "2026-10-16T23:45" { return [] }                                   // Light
        return ["reflections"]                                                        // Light, the switch on
    }

    static func sessions(_ urls: [URL]) -> [(start: String, windows: [FrameWindow])] {
        var out: [(String, [FrameWindow])] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var start: String?, windows: [FrameWindow] = []
            for line in text.split(separator: "\n") {
                if line.hasPrefix("=== ") {
                    if let s = start, !windows.isEmpty { out.append((s, windows)) }
                    let lego = line.hasPrefix("=== LEGO")
                    start = lego ? line.components(separatedBy: " — ").dropFirst().first : nil
                    windows = []
                    continue
                }
                if start != nil, let w = FrameLog.parse(line) { windows.append(w) }
            }
            if let s = start, !windows.isEmpty { out.append((s, windows)) }
        }
        return out.filter { $0.0 >= "2026-10-12T21" }   // from when every pass was timed (0.46)
    }

    @MainActor
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 5 else { print("usage: LearnTest <game.old.log> <game.log> <a Windows program> <a DLL that uses msvcp140>"); exit(2) }
        let all = sessions([URL(fileURLWithPath: a[1]), URL(fileURLWithPath: a[2])])
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-10-18T00:00:00Z")!
        func model(_ sessions: [(start: String, windows: [FrameWindow])]) -> LearnModel {
            var m = LearnModel(program: "LEGOSTARWARSSKYWALKERSAGA_DX11.exe", mac: "test")
            for s in sessions { m.learn(startedAt: iso.date(from: s.start)!, parts: legoParts(s.start), windows: s.windows) }
            return m
        }
        print("— learned from \(all.count) sessions")
        let full = model(all)
        if let dump = ProcessInfo.processInfo.environment["LEARN_DUMP"] {
            var csv = "at,parts,scene,game,frame,seconds\n"
            for s in full.samples { csv += "\(s.at),\(s.parts.joined(separator: "+")),\(s.scene),\(s.game),\(s.frame),\(s.seconds)\n" }
            try? csv.write(toFile: dump, atomically: false, encoding: .utf8)
        }
        let fit = full.fit(now: now)
        check(fit.timed && fit.sessions >= 12, String(format: "%d sessions, %.0f minutes of play", fit.sessions, fit.minutes))
        let rt = fit.costs["reflections"] ?? .nan, lvFull = fit.costs["level:full"] ?? .nan, lvMed = fit.costs["level:medium"] ?? .nan
        print(String(format: "     costs: reflections %+.2f ms, the game's own look %+.2f, Medium %+.2f", rt, lvFull, lvMed))
        // Measured with the stalls left out, as Anvil leaves them out: 4 stretches of a load at 78 ms a frame
        // among the game's own look's 196 had made its extras look like 1.7 ms in the first try in Python.
        check(rt > 0.9 && rt < 1.6, String(format: "reflections cost about 1.2 ms a frame (%.2f)", rt))
        check(lvFull > -0.3 && lvFull < 0.8, String(format: "the game's own look's other extras little more (%.2f)", lvFull))
        check(abs(lvMed) < 0.5, String(format: "Medium costs about what Light does (%.2f)", lvMed))
        check(fit.known("reflections") && fit.known("level:full") && fit.known("level:medium"), "each measured both ways for 5 minutes or more")

        print("— each session predicted from the others")
        var errors: [Double] = [], naive: [Double] = []
        for (i, s) in all.enumerated() {
            // Scene-matched needs the scene timed: 12 October's session (0.46) didn't time it.
            let play = LearnModel.usable(s.windows).filter { $0.gpuKinds?["scene"] != nil }
            let seconds = play.reduce(0) { $0 + $1.seconds }
            guard seconds >= 240 else { continue }
            var others = model(all.enumerated().filter { $0.offset != i }.map(\.element))
            // Weighted to this session's scenes: its own samples kept only as where it was, not how it ran.
            let actual = play.filter { $0.capacity >= 79.5 }.reduce(0) { $0 + $1.seconds } / seconds
            var held = LearnModel(program: "x", mac: "x")
            held.learn(startedAt: iso.date(from: s.start)!, parts: legoParts(s.start), windows: s.windows)
            held.samples.removeAll { $0.scene < 0 }
            let f = others.fit(now: now)
            // The other sessions' stretches at this session's scene loads.
            let bins = Dictionary(grouping: held.samples, by: { LearnModel.bin($0.scene) }).mapValues { $0.reduce(0) { $0 + Double($1.seconds) } }
            var pool: [Int: [LearnSample]] = Dictionary(grouping: others.samples, by: { LearnModel.bin($0.scene) })
            var num = 0.0, den = 0.0
            for (bin, w) in bins {
                var v = pool[bin] ?? []
                if v.reduce(0, { $0 + Double($1.seconds) }) < 30 { v += (pool[bin - 1] ?? []) + (pool[bin + 1] ?? []) }
                guard !v.isEmpty else { continue }
                var sub = others; sub.samples = v
                guard let p = sub.predict(legoParts(s.start), target: 80, fit: f, now: now) else { continue }
                num += w * p.shareAt; den += w
            }
            pool = [:]
            let predicted = num / max(den, 1e-9)
            let same = others.samples.filter { $0.parts == legoParts(s.start).sorted() }
            let naiveShare = same.isEmpty ? 0.5 : same.filter { $0.frame <= 1000 / 79.5 }.reduce(0) { $0 + Double($1.seconds) } / same.reduce(0) { $0 + Double($1.seconds) }
            errors.append(abs(predicted - actual)); naive.append(abs(naiveShare - actual))
            others.samples = []
            print(String(format: "     %@ %-26@ actual %3.0f%%  Learn %3.0f%%  setup's own average %3.0f%%", s.start, legoParts(s.start).joined(separator: "+") as NSString, actual * 100, predicted * 100, naiveShare * 100))
        }
        let mae = errors.reduce(0, +) / Double(max(errors.count, 1)), naiveMAE = naive.reduce(0, +) / Double(max(naive.count, 1))
        check(errors.count >= 10, "\(errors.count) sessions long enough to judge")
        // 10.5 points on 17 October, against 16.8 for each setup's own average. Session-to-session swings Learn
        // can't see (a Mac on battery holding 80, FSR 3 eased, a scene's CPU) are most of what's left.
        check(mae < 0.12, String(format: "within %.1f points on average (under 12)", mae * 100))
        check(mae < naiveMAE - 0.04, String(format: "clearly better than each setup's own average (%.1f points)", naiveMAE * 100))

        print("— what it would choose")
        for parts in [[], ["reflections"], ["level:medium", "reflections"], ["level:full", "reflections"]] {
            if let p = full.predict(parts, target: 80, fit: fit, now: now) {
                print(String(format: "     %-26@ 80+ %3.0f%%  typically %3.0f fps  %+.1f ms  %@", (parts.isEmpty ? "light" : parts.joined(separator: "+")) as NSString,
                             p.shareAt * 100, p.typicalFPS, p.extraMs, p.known ? "measured" : "not measured"))
            }
        }
        let mr = full.predict(["level:medium", "reflections"], target: 80, fit: fit, now: now)
        check(mr?.known == true, "Medium with reflections — never played — predicted from its parts")
        let light = full.predict([], target: 80, fit: fit, now: now)!, own = full.predict(["level:full", "reflections"], target: 80, fit: fit, now: now)!
        check(light.shareAt > own.shareAt + 0.05, String(format: "Light holds 80 longer than the game's own look (%.0f%% against %.0f%%)", light.shareAt * 100, own.shareAt * 100))
        let smooth = LearnStore.choose(model: full, fit: fit, goal: .smooth, reflectionsChosen: true, target: 80)
        check(smooth?.level == .medium && smooth?.reflections == true, "Smooth 80+, reflections switched on: Medium with them (the same settings as Light with them, the better level) — \(smooth?.reason ?? "-")")
        let auto = LearnStore.choose(model: full, fit: fit, goal: .smooth, reflectionsChosen: nil, target: 80)
        check(auto != nil, "Smooth 80+, the switch on Automatic: \(auto.map { "\($0.level.title)\($0.reflections ? " with reflections" : "")" } ?? "-") — \(auto?.reason ?? "-")")
        let quality = LearnStore.choose(model: full, fit: fit, goal: .quality, reflectionsChosen: true, target: 80)
        check(quality != nil && quality?.level != .full, "Best graphics: \(quality.map { $0.level.title } ?? "-"), never the game's own look by itself — \(quality?.reason ?? "-")")

        print("— learning, kept")
        var m = LearnModel(program: "x", mac: "x")
        let first = all[0]
        let n1 = m.learn(startedAt: iso.date(from: first.start)!, parts: [], windows: first.windows)
        let n2 = m.learn(startedAt: iso.date(from: first.start)!, parts: [], windows: first.windows)
        check(n1 > 0 && n2 == 0, "a session is learned once (\(n1), then \(n2))")
        let old = LearnSample(at: now.timeIntervalSince1970 - 30 * 86_400, parts: [], scene: 5, game: 8, frame: 10, seconds: 7)
        check(abs(m.weight(old, now: now) - 3.5) < 0.01, "a month-old stretch counts half")
        let data = try! JSONEncoder().encode(full)
        let back = try! JSONDecoder().decode(LearnModel.self, from: data)
        check(back.samples.count == full.samples.count && back.sessions == full.sessions, String(format: "kept and read back (%.0f KB for %d stretches)", Double(data.count) / 1024, full.samples.count))
        check(full.samples.count <= LearnModel.maxSamples, "within its size limit")

        print("— a session's parts")
        let parts = Learn.parts(level: .medium, reflections: true, halfResolution: nil, unreal: ["sg.ShadowQuality": 3, "sg.EffectsQuality": 2])
        check(parts == ["level:medium", "reflections", "sg.EffectsQuality=2", "sg.ShadowQuality=3"], "\(parts)")
        check(Learn.parseSetupLine(Substring(Learn.setupLine(parts))) == parts, "the setup line reads back: \(Learn.setupLine(parts))")
        check(Learn.parseSetupLine("12:00:00.000 [anvil] setup: -") == [], "nothing to tune reads back as nothing")
        check(LearnModel.features(["sg.ShadowQuality=3", "reflections"]) == ["sg.ShadowQuality": 3, "reflections": 1], "an Unreal setting counts by its level")
        let ini = "[/Script/Engine.GameUserSettings]\nbUseVSync=False\n\n[ScalabilityGroups]\nsg.ResolutionQuality=100.000000\nsg.ViewDistanceQuality=3\nsg.ShadowQuality=2\nsg.PostProcessQuality=3\n\n[Other]\nsg.Bogus=9\n"
        check(Learn.scalability(in: ini) == ["sg.ViewDistanceQuality": 3, "sg.ShadowQuality": 2, "sg.PostProcessQuality": 3],
              "Unreal's own quality settings read from GameUserSettings.ini, its resolution percentage left out")
        check(Learn.describe("sg.PostProcessQuality=3") == "Post-processing quality" && Learn.describe("reflections") == "its reflections", "and said in words")

        print("— an Unreal launcher, read through to the game")
        let launcher = makeStandInUnrealGame(launcherFrom: URL(fileURLWithPath: a[3]), programFrom: URL(fileURLWithPath: a[4]))
        let program = GameAnalysis.drawingProgram(for: launcher)
        check(program.path.hasSuffix("Phoenix/Binaries/Win64/HogwartsLegacy.exe"), "Hogwarts Legacy's launcher starts \(program.path.components(separatedBy: "/").suffix(4).joined(separator: "/"))")
        let analysis = GameAnalysis.analyze(executable: launcher)
        check(analysis.engine == .unreal && analysis.primary == .d3d12 && analysis.is64Bit, "read as \(analysis.summary)")
        check(GameAnalysis.offersRayTracing(executable: launcher), "with ray-traced effects to offer")
        check(GameAnalysis.drawingProgram(for: URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator")).lastPathComponent == "Calculator", "anything else is itself")

        print("— Unreal's driver warning, off")
        let plain = UnrealConfig.settingSystem("r.WarnOfBadDrivers", to: "0", in: "[Core.System]\nPaths=a\n")
        check(plain == "[Core.System]\nPaths=a\n\n[SystemSettings]\nr.WarnOfBadDrivers=0\n", "a [SystemSettings] section added, the rest kept")
        check(UnrealConfig.settingSystem("r.WarnOfBadDrivers", to: "0", in: plain) == plain, "and written once: the next start changes nothing")
        let had = "[SystemSettings]\r\nr.Foo=1\r\nr.WarnOfBadDrivers=1\r\n[Other]\r\nx=1\r\n"
        check(UnrealConfig.settingSystem("r.WarnOfBadDrivers", to: "0", in: had) == "[SystemSettings]\r\nr.Foo=1\r\nr.WarnOfBadDrivers=0\r\n[Other]\r\nx=1\r\n",
              "an existing value changed in place, its section and line endings kept")
        check(UnrealConfig.settingSystem("r.WarnOfBadDrivers", to: "0", in: "") == "[SystemSettings]\nr.WarnOfBadDrivers=0\n", "a file made when there's none")
        var box = Container(name: "Unreal test", runtimeID: "none")
        box.id = UUID()
        let cfg = box.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/Config/WindowsNoEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try? "[Core.System]\r\nPaths=../../../Engine/Content\r\n".write(to: cfg.appendingPathComponent("Engine.ini"), atomically: true, encoding: .utf8)
        let hog = Game(title: "Hogwarts Legacy", executablePath: launcher.path, containerID: box.id)
        check(UnrealConfig.folder(for: hog, in: box)?.standardizedFileURL.path == cfg.standardizedFileURL.path, "Hogwarts Legacy's config folder found by its project's name (Phoenix)")
        let line = UnrealConfig.prepare(hog, in: box)
        let written = (try? String(contentsOf: cfg.appendingPathComponent("Engine.ini"), encoding: .utf8)) ?? ""
        check(line != nil && written.contains("[SystemSettings]\r\nr.WarnOfBadDrivers=0\r\n") && written.hasPrefix("[Core.System]\r\nPaths="), "written into its Engine.ini: \(line ?? "nothing")")
        check(UnrealConfig.prepare(hog, in: box) == nil, "and left alone at the next start")
        try? "[ScalabilityGroups]\nsg.ShadowQuality=3\nsg.EffectsQuality=2\n".write(to: cfg.appendingPathComponent("GameUserSettings.ini"), atomically: true, encoding: .utf8)
        check(Learn.unrealSettings(for: hog, in: box) == ["sg.ShadowQuality": 3, "sg.EffectsQuality": 2], "and its own quality settings read from beside it")
        try? FileManager.default.removeItem(at: box.prefixURL)

        print(failures == 0 ? "learn: all checks passed" : "learn: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
