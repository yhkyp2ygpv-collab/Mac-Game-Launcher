import Foundation
import AppKit

/// How much of a game's own graphics Anvil turns down, for a game it knows how to tune.
enum GraphicsLevel: String, Codable, CaseIterable, Identifiable, Comparable {
    case light, medium, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .full: "Full"
        }
    }

    var detail: String {
        switch self {
        case .light: "The heaviest effects off, reflections too, for the steadiest frame rate"
        case .medium: "The game's reflections on; what costs the most or warps the picture (depth of field, water and heat distortion) off"
        case .full: "The game's own settings, exactly as it keeps them"
        }
    }

    var rank: Int { GraphicsLevel.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: GraphicsLevel, b: GraphicsLevel) -> Bool { a.rank < b.rank }
}

/// Whether, and how far, Anvil tunes a game's own graphics settings for this Mac.
enum GraphicsTuning: String, Codable, CaseIterable, Identifiable {
    /// Anvil decides: what Auto-Tune found best, and Medium until it has.
    case automatic
    case light
    case medium
    /// The game's own settings, exactly as it keeps them.
    case gameDefault

    var id: String { rawValue }

    /// The level chosen by hand, or nil for Anvil's choice.
    var level: GraphicsLevel? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .medium: .medium
        case .gameDefault: .full
        }
    }

    init(level: GraphicsLevel) {
        switch level {
        case .light: self = .light
        case .medium: self = .medium
        case .full: self = .gameDefault
        }
    }
}

/// A game's own graphics settings, set for a steady frame rate on this Mac.
///
/// Frame pacing only decides when a finished frame is shown; it cannot make the game
/// finish one sooner. LEGO Star Wars: The Skywalker Saga spends 29% of its time below
/// 80 fps on a base M4 at 1512×982, down to the mid-40s in heavy scenes, and a sample
/// of one such scene had its render thread waiting on D3DMetal's command queue for 42%
/// of the time — the GPU could not keep up. Some of the game's effects cost far more
/// than they show at this size: screen-space reflections, depth of field and two kinds of
/// motion blur. Turning those off takes that work off the GPU.
///
/// Shadows are left as the game draws them, at every level. Until 0.38 Medium turned soft
/// shadows off and shadows down, and Light ambient occlusion off too; on 10 October the player
/// saw LEGO Star Wars' shadows looking wrong — hard, jagged edges that crawl as things move, and
/// figures with no shading where they meet the ground. What was paid for with them was measured
/// while every start was compiling its shaders again (ShaderCacheManager), not the game itself.
///
/// Applied before a launch, to the settings file the game itself reads. What the game
/// had is kept, and put back for any key a level no longer sets. A value changed in the
/// game's own menu afterwards is the player's, and is never overwritten.
enum GameTuning {
    struct Setting: Hashable {
        let key: String
        let value: String
        /// What it is, in words, for the settings screen and the log.
        let label: String
    }

    struct Profile {
        /// The game's executable, which identifies it.
        let executable: String
        /// The settings file, relative to the Windows user's profile folder.
        let settingsFile: String
        /// What each level sets. Full sets nothing: it is the game's own values.
        let light: [Setting]
        let medium: [Setting]
        /// Bumped when the settings change, so a game tuned by an older version is
        /// tuned again once.
        let version: Int
        /// Keys set again once, on reaching the version that is about them, even where the
        /// game's menu had changed them since. A game already past that version keeps what its
        /// player set. See `profiles`.
        var reapply: (version: Int, keys: Set<String>) = (0, [])
        /// The game keeps its display mode in the same file (TT Games' ScreenWidth,
        /// Windowed, BorderlessWindow…), so Anvil can fit it to the screen. See fitDisplay.
        var fitsDisplay = false
        /// Keys set at every launch at Light and Medium, whatever the file says since: the game
        /// turns them back on by itself. LEGO Star Wars' two motion blurs, off since 0.14, were on
        /// again in its settings on 7 October and again by 10 October with nobody changing them in
        /// its menu — and a blur meant to smear every moving frame is the opposite of what the
        /// player asked for (11 October: "never smear across the screen in fast scenes"). Full
        /// leaves them to the game.
        var keptOff: Set<String> = []
        /// The game's own temporal anti-aliasing switch in that file: on (1), its frames come
        /// already blended over time, and FSR 3 blends only a few more (kAnvilFSR3FramesGameAA).
        var temporalAAKey: String? = nil
        /// Set at every start while FSR upscales the game, at every level, and put back when it doesn't: what
        /// the game does to its picture before FSR that FSR does better after, and the blurs that smear
        /// across FSR 3's blend and Smooth Motion's made frames. Until 0.51 only at Light and Medium — the
        /// game's own look (Full) had its sharpening ringing under FSR's, and its motion blurs back on.
        var forFSR: [Setting] = []
        /// The game's own ray tracing, where it has some: the switch for its screen-space reflections (rays traced
        /// through the depth of what's on screen — LEGO Star Wars' shaders call theirs "SSRRaytracedReflection"),
        /// the key for their quality, and the quality a standard or entry-level GPU is given at Anvil's levels when
        /// the game's own is higher (Graphics Prep's choice for this Mac; see `wanted`). Its Ray Tracing switch
        /// turns them on or off at every level.
        var rayTraced: (enabled: String, quality: String, lighter: Int)? = nil

