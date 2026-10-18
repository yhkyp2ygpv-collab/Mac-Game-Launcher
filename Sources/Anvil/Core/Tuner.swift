import Foundation

// MARK: - What "best" means

/// What the player wants most from a game. Auto-Tune measures setups against it.
enum TuneGoal: String, Codable, CaseIterable, Identifiable {
    case smooth, maxFPS, quality, balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: "Smooth \(DisplayProfile.targetText)+"
        case .maxFPS: "Highest frame rate"
        case .quality: "Best graphics"
        case .balanced: "Balanced"
        }
    }

    var summary: String {
        switch self {
        case .smooth: "The best look that still holds \(DisplayProfile.targetText) fps or more nearly all the time, with frames shown evenly."
        case .maxFPS: "As many frames as this Mac can make. Looks give way unless they cost nothing."
        case .quality: "The best look that still plays well — 60 fps or more nearly all the time."
        case .balanced: "Frame rate and looks weighed together."
        }
    }

    var symbol: String {
        switch self {
        case .smooth: "waveform.path"
        case .maxFPS: "hare.fill"
        case .quality: "sparkles"
        case .balanced: "dial.medium.fill"
        }
    }

    /// Frame pacing the goal wants: Steady (120, or an even 80) or every frame as ready.
    var pacing: Int { self == .maxFPS ? 0 : 80 }
}

// MARK: - Setups and what they measured

/// One way of running a game that Auto-Tune can measure: the game's own graphics level,
/// for a game Anvil can tune; the resolution, for a game that draws at its window's
/// size; and the frame pacing, which the goal decides.
struct TuneSetup: Codable, Hashable, Identifiable {
    var graphics: GraphicsLevel?
    /// Render at half resolution and upscale. Nil for a game where Anvil can't change it.
    var halfResolution: Bool?
    var pacing: Int

    var id: String {
        "\(graphics?.rawValue ?? "-")/\(halfResolution.map { $0 ? "half" : "full" } ?? "-")/\(pacing)"
    }

    /// Higher looks better. Graphics level outranks resolution; a setup only ever
    /// varies one of them.
    var qualityRank: Int { (graphics?.rank ?? 0) * 10 + (halfResolution == true ? 0 : 1) }

    var title: String {
        var parts: [String] = []
        if let graphics { parts.append("\(graphics.title) graphics") }
        if let halfResolution { parts.append(halfResolution ? "Half resolution, upscaled" : "Full resolution") }
        parts.append(pacing == 80 ? "Steady 80+" : pacing == 0 ? "Up to 120" : "Held at \(pacing)")
        return parts.joined(separator: " · ")
    }

    /// The part that changes between setups, for a compact table.
    var shortTitle: String {
        if let graphics { return graphics.title }
        if let halfResolution { return halfResolution ? "Half resolution" : "Full resolution" }
        return pacing == 80 ? "Steady 80+" : "Up to 120"
    }
}

/// Everything measured with one setup, possibly over several sessions.
struct TuneTrial: Codable, Hashable {
    var setup: TuneSetup
    /// Stretches of play, most recent last; capped so a long history does not grow forever.
    var windows: [FrameWindow] = []
    var hitches: Int = 0
    var sessions: Int = 0
    var lastMeasured: Date?

    var minutes: Double { windows.reduce(0) { $0 + $1.seconds } / 60 }
    var stats: TrialStats? { TrialStats.from(play: windows, hitches: hitches) }

    static let maxMinutes = 20.0

    mutating func add(_ play: [FrameWindow], hitches newHitches: Int) {
        windows += play
        hitches += newHitches
        sessions += 1
        lastMeasured = Date()
        // Keep the latest twenty minutes; older stretches go with their share of hitches.
        var total = minutes
        var dropped = 0
        while total > Self.maxMinutes, !windows.isEmpty {
            total -= windows[0].seconds / 60
            windows.removeFirst()
            dropped += 1
        }
        if dropped > 0, windows.count + dropped > 0 {
            hitches = Int((Double(hitches) * Double(windows.count) / Double(windows.count + dropped)).rounded())
        }
    }
}

/// What a result was measured on. When any of it changes the result may no longer hold.
struct TuneFingerprint: Codable, Hashable {
    var executableSize: Int
    var executableModified: Double
    var runtimeID: String
    var d3dMetal: String?
    var macOS: String
    var gpu: String
    var anvil: String

    /// What differs, in words; empty when nothing does.
    func changes(since earlier: TuneFingerprint) -> [String] {
        var out: [String] = []
        if executableSize != earlier.executableSize || abs(executableModified - earlier.executableModified) > 1 {
            out.append("the game was updated")
        }
        if runtimeID != earlier.runtimeID { out.append("its engine changed") }
        else if d3dMetal != earlier.d3dMetal { out.append("its D3DMetal changed") }
        if macOS.split(separator: ".").prefix(2) != earlier.macOS.split(separator: ".").prefix(2) { out.append("macOS was updated") }
        if gpu != earlier.gpu { out.append("the Mac changed") }
        if anvil.split(separator: ".").prefix(2) != earlier.anvil.split(separator: ".").prefix(2) { out.append("Anvil was updated") }
        return out
    }
}

