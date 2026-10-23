import Foundation

/// A game's own upscaler — NVIDIA's DLSS, Intel's XeSS or AMD's FSR, built into the game — chosen in Anvil and set in
/// the game's settings file before it starts, for a game whose file Anvil knows how to write (`profiles`).
///
/// Hogwarts Legacy on 21 October drew 756 × 491: its own FSR 3 at Performance, half its 1512 × 982 window each way,
/// with its sharpening at the top of its slider and its own frame generation on as well as Anvil's. Anvil's FSR 1 then
/// stretched that to the display's 3024 × 1964 and sharpened it again at full strength, with every texture sampled a mip
/// level sharper on top of what the game's FSR had already asked for. Its edges came out grainy. It has two AI
/// upscalers that run on this Mac. DLSS, which D3DMetal 3.0 answers with Apple's MetalFX temporal upscaler: the game
/// loaded D3DMetal's nvngx.dll and was shown an NVIDIA GPU (the registry key D3DMetal writes when it finds that file).
/// And Intel's XeSS, which runs on any GPU: the game loaded libxess and offered XeSS frame generation.
///
/// So for a game it knows, Anvil sets the upscaler — Automatic: DLSS where D3DMetal can run it, else XeSS, else the
/// game's FSR — and its quality, how much of its window the game draws before the upscaler fills in the rest, chosen
/// from how the game ran here. And so nothing is done twice: the game's frame generation off while Anvil's is on, its
/// sharpening back at its default while Anvil's FSR sharpens the picture to the display, and its film grain and colour
/// fringing off — grain is noise the upscalers turn into crawling specks. Anything changed in the game's own menu
/// afterwards stays as set there, until a choice on its page changes.
enum GameUpscaler {
    /// One of a game's own upscalers.
    enum Brand: String, Codable, CaseIterable, Identifiable {
        case dlss, xess, fsr
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dlss: "DLSS, run by Apple's MetalFX"
            case .xess: "Intel XeSS"
            case .fsr: "AMD FSR 3"
            }
        }
        var short: String {
            switch self {
            case .dlss: "DLSS"
            case .xess: "XeSS"
            case .fsr: "FSR 3"
            }
        }
    }

    /// The player's choice, kept on the game (Game.gameUpscaler).
    enum Choice: String, Codable, CaseIterable, Identifiable {
        case automatic, dlss, xess, fsr, asInGame
        var id: String { rawValue }
        var brand: Brand? {
            switch self {
            case .dlss: .dlss
            case .xess: .xess
            case .fsr: .fsr
            case .automatic, .asInGame: nil
            }
        }
    }

    /// Which frame generation a game whose settings Anvil knows runs with (Game.gameFrameGen).
    ///
    /// Automatic is the game's own where it has one: made from its own motion vectors and depth, as Anvil's can't
    /// be. Hogwarts Legacy on 22 October, Ultra on a base M4: 67 fps on average with AMD FSR 3's frame generation and
    /// Anvil only taking the picture to the display (1.3 ms of the GPU a frame), its FSR 3 at Performance; 48 with
    /// Anvil's Smooth Motion and DLSS at Performance, whose FSR 3 and frames between took 5–8 ms of every frame.
    enum FrameGen: String, Codable, CaseIterable, Identifiable {
        case automatic, anvil, off
        var id: String { rawValue }
    }

    /// How a game's own quality settings are kept, for a game whose settings Anvil knows (Game.gameGraphics).
    ///
    /// For an even 80: after each session that held 80 fps or more less than 80% of the time, the setting that costs
    /// the most frame time for the least to see goes a step lower — never below High, its textures never — and after
    /// one with plenty to spare the last one lowered goes back up. As set: exactly as in the game's menu.
    enum Graphics: String, Codable, CaseIterable, Identifiable {
        case automatic, asSet
        var id: String { rawValue }
    }

    /// A game's own ray-traced effects, for a game whose settings Anvil knows (Game.gameRayTracing).
    ///
    /// Traced by the GPU's ray-tracing hardware (M3 and later), which D3DMetal hands the game's DirectX ray tracing to.
    /// With DLSS as its upscaler, NVIDIA's Ray Reconstruction — DLSS's own denoiser, which D3DMetal 3.0 runs as Apple's
    /// MetalFX denoiser (MTLFXTemporalDenoisedScaler, read out of the framework) — cleans what a few rays a pixel
    /// leave grainy; with FSR or XeSS, the game's own denoisers. Automatic leaves them as set in the game's menu, and
    /// turns its reflections on only after a session with plenty to spare at an even 80 — off again first when one
    /// falls short.
    enum RayTracing: String, Codable, CaseIterable, Identifiable {
        case automatic, reflections, all, off
        var id: String { rawValue }
        /// The effects it turns on; nil for as in the game's menu.
        var effects: [String]? {
            switch self {
            case .automatic: nil
            case .reflections: ["reflections"]
            case .all: ["reflections", "shadows", "ao"]
            case .off: []
            }
        }
    }

    /// The qualities offered: how much of its window each way the game draws before its upscaler fills it in.
    static let qualities: [UpscaleQuality] = [.quality, .balanced, .performance]

    /// A game's settings file, as Anvil writes it.
    struct Profile {
        let name: String
        /// Its program, <project>/Binaries/Win64/<program>.
        let project: String
        let program: String
        /// The section of GameUserSettings.ini its own settings are in.
        let section: String
        let upscaleKey: String
        let upscaleModifiedKey: String
        /// Each upscaler's values by how much of the window each way they draw. XeSS since 1.3 names them a step apart
        /// from the others: its "Quality" draws 1/1.7 of the window, as DLSS's and FSR's Balanced do.
        let modes: [Brand: [(scale: Double, value: String)]]
        /// The anti-aliasing key, and its values that are a temporal upscaler at the window's own size.
        let antiAliasingKey: String
        let frameGenKey: String
        let frameGenOff: String
        /// The game's sharpening of its upscaler's picture, 0…1 — "UpscaleSoftness" in Hogwarts Legacy's file is its
        /// menu's "Upscale Sharpness" — and its default.
        let sharpenKey: String
        let sharpenModifiedKey: String
        let sharpenDefault: String
        /// The camera's picture effects, in one tuple (CameraSettings=(…,bFilmGrain=True,…)), and the ones a clean
        /// picture turns off.
        let cameraKey: String
        let cleanOff: [String]
        let widthKey: String
        let heightKey: String
        /// Its options kept again in a save in its SaveGames folder, which it applies over the ini (`OptionsSave`).
        let optionsSave: String?
        /// Its own frame generation, as it writes it on, and in words.
        let ownFrameGen: String?
        let ownFrameGenTitle: String
        /// Its quality groups (Unreal's [ScalabilityGroups]) in the order an even 80 lowers them — the most frame time
        /// for the least to see first — and the lowest any goes (2, High). Textures cost memory, not frame time; view
        /// distance, shading and the sky are what the picture is made of: none of those is on the list.
        let scalability: [String]
        let scalabilityFloor: Int
        /// Its ray-traced effects' switches in its section, by effect ("reflections", "shadows", "ao"); its quality
        /// groups for them; and its switch for NVIDIA's Ray Reconstruction.
        var rayTracingSwitches: [(effect: String, key: String)] = []
        var rayTracingGroups: [String] = []
        var rayReconstructionKey: String? = nil

        func value(_ brand: Brand, _ quality: UpscaleQuality) -> String? {
            modes[brand]?.min { abs($0.scale - quality.renderScale) < abs($1.scale - quality.renderScale) }?.value
        }

        /// The upscaler a value is, and how much of the window it draws.
        func reading(_ value: String) -> (brand: Brand, scale: Double)? {
            for (brand, list) in modes { if let m = list.first(where: { $0.value == value }) { return (brand, m.scale) } }
            return nil
        }
    }

    /// Hogwarts Legacy (Unreal Engine 4.27, project "Phoenix"): its values as its program names them (EUpscaleMode,
    /// EFrameGenerationMode), and its frame generation off as the game itself writes it.
    static let hogwarts = Profile(
        name: "Hogwarts Legacy", project: "Phoenix", program: "hogwartslegacy.exe",
        section: "[/Script/Phoenix.PhoenixGameSettings]",
        upscaleKey: "UpscaleMode", upscaleModifiedKey: "bIsUpscaleModeModified",
        modes: [
            .dlss: [(0.667, "DLSS_Quality"), (0.58, "DLSS_Balanced"), (0.5, "DLSS_Performance"), (0.333, "DLSS_UltraPerformance")],
            .xess: [(0.769, "Intel_XeSS_UltraQualityPlus"), (0.667, "Intel_XeSS_UltraQuality"), (0.588, "Intel_XeSS_Quality"),
                    (0.5, "Intel_XeSS_Balanced"), (0.435, "Intel_XeSS_Performance"), (0.333, "Intel_XeSS_UltraPerformance")],
            .fsr: [(0.667, "AMD_FSR3_Quality"), (0.588, "AMD_FSR3_Balanced"), (0.5, "AMD_FSR3_Performance"), (0.333, "AMD_FSR3_UltraPerformance"),
                   (0.667, "AMD_FSR2_Quality"), (0.588, "AMD_FSR2_Balanced"), (0.5, "AMD_FSR2_Performance"), (0.333, "AMD_FSR2_UltraPerformance")],
        ],
        antiAliasingKey: "AntiAliasingMode",
        frameGenKey: "FrameGeneration", frameGenOff: #"(Mode=Off,NumFramesInterpolated=0,LocStr="Off")"#,
        sharpenKey: "UpscaleSoftness", sharpenModifiedKey: "bIsUpscaleSoftnessModified", sharpenDefault: "0.200000",
        cameraKey: "CameraSettings", cleanOff: ["bFilmGrain", "bChromaticAberration"],
        widthKey: "ResolutionSizeX", heightKey: "ResolutionSizeY", optionsSave: "SavedUserOptions.sav",
        ownFrameGen: #"(Mode=AMD_FFXFI,NumFramesInterpolated=1,LocStr="AMD_FFXFI_MODE_X2")"#,
        ownFrameGenTitle: "AMD FSR 3's frame generation",
        // Effects first: Learn measured it at 2.1–2.5 ms a frame at Ultra on a base M4 (22 October); then the fog and
        // light shafts, shadows, foliage (1.0–1.3 ms), and post-processing.
        scalability: ["sg.EffectsQuality", "sg.VolumetricsQuality", "sg.ShadowQuality", "sg.FoliageQuality", "sg.PostProcessQuality"],
        scalabilityFloor: 2,
        // As its program names them (bInEnableRaytracingReflections…, SetNvidiaRayReconstruction).
        rayTracingSwitches: [("reflections", "bEnableRaytracingReflections"), ("shadows", "bEnableRaytracingShadows"),
                             ("ao", "bEnableRaytracingAO")],
        rayTracingGroups: ["sg.RaytracingQuality", "sg.RaytracingReflectionsQuality", "sg.RaytracingShadowsQuality"],
        rayReconstructionKey: "NvidiaRayReconstruction")

    static let profiles: [Profile] = [hogwarts]

    /// The profile for a game: its drawing program, by name and project.
    static func profile(for game: Game) -> Profile? {
        let program = GameAnalysis.drawingProgram(for: game.executableURL)
        let comps = program.pathComponents
        return profiles.first { p in
            program.lastPathComponent.lowercased() == p.program && comps.contains { $0.caseInsensitiveCompare(p.project) == .orderedSame }
        }
    }

    /// Its GameUserSettings.ini in the container, once the game has written one at its first start.
    static func settingsFile(for game: Game, in container: Container) -> URL? {
        guard let folder = UnrealConfig.folder(for: game, in: container) else { return nil }
        let ini = folder.appendingPathComponent("GameUserSettings.ini")
        return FileManager.default.fileExists(atPath: ini.path) ? ini : nil
    }

    // MARK: What the game's file says

    struct InGame: Equatable {
        var upscale: String?
        var brand: Brand?
        /// How much of its window each way it draws, with its upscaler.
        var scale: Double?
        /// A temporal upscaler, or DLAA: the game blends its frames over time itself.
        var temporal: Bool
        /// Its own frame generation, by the name in its file ("AMD_FFXFI"), when on.
        var frameGen: String?
        var width: Int?
        var height: Int?
        var sharpen: String?
        /// Its ray-traced effects switched on ("reflections"…), and Ray Reconstruction.
        var rayTraced: [String] = []
        var rayReconstruction = false

        /// "DLSS, run by Apple's MetalFX at Balanced (877 × 570 of its 1512 × 982 window)".
        var text: String {
            guard let upscale else { return "no upscaler" }
            let what = brand.map { "\($0.title) at \(GameUpscaler.qualityName(scale ?? 1))" } ?? upscale
            if let scale, let width, let height {
                return what + " (\(Int((Double(width) * scale).rounded())) × \(Int((Double(height) * scale).rounded())) of its \(width) × \(height) window)"
            }
            return what
        }
    }

    static func qualityName(_ scale: Double) -> String {
        let q = UpscaleQuality.allCases.min { abs($0.renderScale - scale) < abs($1.renderScale - scale) } ?? .balanced
        return q.title
    }

    static func read(_ text: String, profile: Profile) -> InGame {
        let upscale = value(profile.upscaleKey, in: profile.section, of: text)
        let reading = upscale.flatMap(profile.reading)
        let aa = value(profile.antiAliasingKey, in: profile.section, of: text) ?? ""
        let fg = value(profile.frameGenKey, in: profile.section, of: text).flatMap { v -> String? in
            guard let r = v.range(of: "Mode=") else { return nil }
            let mode = v[r.upperBound...].prefix { $0 != "," && $0 != ")" }
            return mode == "Off" || mode.isEmpty ? nil : String(mode)
        }
        return InGame(upscale: upscale, brand: reading?.brand, scale: reading?.scale,
                      temporal: reading != nil || aa.lowercased().contains("dlaa"),
                      frameGen: fg,
                      width: value(profile.widthKey, in: profile.section, of: text).flatMap { Int($0) },
                      height: value(profile.heightKey, in: profile.section, of: text).flatMap { Int($0) },
                      sharpen: value(profile.sharpenKey, in: profile.section, of: text),
                      rayTraced: profile.rayTracingSwitches.filter { value($0.key, in: profile.section, of: text) == "True" }.map(\.effect),
                      rayReconstruction: profile.rayReconstructionKey.map { value($0, in: profile.section, of: text) == "True" } ?? false)
    }

    /// Its ray-traced effects that run at a start, as Learn's parts ("raytraced:reflections"): those switched on in its
    /// settings, when D3DMetal offers it ray tracing (`dxr`).
    static func rayTracedParts(_ game: Game, in container: Container, dxr: Bool) -> [String] {
        guard dxr, let now = inGame(game, in: container) else { return [] }
        return now.rayTraced.map { Learn.rayTracedPrefix + $0 }
    }

    static func effectNames(_ effects: [String]) -> String {
        let names = effects.map { e -> String in
            switch e {
            case "reflections": "reflections"
            case "shadows": "shadows"
            case "ao": "ambient occlusion"
            default: e
            }
        }
        switch names.count {
        case 0: return "none"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// What the game's file says now, for a game Anvil knows: read by a start's environment.
    /// From its options save where it keeps one: that's what it applies once it has started.
    static func inGame(_ game: Game, in container: Container) -> InGame? {
        guard let profile = profile(for: game), let file = settingsFile(for: game, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let save = optionsSaves(for: game, in: container, profile: profile).lazy.compactMap { OptionsSave($0) }.first
        return read(save?.text ?? text, profile: profile)
    }

    // MARK: Kept

    /// What Anvil set, and what it has seen since.
    struct Record: Codable, Equatable {
        /// The upscaler value Anvil last wrote; nil when it left the game's.
        var wrote: String?
        var choice: Choice
        /// As chosen on the page; nil for Automatic.
        var quality: UpscaleQuality?
        /// Where Automatic's quality has got to for this game on this Mac.
        var autoQuality: UpscaleQuality
        var at: Date
        /// Set in the game's own menu since Anvil set it: what it says there. Left as it is until a choice changes.
        var changedInGame: String?
        /// Upscalers found not to run here (DLSS when D3DMetal didn't show the game an NVIDIA GPU).
        var unavailable: [Brand] = []
        /// Anvil turned the game's frame generation off, its sharpening to its default: changed in its menu after
        /// that, they're the player's.
        var frameGenOffByAnvil = false
        var sharpenByAnvil = false
        /// The camera effects as the game had them before a clean picture turned them off, to put back.
        var cameraBefore: [String: String] = [:]
        /// Anvil's frame generation was on for the start: what the game needs of its own to look smooth.
        var anvilFrameGen = true
        /// What the last session showed, for the game's page.
        var note: String?
        /// Its options save written along with its ini (nil in records from before Anvil knew of it).
        var savedOptions: Bool? = nil
        /// What the record is from: 2 since 0.63, when the game's own frame generation became Automatic's. One from
        /// before is started over once.
        var version: Int? = nil
        /// Anvil switched the game's own frame generation on; the player switched it off again in its menu; the
        /// upscalers the game didn't keep it with (it turns its frame generation off with one it can't pair it with).
        var frameGenOnByAnvil: Bool? = nil
        var frameGenLeftOff: Bool? = nil
        var frameGenRefusedWith: [Brand]? = nil
        /// Quality groups lowered for an even 80, in the order lowered; what Anvil set each to; the player's own before.
        var lowered: [String]? = nil
        var graphicsSet: [String: Int]? = nil
        var graphicsBefore: [String: Int]? = nil
        /// Decided after a session, written at the next start: then what was set before tells a change in its menu.
        var graphicsNext: [String: Int]? = nil
        /// Its ray-traced effects as Anvil last switched them (by key), for which choice; switched in its menu since,
        /// they're the player's until the choice changes. Automatic's even 80 turned its reflections on.
        var rayTracingWrote: [String: Bool]? = nil
        var rayTracingChoice: RayTracing? = nil
        var rayTracingByAnvil: Bool? = nil
        var rayTracingLeft: Bool? = nil
    }

    /// 3 since 0.64: a record of 2 stepped Automatic's quality up from frames the game made between its own, counted
    /// as its own — Hogwarts Legacy to Balanced on 22 October from "61 fps of its own", 30 of them made.
    static let recordVersion = 3

    static let scalabilitySection = "[ScalabilityGroups]"

    /// What the game will run with, as text: its options save where it keeps one, else its ini.
    static func gameText(_ game: Game, in container: Container, profile: Profile) -> String? {
        if let save = optionsSaves(for: game, in: container, profile: profile).lazy.compactMap({ OptionsSave($0) }).first { return save.text }
        guard let file = settingsFile(for: game, in: container) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    static func groupName(_ key: String) -> String {
        switch key {
        case "sg.EffectsQuality": "Effects"
        case "sg.VolumetricsQuality": "Fog and light shafts"
        case "sg.ShadowQuality": "Shadows"
        case "sg.FoliageQuality": "Foliage"
        case "sg.PostProcessQuality": "Post-processing"
        default: key.replacingOccurrences(of: "sg.", with: "").replacingOccurrences(of: "Quality", with: "")
        }
    }

    static func levelName(_ v: Int) -> String {
        switch v {
        case ...0: "Low"
        case 1: "Medium"
        case 2: "High"
        default: "Ultra"
        }
    }

    nonisolated(unsafe) static var directory: URL = RuntimeManager.support.appendingPathComponent("GameUpscaler", isDirectory: true)

    static func record(for game: Game) -> Record? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(game.id.uuidString).json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    static func save(_ record: Record, for game: Game) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            DiskCache.writeReplacing(data, to: directory.appendingPathComponent("\(game.id.uuidString).json"))
        }
    }

    // MARK: Choosing

    /// Which of its own upscalers the game has, from its Graphics Scan (or, not scanned yet, the profile's), and which
    /// this start can run: DLSS only through D3DMetal's MetalFX.
    static func available(for game: Game, profile: Profile, dlssReady: Bool) -> [Brand] {
        let kinds = GraphicsScan.stored(gameID: game.id).map { Set($0.builtins.map(\.kind)) }
        func has(_ b: Brand) -> Bool {
            guard profile.modes[b] != nil else { return false }
            guard let kinds else { return true }
            switch b {
            case .dlss: return kinds.contains(.dlss)
            case .xess: return kinds.contains(.xess)
            case .fsr: return !kinds.isDisjoint(with: [.fsr2, .fsr3, .fsr31, .fsr4])
            }
        }
        return Brand.allCases.filter { has($0) && ($0 != .dlss || dlssReady) }
    }

    /// The upscaler a start sets: the chosen one where it runs here, else the next of DLSS, XeSS, FSR that does.
    ///
    /// With the game's own frame generation, its FSR first: the pair seen working together (Hogwarts Legacy, 22
    /// October: AMD's frame generation with its FSR 3), then DLSS, then XeSS — Intel's network takes more of an Apple
    /// GPU's time. And not an upscaler the game wouldn't keep its frame generation with.
    static func resolve(_ choice: Choice, available: [Brand], unavailable: [Brand], gamesFrameGen: Bool = false,
                        frameGenRefusedWith: [Brand] = []) -> Brand? {
        var usable = available.filter { !unavailable.contains($0) }
        if gamesFrameGen, usable.contains(where: { !frameGenRefusedWith.contains($0) }) {
            usable = usable.filter { !frameGenRefusedWith.contains($0) }
        }
        if let wanted = choice.brand, usable.contains(wanted) { return wanted }
        return (gamesFrameGen ? [Brand.fsr, .dlss, .xess] : [Brand.dlss, .xess, .fsr]).first { usable.contains($0) }
    }

    /// Whether a start runs the game's own frame generation: chosen (Automatic, where it has one), not switched off in
    /// its menu since Anvil switched it on.
    static func usesGamesFrameGen(_ game: Game, profile: Profile, record: Record?) -> Bool {
        profile.ownFrameGen != nil && game.gameFrameGen == .automatic && record?.frameGenLeftOff != true
    }

    /// Where Automatic starts on a Mac: Balanced on standard graphics (a base M4) — 0.58 of the window each way, about
    /// 1.35 times the pixels Hogwarts Legacy drew at Performance — Quality on Pro and up, Performance on entry-level.
    static func startQuality(_ tier: DeviceProfile.Tier?) -> UpscaleQuality {
        switch tier {
        case .entry?: .performance
        case .pro?, .max?, .ultra?: .quality
        case .base?, nil: .balanced
        }
    }

    // MARK: Before a start

    /// The game's own upscaler as chosen, and nothing done twice, set in its settings before it starts — in its
    /// GameUserSettings.ini and, for a game that keeps its options in a save too, there as well (`OptionsSave`). The
    /// launch log's lines; none for a game Anvil doesn't know, or that hasn't written its settings yet.
    static func prepare(_ game: Game, in container: Container, dlssReady: Bool, anvilFrameGen: Bool, anvilToDisplay: Bool,
                        tier: DeviceProfile.Tier?, dxr: Bool = false) -> [String] {
        guard let profile = profile(for: game), let file = settingsFile(for: game, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let saves = optionsSaves(for: game, in: container, profile: profile).compactMap { OptionsSave($0) }
        // What the game will run with: its options save, which it applies over the ini once it has started.
        let source = saves.first?.text ?? text
        let now = read(source, profile: profile)
        var record = record(for: game)
        // A record from before Anvil wrote the options save too (0.62.0's first build): what it saw changed was the
        // game putting its saved options back, not the player — started over.
        if !saves.isEmpty, record != nil, record?.savedOptions != true {
            record?.wrote = nil
            record?.changedInGame = nil
            record?.frameGenOffByAnvil = false
            record?.sharpenByAnvil = false
        }
        // A record from before 0.63, when the game's own frame generation became Automatic's: set up again once, as
        // the player asked on 22 October ("I need real frame gen working … stable 80"). What they had changed in its
        // menu since was trying for the same.
        var fresh = false
        var requalified = false
        if let r = record, (r.version ?? 0) < 2 {
            record?.wrote = nil
            record?.changedInGame = nil
            record?.frameGenOffByAnvil = false
            record?.sharpenByAnvil = false
            record?.version = recordVersion
            fresh = true
        } else if let r = record, (r.version ?? 0) < recordVersion {
            // Quality stepped up from the game's made frames counted as its own: back to where it was measured from.
            if r.frameGenOnByAnvil == true, r.autoQuality == .balanced {
                record?.autoQuality = .performance
                requalified = true
            }
            record?.version = recordVersion
        }
        let gamesFG = usesGamesFrameGen(game, profile: profile, record: record)
        var keys: [(String, String)] = []
        var tupleKeys: [String: String] = [:]
        var lines: [String] = []
        let choice = game.gameUpscaler
        let sameChoice = record.map { $0.choice == choice && $0.quality == game.gameUpscalerQuality } ?? false
        // The upscaler that runs this start: what Anvil sets, else what's in its menu (Ray Reconstruction needs DLSS).
        var runs = now.brand

        // The upscaler.
        if choice == .asInGame {
            lines.append("its own upscaler: \(now.text), as set in its menu")
        } else if sameChoice, let r = record, let wrote = r.wrote, now.upscale != wrote || r.changedInGame != nil {
            // Changed in the game's menu since Anvil set it: the player's.
            record?.changedInGame = now.upscale ?? "none"
            lines.append("its own upscaler: \(now.text), as chosen in its menu since Anvil set \(profile.reading(wrote)?.brand.short ?? wrote) — left as it is; choosing on its page sets it again")
        } else {
            let brands = available(for: game, profile: profile, dlssReady: dlssReady)
            if let brand = resolve(choice, available: brands, unavailable: record?.unavailable ?? [], gamesFrameGen: gamesFG,
                                   frameGenRefusedWith: record?.frameGenRefusedWith ?? []) {
                let auto = record?.autoQuality ?? startQuality(tier)
                let quality = game.gameUpscalerQuality ?? auto
                if let value = profile.value(brand, quality) {
                    runs = brand
                    if now.upscale != value { keys += [(profile.upscaleKey, value), (profile.upscaleModifiedKey, "True")] }
                    let set = read(setting([(profile.upscaleKey, value)], in: profile.section, of: source), profile: profile)
                    var line = "its own upscaler: \(set.text)"
                    if game.gameUpscalerQuality == nil { line += ", the quality Anvil found for it here" }
                    if let wanted = choice.brand, wanted != brand {
                        line += (record?.frameGenRefusedWith ?? []).contains(wanted) && gamesFG
                            ? " — the game doesn't run its own frame generation with \(wanted.short)"
                            : " — \(wanted.title) doesn't run here"
                    }
                    if now.upscale != value, now.upscale != nil { line += " (it was \(now.text))" }
                    lines.append(line)
                    // Updated in place: everything else it holds (what's lowered for an even 80, its frame generation,
                    // its camera as it was) carries on.
                    var updated = record ?? Record(wrote: nil, choice: choice, quality: game.gameUpscalerQuality, autoQuality: auto,
                                                   at: Date(), version: recordVersion)
                    updated.wrote = value
                    updated.choice = choice
                    updated.quality = game.gameUpscalerQuality
                    updated.autoQuality = auto
                    updated.at = Date()
                    updated.changedInGame = nil
                    updated.anvilFrameGen = anvilFrameGen
                    updated.version = recordVersion
                    record = updated
                }
            } else {
                lines.append("its own upscaler: \(now.text) — none of DLSS, XeSS or FSR it has runs here")
            }
        }

        var r = record ?? Record(wrote: nil, choice: choice, quality: game.gameUpscalerQuality,
                                 autoQuality: startQuality(tier), at: Date(), version: recordVersion)
        if !saves.isEmpty { r.savedOptions = true }
        if fresh { lines.append("set up afresh for 0.63 — the game's own frame generation, from its motion vectors, is Automatic's now") }
        if requalified { lines.append("quality back to Performance — its step to Balanced came from counting the frames the game made between its own as its own") }

        // Its own frame generation, Automatic's where it has one: made from the game's own motion vectors and depth.
        // Anvil's Smooth Motion stands down (the launch reads the file), and Anvil only takes the picture to the display.
        if gamesFG, let ownFG = profile.ownFrameGen {
            r.anvilFrameGen = true
            if now.frameGen == nil {
                keys.append((profile.frameGenKey, ownFG))
                r.frameGenOnByAnvil = true
                r.frameGenOffByAnvil = false
                lines.append("its own frame generation on — \(profile.ownFrameGenTitle), made from the game's own motion vectors and depth, a frame between each two of its own; Anvil's Smooth Motion stands down and Anvil only takes the picture to the display")
            } else if let fg = now.frameGen {
                lines.append("its own frame generation (\(fg)) on, made from the game's own motion vectors and depth; Anvil's Smooth Motion stands down")
            }
        } else if game.gameFrameGen == .off {
            r.anvilFrameGen = false
            if let fg = now.frameGen {
                keys.append((profile.frameGenKey, profile.frameGenOff))
                lines.append("its own frame generation (\(fg)) off, and Anvil's — frame generation off, as chosen on its page")
            }
        } else {
            r.anvilFrameGen = anvilFrameGen
        }

        // Its frame generation under Anvil's Smooth Motion: never on top of it — frames made from frames it made
        // itself warp. Turned on in its menu after Anvil turned it off, it's the player's: Anvil's stands down for
        // that start instead.
        if !gamesFG, game.gameFrameGen != .off, let fg = now.frameGen, anvilFrameGen {
            if r.frameGenOffByAnvil {
                lines.append("its own frame generation (\(fg)) switched on in its menu — Anvil's frame generation stays off for this start, so no frame is made from a made frame")
            } else {
                keys.append((profile.frameGenKey, profile.frameGenOff))
                r.frameGenOffByAnvil = true
                lines.append("its own frame generation (\(fg)) off — Anvil's makes the frames between, from the game's own; both at once make frames from made frames")
            }
        }

        // Its sharpening, back at its default once while Anvil's FSR sharpens the picture to the display. Hogwarts
        // Legacy's was at the top of its slider (1.0 against 0.2) under Anvil's own at full strength.
        if anvilToDisplay, !r.sharpenByAnvil, let s = now.sharpen, let v = Double(s), let d = Double(profile.sharpenDefault), v > d + 0.01 {
            keys += [(profile.sharpenKey, profile.sharpenDefault), (profile.sharpenModifiedKey, "False")]
            r.sharpenByAnvil = true
            lines.append(String(format: "its own sharpening back at its default (%.1f, from %.1f) — Anvil's FSR sharpens the picture to the display, and twice over is what makes edges grainy", d, v))
        }

        // A clean picture: film grain and colour fringing off while it's chosen; as the game had them when it isn't.
        // Set field by field in each copy's own tuple, which can differ (Hogwarts Legacy's ini and save had opposite
        // fields of view on 22 October).
        if let tuple = value(profile.cameraKey, in: profile.section, of: source) {
            if game.cleanPicture {
                var off: [String] = []
                for key in profile.cleanOff {
                    if let current = tupleValue(key, in: tuple), current != "False" {
                        if r.cameraBefore[key] == nil { r.cameraBefore[key] = current }
                        tupleKeys[key] = "False"
                        off.append(key)
                    }
                }
                if !off.isEmpty {
                    lines.append("clean picture: \(off.map(cleanWords).joined(separator: " and ")) off — the upscaler turns grain into specks that crawl")
                }
            } else if !r.cameraBefore.isEmpty {
                tupleKeys = r.cameraBefore
                lines.append("clean picture off: \(r.cameraBefore.keys.sorted().map(cleanWords).joined(separator: " and ")) as the game had them")
                r.cameraBefore = [:]
            }
        }

        // Its quality groups, for an even 80: the ones lowered, kept lowered — unless changed in its menu since, then
        // the player's; as set, the player's own back.
        var groupKeys: [(String, String)] = []
        let groups = Learn.scalability(in: source)
        if let lowered = r.lowered, !lowered.isEmpty {
            if game.gameGraphics == .automatic {
                var kept: [String] = []
                var said: [String] = []
                let next = r.graphicsNext ?? [:]
                r.graphicsNext = nil
                for key in lowered {
                    let last = r.graphicsSet?[key]
                    let current = groups[key]
                    // Not what Anvil last wrote, nor the player's own before: changed in its menu since — theirs.
                    if let last, let current, current != last, current != r.graphicsBefore?[key] {
                        said.append("\(groupName(key)) \(levelName(current)) as set in its menu")
                        r.graphicsSet?[key] = nil
                        r.graphicsBefore?[key] = nil
                        continue
                    }
                    guard let want = next[key] ?? last else { continue }
                    r.graphicsSet?[key] = want
                    if current != want { groupKeys.append((key, String(want))) }
                    // Back at the player's own: written, and no longer Anvil's.
                    if want >= (r.graphicsBefore?[key] ?? 99) {
                        r.graphicsSet?[key] = nil
                        r.graphicsBefore?[key] = nil
                    } else {
                        kept.append(key)
                    }
                }
                r.lowered = kept
                let list = kept.compactMap { k in r.graphicsSet?[k].map { "\(groupName(k)) \(levelName($0))" } }
                if !list.isEmpty {
                    lines.append("graphics for an even 80: " + list.joined(separator: ", ") + " — the rest as set in its menu")
                }
                if !said.isEmpty { lines.append("graphics: " + said.joined(separator: ", ") + " — left as it is") }
            } else {
                for key in lowered {
                    if let before = r.graphicsBefore?[key], groups[key] == r.graphicsSet?[key] { groupKeys.append((key, String(before))) }
                }
                lines.append("graphics exactly as set in its menu: " + lowered.compactMap { k in r.graphicsBefore?[k].map { "\(groupName(k)) \(levelName($0))" } }.joined(separator: ", ") + " back")
                r.lowered = []
                r.graphicsSet = [:]
                r.graphicsBefore = [:]
                r.graphicsNext = nil
            }
        }

        // Its ray-traced effects, as chosen — and with DLSS, NVIDIA's Ray Reconstruction, which D3DMetal runs as Apple's
        // MetalFX denoiser.
        if !profile.rayTracingSwitches.isEmpty {
            let rt = rayTracing(game, profile: profile, record: &r, now: now, levels: groups, runs: runs, dxr: dxr)
            keys += rt.keys
            groupKeys += rt.groups
            lines += rt.lines
        }

        // The same changes in each copy: the ini, and each options save.
        func applied(_ t: String) -> String {
            var out = keys.isEmpty ? t : setting(keys, in: profile.section, of: t)
            if !groupKeys.isEmpty { out = setting(groupKeys, in: scalabilitySection, of: out) }
            if !tupleKeys.isEmpty, var tuple = value(profile.cameraKey, in: profile.section, of: out) {
                for (k, v) in tupleKeys.sorted(by: { $0.key < $1.key }) { tuple = settingTuple(k, to: v, in: tuple) }
                out = setting([(profile.cameraKey, tuple)], in: profile.section, of: out)
            }
            return out
        }
        if !keys.isEmpty || !tupleKeys.isEmpty || !groupKeys.isEmpty {
            let updated = applied(text)
            if updated != text, !DiskCache.writeReplacing(Data(updated.utf8), to: file, durable: true) {
                return ["its own upscaler: its settings file couldn't be written — the game starts with its own"]
            }
            for save in saves {
                let t = applied(save.text)
                guard t != save.text else { continue }
                guard let data = save.replacing(text: t), OptionsSave(url: save.url, data: data)?.text == t,
                      DiskCache.writeReplacing(data, to: save.url, durable: true) else {
                    lines.append("its saved options (\(save.url.lastPathComponent)) couldn't be written — the game may put its own back once it has started")
                    continue
                }
            }
        }
        save(r, for: game)
        return lines
    }

    // MARK: Ray tracing

    /// The settings for its ray-traced effects at a start: the switches, the quality groups when Anvil turns them on,
    /// Ray Reconstruction with them under DLSS; and the log's lines.
    ///
    /// Turned on, the effects trace at High; with Ray Reconstruction at Medium — the denoiser is made to clean up a
    /// few rays a pixel, and fewer rays leave the base M4's GPU, already 97–99% busy in Hogwarts Legacy at Ultra (22
    /// October), the time it can. Switched in the game's menu after Anvil set them, they're the player's until the
    /// choice on its page changes.
    static func rayTracing(_ game: Game, profile: Profile, record r: inout Record, now: InGame, levels: [String: Int], runs: Brand?,
                           dxr: Bool) -> (keys: [(String, String)], groups: [(String, String)], lines: [String]) {
        var keys: [(String, String)] = [], groups: [(String, String)] = [], lines: [String] = []
        let choice = game.gameRayTracing
        // Switched in its menu since Anvil set them, for the same choice: left as they are, until the choice changes.
        if r.rayTracingChoice != choice { r.rayTracingLeft = nil }
        if r.rayTracingLeft != true, let wrote = r.rayTracingWrote, r.rayTracingChoice == choice {
            let current = Dictionary(uniqueKeysWithValues: profile.rayTracingSwitches.map { ($0.key, now.rayTraced.contains($0.effect)) })
            if wrote.contains(where: { current[$0.key] != $0.value }) {
                r.rayTracingLeft = true
                r.rayTracingByAnvil = nil
            }
        }
        if r.rayTracingLeft == true {
            r.rayTracingWrote = nil
            lines.append("ray tracing: \(effectNames(now.rayTraced)) as switched in its menu — left as it is; choosing on its page sets it again")
            return (keys, groups, lines)
        }
        let wanted: [String]? = choice == .automatic ? (r.rayTracingByAnvil == true ? ["reflections"] : nil) : choice.effects
        guard let wanted else {
            r.rayTracingWrote = nil
            r.rayTracingChoice = choice
            if !now.rayTraced.isEmpty {
                lines.append("ray tracing: \(effectNames(now.rayTraced)) on, as set in its menu" + (dxr ? "" : " — but D3DMetal doesn't offer it ray tracing at this start (the Ray Tracing switch is off), so they don't run"))
            }
            return (keys, groups, lines)
        }
        if !wanted.isEmpty && !dxr {
            lines.append("ray tracing: \(effectNames(wanted)) not switched on — D3DMetal doesn't offer the game ray tracing at this start (this Mac's GPU, or the Ray Tracing switch)")
            return (keys, groups, lines)
        }
        var wrote: [String: Bool] = [:]
        for (effect, key) in profile.rayTracingSwitches {
            let on = wanted.contains(effect)
            wrote[key] = on
            if now.rayTraced.contains(effect) != on { keys.append((key, on ? "True" : "False")) }
        }
        let denoised = !wanted.isEmpty && runs == .dlss
        if let rr = profile.rayReconstructionKey, now.rayReconstruction != denoised { keys.append((rr, denoised ? "True" : "False")) }
        // From all off to on: its ray-tracing quality where it was below what Anvil traces at.
        if !wanted.isEmpty, now.rayTraced.isEmpty {
            let target = denoised ? 1 : 2
            for g in profile.rayTracingGroups where (levels[g] ?? 0) < target { groups.append((g, String(target))) }
        }
        r.rayTracingWrote = wrote
        r.rayTracingChoice = choice
        if wanted.isEmpty {
            if !now.rayTraced.isEmpty { lines.append("ray tracing: \(effectNames(now.rayTraced)) off" + (choice == .off ? ", as chosen on its page" : " — Automatic's reflections off again")) }
        } else {
            lines.append("ray tracing: \(effectNames(wanted)) on — traced by this Mac's ray-tracing hardware, "
                         + (denoised ? "and cleaned by NVIDIA's Ray Reconstruction, which D3DMetal runs as Apple's MetalFX denoiser"
                                     : "and cleaned by the game's own denoiser (Ray Reconstruction, Apple's MetalFX denoiser, needs DLSS as its upscaler)")
                         + (choice == .automatic ? " — Automatic's: the last session had room for them" : ""))
        }
        return (keys, groups, lines)
    }

    // MARK: Its options save

    /// The options saves of a game that keeps them in its SaveGames folder too — one per account that played it.
    static func optionsSaves(for game: Game, in container: Container, profile: Profile) -> [URL] {
        guard let name = profile.optionsSave, let config = UnrealConfig.folder(for: game, in: container) else { return [] }
        let saveGames = config.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SaveGames", isDirectory: true)
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: saveGames, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent(name) }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    /// A game's options kept in an Unreal save (GVAS): the whole GameUserSettings.ini, as the bytes of an
    /// ArrayProperty named "SettingsData" — its size (8 bytes) and its count (4) in front of them. Hogwarts Legacy
    /// keeps one, SavedUserOptions.sav, and applies it over its ini once it has started: on 22 October it drew FSR 3 at
    /// Performance (756 × 492) the whole session with DLSS set in the ini, and wrote the ini back from it 20 minutes in.
    struct OptionsSave {
        let url: URL
        let data: Data
        /// Where its ArrayProperty's size and count are, and where the text starts.
        let sizeAt: Int
        let countAt: Int
        let start: Int
        let count: Int
        let text: String

        init?(_ url: URL) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            self.init(url: url, data: data)
        }

        init?(url: URL, data: Data) {
            self.url = url
            self.data = data
            func fstring(_ s: String) -> Data {
                var d = Data()
                var n = UInt32(s.utf8.count + 1).littleEndian
                withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
                d.append(contentsOf: Array(s.utf8) + [0])
                return d
            }
            func i32(_ o: Int) -> Int? {
                guard o >= 0, o + 4 <= data.count else { return nil }
                return Int(Int32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) }))
            }
            func i64(_ o: Int) -> Int? {
                guard o >= 0, o + 8 <= data.count else { return nil }
                return Int(Int64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) }))
            }
            guard data.prefix(4) == Data("GVAS".utf8),
                  let name = data.range(of: fstring("SettingsData") + fstring("ArrayProperty")) else { return nil }
            let sizeAt = name.upperBound
            let inner = fstring("ByteProperty")
            guard let size = i64(sizeAt), data.count >= sizeAt + 8 + inner.count + 1,
                  data.subdata(in: sizeAt + 8 ..< sizeAt + 8 + inner.count) == inner,
                  data[sizeAt + 8 + inner.count] == 0 else { return nil }
            let countAt = sizeAt + 8 + inner.count + 1
            guard let count = i32(countAt), count >= 0, size == count + 4, countAt + 4 + count <= data.count,
                  let text = String(data: data.subdata(in: countAt + 4 ..< countAt + 4 + count), encoding: .utf8) else { return nil }
            self.sizeAt = sizeAt
            self.countAt = countAt
            self.start = countAt + 4
            self.count = count
            self.text = text
        }

        /// The same save with `text` in place of its settings, size and count to match; everything after as it was.
        func replacing(text new: String) -> Data? {
            let bytes = Data(new.utf8)
            guard bytes.count < Int32.max - 4 else { return nil }
            var out = data.prefix(sizeAt)
            var size = Int64(bytes.count + 4).littleEndian
            withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
            out.append(data.subdata(in: sizeAt + 8 ..< countAt))
            var count = Int32(bytes.count).littleEndian
            withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
            out.append(bytes)
            out.append(data.suffix(from: start + self.count))
            return out
        }
    }

    static func cleanWords(_ key: String) -> String {
        switch key {
        case "bFilmGrain": "film grain"
        case "bChromaticAberration": "colour fringing (chromatic aberration)"
        case "bMotionBlur": "motion blur"
        default: key
        }
    }

    // MARK: After a session

    /// What the session showed: an upscaler the game didn't take, one changed in its menu, and — for Automatic — the
    /// quality for its next start, from how it ran. The log's lines.
    static func afterSession(_ game: Game, in container: Container, play: [FrameWindow]) -> [String] {
        guard let profile = profile(for: game), var r = record(for: game), let wrote = r.wrote,
              let now = inGame(game, in: container) else { return [] }
        var lines: [String] = []
        // Its own frame generation, switched on by Anvil and off at the end: with an upscaler it can't pair it with,
        // the game turns it off itself — another upscaler next time; with its own FSR, the player did.
        if r.frameGenOnByAnvil == true, now.frameGen == nil {
            if now.upscale == wrote, let brand = profile.reading(wrote)?.brand, brand != .fsr {
                var refused = r.frameGenRefusedWith ?? []
                if !refused.contains(brand) { refused.append(brand) }
                r.frameGenRefusedWith = refused
                r.wrote = nil
                r.note = "The game turned its own frame generation off with \(brand.title). Its FSR 3 runs with it from its next start."
                lines.append("its own frame generation: turned off by the game with \(brand.short) — its FSR 3 with it from its next start")
                save(r, for: game)
                return lines
            } else {
                r.frameGenLeftOff = true
                r.frameGenOnByAnvil = nil
                r.note = "Its own frame generation was switched off in its menu. Anvil's Smooth Motion runs instead; Set It Again on this page has it back."
                lines.append("its own frame generation: switched off in its menu — left off; Anvil's Smooth Motion from its next start")
            }
        }
        if now.upscale != wrote {
            let brand = profile.reading(wrote)?.brand
            // DLSS asked for, and D3DMetal never showed the game an NVIDIA GPU: the game had no DLSS to offer.
            if brand == .dlss, !DLSSThroughMetalFX.shownNVIDIA(container) {
                if !r.unavailable.contains(.dlss) { r.unavailable.append(.dlss) }
                r.wrote = nil
                r.note = "DLSS wasn't offered: D3DMetal didn't show the game an NVIDIA GPU. The next of its own is set at its next start."
                lines.append("its own upscaler: DLSS wasn't offered — D3DMetal didn't show the game an NVIDIA GPU; the next of its own from its next start")
            } else {
                r.changedInGame = now.upscale ?? "none"
                r.note = "Changed in the game's own menu to \(now.text). Anvil leaves it until you choose here."
                lines.append("its own upscaler: changed in its menu to \(now.text) — left as it is")
            }
            save(r, for: game)
            return lines
        }
        r.note = "\(now.text) last session."
        // For an even 80: a step at a time, from how much of the session it held 80 or more.
        let groups = gameText(game, in: container, profile: profile).map { Learn.scalability(in: $0) } ?? [:]
        let at80 = shareAt80(play)
        let effective = (r.graphicsSet ?? [:]).merging(r.graphicsNext ?? [:]) { _, next in next }
        if let step = tuneStep(at80: at80.share, seconds: at80.seconds, quality: game.gameUpscalerQuality == nil ? r.autoQuality : nil,
                               graphics: game.gameGraphics == .automatic ? groups.merging(effective) { _, set in set } : nil,
                               lowered: r.lowered ?? [], set: effective, before: r.graphicsBefore ?? [:], profile: profile,
                               rayTracing: rayTracingTuning(game, profile: profile, record: r, now: now)) {
            let held = String(format: "%.0f%% of its play at 80 fps or more", at80.share * 100)
            switch step {
            case .quality(let to):
                let from = r.autoQuality
                r.autoQuality = to
                lines.append("its own upscaler: \(to.title) from its next start, from \(from.title) — \(held)")
                r.note = "\(now.text) last session, \(held) — \(to.title) from its next start."
            case .lower(let changes):
                var lowered = r.lowered ?? [], next = r.graphicsNext ?? [:], before = r.graphicsBefore ?? [:]
                for (key, value) in changes {
                    if before[key] == nil { before[key] = groups[key] }
                    next[key] = value
                    if !lowered.contains(key) { lowered.append(key) }
                }
                if r.graphicsSet == nil { r.graphicsSet = [:] }
                r.lowered = lowered; r.graphicsNext = next; r.graphicsBefore = before
                let list = changes.map { "\(groupName($0.key)) \(levelName($0.value))" }.joined(separator: ", ")
                lines.append("graphics for an even 80: \(list) from its next start — \(held), short of the 80% it's held to")
                r.note = "\(held) last session — \(list) from its next start, for an even 80. Exactly As Set in its menu keeps its own."
            case .rayTracing(let on):
                r.rayTracingByAnvil = on ? true : nil
                lines.append(on ? "ray tracing: its reflections on from its next start — \(held), room to spare"
                                : "ray tracing: its reflections off from its next start — \(held), short of the 80% it's held to")
                r.note = "\(held) last session — ray-traced reflections \(on ? "on" : "off") from its next start."
            case .raise(let key, let value):
                // Written at the next start, and let go of there once it's back at the player's own (prepare).
                var next = r.graphicsNext ?? [:]
                next[key] = value
                r.graphicsNext = next
                lines.append(value >= (r.graphicsBefore?[key] ?? value)
                             ? "graphics: \(groupName(key)) back to \(levelName(value)) as set in its menu from its next start — \(held)"
                             : "graphics for an even 80: \(groupName(key)) up to \(levelName(value)) from its next start — \(held)")
                r.note = "\(held) last session — \(groupName(key)) a step back up from its next start."
            }
        } else if at80.seconds >= 300 {
            r.note = String(format: "\(now.text) last session, %.0f%% of its play at 80 fps or more.", at80.share * 100)
        }
        save(r, for: game)
        return lines
    }

    /// For the tuner: Automatic's ray-traced reflections, whether on by Anvil, and whether they could be.
    static func rayTracingTuning(_ game: Game, profile: Profile, record r: Record, now: InGame) -> (anvilOn: Bool, canAdd: Bool)? {
        guard !profile.rayTracingSwitches.isEmpty, game.gameRayTracing == .automatic else { return nil }
        let anvilOn = r.rayTracingByAnvil == true
        let canAdd = !anvilOn && now.rayTraced.isEmpty && game.rayTracing != false && MetalCapability.current.hardwareRayTracing
        return (anvilOn, canAdd)
    }

    /// How much of a session's play was shown at an even 80 or more — every frame shown, the game's made ones and
    /// Anvil's too, as the player saw it — and how long it played.
    static func shareAt80(_ play: [FrameWindow]) -> (share: Double, seconds: Double) {
        let seconds = play.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return (0, 0) }
        let held = play.filter { w in
            let shown = w.displayed / max(0.05, 1 - (w.generatedShare ?? 0))
            return shown >= 78
        }.reduce(0) { $0 + $1.seconds }
        return (held / seconds, seconds)
    }

    enum TuneStep: Equatable {
        case quality(UpscaleQuality)
        case lower([String: Int])
        case raise(String, Int)
        /// Automatic's ray-traced reflections on or off.
        case rayTracing(Bool)
    }

    /// The next step for an even 80, from a session of five minutes or more: under 80% of it at 80 or more, quality to
    /// Performance first (where Automatic has it higher), then the next quality group on the profile's list a step
    /// lower — two when under half — never below its floor; 95% or more, the last group lowered a step back up, and
    /// with none lowered, quality a step sharper. `quality` and `graphics` are nil where the player chose them.
    /// `rayTracing`, for Automatic's ray tracing: whether its reflections are on by Anvil, and whether they could be
    /// (traced in hardware, offered by D3DMetal, off in its menu). Off is the first step down; on the last step up,
    /// once quality is at its sharpest with nothing lowered.
    static func tuneStep(at80: Double, seconds: Double, quality: UpscaleQuality?, graphics: [String: Int]?, lowered: [String],
                         set: [String: Int], before: [String: Int], profile: Profile,
                         rayTracing: (anvilOn: Bool, canAdd: Bool)? = nil) -> TuneStep? {
        guard seconds >= 300 else { return nil }
        if at80 < 0.80, rayTracing?.anvilOn == true { return .rayTracing(false) }
        if at80 < 0.80 {
            if let q = quality, let i = qualities.firstIndex(of: q), q != .performance, i + 1 < qualities.count {
                return .quality(qualities[i + 1])
            }
            guard let graphics else { return nil }
            var changes: [String: Int] = [:]
            let wanted = at80 < 0.5 ? 2 : 1
            for key in profile.scalability where changes.count < wanted {
                guard let v = graphics[key], v > profile.scalabilityFloor else { continue }
                changes[key] = v - 1
            }
            return changes.isEmpty ? nil : .lower(changes)
        }
        if at80 >= 0.95 {
            if graphics != nil, let key = lowered.last, let v = set[key], v < (before[key] ?? 3) { return .raise(key, v + 1) }
            if let q = quality, let i = qualities.firstIndex(of: q), i > 0 { return .quality(qualities[i - 1]) }
            if let rt = rayTracing, !rt.anvilOn, rt.canAdd, lowered.isEmpty { return .rayTracing(true) }
        }
        return nil
    }

    // MARK: The file

    /// `key=value` in an ini's section; nil when absent.
    static func value(_ key: String, in section: String, of text: String) -> String? {
        var inside = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("[") { inside = line.trimmingCharacters(in: .whitespaces) == section; continue }
            guard inside, line.hasPrefix(key + "=") else { continue }
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }

    /// The section's keys set, each in place where it is and at the section's end where it isn't; the rest of the file
    /// as it was, line endings and all.
    static func setting(_ changes: [(String, String)], in section: String, of text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == section }) else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(section)
            for (k, v) in changes { lines.append("\(k)=\(v)") }
            return lines.joined(separator: newline) + newline
        }
        var end = lines.count
        for i in (header + 1)..<lines.count where lines[i].hasPrefix("[") { end = i; break }
        // Before any blank lines that end the section.
        var insertAt = end
        while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        for (k, v) in changes {
            if let i = (header + 1..<end).first(where: { lines[$0].hasPrefix(k + "=") }) {
                lines[i] = "\(k)=\(v)"
            } else {
                lines.insert("\(k)=\(v)", at: insertAt)
                insertAt += 1
                end += 1
            }
        }
        return lines.joined(separator: newline) + (trailing ? newline : "")
    }

    /// A field of a tuple value — "(A=1,bFilmGrain=True,…)".
    static func tupleValue(_ key: String, in tuple: String) -> String? {
        for part in tuple.trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key { return String(kv[1]) }
        }
        return nil
    }

    static func settingTuple(_ key: String, to value: String, in tuple: String) -> String {
        guard let current = tupleValue(key, in: tuple) else { return tuple }
        return tuple.replacingOccurrences(of: "\(key)=\(current)", with: "\(key)=\(value)")
    }
}
