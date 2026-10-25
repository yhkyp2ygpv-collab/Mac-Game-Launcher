import Foundation

/// Anvil Learn: what Anvil has learned of how each game runs on this Mac, from every session of it, and
/// the settings it chooses from that.
///
/// Auto-Tune used to compare setups by what each measured in the sessions it ran in. Scenes differ far more
/// than settings do — LEGO Star Wars ran at 77% "80 or more" in one Light session and 39% in another — so a
/// setup measured in a light evening looked better than one measured in Mustafar. Learn takes every stretch
/// of every session (about seven seconds each) with how heavy the scene was — the game's main drawing pass,
/// timed on the GPU — and what the game's own GPU work came to. It learns what each part of a setup costs at
/// the same scene load (its graphics level, its reflections, each of an Unreal game's quality settings) as a
/// few milliseconds a frame, by regression across sessions; and it predicts what any setup would have done
/// over the play it has seen, moment by moment: the same scenes, the same Mac on battery or not, with only
/// that setup's cost changed. Setups never played — Medium with reflections — come from their parts.
///
/// Checked on LEGO Star Wars' twelve sessions of 13–17 October on a base M4, each predicted from the others:
/// 10.5 points off its real share of time at 80 fps or more on average, against 16.8 for each setup's own
/// average. It found the game's reflections cost about 1.2 ms a frame, its own look's other extras (depth of
/// field, water distortion) about 0.2 ms, and Medium the same as Light.
///
/// Older sessions count for less (a 30-day half-life), and nothing is thrown away when the game, its engine or
/// macOS changes: what changed shows in the next sessions and outweighs the old. Kept per game and per Mac in
/// Learn/<program>-<Mac>.json; never leaves the Mac.
struct LearnSample: Codable, Hashable {
    /// The session's start, seconds since 1970.
    var at: Double
    /// What it ran with: "level:medium", "reflections", "sg.ShadowQuality=3", "resolution:full" (see Learn.parts).
    var parts: [String]
    /// The game's main drawing pass, ms a frame; -1 where the GPU wasn't timed.
    var scene: Float
    /// The game's own GPU work, ms a frame (Anvil's left out); -1 where not timed.
    var game: Float
    /// What a frame took the game on its own: 1000 / what it could make.
    var frame: Float
    var seconds: Float
}

struct LearnModel: Codable {
    var program: String
    var mac: String
    var samples: [LearnSample] = []
    /// Sessions learned from, by their start (seconds since 1970).
    var sessions: [Double] = []
    var updated: Date = .distantPast

    static let maxSamples = 20_000
    static let halfLifeDays = 30.0
    /// Seconds of play that pull a part's cost towards nothing: little measured, little believed.
    static let shrink = 300.0
    /// A part counts as measured once played both with and without it for this long.
    static let knownSeconds = 300.0
    /// Frame time follows GPU time at about this rate: the two overlap (game.log, 13–17 October).
    static let slope = 0.85

    // MARK: Learning

    /// The stretches of one session worth learning from: play, not its start, a menu, a pause or a load.
    static func usable(_ windows: [FrameWindow]) -> [FrameWindow] {
        Gameplay.split(windows).play.filter { w in
            w.capacity > 1 && w.capacity < 250 && (w.gpuBusy ?? 50) >= 35 && !w.wasBehind
        }
    }

    /// One session, with what it ran with. Returns the stretches learned: 0 when already learned.
    @discardableResult
    mutating func learn(startedAt: Date, parts: [String], windows: [FrameWindow]) -> Int {
        let at = startedAt.timeIntervalSince1970
        guard !sessions.contains(where: { abs($0 - at) < 1 }) else { return 0 }
        // The game making a frame of its own between each two (its own frame generation): every other frame presented
        // is a made one, so a frame of its own took twice what's measured a presented one. Until 0.64 they were
        // counted as its own, and Hogwarts Legacy's Ultra effects read as +0.6 ms a frame where earlier sessions had
        // measured 2.1–2.5 (22 October).
        let made = parts.contains(Learn.gamesOwnFrames)
        let per: Double = made ? 2 : 1
        let sorted = parts.filter { $0 != Learn.gamesOwnFrames }.sorted()
        let new = Self.usable(windows).map { w -> LearnSample in
            let scene = w.gpuKinds?["scene"].map { $0 * per }
            let game = w.gpuWorkMs.map { ($0 - (w.gpuKinds?["Anvil"] ?? 0)) * per }
            return LearnSample(at: at, parts: sorted, scene: Float(scene ?? -1), game: Float(game ?? -1),
                               frame: Float(1000 / w.capacity * per), seconds: Float(w.seconds))
        }
        guard !new.isEmpty else { return 0 }
        sessions.append(at)
        samples += new
        if samples.count > Self.maxSamples {
            samples.sort { $0.at < $1.at }
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        if sessions.count > 400 { sessions.removeFirst(sessions.count - 400) }
        updated = Date()
        return new.count
    }

    func weight(_ s: LearnSample, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince1970 - s.at) / 86_400
        return Double(s.seconds) * pow(0.5, days / Self.halfLifeDays)
    }

