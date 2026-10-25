import AppKit
import Foundation

/// Unreal Engine's own settings tuned for this Mac, for an Unreal game bought on Steam or Epic and installed through
/// Anvil. A tuning is a few of the engine's console settings in the [SystemSettings] of the game's own Engine.ini —
/// never its files or its code — and only settings its program has. Each is tried for a session and kept only when
/// that session measured better than the ones before it; a game that ends unexpectedly with one on trial starts
/// without it next time.
///
/// Why: Hogwarts Legacy held 80 fps inside the castle and fell to 65–75 over the open world (24 October), with a
/// stutter every 5–9 s for minutes at a time while it travelled — 279 of its 319 its own work, with nothing read from
/// disk and no shader compiled. Unreal 4 collects its garbage on the game's thread each time a part of the world
/// streams out — its own setting reclaims the memory "at the expense of a hitch" — and under Rosetta that collection
/// is slower still. Tried there on 24 October, it made no difference (2.0 → 2.2 a minute) and was dropped by itself.
///
/// Over the open world the GPU is the limit: flying over Hogwarts Legacy's at Ultra held 38–44 fps with the GPU 97–99%
/// busy and its memory climbing from 17 to 19.6 GB in three minutes, where Hogsmeade and the castle ran 50–60. Unreal's
/// dynamic resolution is made for that: fewer pixels only in the frames that would miss, more where there's room.
///
/// And its loading: every start of Hogwarts Legacy stopped for 5.1–5.3 s at its title screen with next to nothing read,
/// and its loading screens for 1.8–2.8 s as it read 0.7–1.5 GB (22–24 October).
enum UnrealTuning {
    /// What a start writes a tuning for: whether the game makes frames of its own (its own frame generation on), and the
    /// frame rate it should hold (Game.fpsGoal: 60, or the display's steady rate).
    struct Context: Equatable {
        var ownFrames = false
        var goal = 80
        /// Every context a setting may have been written for, so each of its values is known as Anvil's.
        static var all: [Context] {
            Set([60, 80, Int(DisplayProfile.steadyTarget)]).sorted().flatMap { [Context(ownFrames: false, goal: $0), Context(ownFrames: true, goal: $0)] }
        }
    }

    struct Tuning {
        /// What a trial is judged by: the game's own stutters a minute of play; the share of its play at its frame-rate
        /// goal; or how long its start and its loading screens stop.
        enum Metric: Equatable { case ownStutters, frameRate, loading }
        let id: String
        /// What it does, for the game's page and the log.
        let title: String
        let metric: Metric
        let keys: (Context) -> [(String, String)]
        /// Every key=value it may write.
        var variants: [(String, String)] {
            var out: [(String, String)] = []
            for c in Context.all { for k in keys(c) where !out.contains(where: { $0 == k }) { out.append(k) } }
            return out
        }
    }

    /// The memory of a part of the world that has streamed out reclaimed at the game's regular collection, rather than
    /// by one forced on the game's thread there and then — and no further collections kicked off while it waits.
    static let streaming = Tuning(id: "streaming", title: "no garbage collection forced as the world streams out", metric: .ownStutters,
                                  keys: { _ in [("s.ForceGCAfterLevelStreamedOut", "0"),
                                                ("s.ContinuouslyIncrementalGCWhileLevelsPendingPurge", "0")] })
    /// Unreal's dynamic resolution, on whatever the game's menu says: the game draws fewer pixels in the frames that
    /// would miss its goal — as it flies over an open world — down to two-fifths of its window each way, and more where
    /// there's room, up to two-thirds, sharper than a Performance upscaler's half. Its budget is a frame the game draws:
    /// with its own frame generation every other frame shown is made, so twice the goal's frame time — 33.3 ms for 60
    /// shown, 25 for 80; without, 16.7 and 12.5.
    static let dynamicResolution = Tuning(id: "dynamicres", title: "dynamic resolution", metric: .frameRate,
                                          keys: { c in [("r.DynamicRes.OperationMode", "2"),
                                                        ("r.DynamicRes.FrameTimeBudget", String(format: "%.1f", (c.ownFrames ? 2000 : 1000) / Double(max(c.goal, 1)))),
                                                        ("r.DynamicRes.MinScreenPercentage", "40"),
                                                        ("r.DynamicRes.MaxScreenPercentage", "67")] })
    /// Its pipelines prepared for at most a second before its title screen, the rest in the background as it plays. Every
    /// start of Hogwarts Legacy stopped for 5.1–5.3 s, 40 s in, with next to nothing read: the length of a limit, not of
    /// work — Unreal's r.ShaderPipelineCache.MaxPrecompileTime, the wall time the game may block for before carrying on in
    /// the background. Its shaders are in D3DMetal's cache by then, so each one later is a lookup rather than a compile.
    static let pipelines = Tuning(id: "pipelines", title: "pipelines prepared in the background after a second", metric: .loading,
                                  keys: { _ in [("r.ShaderPipelineCache.MaxPrecompileTime", "1")] })
    /// Loading on Unreal's own loading thread rather than the game's: Hogwarts Legacy's loading screens stopped for
    /// 1.8–2.8 s as it read 0.7–1.5 GB — 400–500 MB a second, a fraction of the SSD's — the game's thread unpacking it all.
    static let asyncLoading = Tuning(id: "asyncloading", title: "loading on its own thread", metric: .loading,
                                     keys: { _ in [("s.AsyncLoadingThreadEnabled", "1")] })
    /// In the order they're tried: one at a time of each kind.
    static let tunings = [streaming, dynamicResolution, pipelines, asyncLoading]