        func settings(for level: GraphicsLevel) -> [Setting] {
            switch level {
            case .light: light
            case .medium: medium
            case .full: []
            }
        }

        /// The Medium settings; what 0.14.0 called "the tuning".
        var settings: [Setting] { medium }
    }

    static let profiles: [Profile] = {
        // Medium keeps the game's reflections (since 0.52): what the player missed at Light, and what made the game's
        // own look worth having on 14 October. Its water distortion — the ripple of the picture behind water and heat,
        // which warps it a little differently every frame — is off: FSR 3's blend and Smooth Motion's made frames
        // follow a picture that moves, not one that warps, and with it on the player saw the picture distort.
        let medium = [
            Setting(key: "DoFEnabled", value: "0", label: "Depth of field off"),
            Setting(key: "WaterDistortionEnabled", value: "0", label: "Water distortion off"),
            Setting(key: "MotionBlurEnabled", value: "0", label: "Motion blur off"),
            Setting(key: "SpeedBlurEnabled", value: "0", label: "Speed blur off"),
        ]
        let light = [Setting(key: "ScreenSpaceReflectionsEnabled", value: "0", label: "Reflections off")] + medium
        return [
            Profile(
                executable: "LEGOSTARWARSSKYWALKERSAGA_DX11.exe",
                settingsFile: "AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT",
                light: light,
                medium: medium,
                // 2, in 0.31.0: the player saw blur on 7 October, and the game's two motion blurs
                // were back on in its settings — over the top of FSR 3, which blends frames
                // already, they smear every moving frame. Off once more; changed in the game's
                // menu after this, they stay as set there.
                // 3, in 0.38.0: soft shadows, shadow quality and ambient occlusion no longer
                // set at any level — put back to the game's own where Anvil had turned them down.
                // 4, in 0.52.0: Medium keeps the game's reflections and turns its water distortion off.
                version: 4,
                reapply: (2, ["MotionBlurEnabled", "SpeedBlurEnabled"]),
                fitsDisplay: true,
                keptOff: ["MotionBlurEnabled", "SpeedBlurEnabled"],
                temporalAAKey: "TemporalAAEnabled",
                // Its sharpening runs on the 1512x982 picture before FSR, and FSR's RCAS sharpens
                // again after upscaling: sharpened twice, edges ring with halos. Its edge
                // smoothing (a filter over the finished frame, apart from the temporal AA kept on)
                // softens the very edges FSR reconstructs from. AMD's guidance: the input
                // anti-aliased (its TAA does that) and not post-processed.
                forFSR: [
                    Setting(key: "SharpeningEnabled", value: "0", label: "its own sharpening off (FSR sharpens after upscaling, so edges don't ring)"),
                    Setting(key: "EdgeAAEnabled", value: "0", label: "edge smoothing off (its temporal AA and FSR 3 smooth edges without the blur)"),
                    Setting(key: "MotionBlurEnabled", value: "0", label: "motion blur off (it smears across FSR 3 and Smooth Motion)"),
                    Setting(key: "SpeedBlurEnabled", value: "0", label: "speed blur off (it smears across FSR 3 and Smooth Motion)"),
                ],
                // Its reflections' quality is 0–3 (an enum in its settings); its PC presets set 3.
                rayTraced: (enabled: "ScreenSpaceReflectionsEnabled", quality: "ScreenSpaceReflectionsQuality", lighter: 2)),
        ]
    }()