    // MARK: What each part costs

    /// A part's name and how much of it: "sg.ShadowQuality=3" is ShadowQuality at 3; "reflections" is 1.
    static func feature(_ part: String) -> (name: String, amount: Double) {
        if let eq = part.firstIndex(of: "="), let v = Double(part[part.index(after: eq)...]) {
            return (String(part[..<eq]), v)
        }
        return (part, 1)
    }

    /// Its ray-tracing quality groups count only in a session that traced rays (a "raytraced:" part): until 0.65 they
    /// were learned from sessions with every ray-traced effect off, and Hogwarts Legacy's read as −0.8 ms a frame each
    /// — the other settings changed alongside them, not anything they did.
    static func features(_ parts: [String]) -> [String: Double] {
        var out: [String: Double] = [:]
        let traced = parts.contains { $0.hasPrefix(Learn.rayTracedPrefix) }
        for p in parts {
            let f = feature(p)
            if !traced, f.name.hasPrefix("sg.Raytracing") { continue }
            out[f.name, default: 0] += f.amount
        }
        return out
    }

    struct Fit {
        /// ms of the game's GPU work a frame for one unit of each part, at the same scene load.
        var costs: [String: Double] = [:]
        /// Seconds of play on the less-played side of each part (with it and without, or at each amount).
        var support: [String: Double] = [:]
        /// Whether the scene load was timed — without it, costs can't be told from where the player was.
        var timed = false
        var minutes = 0.0
        var sessions = 0

        func known(_ name: String) -> Bool { (support[name] ?? 0) >= LearnModel.knownSeconds }
        func cost(_ parts: [String]) -> Double {
            LearnModel.features(parts).reduce(0) { $0 + (costs[$1.key] ?? 0) * $1.value }
        }
    }

    static func bin(_ scene: Float) -> Int { scene < 0 ? -1 : min(Int(scene), 24) }

    /// The costs, by backfitting: each scene load's own level of GPU work, and each part's ms on top, in turn,
    /// until they settle. Ridge-shrunk: a part played for a minute isn't trusted with a big number.
    func fit(now: Date = Date()) -> Fit {
        let data = samples.compactMap { s -> (bin: Int, f: [String: Double], y: Double, w: Double)? in
            guard s.game >= 0 else { return nil }
            return (Self.bin(s.scene), Self.features(s.parts), Double(s.game), weight(s, now: now))
        }
        var fit = Fit()
        fit.timed = data.contains { $0.bin >= 0 }
        fit.minutes = samples.reduce(0) { $0 + Double($1.seconds) } / 60
        fit.sessions = Set(samples.map(\.at)).count
        guard !data.isEmpty else { return fit }
        let names = Set(data.flatMap { $0.f.keys }).sorted()
        // Support: the lighter side of each part, in plain seconds.
        for n in names {
            var by: [Double: Double] = [:]
            for s in samples { by[Self.features(s.parts)[n] ?? 0, default: 0] += Double(s.seconds) }
            let most = by.max { $0.value < $1.value }?.key ?? 0
            fit.support[n] = by.filter { $0.key != most }.values.reduce(0, +)
        }
        var theta = Dictionary(uniqueKeysWithValues: names.map { ($0, 0.0) })
        var base: [Int: Double] = [:]
        for _ in 0..<40 {
            var sums: [Int: (w: Double, y: Double)] = [:]
            for d in data {
                let rest = d.f.reduce(0) { $0 + (theta[$1.key] ?? 0) * $1.value }
                let s = sums[d.bin] ?? (0, 0)
                sums[d.bin] = (s.w + d.w, s.y + d.w * (d.y - rest))
            }
            base = sums.mapValues { $0.y / max($0.w, 1e-9) }
            for n in names {
                var num = 0.0, den = 0.0
                for d in data {
                    guard let x = d.f[n] else { continue }
                    let others = d.f.reduce(0) { $0 + ($1.key == n ? 0 : (theta[$1.key] ?? 0) * $1.value) }
                    num += d.w * x * (d.y - (base[d.bin] ?? 0) - others)
                    den += d.w * x * x
                }
                theta[n] = num / (den + Self.shrink)
            }
        }
        fit.costs = theta
        return fit
    }

