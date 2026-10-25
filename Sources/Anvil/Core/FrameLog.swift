import Foundation

/// One stretch of 600 frames from game.log, as Anvil's library measured it inside the
/// game:
///
///     [anvil] displayed 88.8 fps | 1% LOW 59.7 fps | … worst gap 66.7 ms | rendered 80.0 fps
///     (game could 104.7) | … LATENCY 31.3 ms avg … | GPU 87% busy | busiest threads 93% and 41% of a core
struct FrameWindow: Codable, Hashable {
    /// Frames per second the display showed.
    var displayed: Double
    var onePercentLow: Double
    var worstGapMs: Double
    /// Frames per second the game rendered.
    var rendered: Double
    /// What the game could manage on its own, with no pacing holding it back — the
    /// number that says how heavy a setting is, whatever the pacing does with it.
    var capacity: Double
    var latencyMs: Double?
    var gpuBusy: Int?
    var topThread: Int?
    /// Frames of the stretch drawn while another app was in front, held to 30 fps (10 after two minutes, 5 with the screen locked).
    var behind: Int?
    /// Share of the frames shown that Anvil generated; `displayed` is already the game's
    /// own frames alone.
    var generatedShare: Double?
    /// libanvil's timing of one frame's passes (anvil_gpuwork.mm): the GPU's busy time and each
    /// kind's part of it, in ms — "| GPU work 27.1 ms a frame: scene 11.2, shadows 6.3, …".
    var gpuWorkMs: Double? = nil
    var gpuKinds: [String: Double]? = nil
    /// The game's shader compiles in the stretch: "| shaders compiled 14 (310 ms, longest 120 ms)".
    var compiles: Int? = nil
    var compileMs: Double? = nil
    var compileLongestMs: Double? = nil
    /// How evenly frames reached the screen: "| gaps: half under 16.7 ms, 90% under 20.8 ms".
    var gapMedianMs: Double? = nil
    var gap90Ms: Double? = nil
    /// In a heavy stretch, its heaviest timed frame's longest passes, as libanvil names them:
    /// "| heaviest passes (of a 42.9 ms frame): scene 14.2 ms (1512x982, 4 colour (8-bit) + depth); …".
    var heaviestFrameMs: Double? = nil
    var heaviestPasses: [String]? = nil
    /// Smooth Motion's frames between (or made ahead, 0.69): how long the game waited a frame for its frames in flight.
    var betweenWaitMs: Double? = nil
    /// How long the first of each of the game's frames waited for the GPU once handed to it (0.69): "| waited 38.2 ms
    /// for the GPU" — a frame queued behind the ones before, the latency of a game the GPU sets the pace for.
    var gpuWaitMs: Double? = nil
    /// The game's memory, as libanvil reads it: "| memory 20023 MB".
    var memoryMB: Double? = nil

    /// Mostly drawn behind another app: not play, whatever the numbers say.
    var wasBehind: Bool { (behind ?? 0) >= 300 }

    /// How long the stretch lasted: 600 rendered frames at the rendered rate.
    var seconds: Double { 600 / max(rendered > 1 ? rendered : displayed, 1) }
}

enum FrameLog {
    /// A session's header: "=== <title> — <ISO 8601 date> — Anvil <version> ===".
    struct Session {
        var startedAt: Date?
        var windows: [FrameWindow]
    }

