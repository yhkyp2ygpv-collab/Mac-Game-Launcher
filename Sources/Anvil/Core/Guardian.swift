import Foundation

/// Guardian: a small part of Anvil inside each game that wakes every few seconds while it plays, makes sure
/// what Anvil does for it is working, and learns what runs best on this Mac (libanvil's anvil_guardian and
/// its check-ups in anvil_inject.mm).
///
/// What it learns is whether Smooth Motion's frames between pay for themselves at each frame rate of the
/// game's own — measured by showing the game's own frames alone for a few seconds now and then and comparing,
/// the same scene seconds apart. That differs by Mac (an M4 makes a frame between in a quarter of a base
/// M1's time) and by game, so it is kept per game and per Mac, here, and read back at the game's next start.
/// It never restarts a game or changes its settings: only what Anvil does inside it, as it plays.
enum Guardian {
    nonisolated static var directory: URL {
        RuntimeManager.support.appendingPathComponent("Guardian", isDirectory: true)
    }

    /// This Mac as Guardian tells Macs apart: its chip, GPU and display. A Mac moved to with Migration
    /// Assistant starts afresh rather than on what another Mac's GPU and display found.
    static var macKey: String {
        let device = DeviceProfile.current
        let chip = device?.chip ?? (DeviceProfile.sysctl("machdep.cpu.brand_string") ?? "Mac")
        let gpu = device?.gpuCores.map { "-\($0)gpu" } ?? ""
        let display = "\(Int(DisplayProfile.maxHz.rounded()))hz\(DisplayProfile.variableRefresh ? "-vrr" : "")"
        let raw = "\(chip)\(gpu)-\(display)"
        return String(raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Where libanvil keeps what it learns for this game on this Mac (ANVIL_GUARDIAN_STATE).
    static func stateURL(for gameID: UUID, mac: String = macKey) -> URL {
        directory.appendingPathComponent("\(gameID.uuidString)-\(mac).txt")
    }

    /// One band of the game's own frame rate, as learned.
    struct Band: Equatable {
        var low: Int
        var high: Int
        /// Checks made.
        var checks: Int
        /// Frames between against the game's own alone, on average: 0.4 is 40% better.
        var change: Double
        /// libanvil's own rule (anvil_guardian.mm): against them from three checks, a loss of more than 5%
        /// on average, clear of nothing by a standard error.
        var wanted: Bool
        var settled: Bool { checks >= 3 }
    }

    /// What's been learned for a game on this Mac. Empty before its first check.
    static func learned(gameID: UUID, mac: String = macKey) -> [Band] {
        guard let text = try? String(contentsOf: stateURL(for: gameID, mac: mac), encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// libanvil's file (anvil_guardian.mm's save), read.
    static func parse(_ text: String) -> [Band] {
        guard text.hasPrefix("anvil-guardian 1") else { return [] }
        return text.split(separator: "\n").compactMap { line -> Band? in
            let f = line.split(separator: " ")
            guard f.count == 6, f[0] == "band", let lo = Double(f[1]), let hi = Double(f[2]), let n = Int(f[3]),
                  let mean = Double(f[4]), let m2 = Double(f[5]), n > 0 else { return nil }
            let se = n >= 2 ? (max(0, m2) / Double(n - 1) / Double(n)).squareRoot() : .infinity
            let against = n >= 3 && mean < -0.05 && mean + se < 0
            return Band(low: Int(lo), high: Int(hi), checks: n, change: mean, wanted: !against)
        }
    }

    /// In words, for the log and the game's page: nil before anything is learned.
    static func summary(gameID: UUID, mac: String = macKey) -> String? {
        summary(of: learned(gameID: gameID, mac: mac))
    }

    static func summary(of bands: [Band]) -> String? {
        guard !bands.isEmpty else { return nil }
        func list(_ b: [Band]) -> String {
            b.map { "\($0.low)–\($0.high) fps (\($0.change >= 0 ? "+" : "−")\(Int((abs($0.change) * 100).rounded()))%)" }
                .joined(separator: ", ")
        }
        var parts: [String] = []
        let help = bands.filter { $0.settled && $0.wanted }, not = bands.filter { $0.settled && !$0.wanted }
        let learning = bands.filter { !$0.settled }
        if !help.isEmpty { parts.append("Smooth Motion helps at \(list(help))") }
        if !not.isEmpty { parts.append("the game's own frames are better at \(list(not))") }
        if !learning.isEmpty { parts.append("still learning \(list(learning))") }
        return parts.joined(separator: "; ")
    }

    /// Start learning afresh for a game on this Mac.
    static func forget(gameID: UUID) {
        try? FileManager.default.removeItem(at: stateURL(for: gameID))
    }

    /// The environment for a launch: on or off, and the file for this game on this Mac.
    static func environment(gameID: UUID, on: Bool) -> [String: String] {
        guard on else { return ["ANVIL_GUARDIAN": "0"] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ["ANVIL_GUARDIAN": "1", "ANVIL_GUARDIAN_STATE": stateURL(for: gameID).path]
    }

    /// The launch log's line.
    static func launchLine(gameID: UUID, on: Bool) -> String {
        guard on else { return "Guardian: off" }
        let learned = summary(gameID: gameID).map { "learned on this Mac: \($0)" } ?? "nothing learned on this Mac yet"
        return "Guardian: on — checks every few seconds that what Anvil does is working, and learns what runs best here; \(learned)"
    }
}