// MARK: - Planning

/// Which setup to measure next and which one wins. No state, no side effects — the
/// rules in one place, so they can be checked on their own.
enum TunePlanner {
    struct Space: Hashable, Codable {
        /// The game's own graphics levels, for a game Anvil knows how to tune.
        var levels: [GraphicsLevel]
        /// Whether rendering fewer pixels is Anvil's to do (a game that draws at its window's size).
        var canHalveResolution: Bool
        /// What the game runs with now, at the goal's pacing.
        var baseline: TuneSetup
        var goal: TuneGoal
    }

    /// Every setup worth measuring, from the lightest to the best-looking.
    static func ladder(_ space: Space) -> [TuneSetup] {
        let pacing = space.goal.pacing
        if !space.levels.isEmpty {
            return space.levels.sorted().map { TuneSetup(graphics: $0, halfResolution: nil, pacing: pacing) }
        }
        if space.canHalveResolution {
            return [true, false].map { TuneSetup(graphics: nil, halfResolution: $0, pacing: pacing) }
        }
        return []
    }

    /// Where the ladder is climbed from, for this goal.
    static func start(_ space: Space) -> TuneSetup? {
        let l = ladder(space)
        guard !l.isEmpty else { return nil }
        switch space.goal {
        case .smooth, .balanced:
            return l.first { $0.qualityRank == space.baseline.qualityRank } ?? l[l.count / 2]
        case .maxFPS: return l.first
        case .quality: return l.last
        }
    }

    /// Holds 80 or better nearly all the time, without hitching.
    static func meetsSmooth(_ s: TrialStats) -> Bool { s.shareAt80 >= 0.95 && s.hitchesPerMinute <= 2 }
    /// Plays well: 60 or better nearly all the time.
    static func meetsPlayable(_ s: TrialStats) -> Bool { s.shareAt60 >= 0.95 && s.lowFPS >= 50 && s.hitchesPerMinute <= 3 }

    /// Setups within this much of the fastest count as equally fast: the difference is
    /// within what one session's scenes change from the next.
    static let sameSpeed = 0.97
    /// How much more of the time at 80 a lighter look must give when no setup holds 80.
    static let clearlyLonger = 0.08

    /// The next setup to measure, or nil once the result is decided.
    static func next(_ space: Space, trials: [TuneTrial], minMinutes: Double) -> TuneSetup? {
        let l = ladder(space)
        guard let first = start(space) else { return nil }
        func stats(_ s: TuneSetup) -> TrialStats? {
            guard let t = trials.first(where: { $0.setup == s }), t.minutes >= minMinutes else { return nil }
            return t.stats
        }
        guard let firstStats = stats(first) else { return first }
        let index = l.firstIndex(of: first) ?? 0

        switch space.goal {
        case .smooth:
            if meetsSmooth(firstStats) {
                // Holding 80: see how much better it can look and still hold it.
                for s in l[(index + 1)...] {
                    guard let m = stats(s) else { return s }
                    if !meetsSmooth(m) { return nil }
                }
            } else {
                // Not holding 80: lighter until one does.
                for s in l[..<index].reversed() {
                    guard let m = stats(s) else { return s }
                    if meetsSmooth(m) { return nil }
                }
            }
            return nil

        case .quality:
            // From the best look down, until one plays well.
            for s in l.reversed() {
                guard let m = stats(s) else { return s }
                if meetsPlayable(m) { return nil }
            }
            return nil

        case .maxFPS:
            // From the lightest up, while a better look costs nothing — a game held back
            // by its CPU runs as fast with more detail.
            var fastest = firstStats.capacity
            for s in l.dropFirst() {
                guard let m = stats(s) else { return s }
                if m.capacity < fastest * sameSpeed { return nil }
                fastest = max(fastest, m.capacity)
            }
            return nil

        case .balanced:
            return l.first { stats($0) == nil }
        }
    }