    // MARK: What a setup would do

    struct Prediction: Equatable {
        var parts: [String]
        /// Share of play at the target frame rate or more, of the game's own.
        var shareAt: Double
        var typicalFPS: Double
        var lowFPS: Double
        /// ms a frame more (or less) than what the play seen ran with, on average.
        var extraMs: Double
        /// Every part of it measured, or it is the setup most of the play ran with.
        var known: Bool
        var minutes: Double
    }

    /// What `parts` would have done over the play Learn has seen: each stretch as it was — its scene, the Mac on
    /// battery or not, Anvil's own work — with the difference in cost between that stretch's setup and this one.
    func predict(_ parts: [String], target: Double, fit: Fit, now: Date = Date()) -> Prediction? {
        let usable = samples.filter { $0.frame > 0 }
        guard !usable.isEmpty else { return nil }
        let want = fit.cost(parts)
        let limit = 1000 / max(target - 0.5, 1)
        var at = 0.0, total = 0.0, extra = 0.0
        var times: [(ms: Double, w: Double)] = []
        for s in usable {
            let w = weight(s, now: now)
            guard w > 0 else { continue }
            let delta = want - fit.cost(s.parts)
            let ms = max(Double(s.frame) + Self.slope * delta, 1)
            times.append((ms, w))
            total += w
            extra += w * delta
            if ms <= limit { at += w }
        }
        guard total > 0 else { return nil }
        times.sort { $0.ms < $1.ms }
        func percentile(_ p: Double) -> Double {
            var run = 0.0
            for t in times { run += t.w; if run >= p * total { return t.ms } }
            return times.last?.ms ?? 0
        }
        let mostPlayed = Dictionary(grouping: usable, by: { $0.parts }).max { a, b in
            a.value.reduce(0) { $0 + Double($1.seconds) } < b.value.reduce(0) { $0 + Double($1.seconds) }
        }?.key
        let known = parts.sorted() == mostPlayed || Self.features(parts).keys.allSatisfy { fit.known($0) }
            && Self.features(mostPlayed ?? []).keys.allSatisfy { fit.known($0) || Self.features(parts)[$0] != nil }
        return Prediction(parts: parts.sorted(), shareAt: at / total, typicalFPS: 1000 / percentile(0.5),
                          lowFPS: 1000 / percentile(0.9), extraMs: extra / total, known: known, minutes: fit.minutes)
    }
}

// MARK: - The parts of a setup

enum Learn {
    /// What a game runs with, as Learn tells setups apart: Anvil's graphics level for a game it tunes (Light is
    /// none), its reflections, an Unreal game's own quality settings, a Unity game's resolution.
    static func parts(level: GraphicsLevel?, reflections: Bool?, halfResolution: Bool?, unreal: [String: Int]) -> [String] {
        var out: [String] = []
        if let level, level != .light { out.append("level:\(level.rawValue)") }
        if reflections == true { out.append("reflections") }
        if halfResolution == false { out.append("resolution:full") }
        for (key, value) in unreal.sorted(by: { $0.key < $1.key }) { out.append("\(key)=\(value)") }
        return out
    }

    /// In a session's parts: the game made frames of its own between its own (GameUpscaler.FrameGen).
    static let gamesOwnFrames = "framegen:game"
    /// In a session's parts: a ray-traced effect the game had on, with D3DMetal offering it ray tracing —
    /// "raytraced:reflections" (GameUpscaler.rayTracedEffects).
    static let rayTracedPrefix = "raytraced:"

    /// The line at the top of a session in game.log that says what it ran with.
    static func setupLine(_ parts: [String]) -> String {
        "[anvil] setup: " + (parts.isEmpty ? "-" : parts.joined(separator: " "))
    }

    static func parseSetupLine(_ line: Substring) -> [String]? {
        guard let r = line.range(of: "[anvil] setup: ") else { return nil }
        let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest == "-" ? [] : rest.split(separator: " ").map(String.init)
    }