    /// The last session of `title` in the log.
    static func lastSession(of title: String, in url: URL) -> Session? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return lastSession(of: title, text: text)
    }

    static func lastSession(of title: String, text: String) -> Session? {
        guard let header = text.range(of: "=== \(title) — ", options: .backwards) else { return nil }
        let rest = text[header.upperBound...]
        let date = rest.split(separator: " ", maxSplits: 1).first.flatMap { ISO8601DateFormatter().date(from: String($0)) }
        var windows: [FrameWindow] = []
        for line in rest.split(separator: "\n") {
            // A later session's header ends this one.
            if line.hasPrefix("=== ") && !windows.isEmpty { break }
            if let window = parse(line) { windows.append(window) }
        }
        return Session(startedAt: date, windows: windows)
    }

    /// The most memory the game used in its last `sessions` sessions in `text` (game.log), in bytes — what it needs
    /// again. More than the last alone: Hogwarts Legacy took 11.3 GB in seven minutes on 22 October and 19.8 GB in its
    /// next session, the one the memory check had read as needing 11.
    static func peakMemory(of title: String, text: String, sessions: Int = 3) -> Int64? {
        var rest = Substring(text)
        var peak = 0.0
        for _ in 0..<max(sessions, 1) {
            guard let header = rest.range(of: "=== \(title) — ", options: .backwards) else { break }
            if let mb = lastSession(of: title, text: String(rest[header.lowerBound...]))?.windows.compactMap(\.memoryMB).max() {
                peak = max(peak, mb)
            }
            rest = rest[..<header.lowerBound]
        }
        return peak > 0 ? Int64(peak * 1_048_576) : nil
    }

    /// One statistics line, or nil for any other line.
    static func parse(_ line: Substring) -> FrameWindow? {
        guard let start = line.range(of: "[anvil] displayed ") else { return nil }
        let body = line[start.upperBound...]
        guard let displayed = number(in: body, after: nil, before: " fps") else { return nil }
        let low = number(in: body, after: "1% LOW ", before: " fps") ?? displayed
        let worst = number(in: body, after: "worst gap ", before: " ms") ?? 0
        let rendered = number(in: body, after: "rendered ", before: " fps") ?? displayed
        let capacity = number(in: body, after: "(game could ", before: ")") ?? rendered
        let latency = number(in: body, after: "LATENCY ", before: " ms")
        let gpu = number(in: body, after: "GPU ", before: "% busy").map { Int($0) }
        let top = number(in: body, after: "busiest threads ", before: "% and").map { Int($0) }
        let behind = numberToEnd(in: body, after: "| behind ").map { Int($0) }
        // "| generated 600 of 1200 shown": what the display showed includes Anvil's frames;
        // what is measured of the game is its own.
        var shown = displayed
        var generatedShare: Double?
        if let generated = numberToEnd(in: body, after: "| generated "),
           let total = number(in: body, after: "| generated \(Int(generated)) of ", before: " shown"), total > 0 {
            generatedShare = min(max(generated / total, 0), 1)
            shown = displayed * (1 - (generatedShare ?? 0))
        }
        var window = FrameWindow(displayed: shown, onePercentLow: low, worstGapMs: worst, rendered: rendered,
                                 capacity: capacity, latencyMs: latency, gpuBusy: gpu, topThread: top, behind: behind,
                                 generatedShare: generatedShare)
        if let r = body.range(of: "| GPU work "), let ms = number(in: body[r.upperBound...], after: nil, before: " ms a frame:") {
            window.gpuWorkMs = ms
            let after = body[r.upperBound...]
            if let colon = after.range(of: "a frame:") {
                var list = after[colon.upperBound...]
                if let bar = list.range(of: " |") { list = list[..<bar.lowerBound] }
                var kinds: [String: Double] = [:]
                for part in list.split(separator: ",") {
                    let words = part.trimmingCharacters(in: .whitespaces)
                    guard let space = words.lastIndex(of: " "), let value = Double(words[words.index(after: space)...]) else { continue }
                    kinds[String(words[..<space])] = value
                }
                window.gpuKinds = kinds
            }
        }
        if let r = body.range(of: "| gaps: half under ") {
            let rest = body[r.upperBound...]
            window.gapMedianMs = number(in: rest, after: nil, before: " ms")
            window.gap90Ms = number(in: rest, after: "90% under ", before: " ms")
        }
        if let r = body.range(of: "| heaviest passes (of a ") {
            let rest = body[r.upperBound...]
            window.heaviestFrameMs = number(in: rest, after: nil, before: " ms frame")
            if let colon = rest.range(of: "):") {
                var list = rest[colon.upperBound...]
                if let bar = list.range(of: " | ") { list = list[..<bar.lowerBound] }
                window.heaviestPasses = list.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        if let r = body.range(of: "| memory ") {
            window.memoryMB = number(in: body[r.upperBound...], after: nil, before: " MB")
        }
        if let r = body.range(of: "| frames between: the game waited ") ?? body.range(of: "| frames made ahead: the game waited ") {
            window.betweenWaitMs = number(in: body[r.upperBound...], after: nil, before: " ms")
        }
        if let r = body.range(of: "| waited "), body[r.upperBound...].contains(" ms for the GPU") {
            window.gpuWaitMs = number(in: body[r.upperBound...], after: nil, before: " ms for the GPU")
        }
        if let r = body.range(of: "| shaders compiled ") {
            let rest = body[r.upperBound...]
            window.compiles = rest.split(separator: " ", maxSplits: 1).first.flatMap { Int($0) }
            window.compileMs = number(in: rest, after: "(", before: " ms")
            window.compileLongestMs = number(in: rest, after: "longest ", before: " ms")
        }
        return window
    }

    /// A number that ends its line, or the next " |" field.
    private static func numberToEnd(in text: Substring, after prefix: String) -> Double? {
        guard let r = text.range(of: prefix) else { return nil }
        let rest = text[r.upperBound...]
        let end = rest.range(of: " ")?.lowerBound ?? rest.endIndex
        return Double(rest[rest.startIndex..<end])
    }

    private static func number(in text: Substring, after prefix: String?, before suffix: String) -> Double? {
        var from = text.startIndex
        if let prefix {
            guard let r = text.range(of: prefix) else { return nil }
            from = r.upperBound
        }
        guard let end = text.range(of: suffix, range: from..<text.endIndex) else { return nil }
        return Double(text[from..<end.lowerBound].trimmingCharacters(in: .whitespaces))
    }
}

/// How long a game takes to load on this Mac, from its earlier sessions.
///
/// Loading ends, for this purpose, at the first stretch with the GPU at least 40% busy:
/// a game's logos, menus and loading screens keep it near 20%, and its first real scene
/// takes it to 50–85%. LEGO Star Wars on 1–2 October: 36 and 45 s online, and 29 s
/// offline in the one offline start that was given the time — while every offline start
/// closed sooner looked "stuck on the loading screen". It also pauses, loading included,
/// whenever another app is in front, which none of the closed ones had been spared.
enum LoadTime {
    struct Estimate: Sendable, Equatable {
        /// The middle of the sessions measured.
        var typical: Double
        var longest: Double
        var sessions: Int
    }

    static let heavyGPU = 40

    /// Seconds from each session's first timed line to its first heavy stretch, for every
    /// session of `title` that got that far.
    static func history(of title: String, text: String) -> [Double] {
        var out: [Double] = []
        var inSession = false, first: Double?, done = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("=== ") {
                inSession = line.hasPrefix("=== \(title) — ")
                first = nil
                done = false
                continue
            }
            guard inSession, !done, let t = clock(line) else { continue }
            guard let start = first else { first = t; continue }
            if let w = FrameLog.parse(line), let gpu = w.gpuBusy, gpu >= heavyGPU {
                var elapsed = t - start
                if elapsed < 0 { elapsed += 86_400 }          // past midnight
                if elapsed < 1_800 { out.append(elapsed) }
                done = true
            }
        }
        return out
    }

    static func estimate(of title: String, text: String) -> Estimate? {
        let seen = history(of: title, text: text).suffix(12).sorted()
        guard !seen.isEmpty else { return nil }
        return Estimate(typical: seen[seen.count / 2], longest: seen.last!, sessions: seen.count)
    }

    static func estimate(of title: String, in url: URL) -> Estimate? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return estimate(of: title, text: text)
    }

    /// "18:24:42.465 [anvil] …" → seconds since midnight.
    static func clock(_ line: Substring) -> Double? {
        guard line.count > 12 else { return nil }
        let chars = Array(line.prefix(12))
        guard chars[2] == ":", chars[5] == ":", chars[8] == ".",
              let h = Int(String(chars[0...1])), let m = Int(String(chars[3...4])),
              let s = Int(String(chars[6...7])), let ms = Int(String(chars[9...11])) else { return nil }
        return Double(h * 3600 + m * 60 + s) + Double(ms) / 1000
    }

    /// "about 40 s", "about 1 min 20 s".
    static func text(_ seconds: Double) -> String {
        let s = Int((seconds / 5).rounded(.up) * 5)
        return s < 60 ? "\(s) s" : (s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s")
    }
}

