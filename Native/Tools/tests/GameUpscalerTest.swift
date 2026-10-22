// A game's own upscaler set in its settings file (0.62, GameUpscaler), on a copy of Hogwarts Legacy's own
// GameUserSettings.ini as it was after its session of 21 October: AMD FSR 3 at Performance (756 × 491 of its
// 1512 × 982 window), its sharpening at 1.0, AMD's frame generation on, film grain on. And its saves found under its
// Unreal project's name ("Phoenix"), which its export of 18 October missed.
//
// It keeps its options a second time, inside SavedUserOptions.sav, and applies them over the ini once it has started
// (22 October: DLSS set in the ini, FSR 3 Performance drawn all session), so both are set.
//
//   CFFIXED_USER_HOME=$T/home HOME=$T/home GameUpscalerTest <its GameUserSettings.ini> <its HogwartsLegacy.exe (the
//     launcher at the top of its folder)> <the Epic Games setup's system.reg> <its SaveGames folder> <its SavedUserOptions.sav>
import Foundation

@main
struct GameUpscalerTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func window(_ rendered: Double, gpu: Int, seconds: Double) -> [FrameWindow] {
        let one = FrameWindow(displayed: rendered, onePercentLow: rendered * 0.8, worstGapMs: 40, rendered: rendered,
                              capacity: rendered, latencyMs: 30, gpuBusy: gpu, topThread: 50)
        return Array(repeating: one, count: max(1, Int((seconds / one.seconds).rounded())))
    }

    @MainActor
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 6 else { print("usage: see header"); exit(2) }
        let fm = FileManager.default
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
        guard !RuntimeManager.support.path.hasPrefix(realHome + "/Library") else { print("refusing: not in a throwaway home"); exit(2) }
        let realIni = URL(fileURLWithPath: a[1]), exe = a[2], realReg = URL(fileURLWithPath: a[3]), realSaves = URL(fileURLWithPath: a[4]), realOptions = URL(fileURLWithPath: a[5])

        var c = Container(name: "Epic Games", runtimeID: "none")
        c.id = UUID()
        let config = c.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/Config/WindowsNoEditor", isDirectory: true)
        try? fm.createDirectory(at: config, withIntermediateDirectories: true)
        let ini = config.appendingPathComponent("GameUserSettings.ini")
        try? fm.copyItem(at: realIni, to: ini)
        let original = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        var game = Game(title: "Hogwarts Legacy", executablePath: exe, containerID: c.id)
        // The flow below is with Anvil's Smooth Motion chosen; the game's own frame generation (Automatic since 0.63)
        // has its own part further on.
        game.gameFrameGen = .anvil

        print("— its options save, read and written")
        guard let real = GameUpscaler.OptionsSave(realOptions) else { check(false, "its SavedUserOptions.sav read"); exit(1) }
        check(real.text.hasPrefix("[/Script/Phoenix.PhoenixGameSettings]\r\n") && real.text.contains("UpscaleMode=") && real.count == real.text.utf8.count,
              "its settings inside it: \(real.count) bytes of GameUserSettings.ini")
        check(real.replacing(text: real.text) == real.data, "written back unchanged, byte for byte")
        let longer = real.text.replacingOccurrences(of: "UpscaleMode=AMD_FSR3_Performance", with: "UpscaleMode=Intel_XeSS_UltraQualityPlus")
        let grown = real.replacing(text: longer).flatMap { GameUpscaler.OptionsSave(url: realOptions, data: $0) }
        check(grown?.text == longer && grown?.data.count == real.data.count + (longer.utf8.count - real.text.utf8.count)
              && grown?.data.suffix(9) == real.data.suffix(9), "a longer value: its size and count follow, and what comes after is unchanged")
        check(GameUpscaler.OptionsSave(url: realOptions, data: Data("GVAS not this".utf8)) == nil
              && GameUpscaler.OptionsSave(url: realOptions, data: real.data.prefix(real.start + 10)) == nil, "anything else, or cut short: not read")
        // In the setup, as the game keeps it: its ini's settings (with the opposite field of view, as on 22 October).
        let saveFolder = c.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/SaveGames/2d99795513544c2cbdc588a08b453ac8", isDirectory: true)
        try? fm.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let options = saveFolder.appendingPathComponent("SavedUserOptions.sav")
        let saveText = original.replacingOccurrences(of: "FieldOfViewOffset=-20.000000", with: "FieldOfViewOffset=20.000000")
        try? real.replacing(text: saveText)?.write(to: options)
        func saved() -> String { GameUpscaler.OptionsSave(options)?.text ?? "" }
        /// As the game changes its settings: in both.
        func inTheGame(_ change: (String) -> String) {
            if let t = try? String(contentsOf: ini, encoding: .utf8) { try? Data(change(t).utf8).write(to: ini) }
            let t = saved()
            try? GameUpscaler.OptionsSave(options)?.replacing(text: change(t))?.write(to: options)
        }
        check(saved() == saveText, "its options save in place")

        print("— the game and its file")
        guard let profile = GameUpscaler.profile(for: game) else { check(false, "Hogwarts Legacy known, by its program under Phoenix/Binaries"); exit(1) }
        check(profile.name == "Hogwarts Legacy", "known by its program: \(profile.name)")
        check(GameUpscaler.profile(for: Game(title: "Notepad", executablePath: "/tmp/notepad.exe", containerID: c.id)) == nil, "another game isn't")
        check(GameUpscaler.settingsFile(for: game, in: c) == ini, "its settings file, under AppData/Local/Phoenix")
        let before = GameUpscaler.inGame(game, in: c)
        check(before?.upscale == "AMD_FSR3_Performance" && before?.brand == .fsr && before?.scale == 0.5 && before?.temporal == true,
              "as the session left it: \(before?.text ?? "-")")
        check(before?.text == "AMD FSR 3 at Performance (756 × 491 of its 1512 × 982 window)", "in words: \(before?.text ?? "-")")
        check(before?.frameGen == "AMD_FFXFI" && before?.sharpen == "1.000000", "AMD's frame generation on, its sharpening at 1.0")
        check(original.contains("\r\n"), "Windows line endings, as the game writes them")

        print("— its first start with 0.62: DLSS, at Balanced on a base M4, nothing done twice")
        let lines = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        lines.forEach { print("     \($0)") }
        let text = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let after = GameUpscaler.read(text, profile: profile)
        check(after.upscale == "DLSS_Balanced" && after.brand == .dlss && after.temporal, "DLSS, run by MetalFX, at Balanced: \(after.text)")
        check(after.text == "DLSS, run by Apple's MetalFX at Balanced (877 × 570 of its 1512 × 982 window)", "in words: \(after.text)")
        check(GameUpscaler.value("bIsUpscaleModeModified", in: profile.section, of: text) == "True", "marked as chosen, so the game keeps it")
        check(after.frameGen == nil && GameUpscaler.value("FrameGeneration", in: profile.section, of: text) == #"(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#,
              "its own frame generation off, as the game writes it")
        check(after.sharpen == "0.200000" && GameUpscaler.value("bIsUpscaleSoftnessModified", in: profile.section, of: text) == "False",
              "its sharpening back at its default")
        let camera = GameUpscaler.value("CameraSettings", in: profile.section, of: text) ?? ""
        check(GameUpscaler.tupleValue("bFilmGrain", in: camera) == "False" && GameUpscaler.tupleValue("bChromaticAberration", in: camera) == "False",
              "film grain and colour fringing off")
        check(GameUpscaler.tupleValue("bMotionBlur", in: camera) == "True" && GameUpscaler.tupleValue("bDepthOfField", in: camera) == "True",
              "the rest of its camera as it was")
        let changed = zip(original.components(separatedBy: "\r\n"), text.components(separatedBy: "\r\n")).filter { $0 != $1 }.map(\.0)
        check(original.components(separatedBy: "\r\n").count == text.components(separatedBy: "\r\n").count && changed.count == 5,
              "five lines changed (it was already marked as chosen), none added or lost: \(changed.map { $0.prefix(24) })")
        check(text.components(separatedBy: "\n").dropLast().allSatisfy { $0.hasSuffix("\r") }, "Windows line endings kept")
        let inSave = GameUpscaler.read(saved(), profile: profile)
        check(inSave.upscale == "DLSS_Balanced" && inSave.frameGen == nil && inSave.sharpen == "0.200000", "the same in its options save, which it applies once started")
        let saveCamera = GameUpscaler.value("CameraSettings", in: profile.section, of: saved()) ?? ""
        check(GameUpscaler.tupleValue("bFilmGrain", in: saveCamera) == "False" && GameUpscaler.tupleValue("FieldOfViewOffset", in: saveCamera) == "20.000000",
              "its film grain off there too, its own field of view kept")
        check(GameUpscaler.inGame(game, in: c)?.upscale == "DLSS_Balanced", "what the game runs with read from its options save")
        check(lines.contains { $0.contains("(it was AMD FSR 3 at Performance") } && lines.contains { $0.contains("frame generation (AMD_FFXFI) off") }
              && lines.contains { $0.contains("sharpening back at its default (0.2, from 1.0)") } && lines.contains { $0.contains("film grain and colour fringing") },
              "each said in the launch log")
        let savedBefore = (try? Data(contentsOf: options)) ?? Data()
        let again = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        check((try? String(contentsOf: ini, encoding: .utf8)) == text && (try? Data(contentsOf: options)) == savedBefore && again.count == 1,
              "the next start: nothing more to change (\(again))")


        print("— changed in the game's own menu")
        inTheGame { $0.replacingOccurrences(of: "UpscaleMode=DLSS_Balanced", with: "UpscaleMode=Intel_XeSS_Performance")
            .replacingOccurrences(of: #"FrameGeneration=(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#,
                                  with: #"FrameGeneration=(Mode=Intel_XeFG,NumFramesInterpolated=1,LocStr="X2")"#)
            .replacingOccurrences(of: "UpscaleSoftness=0.200000", with: "UpscaleSoftness=0.500000") }
        let menu = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let menuSaved = saved()
        let kept = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        kept.forEach { print("     \($0)") }
        check((try? String(contentsOf: ini, encoding: .utf8)) == menu && saved() == menuSaved, "left as set in its menu: upscaler, frame generation and sharpening")
        check(kept.contains { $0.contains("as chosen in its menu since Anvil set DLSS") } && kept.contains { $0.contains("Anvil's frame generation stays off") },
              "and said so")
        check(GameUpscaler.inGame(game, in: c)?.frameGen == "Intel_XeFG", "its own frame generation on: Anvil's stands down at the start (the launch reads this)")
        check(GameUpscaler.record(for: game)?.changedInGame == "Intel_XeSS_Performance", "kept on record as the player's")

        print("— a choice on its page sets it again")
        game.gameUpscaler = .xess
        _ = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        check(GameUpscaler.inGame(game, in: c)?.upscale == "Intel_XeSS_Quality", "XeSS at Balanced's size: its \"Quality\", 1/1.7 of the window")
        game.gameUpscalerQuality = .quality
        _ = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        check(GameUpscaler.inGame(game, in: c)?.upscale == "Intel_XeSS_UltraQuality", "XeSS at Quality's size: its \"Ultra Quality\", 2/3")
        game.gameUpscaler = .automatic; game.gameUpscalerQuality = nil
        _ = GameUpscaler.prepare(game, in: c, dlssReady: false, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        check(GameUpscaler.inGame(game, in: c)?.upscale == "Intel_XeSS_Quality", "Automatic where DLSS can't run: XeSS")
        game.gameUpscaler = .dlss
        let noDLSS = GameUpscaler.prepare(game, in: c, dlssReady: false, anvilFrameGen: true, anvilToDisplay: true, tier: .pro)
        check(GameUpscaler.inGame(game, in: c)?.upscale == "Intel_XeSS_Quality" && noDLSS.contains { $0.contains("doesn't run here") },
              "DLSS chosen where it can't run: the next that does, and said (\(noDLSS.first ?? "-"))")
        game.gameUpscaler = .automatic
        _ = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .pro)
        check(GameUpscaler.inGame(game, in: c)?.upscale == "DLSS_Balanced", "Automatic's quality kept from before, whatever the tier now")

        print("— after a session")
        let reg = c.prefixURL.appendingPathComponent("system.reg")
        try? Data("WINE REGISTRY Version 2\n".utf8).write(to: reg)
        inTheGame { $0.replacingOccurrences(of: "UpscaleMode=DLSS_Balanced", with: "UpscaleMode=AMD_FSR2_Quality") }
        let refused = GameUpscaler.afterSession(game, in: c, play: [])
        check(GameUpscaler.record(for: game)?.unavailable == [.dlss] && refused.first?.contains("DLSS wasn't offered") == true,
              "DLSS set and not kept, with no NVIDIA GPU shown: not offered here (\(refused.first ?? "-"))")
        _ = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        check(GameUpscaler.inGame(game, in: c)?.upscale == "Intel_XeSS_Quality", "so XeSS from the next start")
        // With the setup's own registry, where D3DMetal showed the game an NVIDIA GPU on 21 October.
        try? fm.removeItem(at: reg); try? fm.copyItem(at: realReg, to: reg)
        check(DLSSThroughMetalFX.shownNVIDIA(c), "the Epic Games setup's registry: D3DMetal showed its games an NVIDIA GPU (NGXCore FullPath)")
        try? Data("WINE REGISTRY Version 2\n[Software\\\\Nvidia Corporation\\\\Global\\\\NGXCore] 1\n#time=1\n\n".utf8).write(to: reg)
        check(!DLSSThroughMetalFX.shownNVIDIA(c), "the key with no FullPath in it: not shown")

        print("— Automatic's quality, from how it ran")
        check(GameUpscaler.qualityStep(window(70, gpu: 70, seconds: 120), current: .balanced, anvilFrameGen: true) == nil, "two minutes: too little to go by")
        let up = GameUpscaler.qualityStep(window(70, gpu: 70, seconds: 240), current: .balanced, anvilFrameGen: true)
        check(up?.to == .quality, "70 fps of its own throughout, 45 needed with Smooth Motion: a step sharper — \(up?.why ?? "-")")
        let down = GameUpscaler.qualityStep(window(60, gpu: 60, seconds: 120) + window(33, gpu: 99, seconds: 120), current: .balanced, anvilFrameGen: true)
        check(down?.to == .performance, "held to 33 by the GPU flat out half the time: a step quicker — \(down?.why ?? "-")")
        check(GameUpscaler.qualityStep(window(50, gpu: 99, seconds: 240), current: .balanced, anvilFrameGen: true) == nil, "50 with the GPU flat out: enough, kept")
        check(GameUpscaler.qualityStep(window(55, gpu: 99, seconds: 240), current: .balanced, anvilFrameGen: false)?.to == .performance,
              "55 without frame generation, 72 needed: a step quicker")
        check(GameUpscaler.qualityStep(window(90, gpu: 50, seconds: 240), current: .quality, anvilFrameGen: true) == nil, "already at the sharpest offered: kept")
        check(GameUpscaler.startQuality(.base) == .balanced && GameUpscaler.startQuality(.pro) == .quality && GameUpscaler.startQuality(.entry) == .performance,
              "where it starts by graphics tier")

        print("— a record from 0.62.0's first build")
        // It wrote the ini alone, and the game put its saved options back: that isn't the player's change.
        if var old = GameUpscaler.record(for: game) {
            let wrote = old.wrote
            old.savedOptions = nil; old.changedInGame = "AMD_FSR3_Performance"
            GameUpscaler.save(old, for: game)
            inTheGame { GameUpscaler.setting([("UpscaleMode", "AMD_FSR3_Performance")], in: profile.section, of: $0) }
            let redo = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            check(wrote != nil && GameUpscaler.inGame(game, in: c)?.upscale == wrote && GameUpscaler.record(for: game)?.savedOptions == true
                  && (try? String(contentsOf: ini, encoding: .utf8))?.contains("UpscaleMode=\(wrote ?? "-")") == true,
                  "set again, in both: \(redo.first ?? "-")")
        }

        print("— the game's own frame generation (Automatic, 0.63)")
        do {
            var c2 = Container(name: "Hogwarts", runtimeID: "none")
            c2.id = UUID()
            let config2 = c2.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/Config/WindowsNoEditor", isDirectory: true)
            let save2 = c2.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/SaveGames/2d99795513544c2cbdc588a08b453ac8", isDirectory: true)
            try? fm.createDirectory(at: config2, withIntermediateDirectories: true)
            try? fm.createDirectory(at: save2, withIntermediateDirectories: true)
            let off = original.replacingOccurrences(of: #"FrameGeneration=(Mode=AMD_FFXFI,NumFramesInterpolated=1,LocStr="AMD_FFXFI_MODE_X2")"#,
                                                    with: #"FrameGeneration=(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#)
            let ini2 = config2.appendingPathComponent("GameUserSettings.ini"), opt2 = save2.appendingPathComponent("SavedUserOptions.sav")
            try? Data(off.utf8).write(to: ini2)
            try? real.replacing(text: off)?.write(to: opt2)
            var g2 = Game(title: "Hogwarts Legacy", executablePath: exe, containerID: c2.id)
            check(g2.gameFrameGen == .automatic, "Automatic by default")
            let first = GameUpscaler.prepare(g2, in: c2, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            first.forEach { print("     \($0)") }
            let set = GameUpscaler.inGame(g2, in: c2)
            check(set?.frameGen == "AMD_FFXFI" && set?.upscale == "AMD_FSR3_Balanced",
                  "its own frame generation on, with its FSR 3 — the pair seen working: \(set?.frameGen ?? "-"), \(set?.upscale ?? "-")")
            let iniText = (try? String(contentsOf: ini2, encoding: .utf8)) ?? ""
            check(GameUpscaler.read(iniText, profile: profile).frameGen == "AMD_FFXFI", "in its ini as well as its options save")
            check(first.contains { $0.contains("its own frame generation on — AMD FSR 3's frame generation") }, "and said so")
            // DLSS chosen on its page, and the game won't pair it with DLSS: it turns it off itself.
            g2.gameUpscaler = .dlss
            _ = GameUpscaler.prepare(g2, in: c2, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            check(GameUpscaler.inGame(g2, in: c2)?.upscale == "DLSS_Balanced" && GameUpscaler.inGame(g2, in: c2)?.frameGen == "AMD_FFXFI",
                  "DLSS chosen: DLSS with its own frame generation")
            func game2(_ change: (String) -> String) {
                if let t = try? String(contentsOf: ini2, encoding: .utf8) { try? Data(change(t).utf8).write(to: ini2) }
                if let o = GameUpscaler.OptionsSave(opt2) { try? o.replacing(text: change(o.text))?.write(to: opt2) }
            }
            game2 { $0.replacingOccurrences(of: #"FrameGeneration=(Mode=AMD_FFXFI,NumFramesInterpolated=1,LocStr="AMD_FFXFI_MODE_X2")"#,
                                            with: #"FrameGeneration=(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#) }
            let after = GameUpscaler.afterSession(g2, in: c2, play: [])
            check(GameUpscaler.record(for: g2)?.frameGenRefusedWith == [.dlss] && after.first?.contains("turned off by the game with DLSS") == true,
                  "turned off by the game with DLSS: not paired with it again (\(after.first ?? "-"))")
            let back = GameUpscaler.prepare(g2, in: c2, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            let next = GameUpscaler.inGame(g2, in: c2)
            check(next?.upscale == "AMD_FSR3_Balanced" && next?.frameGen == "AMD_FFXFI"
                  && back.first?.contains("the game doesn't run its own frame generation with DLSS") == true,
                  "so its FSR 3 with it from the next start, and why: \(back.first ?? "-")")
            g2.gameUpscaler = .automatic
            // The player switches it off in its menu: left off, Anvil's Smooth Motion instead.
            game2 { $0.replacingOccurrences(of: #"FrameGeneration=(Mode=AMD_FFXFI,NumFramesInterpolated=1,LocStr="AMD_FFXFI_MODE_X2")"#,
                                            with: #"FrameGeneration=(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#) }
            _ = GameUpscaler.afterSession(g2, in: c2, play: [])
            let leftOff = GameUpscaler.prepare(g2, in: c2, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            check(GameUpscaler.record(for: g2)?.frameGenLeftOff == true && GameUpscaler.inGame(g2, in: c2)?.frameGen == nil
                  && !GameUpscaler.usesGamesFrameGen(g2, profile: profile, record: GameUpscaler.record(for: g2)),
                  "switched off in its menu with its own FSR: left off, Anvil's Smooth Motion instead (\(leftOff.count) lines)")
            // Off on the page: neither.
            g2.gameFrameGen = .off
            game2 { $0.replacingOccurrences(of: #"FrameGeneration=(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#,
                                            with: #"FrameGeneration=(Mode=AMD_FFXFI,NumFramesInterpolated=1,LocStr="AMD_FFXFI_MODE_X2")"#) }
            _ = GameUpscaler.prepare(g2, in: c2, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            check(GameUpscaler.inGame(g2, in: c2)?.frameGen == nil && GameUpscaler.record(for: g2)?.anvilFrameGen == false, "Off: its own off too")
            // A record from 0.62 with a choice "changed in its menu": set up afresh once.
            var old = GameUpscaler.record(for: g2)!
            old.version = nil; old.changedInGame = "AMD_FSR3_Balanced"; old.frameGenLeftOff = nil
            GameUpscaler.save(old, for: g2)
            g2.gameFrameGen = .automatic
            let redo = GameUpscaler.prepare(g2, in: c2, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
            check(redo.contains { $0.contains("set up afresh") } && GameUpscaler.record(for: g2)?.version == GameUpscaler.recordVersion
                  && GameUpscaler.inGame(g2, in: c2)?.frameGen == "AMD_FFXFI", "a 0.62 record: set up afresh once, its own frame generation on")
        }

        print("— a clean picture, and back")
        game.cleanPicture = false
        let back = GameUpscaler.prepare(game, in: c, dlssReady: true, anvilFrameGen: true, anvilToDisplay: true, tier: .base)
        let cam = GameUpscaler.value("CameraSettings", in: profile.section, of: (try? String(contentsOf: ini, encoding: .utf8)) ?? "") ?? ""
        let camSaved = GameUpscaler.value("CameraSettings", in: profile.section, of: saved()) ?? ""
        check(GameUpscaler.tupleValue("bFilmGrain", in: cam) == "True" && GameUpscaler.tupleValue("bChromaticAberration", in: cam) == "True"
              && GameUpscaler.tupleValue("bFilmGrain", in: camSaved) == "True" && GameUpscaler.tupleValue("FieldOfViewOffset", in: camSaved) == "20.000000"
              && back.contains { $0.contains("as the game had them") }, "off: film grain and colour fringing as the game had them, in both")

        print("— the file's own format")
        let small = "[A]\r\nx=1\r\n\r\n[B]\r\ny=2\r\n"
        check(GameUpscaler.setting([("x", "3"), ("z", "4")], in: "[A]", of: small) == "[A]\r\nx=3\r\nz=4\r\n\r\n[B]\r\ny=2\r\n", "a key changed and one added, in its section")
        check(GameUpscaler.setting([("q", "1")], in: "[C]", of: "[A]\nx=1\n") == "[A]\nx=1\n\n[C]\nq=1\n", "a section that isn't there, added")
        check(GameUpscaler.value("y", in: "[A]", of: small) == nil && GameUpscaler.value("y", in: "[B]", of: small) == "2", "a key read in its own section only")

        print("— its saves, under its Unreal project's name")
        let saves = c.driveC.appendingPathComponent("users/crossover/AppData/Local/Phoenix/Saved/SaveGames", isDirectory: true)
        try? fm.copyItem(at: realSaves, to: saves)
        check(GameSaves.unrealProject(of: game) == "Phoenix", "its project: \(GameSaves.unrealProject(of: game) ?? "-")")
        let places = GameSaves.places(for: game, in: c, aloneInContainer: false)
        check(places.map(\.relativePath) == ["AppData/Local/Phoenix"], "found in a setup it shares: \(places.map(\.relativePath))")
        let lego = Game(title: "LEGO® Star Wars™: The Skywalker Saga", executablePath: "/x/LEGOSTARWARSSKYWALKERSAGA_DX11.exe", containerID: c.id)
        let theirs = [GameSaves.Place(relativePath: "AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga", bytes: 1),
                      GameSaves.Place(relativePath: "AppData/Local/Phoenix", bytes: 1),
                      GameSaves.Place(relativePath: "AppData/Local/Microsoft", bytes: 1)]
        check(GameSaves.toRestore(theirs, for: lego, others: [game]).map(\.relativePath) == [theirs[0].relativePath],
              "LEGO's export with Hogwarts' folder in it: only LEGO's put back")
        let unnamed = [GameSaves.Place(relativePath: "AppData/Local/Phoenix", bytes: 1), GameSaves.Place(relativePath: "AppData/Local/SomeStudio", bytes: 1)]
        let other = Game(title: "Cat Quest II", executablePath: "/x/Cat Quest II.exe", containerID: c.id)
        check(GameSaves.toRestore(unnamed, for: other, others: [game]).map(\.relativePath) == ["AppData/Local/SomeStudio"],
              "an export of none named for the game: everything but another game's")

        print("— what's in the way, set aside under a name of its own")
        let spot = c.driveC.appendingPathComponent("users/crossover/AppData/Local/Spot", isDirectory: true)
        try? fm.createDirectory(at: spot, withIntermediateDirectories: true)
        let first = GameSaves.aside(for: spot)
        try? fm.moveItem(at: spot, to: first)
        try? fm.createDirectory(at: spot, withIntermediateDirectories: true)
        let second = GameSaves.aside(for: spot)
        check(first.lastPathComponent.hasPrefix("Spot.anvil-replaced-") && second != first
              && (second.lastPathComponent.hasSuffix("-2") || second.lastPathComponent != first.lastPathComponent),
              "two in the same second don't collide: \(first.lastPathComponent), \(second.lastPathComponent)")
        check((try? fm.moveItem(at: spot, to: second)) != nil, "and the second moves aside too")

        print(failures == 0 ? "game upscaler: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