    static func describe(_ part: String) -> String {
        let f = LearnModel.feature(part)
        switch f.name {
        case "level:medium": return "Medium graphics"
        case "level:full": return "the game's own look (Full)"
        case "reflections": return "its reflections"
        case "resolution:full": return "full resolution"
        case "detail": return "distant detail trimmed (a step)"
        case "unreal:streaming": return "no garbage collection forced as the world streams out"
        case "unreal:dynamicres": return "dynamic resolution"
        case "unreal:pipelines": return "pipelines prepared in the background after a second"
        case "unreal:asyncloading": return "loading on its own thread"
        case "unreal:latency": return "a shorter queue to the GPU"
        case "unreal:texturepool": return "its textures' memory sized to this Mac"
        case "unreal:streamslices": return "the world streamed in smaller pieces"
        case "raytraced:reflections": return "ray-traced reflections"
        case "raytraced:shadows": return "ray-traced shadows"
        case "raytraced:ao": return "ray-traced ambient occlusion"
        default:
            let name = f.name.hasPrefix("sg.") ? String(f.name.dropFirst(3)) : f.name
            return name.replacingOccurrences(of: "Quality", with: " quality")
                .replacingOccurrences(of: "PostProcess", with: "Post-processing")
                .replacingOccurrences(of: "ViewDistance", with: "View distance")
                .replacingOccurrences(of: "AntiAliasing", with: "Anti-aliasing")
        }
    }

    // MARK: Unreal Engine's own quality settings

    /// An Unreal game's [ScalabilityGroups] (sg.ShadowQuality=3…), from the GameUserSettings.ini its program
    /// writes under AppData/Local/<its name>/Saved/Config. Read only: the player's own choices, learned from.
    static func unrealSettings(for game: Game, in container: Container) -> [String: Int] {
        // A game that keeps its options in a save too applies those over its ini once it has started (GameUpscaler).
        if let profile = GameUpscaler.profile(for: game),
           let save = GameUpscaler.optionsSaves(for: game, in: container, profile: profile).lazy.compactMap({ GameUpscaler.OptionsSave($0) }).first {
            return scalability(in: save.text)
        }
        guard let file = unrealSettingsFile(for: game, in: container),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        return scalability(in: text)
    }

    static func scalability(in text: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var inGroups = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inGroups = line == "[ScalabilityGroups]"; continue }
            guard inGroups, line.hasPrefix("sg."), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            // sg.ResolutionQuality is a percentage, not a level: left to the picture's own settings.
            guard key != "sg.ResolutionQuality", let v = Int(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)) else { continue }
            out[key] = v
        }
        return out
    }

    /// The game's GameUserSettings.ini: the Saved folder whose log is named after the game's project (Phoenix.log
    /// for Hogwarts Legacy, whose Saved folder is "Hogwarts Legacy"), or named after the game itself.
    static func unrealSettingsFile(for game: Game, in container: Container) -> URL? {
        guard let folder = UnrealConfig.folder(for: game, in: container) else { return nil }
        let ini = folder.appendingPathComponent("GameUserSettings.ini")
        return FileManager.default.fileExists(atPath: ini.path) ? ini : nil
    }
}