    /// Distant detail trimmed for an even 80, a step at a time: distant objects' simpler models sooner, distant
    /// foliage's too, and the smallest objects left out of the shadow maps. Hogwarts Legacy's heavy scenes at Ultra on a
    /// base M4 (23 October) spent 12 ms a frame drawing the scene at 756 × 492 and up to 8.6 ms on shadow maps: the
    /// number of things drawn, not pixels. A game whose settings GameUpscaler knows trims it there, in its own order;
    /// any other Unreal game here.
    static let detailLevels: [[(String, String)]] = [
        [("r.StaticMeshLODDistanceScale", "1.25"), ("foliage.LODDistanceScale", "0.85"), ("r.Shadow.RadiusThreshold", "0.03")],
        [("r.StaticMeshLODDistanceScale", "1.5"), ("foliage.LODDistanceScale", "0.7"), ("r.Shadow.RadiusThreshold", "0.05")],
        [("r.StaticMeshLODDistanceScale", "2.0"), ("foliage.LODDistanceScale", "0.55"), ("r.Shadow.RadiusThreshold", "0.08")],
    ]

    /// Below this many of its own stutters a minute of play there is nothing for a tuning to win.
    static let rareStutters = 0.3
    /// A trial is kept when its session had at most this share of the stutters a minute of the ones before…
    static let keepAtMost = 0.85
    /// …and the game's memory at its most rose by no more than this.
    static let memoryAllowanceMB = 1536.0
    /// Play long enough to judge a trial by, and to count towards how the game ran before.
    static let judgeMinutes = 10.0
    /// A stretch is in the game's world, not a title screen or menu before a save loads, with this share of the
    /// memory it took at its most.
    static let worldMemoryShare = 0.7
    /// A frame-rate trial is kept with this much more of its play at its goal (a share), or this much more on average…
    static let keepShareGain = 0.10
    static let keepFPSGain = 1.10
    /// …and its own stutters no more than this many times as often.
    static let stutterAllowance = 1.25
    /// A frame-rate tuning isn't needed by a game that held its goal this much of its play.
    static let holdsGoal = 0.8
    /// A loading trial is kept when its start's stop is at most half as long as before (and no more than this)…
    static let startFreezeKeep = 2.0
    /// …or its loading screens stop for at most this share of the time they did.
    static let loadStallKeep = 0.7

    // MARK: Who

    enum Eligibility: Equatable { case tuned, notUnreal, notFromStore, off }

    /// Bought on Steam or Epic and installed through Anvil's own Steam or Epic. Not a program added by hand.
    static func fromStore(_ game: Game) -> Bool { game.steamAppID != nil || game.epicAppName != nil }

    static func isUnreal(_ game: Game) -> Bool { GameAnalysis.cached(for: game.executableURL)?.engine == .unreal }

    static func eligibility(_ game: Game, unreal: Bool) -> Eligibility {
        guard unreal else { return .notUnreal }
        guard fromStore(game) else { return .notFromStore }
        return game.unrealTuning ? .tuned : .off
    }

    // MARK: What it keeps

    /// The game's own stutters a minute of play, how long that was, and the most memory it took; its frame rate against
    /// its goal, and how wide it drew (the commonest width of its passes at the game's own shape); and how long its start
    /// and its loading screens stopped, and its stutters from compiling shaders a minute.
    struct Measure: Codable, Equatable {
        var perMinute: Double
        var minutes: Double
        var memoryMB: Double?
        var shareAtGoal: Double? = nil
        var goal: Int? = nil
        var averageFPS: Double? = nil
        var renderWidth: Int? = nil
        var startFreeze: Double? = nil
        var loadStall: Double? = nil
        var compilePerMinute: Double? = nil
    }

