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
        widthKey: "ResolutionSizeX", heightKey: "ResolutionSizeY", optionsSave: "SavedUserOptions.sav")

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
                      sharpen: value(profile.sharpenKey, in: profile.section, of: text))
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
    static func resolve(_ choice: Choice, available: [Brand], unavailable: [Brand]) -> Brand? {
        let usable = available.filter { !unavailable.contains($0) }
        if let wanted = choice.brand, usable.contains(wanted) { return wanted }
        return [Brand.dlss, .xess, .fsr].first { usable.contains($0) }
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
                        tier: DeviceProfile.Tier?) -> [String] {
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
        var keys: [(String, String)] = []
        var tupleKeys: [String: String] = [:]
        var lines: [String] = []
        let choice = game.gameUpscaler
        let sameChoice = record.map { $0.choice == choice && $0.quality == game.gameUpscalerQuality } ?? false

        // The upscaler.
        if choice == .asInGame {
            lines.append("its own upscaler: \(now.text), as set in its menu")
        } else if sameChoice, let r = record, let wrote = r.wrote, now.upscale != wrote || r.changedInGame != nil {
            // Changed in the game's menu since Anvil set it: the player's.
            record?.changedInGame = now.upscale ?? "none"
            lines.append("its own upscaler: \(now.text), as chosen in its menu since Anvil set \(profile.reading(wrote)?.brand.short ?? wrote) — left as it is; choosing on its page sets it again")
        } else {
            let brands = available(for: game, profile: profile, dlssReady: dlssReady)
            if let brand = resolve(choice, available: brands, unavailable: record?.unavailable ?? []) {
                let auto = record?.autoQuality ?? startQuality(tier)
                let quality = game.gameUpscalerQuality ?? auto
                if let value = profile.value(brand, quality) {
                    if now.upscale != value { keys += [(profile.upscaleKey, value), (profile.upscaleModifiedKey, "True")] }
                    let set = read(setting([(profile.upscaleKey, value)], in: profile.section, of: source), profile: profile)
                    var line = "its own upscaler: \(set.text)"
                    if game.gameUpscalerQuality == nil { line += ", the quality Anvil found for it here" }
                    if let wanted = choice.brand, wanted != brand { line += " — \(wanted.title) doesn't run here" }
                    if now.upscale != value, now.upscale != nil { line += " (it was \(now.text))" }
                    lines.append(line)
                    record = Record(wrote: value, choice: choice, quality: game.gameUpscalerQuality, autoQuality: auto, at: Date(),
                                    changedInGame: nil, unavailable: record?.unavailable ?? [],
                                    frameGenOffByAnvil: record?.frameGenOffByAnvil ?? false, sharpenByAnvil: record?.sharpenByAnvil ?? false,
                                    cameraBefore: record?.cameraBefore ?? [:], anvilFrameGen: anvilFrameGen, note: record?.note)
                }
            } else {
                lines.append("its own upscaler: \(now.text) — none of DLSS, XeSS or FSR it has runs here")
            }
        }

        var r = record ?? Record(wrote: nil, choice: choice, quality: game.gameUpscalerQuality,
                                 autoQuality: startQuality(tier), at: Date())
        r.anvilFrameGen = anvilFrameGen
        if !saves.isEmpty { r.savedOptions = true }

        // Its frame generation: never on top of Anvil's — frames made from frames it made itself warp. Turned on in
        // its menu after Anvil turned it off, it's the player's: Anvil's stands down for that start instead.
        if let fg = now.frameGen, anvilFrameGen {
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

        // The same changes in each copy: the ini, and each options save.
        func applied(_ t: String) -> String {
            var out = keys.isEmpty ? t : setting(keys, in: profile.section, of: t)
            if !tupleKeys.isEmpty, var tuple = value(profile.cameraKey, in: profile.section, of: out) {
                for (k, v) in tupleKeys.sorted(by: { $0.key < $1.key }) { tuple = settingTuple(k, to: v, in: tuple) }
                out = setting([(profile.cameraKey, tuple)], in: profile.section, of: out)
            }
            return out
        }
        if !keys.isEmpty || !tupleKeys.isEmpty {
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
        // Automatic: one step at a time, from the frame rate of its own it made where the GPU set the pace.
        if game.gameUpscalerQuality == nil, let step = qualityStep(play, current: r.autoQuality, anvilFrameGen: r.anvilFrameGen) {
            let from = r.autoQuality
            r.autoQuality = step.to
            r.note = "\(now.text) last session — \(step.to.title) from its next start: \(step.why)."
            lines.append("its own upscaler: \(step.to.title) from its next start, from \(from.title) — \(step.why)")
        }
        save(r, for: game)
        return lines
    }

    /// What it needs of its own frame rate to look smooth here: with Anvil's frames between, 45 (shown as 90); without,
    /// Steady's even 80, less a little.
    static func needed(anvilFrameGen: Bool) -> Double { anvilFrameGen ? 45 : 72 }

    /// The next quality for Automatic, or nil to stay: a step sharper where the game made well over what it needs
    /// even in its heaviest stretches, a step quicker where the GPU held it under. Three minutes of play at least.
    static func qualityStep(_ play: [FrameWindow], current: UpscaleQuality, anvilFrameGen: Bool) -> (to: UpscaleQuality, why: String)? {
        let seconds = play.reduce(0) { $0 + $1.seconds }
        guard seconds >= 180, let at = qualities.firstIndex(of: current) else { return nil }
        let need = needed(anvilFrameGen: anvilFrameGen)
        let weighted = play.map { (value: $0.rendered, weight: $0.seconds) }
        let busy = play.filter { ($0.gpuBusy ?? 0) >= 90 }
        let busyShare = busy.reduce(0) { $0 + $1.seconds } / seconds
        let low = TrialStats.percentile(weighted, 0.25)
        let busyLow = busy.isEmpty ? low : TrialStats.percentile(busy.map { (value: $0.rendered, weight: $0.seconds) }, 0.25)
        if busyShare >= 0.25, busyLow < need * 0.85, at + 1 < qualities.count {
            return (qualities[at + 1], String(format: "the GPU flat out held it to %.0f fps of its own in its heavier quarter, under the %.0f it needs", busyLow, need))
        }
        if low >= need * 1.25, busyLow >= need * 1.25, at > 0 {
            return (qualities[at - 1], String(format: "it made %.0f fps of its own or more three quarters of the time, well over the %.0f it needs", low, need))
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