    /// The best of what has been measured, with the reason in words.
    static func winner(_ space: Space, trials: [TuneTrial], minMinutes: Double) -> (setup: TuneSetup, reason: String)? {
        let measured = trials.compactMap { t -> (TuneSetup, TrialStats)? in
            guard t.minutes >= minMinutes, let s = t.stats else { return nil }
            return (t.setup, s)
        }
        guard !measured.isEmpty else { return nil }
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

        switch space.goal {
        case .smooth:
            if let best = measured.filter({ meetsSmooth($0.1) }).max(by: { $0.0.qualityRank < $1.0.qualityRank }) {
                return (best.0, "the best look that held 80 fps or more \(pct(best.1.shareAt80)) of the time")
            }
            // None holds 80. A lighter look wins only when it holds 80 clearly longer —
            // eight points of the time or more; otherwise the better look stays. Two
            // points used to be enough, so a game that could hold 80 with neither took
            // the lighter one for a difference no one would see, and lost its shadows.
            let best = measured.max { a, b in
                abs(a.1.shareAt80 - b.1.shareAt80) >= Self.clearlyLonger ? a.1.shareAt80 < b.1.shareAt80 : a.0.qualityRank < b.0.qualityRank
            }!
            return (best.0, "none held 80 all the time on this Mac; this came closest, at 80 or more \(pct(best.1.shareAt80)) of the time")

        case .quality:
            if let best = measured.filter({ meetsPlayable($0.1) }).max(by: { $0.0.qualityRank < $1.0.qualityRank }) {
                return (best.0, "the best look that stayed at 60 fps or more \(pct(best.1.shareAt60)) of the time")
            }
            let best = measured.max { $0.1.shareAt60 < $1.1.shareAt60 }!
            return (best.0, "none stayed at 60 all the time; this came closest, at 60 or more \(pct(best.1.shareAt60)) of the time")

        case .maxFPS:
            let top = measured.map(\.1.capacity).max() ?? 0
            let best = measured.filter { $0.1.capacity >= top * sameSpeed }.max { $0.0.qualityRank < $1.0.qualityRank }!
            return (best.0, String(format: "the most frames — %.0f fps the game could make — ", best.1.capacity)
                    + (measured.count > 1 ? "with the best look that cost nothing extra" : "measured"))

        case .balanced:
            let ranks = measured.map(\.0.qualityRank)
            let low = Double(ranks.min() ?? 0), span = max(Double((ranks.max() ?? 0)) - low, 1)
            func score(_ m: (TuneSetup, TrialStats)) -> Double {
                0.45 * min(1, m.1.capacity / 120) + 0.35 * (Double(m.0.qualityRank) - low) / span
                    + 0.2 * m.1.shareAt80 - 0.03 * min(m.1.hitchesPerMinute, 5)
            }
            let best = measured.max { score($0) < score($1) }!
            return (best.0, String(format: "frame rate and looks weighed together: %.0f fps typical, 80 or more %@ of the time",
                                   best.1.typicalFPS, pct(best.1.shareAt80)))
        }
    }

    /// Roughly how many setups a test will measure, for "2 of 3".
    static func expectedCount(_ space: Space) -> Int {
        let n = ladder(space).count
        switch space.goal {
        case .balanced: return n
        default: return min(n, 2)
        }
    }
}

// MARK: - State kept per game

struct TuneState: Codable {
    enum Mode: String, Codable {
        /// Each normal session measures the next setup.
        case whilePlaying
        /// Anvil starts, measures and closes the game for each setup in turn.
        case quickTest
        /// A quick test waiting to be continued.
        case paused
        /// Decided; the winner is in place.
        case finished
        /// Stopped by the player before it finished.
        case stopped
    }

    var goal: TuneGoal
    var mode: Mode
    var space: TunePlanner.Space
    var trials: [TuneTrial] = []
    var current: TuneSetup?
    var winner: TuneSetup?
    var winnerReason: String?
    var startedAt: Date = Date()
    var finishedAt: Date?
    var fingerprint: TuneFingerprint?
    var pausedReason: String?
    /// Decisions in words, newest last.
    var notes: [String] = []
    /// Sessions in a row, since it decided, that ran clearly below what the winner measured.
    var driftSessions: Int?

    var isActive: Bool { mode == .whilePlaying || mode == .quickTest }

    mutating func note(_ text: String) {
        notes.append(text)
        if notes.count > 40 { notes.removeFirst(notes.count - 40) }
    }

    func trial(_ setup: TuneSetup) -> TuneTrial? { trials.first { $0.setup == setup } }
}

// MARK: - The coordinator

/// Auto-Tune: measures a game with different setups and keeps the one that best meets
/// the player's goal.
///
/// Measuring is what Anvil's library already does in every session — each 600 frames
/// it writes what the display showed, what the game could manage on its own, the 1%
/// low and the longest gap to game.log. A setup is a different graphics level for a
/// game Anvil knows how to tune (LEGO Star Wars), or a different resolution for one
/// that draws at its window's size (Unity games). Only stretches of real play count:
/// the first frames, the menus before the load and the load itself are left out.
///
/// Two ways to run it, both with no connection needed:
/// - **Test now**: Anvil starts the game with each setup, measures about ninety seconds
///   of play, closes it and starts the next — the player only has to load in.
/// - **While I play**: every normal session measures the next setup, until there is
///   enough to decide.
/// When it is decided the winner becomes the game's settings, and the results are kept
/// in Tuning/<game>.json with what they were measured on, so they are reused until the
/// game, its engine, macOS or the Mac changes.
@MainActor
final class Tuner: ObservableObject {
    static let shared = Tuner()

    struct Announcement: Identifiable {
        let id = UUID()
        var gameID: UUID
        var title: String
        var message: String
    }

    @Published private(set) var states: [UUID: TuneState] = [:]
    /// Minutes of play measured so far in a quick test's running session.
    @Published private(set) var live: [UUID: Double] = [:]
    @Published var announcement: Announcement?

    /// The setup each running game was started with, until its session ends.
    private var running: [UUID: TuneSetup] = [:]
    private var monitors: [UUID: Task<Void, Never>] = [:]