    /// What a start sets: the level's settings, with the game's own ray tracing as its Ray Tracing switch says (nil:
    /// as the level has it — on at Medium and Full, off at Light) and, while it's on at Light or Medium on an
    /// entry-level GPU, a step lighter than the game's own quality where that's higher. On a standard one (a base M4)
    /// they're the game's own since 0.55: on 14 October its own look cost a base M4 about 0.8 ms of GPU time a frame
    /// for its reflections at their highest, and 0.55's FSR 3 and FSR 1 take about 0.2 ms less each — and the player
    /// asked for the reflections at their best (16 October). At Full, only the switch, when set:
    /// the rest is the game's own.
    static func wanted(_ profile: Profile, level: GraphicsLevel, rayTracing: Bool?, tier: DeviceProfile.Tier?,
                       values: [String: String], original: [String: String]) -> [Setting] {
        var out = profile.settings(for: level)
        guard let rt = profile.rayTraced else { return out }
        if let chosen = rayTracing {
            out.removeAll { $0.key == rt.enabled }
            out.append(Setting(key: rt.enabled, value: chosen ? "1" : "0",
                               label: chosen ? "ray-traced reflections on (its Ray Tracing switch)" : "ray-traced reflections off (its Ray Tracing switch)"))
        }
        let on = !out.contains { $0.key == rt.enabled && $0.value == "0" } && (rayTracing == true || values[rt.enabled] != "0")
        if on, level != .full, let tier, tier < .base,
           let own = Int(original[rt.quality] ?? values[rt.quality] ?? ""), own > rt.lighter {
            out.append(Setting(key: rt.quality, value: String(rt.lighter),
                               label: "reflections at quality \(rt.lighter) of the game's \(own), for this Mac's \(tier.title)"))
        }
        return out
    }

    /// Graphics Prep's account of a game's ray tracing on this Mac, for its page and the launch log: what it has, and
    /// what the next start sets. Nil for a game with none of its own Anvil knows of.
    static func rayTracingPlan(for game: Game, in container: Container, level: GraphicsLevel,
                               tier: DeviceProfile.Tier? = DeviceProfile.current?.tier) -> String? {
        guard let profile = profile(for: game), let rt = profile.rayTraced else { return nil }
        let file = settingsFile(for: profile, in: container)
        let now = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { Self.values(in: $0) } ?? [:]
        let original = loadRecord(for: game)?.original ?? [:]
        let set = Self.wanted(profile, level: level, rayTracing: game.rayTracing, tier: tier, values: now, original: original)
        let off = set.contains { $0.key == rt.enabled && $0.value == "0" } || (game.rayTracing == nil && now[rt.enabled] == "0")
        if off {
            return game.rayTracing == false
                ? "Off, as switched: the game's screen-space ray-traced reflections are off — a little quicker in the heaviest places."
                : "Off at \(level.title) graphics: the game's screen-space ray-traced reflections are off for speed. The Ray Tracing switch turns them on at any level."
        }
        let quality = set.first { $0.key == rt.quality }?.value ?? original[rt.quality] ?? now[rt.quality]
        let lighter = set.contains { $0.key == rt.quality }
        return "On: the game's screen-space ray-traced reflections, in floors, water and metal"
            + (quality.map { " — quality \($0)" } ?? "")
            + (lighter ? ", a step below its own for this Mac's \(tier?.title ?? "GPU"), where they cost the most frames" : ", as the game has them")
            + ". Its water and heat distortion stays off at Light and Medium."
    }

    static func profile(for game: Game) -> Profile? {
        let exe = game.executableURL.lastPathComponent.lowercased()
        return profiles.first { $0.executable.lowercased() == exe }
    }