/// Which stretches of a session show the game being played.
enum Gameplay {
    /// A stretch whose worst gap is this long held a load or a stall, not play.
    static let stallMs = 250.0
    /// A hitch the player feels.
    static let hitchMs = 100.0

    struct Split {
        var play: [FrameWindow]
        /// Hitches after the game had loaded, including the stalls left out of `play`.
        var hitches: Int
    }

    /// Everything after the start-up stretch and the load into the game, without stalls.
    ///
    /// The first two stretches are the first frames and shaders. After those a game shows
    /// its logos and menus and then loads — LEGO Star Wars at 120 fps in its menus, then a
    /// stretch with a gap of a third of a second as the save loads. Play starts after the
    /// last such stall within the first sixteen stretches; a stall later than that is a
    /// hitch in play and is counted as one.
    ///
    /// `loadsIntoHeavy`: the game's earlier sessions all went from light loading screens to
    /// a first scene that works the GPU (LoadTime). Play then can't start before that scene,
    /// and a session that never reached it — closed on the loading screen, or stuck at a
    /// sign-in — has none: Auto-Tune counted such sessions as play on 3 October, and closed
    /// LEGO Star Wars at its menu for "1.6 minutes measured".
    static func split(_ windows: [FrameWindow], loadsIntoHeavy: Bool = false) -> Split {
        let windows = windows.filter { !$0.wasBehind }
        guard windows.count > 2 else { return Split(play: [], hitches: 0) }
        var start = 2
        for i in 2..<min(windows.count, 16) where windows[i].worstGapMs >= stallMs { start = i + 1 }
        if loadsIntoHeavy {
            guard let first = windows.firstIndex(where: { ($0.gpuBusy ?? 0) >= LoadTime.heavyGPU }) else {
                return Split(play: [], hitches: 0)
            }
            start = max(start, first)
        }
        let after = windows.dropFirst(start).filter { $0.displayed >= 5 }
        let play = after.filter { $0.worstGapMs < stallMs }
        let hitches = after.filter { $0.worstGapMs >= hitchMs }.count
        return Split(play: Array(play), hitches: hitches)
    }