    /// Minutes of play a setup needs before it is judged.
    static let quickMinutes = 1.5
    static let playingMinutes = 4.0

    /// Where results live. Tests point this somewhere else.
    nonisolated(unsafe) static var directory: URL = RuntimeManager.support.appendingPathComponent("Tuning", isDirectory: true)

    private init() {
        load()
    }

    // MARK: Persistence

    private func url(for id: UUID) -> URL { Self.directory.appendingPathComponent("\(id.uuidString).json") }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  var state = try? JSONDecoder().decode(TuneState.self, from: data) else { continue }
            // A quick test cannot survive Anvil closing: nothing is left to restart the game.
            if state.mode == .quickTest {
                state.mode = .paused
                state.pausedReason = "Anvil was closed during the test."
            }
            states[id] = state
        }
    }

    private func save(_ id: UUID) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let state = states[id] else {
            try? FileManager.default.removeItem(at: url(for: id))
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(state) { DiskCache.writeReplacing(data, to: url(for: id)) }
    }

    func state(for game: Game) -> TuneState? { states[game.id] }

    // MARK: The space of setups

    func space(for game: Game, container: Container, goal: TuneGoal) -> TunePlanner.Space {
        let levels = GameTuning.profile(for: game) != nil ? GraphicsLevel.allCases : []
        let analysis = GameAnalysis.cached(for: game.executableURL)
        let halves = levels.isEmpty && (analysis?.rendersAtWindowSize ?? Launcher.isUnityGame(game.executableURL))
        let baseline = TuneSetup(
            graphics: levels.isEmpty ? nil : graphicsLevel(for: game),
            halfResolution: halves ? container.profile.renderScale() < 1.5 : nil,
            pacing: goal.pacing)
        return TunePlanner.Space(levels: levels, canHalveResolution: halves, baseline: baseline, goal: goal)
    }

    /// The graphics level a game runs with when nothing is being measured: the one chosen
    /// by hand, else Auto-Tune's, else where this Mac's setup said to start (Medium).
    func graphicsLevel(for game: Game) -> GraphicsLevel {
        if let chosen = game.graphicsTuning.level { return chosen }
        // The last setup Auto-Tune decided on, while nothing is being measured.
        if let state = states[game.id], !state.isActive, let level = state.winner?.graphics { return level }
        // Where this Mac starts, from what the setup measured.
        return DeviceProfile.current?.startingLevel ?? .medium
    }

    func fingerprint(for game: Game, container: Container) -> TuneFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: game.executablePath)
        let runtime = RuntimeManager.shared.runtime(id: container.runtimeID)
        return TuneFingerprint(
            executableSize: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
            executableModified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            runtimeID: container.runtimeID,
            d3dMetal: runtime?.d3dMetalVersion,
            macOS: SystemInfo.current.macOSVersion,
            gpu: SystemInfo.current.gpuName,
            anvil: AnvilVersion.current)
    }

    /// Why a finished result may no longer hold, or nil when it still does.
    func staleness(for game: Game, container: Container) -> String? {
        guard let state = states[game.id], state.mode == .finished, let then = state.fingerprint else { return nil }
        let changes = fingerprint(for: game, container: container).changes(since: then)
        return changes.isEmpty ? nil : "Since this was measured " + changes.joined(separator: ", ") + "."
    }

    /// Whether Auto-Tune can measure this game at all.
    func unavailableReason(for game: Game) -> String? {
        if !game.exists {
            return "The game's executable isn't where Anvil last saw it, so it can't be started to measure."
        }
        if game.anvilEnhancementsOff {
            return "Anvil's enhancements are off for this game, and they are what measures it. Turn them on in Overview to use Auto-Tune."
        }
        return nil
    }

    // MARK: Starting and stopping

    enum StartError: LocalizedError {
        case running, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .running: "Close the game first — each test starts it with different settings."
            case .unavailable(let why): why
            }
        }
    }

    /// Begin tuning. A quick test starts the game straight away. Returns false when
    /// there is nothing to measure — the goal's pacing is then set and that is all.
    ///
    /// `fresh` measures every setup again; otherwise setups measured before on the same
    /// game, engine, macOS and Mac are reused — as when only the goal changed.
    @discardableResult
    func start(_ game: Game, goal: TuneGoal, quickTest: Bool, fresh: Bool = false) throws -> Bool {
        guard let container = Library.shared.container(id: game.containerID) else { return false }
        if let why = unavailableReason(for: game) { throw StartError.unavailable(why) }
        if quickTest && Launcher.shared.isBusy(game) { throw StartError.running }
        let space = space(for: game, container: container, goal: goal)
        let print = fingerprint(for: game, container: container)
        guard let first = TunePlanner.start(space) else {
            adoptPacing(goal.pacing, for: game)
            var state = TuneState(goal: goal, mode: .finished, space: space)
            state.winner = space.baseline
            state.winnerReason = "nothing Anvil can change makes this game faster or better-looking, so only its pacing was set"
            state.finishedAt = Date()
            state.fingerprint = print
            state.note("Nothing to measure for this game; pacing set to \(space.baseline.shortTitle).")
            states[game.id] = state
            save(game.id)
            AnvilLog.write("auto-tune: \(game.title) — nothing to measure; pacing set for \(goal.title)")
            return false
        }
        var state = TuneState(goal: goal, mode: quickTest ? .quickTest : .whilePlaying, space: space)
        // What was measured before on the same game, engine, macOS and Mac still holds,
        // whatever the goal was then: a setup runs the same whichever goal asks.
        // Every setup measured is kept, whichever goal it was measured for; each goal
        // reads the ones on its own ladder.
        if !fresh, let old = states[game.id], let then = old.fingerprint, print.changes(since: then).isEmpty {
            state.trials = old.trials
        }
        // What was chosen before stays the game's setting until this run decides.
        if let old = states[game.id] {
            state.winner = old.winner
            state.winnerReason = old.winnerReason
        }
        state.fingerprint = print
        state.current = TunePlanner.next(space, trials: state.trials, minMinutes: minutes(for: state.mode))
        if state.current == nil {
            // Everything this goal needs was measured already.
            finish(&state, game: game, early: false)
            save(game.id)
            return true
        }
        let ladder = Set(TunePlanner.ladder(space))
        let reused = state.trials.filter { ladder.contains($0.setup) && $0.minutes >= minutes(for: state.mode) }.count
        state.note("Started for “\(goal.title)”, \(quickTest ? "testing now" : "while you play")"
                   + (reused > 0 ? ", reusing \(reused) setup\(reused == 1 ? "" : "s") measured before" : "")
                   + "; first: \(state.current?.title ?? first.title).")
        states[game.id] = state
        save(game.id)
        AnvilLog.write("auto-tune: \(game.title) — started for \(goal.title) (\(quickTest ? "quick test" : "while playing")), first setup \(state.current?.title ?? "?")")
        if quickTest { launchForTest(game) }
        return true
    }

    /// Continue a paused quick test.
    func resume(_ game: Game) {
        guard var state = states[game.id], state.mode == .paused else { return }
        if Launcher.shared.isBusy(game) { return }
        state.mode = .quickTest
        state.pausedReason = nil
        state.note("Continued.")
        states[game.id] = state
        save(game.id)
        launchForTest(game)
    }

    /// Stop without deciding. The game's own settings apply again from the next launch.
    func stop(_ game: Game) {
        guard var state = states[game.id], state.isActive || state.mode == .paused else { return }
        state.mode = .stopped
        state.current = nil
        state.note("Stopped before it finished.")
        states[game.id] = state
        save(game.id)
        monitors.removeValue(forKey: game.id)?.cancel()
        live[game.id] = nil
        AnvilLog.write("auto-tune: \(game.title) — stopped")
        restoreGraphicsNow(game)
    }

    /// Decide now from what has been measured, without waiting for the rest.
    func finishNow(_ game: Game) {
        guard var state = states[game.id], !state.trials.isEmpty else { return }
        finish(&state, game: game, early: true)
        states[game.id] = state
        save(game.id)
    }

    /// Forget everything measured for this game.
    func reset(_ game: Game) {
        monitors.removeValue(forKey: game.id)?.cancel()
        states[game.id] = nil
        live[game.id] = nil
        save(game.id)
        AnvilLog.write("auto-tune: \(game.title) — results cleared")
        restoreGraphicsNow(game)
    }

    // MARK: Autopilot

    /// Start measuring while the player plays, without being asked: for a game on
    /// Autopilot that Auto-Tune hasn't measured, or whose result no longer holds because
    /// the game, its engine, macOS or Anvil changed. The session just played counts as
    /// the first setup's first minutes when it ran with that setup, so nothing played is
    /// thrown away. A player's own decisions stand — a stop, a test, a level chosen by
    /// hand. Returns whether measuring started.
    @discardableResult
    func autoStart(_ game: Game, container: Container, played: Gameplay.Split?) -> Bool {
        guard game.autopilot, game.graphicsTuning == .automatic, unavailableReason(for: game) == nil,
              !Launcher.shared.isBusy(game) else { return false }
        if let state = states[game.id] {
            guard state.mode == .finished, staleness(for: game, container: container) != nil else { return false }
        }
        let goal = game.tuneGoal ?? .smooth
        let space = space(for: game, container: container, goal: goal)
        guard TunePlanner.start(space) != nil else { return false }
        // What the session just played ran with: the level and resolution Auto-Tune
        // would start from, at the pacing the container had.
        let ranWith = TuneSetup(graphics: space.baseline.graphics, halfResolution: space.baseline.halfResolution,
                                pacing: game.targetFPSOverride ?? container.targetFPS)
        do { try start(game, goal: goal, quickTest: false) } catch { return false }
        guard var state = states[game.id], state.mode == .whilePlaying else { return true }
        state.note("Started by Autopilot after a session.")
        if let played, !played.play.isEmpty, let current = state.current, current == ranWith {
            var trial = state.trial(current) ?? TuneTrial(setup: current)
            trial.add(played.play, hitches: played.hitches)
            if let i = state.trials.firstIndex(where: { $0.setup == current }) { state.trials[i] = trial } else { state.trials.append(trial) }
            state.note(String(format: "Counted the session just played: %.1f min with %@.", trial.minutes, current.title))
            AnvilLog.write(String(format: "auto-tune: \(game.title) — the session just played counts: %.1f min with \(current.title)", trial.minutes))
            if trial.minutes >= Self.playingMinutes {
                if let next = TunePlanner.next(state.space, trials: state.trials, minMinutes: Self.playingMinutes) {
                    state.current = next
                    state.note("Next: \(next.title).")
                } else {
                    finish(&state, game: game, early: false)
                }
            }
        }
        states[game.id] = state
        save(game.id)
        return true
    }

    // MARK: Learning from every session

    /// After a session of a game Auto-Tune has decided for. The winner goes on being
    /// measured in normal play — each session adds to what it knows, the newest twenty
    /// minutes kept — so the choice rests on how the game runs now, not on the minutes it
    /// was first measured in. When two sessions running come out clearly below what the
    /// winner measured — a heavier part of the game, an update, a Mac running hot — every
    /// setup is measured again while the player plays, starting from the winner, instead of
    /// keeping a choice that no longer holds. Nothing is closed or restarted for it. Returns
    /// what happened, in words, when it starts measuring again.
    @discardableResult
    func learn(from split: Gameplay.Split, game: Game, container: Container) -> String? {
        // A session with generated frames says nothing about the game's own frames: real ones
        // are held to every second refresh while frames are generated between them.
        guard !split.play.contains(where: { ($0.generatedShare ?? 0) > 0.02 }) else { return nil }
        guard var state = states[game.id], state.mode == .finished, let winner = state.winner,
              let i = state.trials.firstIndex(where: { $0.setup == winner }),
              let measured = state.trials[i].stats,
              let now = TrialStats.from(play: split.play, hitches: split.hitches), now.minutes >= 2 else { return nil }
        // Only a session that ran with the winner says anything about it.
        guard winner.pacing == (game.targetFPSOverride ?? container.targetFPS),
              winner.graphics == nil || winner.graphics == graphicsLevel(for: game),
              winner.halfResolution == nil || winner.halfResolution == (container.profile.renderScale() < 1.5) else { return nil }
        let worse = now.shareAt80 < measured.shareAt80 - 0.25 || now.typicalFPS < measured.typicalFPS * 0.85
        state.trials[i].add(split.play, hitches: split.hitches)
        state.driftSessions = worse ? (state.driftSessions ?? 0) + 1 : 0
        var said: String?
        if (state.driftSessions ?? 0) >= 2 {
            let was = String(format: "%.0f fps typically, %@ or more %.0f%% of the time", measured.typicalFPS, DisplayProfile.targetText, measured.shareAt80 * 100)
            let is_ = String(format: "%.0f fps, %.0f%%", now.typicalFPS, now.shareAt80 * 100)
            said = "Two sessions in a row ran clearly below what \(winner.title) measured (\(is_) against \(was)), so every setup is being measured again while you play, starting from it. Nothing is closed or restarted for it."
            state.space = space(for: game, container: container, goal: state.goal)
            state.trials = []
            state.current = winner
            state.mode = .whilePlaying
            state.driftSessions = 0
            state.note("Measuring again: two sessions ran below what \(winner.title) measured.")
            AnvilLog.write("auto-tune: \(game.title) — two sessions below what \(winner.title) measured (\(is_) against \(was)); measuring again while playing")
        } else {
            state.note(String(format: "Learned from a session with %@: %.1f min, typically %.0f fps%@.", winner.title, now.minutes, now.typicalFPS,
                              worse ? " — below what it measured" : ""))
        }
        states[game.id] = state
        save(game.id)
        return said
    }

    private func minutes(for mode: TuneState.Mode) -> Double {
        mode == .quickTest ? Self.quickMinutes : Self.playingMinutes
    }

    // MARK: Launching

    /// Called by the launcher before a game starts: the setup being measured, applied to
    /// copies of the game and container for this launch only.
    func prepareLaunch(game: Game, container: Container) -> (game: Game, container: Container, logLine: String?) {
        guard var state = states[game.id], state.isActive else { return (game, container, nil) }
        let setup = state.current ?? TunePlanner.next(state.space, trials: state.trials, minMinutes: minutes(for: state.mode))
        guard let setup else { return (game, container, nil) }
        state.current = setup
        states[game.id] = state
        var g = game, c = container
        Self.apply(setup, to: &g, container: &c)
        // Measuring needs Anvil's frame library, which the refresh lock loads.
        c.lockToRefresh = true
        c.pacing = true
        running[game.id] = setup
        let done = state.trials.filter { $0.minutes >= minutes(for: state.mode) }.count
        let total = max(TunePlanner.expectedCount(state.space), done + 1)
        if state.mode == .quickTest { watch(game) }
        return (g, c, "[anvil] auto-tune: measuring \(setup.title) for “\(state.goal.title)” — setup \(done + 1) of about \(total)")
    }

    /// A setup applied to a game and its container.
    static func apply(_ setup: TuneSetup, to game: inout Game, container: inout Container) {
        if let level = setup.graphics { game.graphicsTuning = GraphicsTuning(level: level) }
        if let half = setup.halfResolution, (container.profile.renderScale() < 1.5) != half {
            (half ? PerformanceProfile.smoothest : .sharpest).apply(to: &container)
        }
        container.targetFPS = setup.pacing
        if game.targetFPSOverride != nil { game.targetFPSOverride = setup.pacing }
    }

    /// While a quick test's session runs: close the game once it has enough play measured.
    private func watch(_ game: Game) {
        monitors[game.id]?.cancel()
        let id = game.id, title = game.title
        let log = Launcher.gameLogURL
        monitors[id] = Task { [weak self] in
            // Measured play so far from earlier attempts at this setup.
            let before: Double = await MainActor.run {
                guard let self, let state = self.states[id], let current = state.current else { return 0 }
                return state.trial(current)?.minutes ?? 0
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                let minutes = await Task.detached(priority: .utility) { () -> Double in
                    guard let text = try? String(contentsOf: log, encoding: .utf8),
                          let session = FrameLog.lastSession(of: title, text: text) else { return 0 }
                    return Gameplay.split(session.windows, loadsIntoHeavy: Gameplay.loadsIntoHeavy(title: title, text: text))
                        .play.reduce(0) { $0 + $1.seconds } / 60
                }.value
                let finished: Bool = await MainActor.run {
                    guard let self, Launcher.shared.isRunning(game) else { return true }
                    self.live[id] = before + minutes
                    if before + minutes >= Self.quickMinutes {
                        AnvilLog.write(String(format: "auto-tune: \(title) — %.1f min of play measured; closing it for the next setup", before + minutes))
                        Launcher.shared.quit(game, grace: .seconds(20))
                        return true
                    }
                    return false
                }
                if finished { return }
            }
        }
    }

    /// Start the next setup of a quick test, and pause the test if the game doesn't get
    /// going — another game starting at the same moment turns a launch away silently.
    private func launchForTest(_ game: Game) {
        QuickLaunch.play(game)
        let id = game.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard var state = self.states[id], state.mode == .quickTest,
                  self.running[id] == nil, Launcher.shared.launching == nil,
                  let fresh = Library.shared.games.first(where: { $0.id == id }),
                  !Launcher.shared.isRunning(fresh) else { return }
            state.mode = .paused
            state.pausedReason = "The game didn't start for the test. Continue when nothing else is starting."
            state.note("Paused: the game didn't start.")
            self.states[id] = state
            self.save(id)
        }
    }

    /// The launch never got as far as a session: a quick test waits rather than
    /// trying again on its own.
    func launchFailed(_ game: Game, reason: String) {
        guard running.removeValue(forKey: game.id) != nil else { return }
        monitors.removeValue(forKey: game.id)?.cancel()
        live[game.id] = nil
        guard var state = states[game.id], state.mode == .quickTest else { return }
        state.mode = .paused
        state.pausedReason = "The game didn't start: \(reason)"
        state.note("Paused: the game didn't start.")
        states[game.id] = state
        save(game.id)
    }

    // MARK: A session ended

    /// Called by the launcher when a game's session ends.
    func sessionEnded(game: Game, userClosed: Bool) {
        guard let setup = running.removeValue(forKey: game.id) else { return }
        monitors.removeValue(forKey: game.id)?.cancel()
        let id = game.id, title = game.title, log = Launcher.gameLogURL
        Task {
            let split = await Task.detached(priority: .utility) { () -> Gameplay.Split? in
                guard let text = try? String(contentsOf: log, encoding: .utf8),
                      let session = FrameLog.lastSession(of: title, text: text) else { return nil }
                return Gameplay.split(session.windows, loadsIntoHeavy: Gameplay.loadsIntoHeavy(title: title, text: text))
            }.value
            self.record(split, setup: setup, gameID: id, userClosed: userClosed)
        }
    }

    private func record(_ split: Gameplay.Split?, setup: TuneSetup, gameID: UUID, userClosed: Bool) {
        live[gameID] = nil
        guard var state = states[gameID], state.isActive,
              let game = Library.shared.games.first(where: { $0.id == gameID }) else { return }
        let needed = minutes(for: state.mode)
        if let split, !split.play.isEmpty {
            var trial = state.trial(setup) ?? TuneTrial(setup: setup)
            trial.add(split.play, hitches: split.hitches)
            if let i = state.trials.firstIndex(where: { $0.setup == setup }) { state.trials[i] = trial } else { state.trials.append(trial) }
            if let s = trial.stats {
                state.note(String(format: "%@: %.1f min of play, 80 or more %.0f%% of the time, typically %.0f fps, the game could make %.0f.",
                                  setup.title, trial.minutes, s.shareAt80 * 100, s.typicalFPS, s.capacity))
                AnvilLog.write(String(format: "auto-tune: \(game.title) — \(setup.title): %.1f min measured, 80+ %.0f%%, typical %.0f fps, capacity %.0f fps, %.1f hitches/min",
                                      trial.minutes, s.shareAt80 * 100, s.typicalFPS, s.capacity, s.hitchesPerMinute))
            }
        }
        let enough = (state.trial(setup)?.minutes ?? 0) >= needed
        if enough {
            if let next = TunePlanner.next(state.space, trials: state.trials, minMinutes: needed) {
                state.current = next
                state.note("Next: \(next.title).")
            } else {
                finish(&state, game: game, early: false)
            }
        } else if state.mode == .quickTest {
            state.mode = .paused
            state.pausedReason = userClosed
                ? "The game was closed before this setup had enough play measured."
                : "The game closed before this setup had enough play measured."
            state.note("Paused: \(state.pausedReason ?? "").")
        } else {
            state.note(String(format: "%@ needs about %.0f more minutes of play.", setup.title,
                              max(needed - (state.trial(setup)?.minutes ?? 0), 0.5)))
        }
        states[gameID] = state
        save(gameID)
        // A quick test goes straight on to the next setup — once Wine has finished with
        // the last one. Started into a prefix whose server is still shutting down, a game
        // can exit at once, and a start that fails that fast is what makes Anvil try the
        // game without its library and then keep it off.
        if state.mode == .quickTest {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if let fresh = Library.shared.games.first(where: { $0.id == gameID }),
                   let container = Library.shared.container(id: fresh.containerID),
                   let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) ?? RuntimeManager.shared.defaultRuntime {
                    await Launcher.waitForWineserver(container: container, runtime: runtime, timeout: 30)
                }
                try? await Task.sleep(for: .seconds(1))
                guard let now = self.states[gameID], now.mode == .quickTest,
                      let fresh = Library.shared.games.first(where: { $0.id == gameID }),
                      !Launcher.shared.isRunning(fresh) else { return }
                self.launchForTest(fresh)
            }
        }
    }

    private func finish(_ state: inout TuneState, game: Game, early: Bool) {
        let needed = early ? min(Self.quickMinutes, 1.0) : minutes(for: state.mode)
        guard let (winner, reason) = TunePlanner.winner(state.space, trials: state.trials, minMinutes: needed)
                ?? TunePlanner.winner(state.space, trials: state.trials, minMinutes: 0.25) else {
            state.mode = .stopped
            state.note("Nothing measured long enough to decide.")
            return
        }
        state.mode = .finished
        state.current = nil
        state.winner = winner
        state.winnerReason = reason
        state.finishedAt = Date()
        if let container = Library.shared.container(id: game.containerID) {
            state.fingerprint = fingerprint(for: game, container: container)
        }
        state.note("Decided: \(winner.title) — \(reason).")
        // Stored before it is adopted: the graphics level written into the game's
        // settings is read back from here.
        states[game.id] = state
        adopt(winner, for: game)
        AnvilLog.write("auto-tune: \(game.title) — chose \(winner.title) for \(state.goal.title): \(reason)")
        announcement = Announcement(gameID: game.id, title: "\(game.title) is tuned",
                                    message: "For \(state.goal.title): \(winner.title) — \(reason).")
    }

    // MARK: Making a result the game's settings

    /// The winner becomes the game's settings: Anvil's graphics choice for it, and its
    /// pacing — on the container when the game has one of its own, on the game otherwise.
    private func adopt(_ setup: TuneSetup, for game: Game) {
        guard var g = Library.shared.games.first(where: { $0.id == game.id }),
              var c = Library.shared.container(id: g.containerID) else { return }
        let alone = Library.shared.games(in: c).count <= 1
        if setup.graphics != nil { g.graphicsTuning = .automatic }
        if let half = setup.halfResolution, alone, (c.profile.renderScale() < 1.5) != half {
            (half ? PerformanceProfile.smoothest : .sharpest).apply(to: &c)
        }
        if alone {
            c.targetFPS = setup.pacing
            g.targetFPSOverride = nil
        } else {
            g.targetFPSOverride = setup.pacing
        }
        Library.shared.update(c)
        Library.shared.update(g)
        restoreGraphicsNow(g)
    }

    private func adoptPacing(_ pacing: Int, for game: Game) {
        guard var g = Library.shared.games.first(where: { $0.id == game.id }),
              var c = Library.shared.container(id: g.containerID) else { return }
        if Library.shared.games(in: c).count <= 1 {
            c.targetFPS = pacing
            g.targetFPSOverride = nil
            Library.shared.update(c)
        } else {
            g.targetFPSOverride = pacing
        }
        Library.shared.update(g)
    }

    /// Write the game's chosen graphics level into its settings file now, rather than at
    /// the next launch, so the file always says what Anvil's page says.
    private func restoreGraphicsNow(_ game: Game) {
        guard !Launcher.shared.isBusy(game),
              let stored = Library.shared.games.first(where: { $0.id == game.id }),
              let container = Library.shared.container(id: stored.containerID),
              GameTuning.profile(for: stored) != nil else { return }
        if let line = GameTuning.prepare(stored, in: container, level: graphicsLevel(for: stored)) {
            AnvilLog.write(line)
        }
    }
}