    /// Whether the game smooths its own edges over time — its own temporal anti-aliasing on in
    /// its settings file. Only for a game whose profile names the switch.
    static func smoothsItsOwnEdges(_ game: Game, in container: Container) -> Bool {
        guard let profile = profile(for: game), let key = profile.temporalAAKey,
              let file = settingsFile(for: profile, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return values(in: text)[key] == "1"
    }

    /// The settings file inside this container, if the game has written one yet.
    static func settingsFile(for profile: Profile, in container: Container) -> URL? {
        let users = container.driveC.appendingPathComponent("users", isDirectory: true)
        guard let people = try? FileManager.default.contentsOfDirectory(atPath: users.path) else { return nil }
        for person in people where person != "Public" {
            let file = users.appendingPathComponent(person).appendingPathComponent(profile.settingsFile)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    // MARK: What was there before

    /// Kept beside Anvil's other data: the game's own values for every key Anvil
    /// changed, what Anvil last wrote, and which level that was.
    private struct Record: Codable {
        var version: Int
        var original: [String: String]
        var applied: [String: String]
        /// Absent in records from 0.14.0, which only had Medium.
        var level: GraphicsLevel?
    }

    /// Where records live. Tests point this somewhere else.
    nonisolated(unsafe) static var recordsDirectory: URL =
        RuntimeManager.support.appendingPathComponent("GameTuning", isDirectory: true)

    private static func recordURL(for game: Game) -> URL {
        recordsDirectory.appendingPathComponent("\(game.id.uuidString).json")
    }

    private static func loadRecord(for game: Game) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(for: game)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func saveRecord(_ record: Record, for game: Game) {
        let url = recordURL(for: game)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) { DiskCache.writeReplacing(data, to: url) }
    }

    /// Whether this game is currently tuned by Anvil.
    static func isTuned(_ game: Game) -> Bool { loadRecord(for: game) != nil }

    /// The level currently written into the game's settings, as far as Anvil knows.
    static func appliedLevel(for game: Game) -> GraphicsLevel {
        guard let record = loadRecord(for: game) else { return .full }
        return record.level ?? .medium
    }

    // MARK: The file

    /// "Key<tabs>Value" lines. Only the value is replaced, so the file keeps its layout.
    static func values(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2 { out[String(parts[0])] = String(parts[parts.count - 1]) }
        }
        return out
    }

    static func replacing(_ changes: [String: String], in text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let lines = text.components(separatedBy: newline).map { line -> String in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let value = changes[String(parts[0])],
                  let range = line.range(of: String(parts[parts.count - 1]), options: .backwards) else { return line }
            return line.replacingCharacters(in: range, with: value)
        }
        return lines.joined(separator: newline)
    }

    /// Written beside the file and renamed over it, so the game never finds half a file.
    private static func write(_ text: String, to file: URL) throws {
        guard DiskCache.writeReplacing(Data(text.utf8), to: file, durable: true) else { throw CocoaError(.fileWriteUnknown) }
    }

    // MARK: The display

    /// The ways a TT Games title can be told to fill the screen, in the order Anvil tries
    /// them on a kind of engine until the game's window really fills it.
    enum DisplayMode: String, Codable, CaseIterable {
        case fullscreen, borderless, fullscreenWindow

        var settings: [String: String] {
            switch self {
            case .fullscreen: ["Windowed": "0", "BorderlessWindow": "0", "FullscreenWindow": "0"]
            case .borderless: ["Windowed": "1", "BorderlessWindow": "1", "FullscreenWindow": "0"]
            case .fullscreenWindow: ["Windowed": "1", "BorderlessWindow": "1", "FullscreenWindow": "1"]
            }
        }
        var title: String {
            switch self {
            case .fullscreen: "fullscreen"
            case .borderless: "a borderless window the size of the screen"
            case .fullscreenWindow: "the game's own fullscreen window"
            }
        }
        var next: DisplayMode? {
            switch self {
            case .fullscreen: .borderless
            case .borderless: .fullscreenWindow
            case .fullscreenWindow: nil
            }
        }
    }

    /// The picture's shape, for a TT Games title (its AspectRatio: 0 4:3, 1 16:9, 2 16:10, 3 the
    /// screen's own). LEGO Star Wars lays its picture out for 16:9 and widens it for a wider
    /// screen, but on a narrower one it crops the sides: on a MacBook's 1512x982 (about 3:2) its
    /// menus lost their left and right edges — the player's name tag cut in half, 4 October.
    ///
    /// 0.30 told it 16:9 on such a screen by default, expecting black above and below. The value
    /// is the shape of the monitor the game is to assume, though — next to "3, from the
    /// resolution" — and after it the player saw the picture distorted (7 October): a 16:9 picture
    /// drawn into a 3:2 screen is squeezed, not bordered. Fill, the screen's own shape, is the
    /// default again, and every game was put back on it once (Housekeeping). Whole stays a choice.
    enum PictureShape: String, Codable, CaseIterable, Identifiable {
        case whole, fill
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fill: "True shape — fills the screen; menus trim their edges"
            case .whole: "16:9 layout — whole menus, but the picture may look squeezed"
            }
        }
        /// The AspectRatio value for a screen of this shape.
        func aspectRatioValue(screen: (width: Int, height: Int)) -> String {
            let shape = Double(screen.width) / Double(max(screen.height, 1))
            return self == .whole && shape < 1.70 ? "1" : "3"
        }
    }

    static func engineKey(wineMajor: Int) -> String { "wine\(wineMajor)" }

    static func displayMode(for game: Game, wineMajor: Int) -> DisplayMode {
        game.displayModes?[engineKey(wineMajor: wineMajor)].flatMap(DisplayMode.init(rawValue:)) ?? .fullscreen
    }

    /// What the game's window did, from the line libanvil writes once it is drawing.
    struct WindowFit: Equatable {
        var fills: Bool
        var detail: String
    }

    static func windowFit(in lines: [Substring]) -> WindowFit? {
        guard let line = lines.last(where: { $0.contains("[anvil] window: ") }),
              let r = line.range(of: "[anvil] window: ") else { return nil }
        let detail = String(line[r.upperBound...])
        return WindowFit(fills: detail.hasSuffix("— fills it"), detail: detail)
    }

    /// The size, in the units the game will see, of the whole main screen: points with
    /// Retina mode off (Wine then reports the display at its point size), pixels with it on.
    @MainActor static func screenSize(for container: Container) -> (width: Int, height: Int)? {
        switch container.scaling {
        case .custom:
            return (container.customWidth, container.customHeight)
        case .native, .retina:
            if let screen = NSScreen.main {
                let scale = container.scaling == .retina ? screen.backingScaleFactor : 1
                return (Int((screen.frame.width * scale).rounded()), Int((screen.frame.height * scale).rounded()))
            }
            // Without AppKit's screen (no window yet), the display itself.
            let display = CGMainDisplayID()
            let points = CGDisplayBounds(display).size
            guard points.width > 0 else { return nil }
            if container.scaling == .retina, let mode = CGDisplayCopyDisplayMode(display) {
                return (mode.pixelWidth, mode.pixelHeight)
            }
            return (Int(points.width), Int(points.height))
        }
    }

    /// Before a launch: the game fullscreen at exactly the screen's size and refresh rate.
    ///
    /// Exclusive fullscreen at the screen's own size is how LEGO Star Wars ran well on
    /// Engine 2.6.1, and what it fills the screen with. 0.19.2 tried a borderless window
    /// instead, after Wine 9 cropped exclusive fullscreen; on Wine 9 that window sat below
    /// the menu bar and didn't cover the screen (1 October), and the game is back on 2.6.1.
    /// The size and rate follow the display Anvil finds at each launch, so another Mac, an
    /// external display or a Retina setting fits too. Not done when the player chose the
    /// game's own settings.
    @MainActor static func fitDisplay(_ game: Game, in container: Container, wineMajor: Int = 7,
                                      screen: (width: Int, height: Int)? = nil) -> String? {
        guard let profile = profile(for: game), profile.fitsDisplay, game.graphicsTuning != .gameDefault,
              let size = screen ?? screenSize(for: container), size.width > 0, size.height > 0,
              let file = settingsFile(for: profile, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let w = String(size.width), h = String(size.height)
        let mode = displayMode(for: game, wineMajor: wineMajor)
        var wanted: [String: String] = [
            "ScreenWidth": w, "ScreenHeight": h,
            "WindowWidth": w, "WindowHeight": h,
            "WindowLeft": "0", "WindowTop": "0",
            "ScreenRefreshRate": String(Int(DisplayProfile.maxHz.rounded())),
        ]
        wanted.merge(mode.settings) { _, new in new }
        let aspect = game.pictureShape.aspectRatioValue(screen: size)
        wanted["AspectRatio"] = aspect
        let current = values(in: text)
        let changes = wanted.filter { key, value in current[key] != nil && current[key] != value }
        guard !changes.isEmpty else { return nil }
        do { try write(replacing(changes, in: text), to: file) } catch { return nil }
        let shape = aspect == "1"
            ? "; told 16:9 (chosen for it), so its menus show whole — on this screen's shape that can squeeze the picture"
            : ""
        return "display: \(game.title) set to \(mode.title) at \(w)×\(h), \(Int(DisplayProfile.maxHz.rounded())) Hz — the screen's own size" + shape
    }

    // MARK: Applying

    /// Before a launch: put the game's settings at `level`. Returns a line for the
    /// launch log when something was done.
    @discardableResult
    static func prepare(_ game: Game, in container: Container, level: GraphicsLevel,
                        tier: DeviceProfile.Tier? = DeviceProfile.current?.tier) -> String? {
        guard let profile = profile(for: game) else { return nil }
        let record = loadRecord(for: game)
        // At Full, nothing of Anvil's — unless its Ray Tracing switch is set.
        if level == .full && (game.rayTracing == nil || profile.rayTraced == nil) {
            guard let record else { return nil }
            return restore(game, profile: profile, record: record, in: container)
        }
        let file = settingsFile(for: profile, in: container)
        let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let current = text.map(values(in:)) ?? [:]
        let wanted = Self.wanted(profile, level: level, rayTracing: game.rayTracing, tier: tier,
                                 values: current, original: record?.original ?? [:])
        if let record, record.version >= profile.version, (record.level ?? .medium) == level,
           wanted.allSatisfy({ record.applied[$0.key] == $0.value }), record.applied.keys.allSatisfy({ k in wanted.contains { $0.key == k } }) {
            // Up to date — but the keys the game turns back on by itself are looked at every time.
            let drifted = wanted.contains { s in
                profile.keptOff.contains(s.key) && current[s.key] != nil && current[s.key] != s.value
            }
            if !drifted { return nil }
        }
        guard let file, let text else {
            return "graphics: \(game.title) has no settings file yet — tuned after its first run"
        }
        var original = record?.original ?? [:]
        var applied = record?.applied ?? [:]
        var changes: [String: String] = [:]
        let wantedKeys = Set(wanted.map(\.key))
        let upgrading = (record?.version ?? profile.version) < profile.version
        var again: [String] = []
        var turnedBack: [String] = []

        // A key the previous level set and this one does not goes back to the game's
        // own value — if it still holds what Anvil wrote.
        for (key, wrote) in applied where !wantedKeys.contains(key) {
            if current[key] == wrote, let own = original[key], own != wrote { changes[key] = own }
            applied[key] = nil
        }
        var kept: [String] = []
        for s in wanted {
            guard let now = current[s.key] else { continue }
            if original[s.key] == nil { original[s.key] = now }
            // Changed in the game's own menu since Anvil set it: the player's choice — except,
            // once, what a new version of the tuning is for.
            if let wrote = applied[s.key], now != wrote {
                if s.key == profile.rayTraced?.enabled && game.rayTracing != nil {
                    // Its Ray Tracing switch in Anvil, set since: as it says.
                } else if profile.keptOff.contains(s.key), now != s.value {
                    turnedBack.append(s.label)
                } else if upgrading, (record?.version ?? profile.version) < profile.reapply.version,
                   profile.reapply.keys.contains(s.key), now != s.value {
                    again.append(s.label)
                } else {
                    kept.append(s.key)
                    continue
                }
            }
            if now != s.value { changes[s.key] = s.value }
            applied[s.key] = s.value
        }
        if !changes.isEmpty {
            do {
                try write(replacing(changes, in: text), to: file)
            } catch {
                return "graphics: couldn't write \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
        saveRecord(Record(version: profile.version, original: original, applied: applied, level: level), for: game)
        let labels = wanted.filter { changes[$0.key] != nil && !turnedBack.contains($0.label) }.map(\.label)
        let restored = changes.keys.filter { !wantedKeys.contains($0) }.count
        var line = labels.isEmpty && restored == 0
            ? "graphics: \(game.title) was already at \(level.title)"
            : "graphics: \(game.title) set to \(level.title) for this Mac — " + labels.joined(separator: ", ")
                + (restored > 0 ? (labels.isEmpty ? "" : "; ") + "\(restored) back to the game's own" : "")
                + " (its own values are kept, and come back at Full)"
        if !again.isEmpty {
            line += "; " + again.joined(separator: ", ")
                + " again, though set on in the game — they smear every moving frame on top of FSR 3's blend (once; set in the game after this, they stay)"
        }
        if !turnedBack.isEmpty {
            line = labels.isEmpty && restored == 0 && again.isEmpty
                ? "graphics: \(game.title) at \(level.title) — " + turnedBack.joined(separator: ", ")
                    + " again: the game had turned \(turnedBack.count == 1 ? "it" : "them") back on (kept off at Light and Medium, so fast scenes don't smear; Full leaves \(turnedBack.count == 1 ? "it" : "them") to the game)"
                : line + "; " + turnedBack.joined(separator: ", ")
                    + " again: the game had turned \(turnedBack.count == 1 ? "it" : "them") back on (kept off at Light and Medium; Full leaves \(turnedBack.count == 1 ? "it" : "them") to the game)"
        }
        if !kept.isEmpty { line += "; left as set in the game: " + kept.joined(separator: ", ") }
        return line
    }

    // MARK: Made for FSR

    private struct FSRRecord: Codable {
        var original: [String: String]
        var applied: [String: String]
    }

    private static func fsrRecordURL(for game: Game) -> URL {
        recordsDirectory.appendingPathComponent("\(game.id.uuidString)-fsr.json")
    }

    /// Before a launch: while FSR upscales the game (and its graphics aren't left at Full), the
    /// profile's `forFSR` settings are set — at every start, as the game may set them back —
    /// with the game's own values kept; otherwise those put back where they still hold Anvil's.
    @discardableResult
    static func prepareForFSR(_ game: Game, in container: Container, upscaling: Bool, level: GraphicsLevel) -> String? {
        guard let profile = profile(for: game), !profile.forFSR.isEmpty,
              let file = settingsFile(for: profile, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let current = values(in: text)
        let url = fsrRecordURL(for: game)
        var record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(FSRRecord.self, from: $0) }
            ?? FSRRecord(original: [:], applied: [:])
        var changes: [String: String] = [:]
        if upscaling {
            var labels: [String] = []
            for s in profile.forFSR {
                guard let now = current[s.key] else { continue }
                if record.original[s.key] == nil { record.original[s.key] = now }
                if now != s.value { changes[s.key] = s.value; labels.append(s.label) }
                record.applied[s.key] = s.value
            }
            if !changes.isEmpty {
                do { try write(replacing(changes, in: text), to: file) } catch { return nil }
            }
            try? FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: url) }
            return labels.isEmpty ? nil : "graphics: \(game.title) made ready for FSR — " + labels.joined(separator: ", ")
        }
        guard !record.applied.isEmpty else { return nil }
        for (key, wrote) in record.applied where current[key] == wrote {
            if let own = record.original[key], own != wrote { changes[key] = own }
        }
        if !changes.isEmpty { try? write(replacing(changes, in: text), to: file) }
        try? FileManager.default.removeItem(at: url)
        return changes.isEmpty ? nil : "graphics: \(game.title) not upscaled by FSR — \(changes.count) of its own picture settings back as it had them"
    }

    /// Put back what the game had, for every key still holding the value Anvil wrote.
    private static func restore(_ game: Game, profile: Profile, record: Record, in container: Container) -> String? {
        defer { try? FileManager.default.removeItem(at: recordURL(for: game)) }
        guard let file = settingsFile(for: profile, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let current = values(in: text)
        var changes: [String: String] = [:]
        for (key, original) in record.original where current[key] == record.applied[key] {
            changes[key] = original
        }
        guard !changes.isEmpty else { return nil }
        try? write(replacing(changes, in: text), to: file)
        return "graphics: \(game.title) back to its own settings (\(changes.count) restored)"
    }
}
