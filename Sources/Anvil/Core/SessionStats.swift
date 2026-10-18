import Foundation

/// How a game's last session ran, from the frame statistics Anvil's library writes to
/// game.log every 600 frames. Shown in the library, so "is it holding 80?" has an
/// answer without reading a log.
struct SessionStats: Codable, Hashable {
    /// Frames shown over time shown: the true average, not an average of averages.
    var averageFPS: Double
    /// Share of the session's time spent at 80 fps or better.
    var shareAt80: Double
    /// Share of the session's time at the display's full 120.
    var shareAt120: Double
    /// The lowest 1% low of any stretch.
    var lowestOnePercent: Double
    var minutes: Double
    var endedAt: Date

    var summary: String {
        String(format: "%.0f fps on average · 80 or more %.0f%% of the time", averageFPS, shareAt80 * 100)
    }

    /// The session that began at the last header for `title` in game.log.
    static func read(log url: URL, title: String) -> SessionStats? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let header = text.range(of: "=== \(title) — ", options: .backwards) else { return nil }
        // The game's own frames, not those Anvil generated between them: on 11 October LEGO Star
        // Wars' session read "93 fps on average, 80 or more 78% of the time" with half of what was
        // shown in its heavy stretches generated — the game itself at 23–60 there.
        var windows: [FrameWindow] = []
        for line in text[header.upperBound...].split(separator: "\n") {
            // The next session's header: what follows is another game's, started beside this one.
            // Steam's own session (no frame hook) read LEGO's started after it as its own (10 October).
            if line.hasPrefix("=== ") { break }
            // [anvil] displayed 88.8 fps | 1% LOW 59.7 fps | ...
            guard let w = FrameLog.parse(line) else { continue }
            // Drawn behind another app, held to 30: not how the game ran.
            if w.wasBehind { continue }
            if w.displayed > 1 { windows.append(w) }
        }
        // The first stretch is loading and the first shaders.
        if windows.count > 2 { windows.removeFirst() }
        guard windows.count >= 2 else { return nil }
        // Each line covers 600 of the game's frames, so a slow stretch covers more time.
        let time = windows.reduce(0) { $0 + $1.seconds }
        let at80 = windows.filter { $0.displayed >= DisplayProfile.steadyTarget - 0.5 }.reduce(0) { $0 + $1.seconds }
        let at120 = windows.filter { $0.displayed >= 118 }.reduce(0) { $0 + $1.seconds }
        let shown = windows.reduce(0) { $0 + $1.displayed * $1.seconds }
        return SessionStats(averageFPS: shown / time,
                            shareAt80: at80 / time, shareAt120: at120 / time,
                            lowestOnePercent: windows.map(\.onePercentLow).min() ?? 0,
                            minutes: time / 60, endedAt: Date())
    }
}