    /// Whether the game's sessions go from light loading screens to a heavy first scene —
    /// seen at least twice in game.log.
    static func loadsIntoHeavy(title: String, text: String) -> Bool {
        LoadTime.history(of: title, text: text).count >= 2
    }
}

/// How a setup ran, over the stretches of play measured with it.
struct TrialStats: Codable, Hashable {
    var minutes: Double
    /// Share of the time at 80 fps or better, as displayed.
    var shareAt80: Double
    var shareAt60: Double
    var shareAt120: Double
    /// Half the time faster than this, as displayed.
    var typicalFPS: Double
    /// Nine-tenths of the time faster than this.
    var lowFPS: Double
    /// What the game could manage unaided, half the time and nine-tenths of the time.
    var capacity: Double
    var capacityLow: Double
    var onePercentLow: Double
    var hitchesPerMinute: Double
    var gpuBusy: Double?
    /// Share of the time one of the game's threads was the limit rather than the GPU.
    var cpuBoundShare: Double

    static func from(play: [FrameWindow], hitches: Int) -> TrialStats? {
        let total = play.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return nil }
        func share(_ keep: (FrameWindow) -> Bool) -> Double {
            play.filter(keep).reduce(0) { $0 + $1.seconds } / total
        }
        let gpus = play.compactMap { w in w.gpuBusy.map { (Double($0), w.seconds) } }
        let cpuBound = share { ($0.topThread ?? 0) >= 90 && ($0.gpuBusy ?? 100) < 85 }
        return TrialStats(
            minutes: total / 60,
            // "80" is the display's steady target: 80 on ProMotion, 60 on a 60 Hz display.
            shareAt80: share { $0.displayed >= DisplayProfile.steadyTarget - 0.5 },
            shareAt60: share { $0.displayed >= 59.5 },
            shareAt120: share { $0.displayed >= 118 },
            typicalFPS: percentile(play.map { ($0.displayed, $0.seconds) }, 0.5),
            lowFPS: percentile(play.map { ($0.displayed, $0.seconds) }, 0.1),
            capacity: percentile(play.map { ($0.capacity, $0.seconds) }, 0.5),
            capacityLow: percentile(play.map { ($0.capacity, $0.seconds) }, 0.1),
            onePercentLow: percentile(play.map { ($0.onePercentLow, $0.seconds) }, 0.5),
            hitchesPerMinute: Double(hitches) / max(total / 60, 0.5),
            gpuBusy: gpus.isEmpty ? nil : percentile(gpus, 0.5),
            cpuBoundShare: cpuBound)
    }

    /// Time-weighted: the value below which `p` of the time was spent.
    static func percentile(_ samples: [(value: Double, weight: Double)], _ p: Double) -> Double {
        let sorted = samples.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        var running = 0.0
        for sample in sorted {
            running += sample.weight
            if running >= p * total { return sample.value }
        }
        return sorted.last?.value ?? 0
    }
}