    struct Record: Codable, Equatable {
        enum State: String, Codable { case trial, kept, dropped, notNeeded }
        /// When the player was told what Anvil does here, before its first tuned start.
        var acknowledged: Date?
        var states: [String: State] = [:]
        /// What decided each, in words, for the page.
        var notes: [String: String] = [:]
        /// Its own stutters a minute of play in the sessions before any tuning was on trial.
        var baseline: Measure?
        /// Its frame rate in its last session with no frame-rate tuning on, for one on trial to be judged against.
        var fpsBaseline: Measure?
        /// Its start's and loading screens' stops in its last sessions with no loading tuning on.
        var loadBaseline: Measure?
        /// How its last judged session went.
        var last: Measure?
        /// What its last start ran with: tunings' ids, and "detail=2" for its distant detail's step.
        var active: [String] = []
        /// Distant detail for a game GameUpscaler has no profile of: the step its last start ran at, and the next.
        var detail: Int?
        var detailNext: Int?
        /// The settings found in its program, which were looked for, and which build of it they were looked for in.
        var programStamp: String?
        var present: [String]?
        var lookedFor: [String]?
        /// Its Engine.ini as the game had it, kept before Anvil's first change to it.
        var backedUp: Bool?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            acknowledged = c.optional("acknowledged")
            states = c.value("states", [:])
            notes = c.value("notes", [:])
            baseline = c.optional("baseline")
            fpsBaseline = c.optional("fpsBaseline")
            loadBaseline = c.optional("loadBaseline")
            last = c.optional("last")
            active = c.value("active", [])
            detail = c.optional("detail")
            detailNext = c.optional("detailNext")
            programStamp = c.optional("programStamp")
            present = c.optional("present")
            lookedFor = c.optional("lookedFor")
            backedUp = c.optional("backedUp")
        }
    }

    nonisolated(unsafe) static var directory: URL = RuntimeManager.support.appendingPathComponent("UnrealTuning", isDirectory: true)

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

    /// Its Engine.ini as it was before Anvil first changed it.
    static func backupURL(for game: Game) -> URL { directory.appendingPathComponent("\(game.id.uuidString)-Engine.ini") }

    /// Every key=value Anvil may write to its Engine.ini here; distant detail only where GameUpscaler doesn't.
    static func managed(hasProfile: Bool) -> [(String, String)] {
        tunings.flatMap(\.variants) + (hasProfile ? [] : detailLevels.flatMap { $0 })
    }

    // MARK: Its program

    /// Which of `names` its program has: Unreal keeps its console settings' names in UTF-16, the rest in ASCII.
    static func present(_ names: [String], in program: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: program, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> Set<String>? in
            guard let base = raw.baseAddress else { return [] }
            var found = Set<String>()
            for name in names {
                let wide = name.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
                for needle in [wide, Array(name.utf8)] {
                    let hit = needle.withUnsafeBytes { n in memmem(base, raw.count, n.baseAddress, n.count) }
                    if hit != nil { found.insert(name); break }
                }
            }
            return found
        }
    }

    /// A build of the program: its size and when it was written.
    static func stamp(_ program: URL) -> String? {
        guard let v = try? program.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return "\(size)-\(Int(date.timeIntervalSince1970))"
    }

    // MARK: Its Engine.ini

    /// The ini with `wanted` set and the rest of `managed` taken out — except a key the player set themselves, to a
    /// value none of Anvil's, which is theirs and left as it is. Returns those keys too.
    static func applying(_ wanted: [(String, String)], managed: [(String, String)], in text: String) -> (text: String, theirs: Set<String>) {
        let keys = Set(managed.map(\.0))
        let ours = Set(managed.map { "\($0.0.lowercased())=\($0.1)" })
        let theirs = keys.filter { k in UnrealConfig.systemValue(k, in: text).map { !ours.contains("\(k.lowercased())=\($0)") } ?? false }
        let want = wanted.filter { !theirs.contains($0.0) }
        var updated = UnrealConfig.removingSystem(keys.subtracting(theirs).subtracting(want.map(\.0)), in: text)
        for (k, v) in want { updated = UnrealConfig.settingSystem(k, to: v, in: updated) }
        return (updated, theirs)
    }

    // MARK: How a session went

    struct Played: Equatable {
        var ownStutters: Int
        var minutes: Double
        var memoryMB: Double?
        /// Of its stretches of play without a load in them, the share of the time at its goal or more, and the average.
        var shareAtGoal: Double
        var averageFPS: Double = 0
        /// The widths its passes were drawn at in the game's own shape, below its window's: how many of each.
        var renderWidths: [Int: Int] = [:]
        var goal: Int = 80
        /// How long it stopped near its start with next to nothing read (its title screen), and each loading screen's stop
        /// (0.1 GB or more read meanwhile), in seconds; its stutters from compiling shaders in its world.
        var startFreeze: Double? = nil
        var loadStalls: [Double] = []
        var compileStutters: Int = 0
        var perMinute: Double { minutes > 0 ? Double(ownStutters) / minutes : 0 }
        var renderWidth: Int? { renderWidths.max { $0.value < $1.value }?.key }
        var loadStall: Double? { loadStalls.isEmpty ? nil : loadStalls.reduce(0, +) / Double(loadStalls.count) }
        var compilePerMinute: Double { minutes > 0 ? Double(compileStutters) / minutes : 0 }
        var measure: Measure {
            Measure(perMinute: perMinute, minutes: minutes, memoryMB: memoryMB, shareAtGoal: shareAtGoal, goal: goal,
                    averageFPS: averageFPS, renderWidth: renderWidth, startFreeze: startFreeze, loadStall: loadStall,
                    compilePerMinute: compilePerMinute)
        }
    }

    /// Whether the game drew at changing sizes: three widths or more seen a few times each, or a commoner width another
    /// than before. Nil when libanvil timed no passes to say.
    static func engaged(_ p: Played, before: Measure?) -> Bool? {
        guard let width = p.renderWidth else { return nil }
        if p.renderWidths.filter({ $0.value >= 2 }).count >= 3 { return true }
        guard let was = before?.renderWidth, was > 0 else { return nil }
        return abs(Double(width - was)) / Double(was) > 0.05
    }

    /// The last session of `title` in a game.log's text: from its header to the next.
    static func lastSession(of title: String, in text: String) -> Substring? {
        guard let h = text.range(of: "=== \(title) — ", options: .backwards) else { return nil }
        return text[h.lowerBound...]
    }

    /// The game's own stutters — Guardian's, put down to neither its data, its shaders nor the GPU — a minute of play in
    /// its world, from a session of game.log (its header onwards; the next header ends it). Its world: past its first
    /// two stretches, not behind another app, and — where libanvil reads the game's memory — with most of what it took
    /// loaded, so a title screen sat at before a save loads isn't counted: Hogwarts Legacy sat at its title for 37
    /// minutes at 9.6 GB on 24 October, with 6 stutters, against 15–17 GB in its world.
    static func played(session text: Substring, goal: Int = Int(DisplayProfile.steadyTarget)) -> Played? {
        var day = 0.0, last = -1.0
        // "19:04:27.677 [anvil] …", local time; past midnight it starts again from 0.
        func time(_ line: Substring) -> Double? {
            let head = line.prefix(12)
            guard head.count == 12, head.dropFirst(2).first == ":" else { return nil }
            let parts = head.split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            var t = h * 3600 + m * 60 + s + day
            if last >= 0, t < last - 43_200 { day += 86_400; t += 86_400 }
            last = t
            return t
        }
        var windows: [(end: Double, w: FrameWindow)] = []
        var stutters: [Double] = []
        var compiles: [Double] = []
        var stops: [(at: Double, seconds: Double, mb: Double)] = []
        var began: Double?
        var sizes: [(Int, Int)] = []
        var window: (Int, Int)?
        var header = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("=== ") {
                if header { break }
                header = true
                continue
            }
            if line.contains("[anvil] displayed ") {
                guard let t = time(line), let w = FrameLog.parse(line) else { continue }
                windows.append((t, w))
                // "| FSR 1512x982 to 3024x1964": the size the game draws its window at.
                if window == nil, let r = line.range(of: #"\| FSR \d+x\d+ to"#, options: .regularExpression) {
                    let pair = line[r].dropFirst(6).dropLast(3).split(separator: "x")
                    if pair.count == 2, let w = Int(pair[0]), let h = Int(pair[1]), h > 0 { window = (w, h) }
                }
            } else if line.contains("[anvil] guardian: stutter ") {
                guard let t = time(line) else { continue }
                if line.contains("mostly the game's own work") { stutters.append(t) }
                if line.contains("mostly compiling shaders") { compiles.append(t) }
            } else if line.contains("[anvil] frames RESUMED after ") {
                // "frames RESUMED after 5.1 s without a frame — 1.0 MB of its data read meanwhile"
                guard let t = time(line), let r = line.range(of: #"after [\d.]+ s without a frame — [\d.]+ MB"#, options: .regularExpression) else { continue }
                let v = line[r].split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
                if v.count >= 2 { stops.append((t, v[0], v[1])) }
            } else if began == nil, line.contains("[anvil] ") {
                began = time(line)
            }
            // libanvil's timed passes: "heaviest passes (of a 30.0 ms frame): smaller effects 4.5 ms (756x492, 7 colour …)".
            if line.contains("heaviest passes") || line.contains("frame anatomy:") || line.contains("| GPU work ") {
                var rest = line[...]
                while let r = rest.range(of: #"\((\d+)x(\d+),"#, options: .regularExpression) {
                    let pair = rest[r].dropFirst().dropLast().split(separator: "x")
                    if pair.count == 2, let w = Int(pair[0]), let h = Int(pair[1]), h > 0 { sizes.append((w, h)) }
                    rest = rest[r.upperBound...]
                }
            }
        }
        let peak = windows.compactMap(\.w.memoryMB).max()
        let world = windows.dropFirst(2).filter { e in
            guard !e.w.wasBehind, e.w.displayed >= 5 else { return false }
            guard let peak, let mb = e.w.memoryMB else { return true }
            return mb >= peak * worldMemoryShare
        }
        let seconds = world.reduce(0) { $0 + $1.w.seconds }
        guard seconds > 0 else { return nil }
        let spans = world.map { ($0.end - $0.w.seconds, $0.end) }
        let own = stutters.filter { t in spans.contains { t > $0.0 && t <= $0.1 } }.count
        let compiled = compiles.filter { t in spans.contains { t > $0.0 && t <= $0.1 } }.count
        // Its start's stop: within four minutes of its first line, three seconds or more, next to nothing read. Its loading
        // screens: a stop with 0.1 GB or more read. (A stop with nothing read later on is the Mac asleep, or a pause.)
        let start = began ?? windows.first?.end ?? 0
        let startFreeze = stops.first { $0.at - start < 240 && $0.seconds >= 3 && $0.mb < 100 }?.seconds
        let loadStalls = stops.filter { $0.mb >= 100 }.map(\.seconds)
        let smooth = world.filter { $0.w.worstGapMs < Gameplay.stallMs }
        let smoothSeconds = smooth.reduce(0) { $0 + $1.w.seconds }
        let atGoal = smooth.filter { $0.w.displayed >= Double(goal) - 0.5 }.reduce(0) { $0 + $1.w.seconds }
        let shown = smooth.reduce(0) { $0 + $1.w.displayed * $1.w.seconds }
        // Its window: as its stats say, or else the widest pass in a screen's shape. What it draws the scene at: passes of
        // the same shape, narrower.
        var widths: [Int: Int] = [:]
        if let window = window ?? sizes.filter({ Double($0.0) / Double($0.1) > 1.2 && Double($0.0) / Double($0.1) < 2.5 && $0.0 <= 4096 }).max(by: { $0.0 < $1.0 }) {
            let shape = Double(window.0) / Double(window.1)
            for (w, h) in sizes where abs(Double(w) / Double(h) - shape) < 0.06 && Double(w) >= 0.3 * Double(window.0) && Double(w) < 0.95 * Double(window.0) {
                widths[w, default: 0] += 1
            }
        }
        return Played(ownStutters: own, minutes: seconds / 60, memoryMB: peak,
                      shareAtGoal: smoothSeconds > 0 ? atGoal / smoothSeconds : 0,
                      averageFPS: smoothSeconds > 0 ? shown / smoothSeconds : 0, renderWidths: widths, goal: goal,
                      startFreeze: startFreeze, loadStalls: loadStalls, compileStutters: compiled)
    }

    /// Its own stutters a minute over its last `sessions` sessions in `text` (game.old.log, then game.log) of at least
    /// `judgeMinutes` of play, weighted by how long each was.
    static func history(of title: String, in text: String, sessions: Int = 3) -> Measure? {
        combined(untuned(of: title, in: text, by: tunings, sessions: sessions).map(\.measure))
    }

    /// Its frame rate against `goal` in its last session in `text` of `judgeMinutes` of play or more with no frame-rate
    /// tuning on.
    static func latestFrameRate(of title: String, in text: String, goal: Int = Int(DisplayProfile.steadyTarget)) -> Measure? {
        untuned(of: title, in: text, by: tunings.filter { $0.metric == .frameRate }, sessions: 1, goal: goal).first?.measure
    }

    /// Its start's stop and its loading screens' over its last three sessions with no loading tuning on — of any length:
    /// a start's stop comes in the first minute.
    static func latestLoading(of title: String, in text: String) -> Measure? {
        let list = untuned(of: title, in: text, by: tunings.filter { $0.metric == .loading }, sessions: 3, minutes: 0)
        guard let newest = list.first else { return nil }
        var m = newest.measure
        m.startFreeze = list.compactMap(\.startFreeze).first
        let stalls = list.flatMap(\.loadStalls)
        m.loadStall = stalls.isEmpty ? nil : stalls.reduce(0, +) / Double(stalls.count)
        return m
    }

    /// Its last `sessions` sessions of `minutes` of play or more, newest first, that ran without any of `by` on: a
    /// session's setup line names each tuning it ran with ("unreal:streaming").
    static func untuned(of title: String, in text: String, by: [Tuning], sessions: Int, minutes: Double = judgeMinutes,
                        goal: Int = Int(DisplayProfile.steadyTarget)) -> [Played] {
        var rest = Substring(text)
        var list: [Played] = []
        while list.count < sessions, let h = rest.range(of: "=== \(title) — ", options: .backwards) {
            let session = rest[h.lowerBound...]
            let setup = session.split(separator: "\n", maxSplits: 400).first { $0.contains("[anvil] setup: ") }
            let tuned = setup.map { line in by.contains { line.contains("unreal:\($0.id)") } } ?? false
            if !tuned, let p = played(session: session, goal: goal), p.minutes >= minutes { list.append(p) }
            rest = rest[..<h.lowerBound]
        }
        return list
    }

    static func combined(_ list: [Measure]) -> Measure? {
        let minutes = list.reduce(0) { $0 + $1.minutes }
        guard minutes > 0 else { return nil }
        return Measure(perMinute: list.reduce(0) { $0 + $1.perMinute * $1.minutes } / minutes,
                       minutes: minutes, memoryMB: list.compactMap(\.memoryMB).max())
    }

    /// The frame rate a game should hold: its own goal (60), or the display's steady rate.
    static func goal(of game: Game) -> Int { game.fpsGoal ?? Int(DisplayProfile.steadyTarget) }

    /// Whether a tuning judged by frame rate is on trial for this start (or the session just ended): the even-80 steps
    /// hold still meanwhile, so the trial is judged against the settings it was measured before with.
    static func frameRateTrial(_ game: Game) -> Bool {
        guard game.unrealTuning, let r = record(for: game) else { return false }
        return tunings.contains { $0.metric == .frameRate && r.active.contains($0.id) && r.states[$0.id] == .trial }
    }

    // MARK: Deciding

    /// What this start runs with: a tuning not tried yet goes on trial once there's a measure of how the game ran
    /// before (none where its own stutters are already rare, or its program lacks the settings); one on trial or kept
    /// is written; distant detail at its step. Sets `active`.
    static func plan(_ r: inout Record, present known: Set<String>?, trimsDetail: Bool, context: Context = Context()) -> [(String, String)] {
        var wanted: [(String, String)] = []
        r.active = []
        // Its program unread: nothing written that might not be its own, and nothing marked missing.
        let present = known ?? []
        // One trial of each kind at a time, so each is judged on its own.
        var trialOn = Set(tunings.filter { r.states[$0.id] == .trial }.map(\.metric))
        for t in tunings {
            let keys = t.keys(context)
            guard keys.allSatisfy({ present.contains($0.0) }) else {
                if r.states[t.id] == nil, known != nil {
                    r.states[t.id] = .notNeeded
                    r.notes[t.id] = "its program doesn't have these settings"
                }
                continue
            }
            if r.states[t.id] == nil, !trialOn.contains(t.metric) {
                switch t.metric {
                case .ownStutters:
                    guard let b = r.baseline else { break }
                    if b.perMinute < rareStutters {
                        r.states[t.id] = .notNeeded
                        r.notes[t.id] = String(format: "its own stutters are already rare — %.1f a minute of play", b.perMinute)
                    } else {
                        r.states[t.id] = .trial
                        r.notes[t.id] = String(format: "on trial — against %.1f of its own stutters a minute of play before", b.perMinute)
                    }
                case .frameRate:
                    guard let b = r.fpsBaseline, let share = b.shareAtGoal else { break }
                    if share >= holdsGoal {
                        r.states[t.id] = .notNeeded
                        r.notes[t.id] = String(format: "it holds %d already — %.0f%% of its play", context.goal, share * 100)
                    } else {
                        r.states[t.id] = .trial
                        r.notes[t.id] = String(format: "on trial — against %d fps or more %.0f%% of its play, %.0f fps on average before",
                                               context.goal, share * 100, b.averageFPS ?? 0)
                    }
                case .loading:
                    guard let b = r.loadBaseline else { break }
                    if t.id == pipelines.id {
                        if let stop = b.startFreeze, stop >= 3 {
                            r.states[t.id] = .trial
                            r.notes[t.id] = String(format: "on trial — against a %.1f s stop at its start before", stop)
                        } else {
                            r.states[t.id] = .notNeeded
                            r.notes[t.id] = "its start shows no stop to shorten"
                        }
                    } else {
                        // No loading screen seen yet: nothing to judge it by, so not yet.
                        guard let stall = b.loadStall else { break }
                        if stall < 1.2 {
                            r.states[t.id] = .notNeeded
                            r.notes[t.id] = String(format: "its loading screens stop only %.1f s", stall)
                        } else {
                            r.states[t.id] = .trial
                            r.notes[t.id] = String(format: "on trial — against %.1f s stops on its loading screens before", stall)
                        }
                    }
                }
                if r.states[t.id] == .trial { trialOn.insert(t.metric) }
            }
            if r.states[t.id] == .trial || r.states[t.id] == .kept {
                wanted += keys
                r.active.append(t.id)
            }
        }
        if trimsDetail {
            // Held where it was while a frame-rate trial runs.
            let held = tunings.contains { $0.metric == .frameRate && r.active.contains($0.id) && r.states[$0.id] == .trial }
            let level = min(max((held ? nil : r.detailNext) ?? r.detail ?? 0, 0), detailLevels.count)
            r.detail = level
            if !held { r.detailNext = nil }
            if level > 0 {
                wanted += detailLevels[level - 1].filter { present.contains($0.0) }
                r.active.append("detail=\(level)")
            }
        } else {
            r.detail = nil
            r.detailNext = nil
        }
        return wanted
    }

    /// After a session: a trial's verdict; how the game runs without one, from a session that had none; distant detail's
    /// next step. `endedBadly` says how a game ended that didn't end well — every trial on in it ends there.
    static func judge(_ r: inout Record, played p: Played?, endedBadly: String?, trimsDetail: Bool) -> [String] {
        var lines: [String] = []
        let trials = tunings.filter { r.active.contains($0.id) && r.states[$0.id] == .trial }
        if let endedBadly {
            for t in trials {
                r.states[t.id] = .dropped
                r.notes[t.id] = "the game ended unexpectedly with it on (\(endedBadly)) — not tried again"
                lines.append("\(t.title): off from its next start — the game ended unexpectedly with it on trial (\(endedBadly))")
            }
            return lines
        }
        guard let p else { return lines }
        for t in trials where t.metric == .frameRate {
            guard p.minutes >= judgeMinutes, let b = r.fpsBaseline, let share = b.shareAtGoal else {
                lines.append(String(format: "\(t.title): %.0f minutes of play — too few to judge; on trial again at its next start", p.minutes))
                continue
            }
            let words = String(format: "%d fps or more %.0f%% → %.0f%% of its play, %.0f → %.0f fps on average",
                               p.goal, share * 100, p.shareAtGoal * 100, b.averageFPS ?? 0, p.averageFPS)
            let stutters = r.baseline.map { p.perMinute <= max($0.perMinute, rareStutters) * stutterAllowance } ?? true
            if engaged(p, before: b) == false {
                r.states[t.id] = .dropped
                r.notes[t.id] = "the game kept drawing \(p.renderWidth ?? 0) pixels across with it — it doesn't take it here"
                lines.append("\(t.title): dropped — the game kept drawing \(p.renderWidth ?? 0) pixels across with it on, so it doesn't use Unreal's dynamic resolution (\(words))")
            } else if (p.shareAtGoal >= share + keepShareGain || p.averageFPS >= (b.averageFPS ?? .infinity) * keepFPSGain) && stutters {
                r.states[t.id] = .kept
                r.notes[t.id] = "kept — " + words
                lines.append("\(t.title): kept — \(words)" + (p.renderWidths.count > 1 ? ", drawn \(p.renderWidths.keys.min() ?? 0)–\(p.renderWidths.keys.max() ?? 0) pixels across" : ""))
            } else {
                r.states[t.id] = .dropped
                r.notes[t.id] = (stutters ? "no better — " : "more of its own stutters — ") + words
                lines.append("\(t.title): dropped — " + (stutters ? "no better, " : "more of its own stutters, ") + words)
            }
            r.last = p.measure
        }
        for t in trials where t.metric == .loading {
            guard p.minutes >= 5, let b = r.loadBaseline else {
                lines.append(String(format: "\(t.title): %.0f minutes of play — too few to judge; on trial again at its next start", p.minutes))
                continue
            }
            // Compiles in play no more often than before: what's left of preparing pipelines now comes in the background.
            let compiles = p.compilePerMinute <= (b.compilePerMinute ?? 0) + 0.3
            let stutters = r.baseline.map { p.perMinute <= max($0.perMinute, rareStutters) * stutterAllowance } ?? true
            if t.id == pipelines.id {
                // A stop under 1.5 s isn't logged at all: none seen in a session that reached its world is that.
                let stop = p.startFreeze ?? 1.0
                let words = String(format: "its start's stop %.1f → %@ s, %.1f → %.1f stutters from compiling shaders a minute",
                                   b.startFreeze ?? 0, p.startFreeze.map { String(format: "%.1f", $0) } ?? "under 1.5", b.compilePerMinute ?? 0, p.compilePerMinute)
                if stop <= max(startFreezeKeep, (b.startFreeze ?? 0) * 0.5) && compiles {
                    r.states[t.id] = .kept
                    r.notes[t.id] = "kept — " + words
                    lines.append("\(t.title): kept — \(words)")
                } else {
                    r.states[t.id] = .dropped
                    r.notes[t.id] = (compiles ? "no shorter — " : "more stutters from compiling shaders — ") + words
                    lines.append("\(t.title): dropped — " + (compiles ? "no shorter, " : "more stutters from compiling shaders, ") + words)
                }
            } else {
                guard let stall = p.loadStall, let before = b.loadStall else {
                    lines.append("\(t.title): no loading screen this session to judge it by — on trial again at its next start")
                    continue
                }
                let words = String(format: "its loading screens' stops %.1f → %.1f s (%d this session)", before, stall, p.loadStalls.count)
                if stall <= before * loadStallKeep && stutters {
                    r.states[t.id] = .kept
                    r.notes[t.id] = "kept — " + words
                    lines.append("\(t.title): kept — \(words)")
                } else {
                    r.states[t.id] = .dropped
                    r.notes[t.id] = (stutters ? "no shorter — " : "more of its own stutters — ") + words
                    lines.append("\(t.title): dropped — " + (stutters ? "no shorter, " : "more of its own stutters, ") + words)
                }
            }
        }
        for t in trials where t.metric == .ownStutters {
            guard p.minutes >= judgeMinutes, let b = r.baseline else {
                lines.append(String(format: "\(t.title): %.0f minutes of play — too few to judge; on trial again at its next start", p.minutes))
                continue
            }
            let words = String(format: "%.1f → %.1f of its own stutters a minute of play", b.perMinute, p.perMinute)
            let grew = (p.memoryMB ?? 0) - (b.memoryMB ?? .infinity)
            if grew > memoryAllowanceMB {
                r.states[t.id] = .dropped
                r.notes[t.id] = String(format: "the game took %.1f GB more memory with it — %@", grew / 1024, words)
                lines.append(String(format: "\(t.title): dropped — the game took %.1f GB more memory with it (%@)", grew / 1024, words))
            } else if p.perMinute <= b.perMinute * keepAtMost {
                r.states[t.id] = .kept
                r.notes[t.id] = "kept — " + words
                lines.append("\(t.title): kept — \(words)")
            } else {
                r.states[t.id] = .dropped
                r.notes[t.id] = "no better — " + words
                lines.append("\(t.title): dropped — no better, \(words)")
            }
            r.last = p.measure
        }
        // A session with no frame-rate tuning on: its frame rate, for the next one to be judged against.
        if !tunings.contains(where: { $0.metric == .frameRate && r.active.contains($0.id) }), p.minutes >= judgeMinutes {
            r.fpsBaseline = p.measure
        }
        // With no loading tuning on: its start's stop and its loading screens', each kept from before where this session
        // had none to show.
        if !tunings.contains(where: { $0.metric == .loading && r.active.contains($0.id) }) {
            var m = p.measure
            m.startFreeze = p.startFreeze ?? r.loadBaseline?.startFreeze
            m.loadStall = p.loadStall ?? r.loadBaseline?.loadStall
            if p.minutes < judgeMinutes { m.compilePerMinute = r.loadBaseline?.compilePerMinute ?? m.compilePerMinute }
            r.loadBaseline = m
        }
        // A session with no tuning on: how the game runs without, for the next trial to be judged against.
        if !tunings.contains(where: { r.active.contains($0.id) }), p.minutes >= judgeMinutes {
            r.baseline = combined([r.baseline, p.measure].compactMap { $0 })
            lines.append(String(format: "%.1f of its own stutters a minute of play over %.0f minutes, without tuning",
                                r.baseline?.perMinute ?? 0, r.baseline?.minutes ?? 0))
        }
        // Distant detail holds still through a frame-rate trial: it's judged against the step it was measured at.
        if trimsDetail, p.minutes >= 5, !trials.contains(where: { $0.metric == .frameRate }) {
            let now = r.detail ?? 0
            let next = min(max(p.shareAtGoal < 0.5 ? now + 2 : p.shareAtGoal < 0.8 ? now + 1 : p.shareAtGoal >= 0.95 ? now - 1 : now, 0),
                           detailLevels.count)
            if next != now {
                r.detailNext = next
                lines.append(String(format: "distant detail: step %d of %d from its next start — %d fps or more %.0f%% of its play",
                                    next, detailLevels.count, p.goal, p.shareAtGoal * 100))
            }
        }
        return lines
    }

    // MARK: At a start, and after

    /// Before a start: what's on trial or kept written to its Engine.ini (backed up before the first change), and
    /// everything of Anvil's taken out again when tuning is off. The first tuned start asks first (`confirm`); a no is
    /// passed to `declined`. Returns the log's lines.
    @MainActor
    static func prepare(_ game: Game, in container: Container, hasProfile: Bool, context: Context = Context(), logs: () -> String,
                        confirm: (Game) -> Bool, declined: () -> Void) -> [String] {
        guard let folder = UnrealConfig.folder(for: game, in: container) else { return [] }
        let ini = folder.appendingPathComponent("Engine.ini")
        let text = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let stored = record(for: game)
        var r = stored ?? Record()
        let managed = managed(hasProfile: hasProfile)
        var tuned = eligibility(game, unreal: true) == .tuned
        var saidNo = false
        if tuned, r.acknowledged == nil {
            if confirm(game) {
                r.acknowledged = Date()
            } else {
                tuned = false
                saidNo = true
                declined()
            }
        }
        var lines: [String] = []
        guard tuned else {
            // Taken out only where they're Anvil's: a game it tuned, or one the player has just said no for. The same
            // settings a player put in a game Anvil never tuned are theirs.
            guard stored != nil || saidNo else { return [] }
            let updated = applying([], managed: managed, in: text).text
            r.active = []
            if updated != text {
                if DiskCache.writeReplacing(Data(updated.utf8), to: ini, durable: true) {
                    lines.append("off — Anvil's settings taken out of its Engine.ini, the engine's own as the game has them")
                }
            }
            if stored != nil, r != stored { save(r, for: game) }
            return lines
        }
        // The settings its program has, looked for once for each build of it — and again when Anvil has more to look
        // for: 0.68's dynamic resolution was marked missing from Hogwarts Legacy's program on 24 October, from a list
        // made before Anvil looked for it at all.
        let program = GameAnalysis.drawingProgram(for: game.executableURL)
        let stamp = stamp(program)
        let names = Array(Set(managed.map(\.0))).sorted()
        let looked = Set(r.lookedFor ?? r.present ?? [])
        if r.present == nil || r.programStamp != stamp || !Set(names).isSubset(of: looked) {
            if r.programStamp != nil {
                // A new build of the game, or settings not looked for before: what it lacked is looked for again.
                for t in tunings where r.states[t.id] == .notNeeded && r.notes[t.id]?.contains("program") == true { r.states[t.id] = nil }
            }
            if let found = present(names, in: program) {
                r.present = found.sorted()
                r.lookedFor = names
                r.programStamp = stamp
            }
        }
        // How it ran before, from game.log, the first time each is wanted — its frame rate again for a new goal.
        let fpsStale = r.fpsBaseline == nil || r.fpsBaseline?.goal != context.goal
        if (r.baseline == nil && r.states.isEmpty) || fpsStale || r.loadBaseline == nil {
            let text = logs()
            if r.baseline == nil, r.states.isEmpty { r.baseline = history(of: game.title, in: text) }
            if fpsStale { r.fpsBaseline = latestFrameRate(of: game.title, in: text, goal: context.goal) }
            if r.loadBaseline == nil { r.loadBaseline = latestLoading(of: game.title, in: text) }
        }
        let wanted = plan(&r, present: r.present.map(Set.init), trimsDetail: !hasProfile && game.gameGraphics.trimsDetail, context: context)
        let (updated, theirs) = applying(wanted, managed: managed, in: text)
        if updated != text {
            if r.backedUp != true {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                r.backedUp = DiskCache.writeReplacing(Data(text.utf8), to: backupURL(for: game), durable: true)
            }
            guard DiskCache.writeReplacing(Data(updated.utf8), to: ini, durable: true) else {
                r.active = []
                save(r, for: game)
                return ["its Engine.ini couldn't be written — the engine's own settings as the game has them"]
            }
        }
        save(r, for: game)
        for t in tunings where r.active.contains(t.id) {
            let set = t.keys(context).map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            lines.append("\(t.title) (\(set)) — \(r.notes[t.id] ?? (r.states[t.id] == .kept ? "kept" : "on trial"))")
        }
        if let d = r.detail, d > 0 { lines.append("distant detail trimmed, step \(d) of \(detailLevels.count)") }
        if !theirs.isEmpty { lines.append("left as set in its Engine.ini by the player: " + theirs.sorted().joined(separator: ", ")) }
        if lines.isEmpty, let p = r.present, p.isEmpty { lines.append("none of the settings it tunes are in this game's program — nothing written") }
        return lines
    }

    /// After a session with tuning on: its verdicts, from game.log.
    static func afterSession(_ game: Game, log: URL, endedBadly: String?, hasProfile: Bool) -> [String] {
        guard game.unrealTuning, var r = record(for: game), r.acknowledged != nil else { return [] }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let p = lastSession(of: game.title, in: text).flatMap { played(session: $0, goal: goal(of: game)) }
        let lines = judge(&r, played: p, endedBadly: endedBadly, trimsDetail: !hasProfile && game.gameGraphics.trimsDetail)
        save(r, for: game)
        return lines
    }

    /// Learn's parts for a start: each tuning on ("unreal:streaming"), and its distant detail's step where it's ours.
    static func learnParts(_ game: Game) -> [String] {
        guard game.unrealTuning, let r = record(for: game) else { return [] }
        return r.active.map { $0.hasPrefix("detail=") ? $0 : "unreal:\($0)" }
    }

    /// Every setting of Anvil's taken out of its Engine.ini — the player's own left as they are — and what was learned
    /// forgotten. False when the file couldn't be written.
    static func restore(_ game: Game, in container: Container) -> Bool {
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(game.id.uuidString).json")) }
        guard let folder = UnrealConfig.folder(for: game, in: container) else { return true }
        let ini = folder.appendingPathComponent("Engine.ini")
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return true }
        let updated = applying([], managed: managed(hasProfile: GameUpscaler.profile(for: game) != nil), in: text).text
        return updated == text || DiskCache.writeReplacing(Data(updated.utf8), to: ini, durable: true)
    }

    /// Asked once for each game, before its first tuned start.
    @MainActor
    static func askFirst(_ game: Game) -> Bool {
        NSApp.activate()
        let ask = NSAlert()
        ask.messageText = "Tune \(game.title)'s Unreal Engine for this Mac?"
        ask.informativeText = "Anvil sets a few of Unreal Engine's own settings in the game's Engine.ini, the file it keeps its engine settings in. It never changes the game's files or its code. Each change is tried for one session and kept only if it measurably helped; the file is backed up first, and Put Its Own Settings Back on the game's page undoes it all.\n\nThis is only for games bought on Steam or Epic and installed through Anvil, and what's tuned stays on this Mac."
        ask.addButton(withTitle: "Tune It")
        ask.addButton(withTitle: "Not for This Game")
        return ask.runModal() == .alertFirstButtonReturn
    }

    /// For the game's page: each tuning's state in words.
    static func summary(_ r: Record) -> [(title: String, text: String)] {
        var out: [(String, String)] = []
        for t in tunings {
            guard let s = r.states[t.id] else { continue }
            let state: String
            switch s {
            case .trial: state = r.notes[t.id] ?? "on trial"
            case .kept, .dropped, .notNeeded: state = r.notes[t.id] ?? s.rawValue
            }
            out.append((t.title.prefix(1).uppercased() + t.title.dropFirst(), state))
        }
        return out
    }
}