/// An Unreal Engine game's own config folder in its Windows setup — <AppData/Local>/<its name>/Saved/Config/
/// WindowsNoEditor (Windows on Unreal 5) — and the one setting Anvil puts in it before every start.
enum UnrealConfig {
    /// The folder, once the game has made it at its first start: the Saved folder named after its project
    /// (Phoenix for Hogwarts Legacy) or the game, or whose log is named after its project.
    static func folder(for game: Game, in container: Container) -> URL? {
        let program = GameAnalysis.drawingProgram(for: game.executableURL)
        let comps = program.pathComponents
        guard let bin = comps.lastIndex(of: "Binaries"), bin > 0 else { return nil }
        let project = comps[bin - 1].lowercased()
        let fm = FileManager.default
        let users = container.driveC.appendingPathComponent("users", isDirectory: true)
        guard let people = try? fm.contentsOfDirectory(atPath: users.path) else { return nil }
        for person in people where person != "Public" {
            let local = users.appendingPathComponent(person).appendingPathComponent("AppData/Local", isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: local.path) else { continue }
            for name in names {
                let saved = local.appendingPathComponent(name).appendingPathComponent("Saved", isDirectory: true)
                let logs = (try? fm.contentsOfDirectory(atPath: saved.appendingPathComponent("Logs").path)) ?? []
                let ours = name.lowercased() == project || name.lowercased() == game.title.lowercased()
                    || logs.contains { $0.lowercased() == project + ".log" }
                guard ours else { continue }
                for platform in ["WindowsNoEditor", "Windows"] {
                    var isDir: ObjCBool = false
                    let dir = saved.appendingPathComponent("Config/\(platform)", isDirectory: true)
                    if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return dir }
                }
            }
        }
        return nil
    }

    /// Unreal checks the graphics driver at start against its list of known-bad ones and says so in a window:
    /// "The installed version of the AMD graphics driver has known issues… Installed: 30.0.15.1233,
    /// Recommended: 23.2.1" (Hogwarts Legacy, 17 October). The "AMD driver" it reads is D3DMetal's, which it can't
    /// know and which there is nothing to update, so the warning is always wrong on a Mac. Unreal's own switch for
    /// it, r.WarnOfBadDrivers, set to 0 in the game's Engine.ini — the one line Anvil writes there. Returns the
    /// log line when it changed the file.
    static func prepare(_ game: Game, in container: Container) -> String? {
        guard let folder = folder(for: game, in: container) else { return nil }
        let ini = folder.appendingPathComponent("Engine.ini")
        let text = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let updated = settingSystem("r.WarnOfBadDrivers", to: "0", in: text)
        guard updated != text else { return nil }
        guard DiskCache.writeReplacing(Data(updated.utf8), to: ini, durable: true) else { return nil }
        return "unreal: \(game.title) — its graphics-driver warning off (r.WarnOfBadDrivers=0 in its Engine.ini): the \"AMD driver\" Unreal checks is D3DMetal, which isn't on its list and has nothing to update"
    }

    /// A key's value in the [SystemSettings] section of an ini; nil when absent.
    static func systemValue(_ key: String, in text: String) -> String? {
        var inside = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("[") { inside = line.trimmingCharacters(in: .whitespaces) == "[SystemSettings]"; continue }
            if inside, line.lowercased().hasPrefix(key.lowercased() + "=") { return String(line.dropFirst(key.count + 1)) }
        }
        return nil
    }

    /// The keys taken out of the [SystemSettings] section of an ini; the rest of the file as it was.
    static func removingSystem(_ keys: Set<String>, in text: String) -> String {
        guard !keys.isEmpty else { return text }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var inside = false
        let lowered = Set(keys.map { $0.lowercased() })
        let kept = text.components(separatedBy: newline).filter { line in
            if line.hasPrefix("[") { inside = line.trimmingCharacters(in: .whitespaces) == "[SystemSettings]"; return true }
            guard inside, let eq = line.firstIndex(of: "=") else { return true }
            return !lowered.contains(line[..<eq].lowercased())
        }
        return kept.joined(separator: newline)
    }

    /// `key=value` in the [SystemSettings] section of an ini, added or changed; the rest of the file as it was.
    static func settingSystem(_ key: String, to value: String, in text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: newline)
        if lines.last == "" { lines.removeLast() }
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[SystemSettings]" }) else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += ["[SystemSettings]", "\(key)=\(value)"]
            return lines.joined(separator: newline) + newline
        }
        var end = lines.count
        for i in (header + 1)..<lines.count where lines[i].hasPrefix("[") { end = i; break }
        if let i = (header + 1..<end).first(where: { lines[$0].lowercased().hasPrefix(key.lowercased() + "=") }) {
            lines[i] = "\(key)=\(value)"
        } else {
            lines.insert("\(key)=\(value)", at: header + 1)
        }
        return lines.joined(separator: newline) + newline
    }
}

// MARK: - Kept, and used

@MainActor
final class LearnStore: ObservableObject {
    static let shared = LearnStore()
    @Published private(set) var models: [String: LearnModel] = [:]

    nonisolated(unsafe) static var directory: URL = RuntimeManager.support.appendingPathComponent("Learn", isDirectory: true)

    /// A game is known by its program's name, so what was learned survives removing and reinstalling it.
    static func key(for game: Game) -> String {
        let program = game.executableURL.deletingPathExtension().lastPathComponent.lowercased()
        return String((program + "-" + Guardian.macKey).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    private func url(_ key: String) -> URL { Self.directory.appendingPathComponent("\(key).json") }

    func model(for game: Game) -> LearnModel? {
        let key = Self.key(for: game)
        if let m = models[key] { return m }
        guard let data = try? Data(contentsOf: url(key)), let m = try? JSONDecoder().decode(LearnModel.self, from: data) else { return nil }
        models[key] = m
        return m
    }

    private func save(_ model: LearnModel, key: String) {
        models[key] = model
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(model) { DiskCache.writeReplacing(data, to: url(key)) }
    }

    /// What this launch runs with, as parts — written to game.log at the session's start.
    static func parts(for game: Game, in container: Container, level: GraphicsLevel) -> [String] {
        let profiled = GameTuning.profile(for: game) != nil
        let analysis = GameAnalysis.cached(for: game.executableURL)
        let halves = !profiled && (analysis?.rendersAtWindowSize ?? false)
        return Learn.parts(level: profiled ? level : nil,
                           reflections: profiled ? GameTuning.reflectionsOn(game, in: container, level: level) : nil,
                           halfResolution: halves ? container.profile.renderScale() < 1.5 : nil,
                           unreal: analysis?.engine == .unreal ? Learn.unrealSettings(for: game, in: container) : [:])
    }

    /// After a session: learn from it. Off the main thread; returns at once.
    func sessionEnded(game: Game) {
        let title = game.title, key = Self.key(for: game), log = Launcher.gameLogURL
        var model = model(for: game) ?? LearnModel(program: game.executableURL.lastPathComponent, mac: Guardian.macKey)
        Task {
            let found = await Task.detached(priority: .utility) { () -> (Date, [String], [FrameWindow])? in
                guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
                return Self.lastSession(of: title, text: text)
            }.value
            guard let (start, parts, windows) = found else { return }
            let n = model.learn(startedAt: start, parts: parts, windows: windows)
            guard n > 0 else { return }
            self.save(model, key: key)
            let fit = model.fit()
            AnvilLog.write(String(format: "learn: \(title) — %d stretches of play learned (%.0f min over %d sessions on this Mac)%@",
                                  n, fit.minutes, fit.sessions, Self.costsText(fit).map { "; " + $0 } ?? ""))
            if let line = self.adjust(gameID: game.id, model: model, fit: fit) { AnvilLog.write(line) }
        }
    }

    /// A session's start, setup and stretches, the last of `title` in game.log's text. Nil without a setup line:
    /// sessions from before 0.59 didn't say what they ran with.
    nonisolated static func lastSession(of title: String, text: String) -> (Date, [String], [FrameWindow])? {
        guard let header = text.range(of: "=== \(title) — ", options: .backwards) else { return nil }
        let rest = text[header.upperBound...]
        guard let date = rest.split(separator: " ", maxSplits: 1).first.flatMap({ ISO8601DateFormatter().date(from: String($0)) }) else { return nil }
        var parts: [String]?
        var windows: [FrameWindow] = []
        for line in rest.split(separator: "\n").dropFirst() {
            if line.hasPrefix("=== ") { break }
            if parts == nil, let p = Learn.parseSetupLine(line) { parts = p; continue }
            if let w = FrameLog.parse(line) { windows.append(w) }
        }
        guard let parts else { return nil }
        return (date, parts, windows)
    }

    nonisolated static func costsText(_ fit: LearnModel.Fit) -> String? {
        let known = fit.costs.filter { fit.known($0.key) }.sorted { abs($0.value) > abs($1.value) }
        guard !known.isEmpty else { return nil }
        return known.prefix(4).map { String(format: "%@ %@%.1f ms a frame", Learn.describe($0.key), $0.value >= 0 ? "+" : "−", abs($0.value)) }
            .joined(separator: ", ")
    }

    // MARK: Choosing

    /// For a game Anvil tunes, on Automatic: the setup Learn finds best for the goal, from what it predicts each
    /// would do over the play it has seen — only among setups whose parts it has measured, and only when that
    /// changes what Auto-Tune chose. Returns the log line.
    private func adjust(gameID: UUID, model: LearnModel, fit: LearnModel.Fit) -> String? {
        guard let game = Library.shared.games.first(where: { $0.id == gameID }), game.graphicsTuning == .automatic,
              game.autopilot, GameTuning.profile(for: game) != nil, fit.timed else { return nil }
        let goal = game.tuneGoal ?? Tuner.shared.state(for: game)?.goal ?? .smooth
        guard let choice = Self.choose(model: model, fit: fit, goal: goal, reflectionsChosen: game.rayTracing) else { return nil }
        let now = Tuner.shared.graphicsLevel(for: game)
        guard choice.level != now else { return nil }
        Tuner.shared.adoptLearned(choice.level, reason: choice.reason, for: game)
        return "learn: \(game.title) — \(choice.level.title) graphics from the next start: \(choice.reason)"
    }

    struct Choice { var level: GraphicsLevel; var reflections: Bool; var prediction: LearnModel.Prediction; var reason: String }

    /// The goal's rules (TunePlanner's) on predicted play: the best look that meets it, else the one that comes
    /// closest — a lighter look only when it holds the target clearly longer (8 points of the time).
    nonisolated static func choose(model: LearnModel, fit: LearnModel.Fit, goal: TuneGoal, reflectionsChosen: Bool?,
                                   target: Double = DisplayProfile.steadyTarget) -> Choice? {
        var options: [(level: GraphicsLevel, rt: Bool, p: LearnModel.Prediction)] = []
        // Light and Medium only: the game's own look (Full) is the player's to choose. Learn measured it at about
        // 0.2 ms a frame more than Medium with reflections for LEGO Star Wars — nearly free — but its water and
        // heat distortion warp the picture under FSR 3 and Smooth Motion, which the player saw on 14 October.
        for level in [GraphicsLevel.light, .medium] {
            for rt in reflectionsChosen.map({ [$0] }) ?? [false, true] {
                let parts = Learn.parts(level: level, reflections: rt, halfResolution: nil, unreal: [:])
                guard let p = model.predict(parts, target: goal == .quality ? 60 : target, fit: fit), p.known else { continue }
                options.append((level, rt, p))
            }
        }
        guard options.count >= 2 else { return nil }
        func rank(_ o: (level: GraphicsLevel, rt: Bool, p: LearnModel.Prediction)) -> Int { o.level.rank * 2 + (o.rt ? 1 : 0) }
        let pick: (level: GraphicsLevel, rt: Bool, p: LearnModel.Prediction)
        let pct = { (v: Double) in String(format: "%.0f%%", v * 100) }
        switch goal {
        case .maxFPS:
            let top = options.map(\.p.typicalFPS).max() ?? 0
            pick = options.filter { $0.p.typicalFPS >= top * TunePlanner.sameSpeed }.max { rank($0) < rank($1) }!
        default:
            if let best = options.filter({ $0.p.shareAt >= 0.95 }).max(by: { rank($0) < rank($1) }) {
                pick = best
            } else {
                pick = options.max { a, b in
                    abs(a.p.shareAt - b.p.shareAt) >= TunePlanner.clearlyLonger ? a.p.shareAt < b.p.shareAt : rank(a) < rank(b)
                }!
            }
        }
        let others = options.filter { !($0.level == pick.level && $0.rt == pick.rt) }
            .sorted { rank($0) > rank($1) }.prefix(2)
            .map { "\($0.level.title)\($0.rt ? " with reflections" : "") \(pct($0.p.shareAt))" }
        let reason = "over the \(String(format: "%.0f", pick.p.minutes)) minutes of play Learn has seen here, "
            + "\(pick.level.title)\(pick.rt ? " with its reflections" : "") would be at \(Int(goal == .quality ? 60 : target)) fps or more \(pct(pick.p.shareAt)) of the time"
            + (others.isEmpty ? "" : " (" + others.joined(separator: ", ") + ")")
        return Choice(level: pick.level, reflections: pick.rt, prediction: pick.p, reason: reason)
    }

    /// The Ray Tracing switch on Automatic, for a game Anvil tunes: its reflections on while Learn finds they cost
    /// the play little — 3 points of the time at the target or less — and off where they would cost more. Nil
    /// until their cost has been measured (the level decides, as before) and while the switch is set by hand.
    func reflections(for game: Game, level: GraphicsLevel) -> (on: Bool, line: String)? {
        guard game.rayTracing == nil, GameTuning.profile(for: game)?.rayTraced != nil, let model = model(for: game) else { return nil }
        let fit = model.fit()
        guard fit.timed, fit.known("reflections"), let cost = fit.costs["reflections"] else { return nil }
        let target = DisplayProfile.steadyTarget
        guard let with = model.predict(Learn.parts(level: level, reflections: true, halfResolution: nil, unreal: [:]), target: target, fit: fit),
              let without = model.predict(Learn.parts(level: level, reflections: false, halfResolution: nil, unreal: [:]), target: target, fit: fit)
        else { return nil }
        let drop = without.shareAt - with.shareAt
        let on = drop <= 0.03
        let words = String(format: "they cost %.1f ms a frame here — %@ fps or more %.0f%% of the time with them, %.0f%% without", cost,
                           String(Int(target)), with.shareAt * 100, without.shareAt * 100)
        return (on, "ray tracing: reflections \(on ? "on" : "off") for \(game.title), as Learn found — \(words)"
                    + (on ? "" : "; the Ray Tracing switch turns them on anyway"))
    }

    /// Sessions in game.log not learned yet — Anvil closed while a game ran, or a session before an update —
    /// at Anvil's start and while it sits idle.
    func catchUp() async {
        for game in Library.shared.games where game.exists && !SteamSupport.isSteamClient(game) {
            let key = Self.key(for: game), title = game.title
            var model = model(for: game) ?? LearnModel(program: game.executableURL.lastPathComponent, mac: Guardian.macKey)
            let sessions = await Task.detached(priority: .utility) { Self.allSessions(of: title) }.value
            let before = model.sessions.count
            for (start, parts, windows) in sessions { model.learn(startedAt: start, parts: parts, windows: windows) }
            if model.sessions.count > before {
                save(model, key: key)
                AnvilLog.write("learn: \(title) — \(model.sessions.count - before) session\(model.sessions.count - before == 1 ? "" : "s") it hadn't learned from yet, from game.log")
            }
        }
    }

    // MARK: While nothing is played

    private var watching = false
    private(set) var lastIdleWork: Date?

    /// While Anvil is open and no game has run for a while: what can be done for the next start, done now rather
    /// than when Play is pressed — sessions not learned yet learned, and Graphics Prep run again for a game whose
    /// prep no longer holds (macOS, Anvil's shaders or the GPU changed since), which would otherwise hold its next
    /// start up. Plugged in, the Mac not hot, at most once every 20 minutes; one game's prep each time.
    func watchWhileIdle() {
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .seconds(20 * 60))
                await idleWork()
            }
        }
    }

    func idleWork() async {
        guard Launcher.shared.isIdle, !MemoryWarmup.onBattery, PowerState.shared.thermal.rawValue < ProcessInfo.ThermalState.serious.rawValue,
              !PowerState.shared.lowPowerMode else { return }
        if let last = Library.shared.games.compactMap(\.lastPlayed).max(), Date().timeIntervalSince(last) < 10 * 60 { return }
        lastIdleWork = Date()
        await catchUp()
        for game in Library.shared.games where game.exists && game.prepareGraphics && !SteamSupport.isSteamClient(game) {
            guard Launcher.shared.isIdle, let container = Library.shared.container(id: game.containerID),
                  Launcher.interceptorWanted(game: game, container: container),
                  GraphicsPrep.stored(gameID: game.id) != nil,          // only ever-prepared games; a first prep is the launch's
                  let why = GraphicsPrep.reason(gameID: game.id),
                  let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) ?? RuntimeManager.shared.defaultRuntime else { continue }
            AnvilLog.write("learn: \(game.title) — Graphics Prep again while Anvil sits idle (\(why)), so the next start doesn't wait for it")
            _ = await GraphicsPrepRunner.shared.run(game: game, container: container, runtime: runtime, beforeLaunch: false,
                                                    reason: why + ", done while Anvil sat idle")
            break
        }
    }

    /// Every session of `title` in game.log and game.old.log that says what it ran with.
    nonisolated static func allSessions(of title: String) -> [(Date, [String], [FrameWindow])] {
        var out: [(Date, [String], [FrameWindow])] = []
        for url in [Launcher.gameLogURL.deletingPathExtension().appendingPathExtension("old.log"), Launcher.gameLogURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var start: Date?, parts: [String]?, windows: [FrameWindow] = []
            func flush() { if let start, let parts, !windows.isEmpty { out.append((start, parts, windows)) } }
            var inTitle = false
            for line in text.split(separator: "\n") {
                if line.hasPrefix("=== ") {
                    if inTitle { flush() }
                    inTitle = line.hasPrefix("=== \(title) — ")
                    start = inTitle ? line.dropFirst("=== \(title) — ".count).split(separator: " ").first.flatMap { ISO8601DateFormatter().date(from: String($0)) } : nil
                    parts = nil; windows = []
                    continue
                }
                guard inTitle else { continue }
                if parts == nil, let p = Learn.parseSetupLine(line) { parts = p; continue }
                if let w = FrameLog.parse(line) { windows.append(w) }
            }
            if inTitle { flush() }
        }
        return out
    }
}
