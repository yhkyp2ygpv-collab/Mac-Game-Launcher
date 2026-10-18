import Foundation
import ImageIO
import Vision

/// What a game showed on screen, read after the session from the small pictures Anvil's
/// library keeps of it (anvil_screens.mm): at set times in its first minutes, and the last
/// one before it was closed. The words in them are read here, on this Mac, with Vision.
///
/// Until 0.32 a game that sat on one screen left only frame rates behind: LEGO Star Wars,
/// started offline on 1, 3, 5 and 8 October, drew its loading screen at full speed and was
/// closed each time with nothing to say which screen it was. Now the check-up after a session
/// can say “it was waiting for a button press” or quote the message it showed.
enum ScreenReader {
    struct Shot: Codable, Hashable {
        /// The picture's file name: "030s.jpg", or "last.jpg" for the one before it closed.
        var name: String
        /// Seconds after the game's first frame; nil for the last picture.
        var seconds: Int?
        /// The lines of text in it, top to bottom.
        var lines: [String]

        var isLast: Bool { seconds == nil }
        var text: String { lines.joined(separator: " · ") }
    }

    /// What a screen is, from its words.
    enum Kind: String {
        case pressToStart, menu, connection, loading, error, other

        var phrase: String {
            switch self {
            case .pressToStart: "waiting for a button press"
            case .menu: "at a menu"
            case .connection: "showing a message about its connection or sign-in"
            case .loading: "still loading"
            case .error: "showing an error"
            case .other: "showing"
            }
        }
    }

    nonisolated static var root: URL { RuntimeManager.support.appendingPathComponent("Screens", isDirectory: true) }

    /// A session's pictures: one folder per game, one inside it per session, named by the
    /// time on the session's line in game.log.
    nonisolated static func folder(gameID: UUID, startedAt: Date) -> URL {
        let stamp = ISO8601DateFormatter().string(from: startedAt).replacingOccurrences(of: ":", with: ".")
        return root.appendingPathComponent(gameID.uuidString, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }

    /// The newest `keep` sessions of a game; older ones go. They are Anvil's own pictures, kept
    /// only to be read.
    nonisolated static func prune(gameID: UUID, keep: Int = 8) {
        let dir = root.appendingPathComponent(gameID.uuidString, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for old in names.filter({ !$0.hasPrefix(".") }).sorted().dropLast(keep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old, isDirectory: true))
        }
    }

    /// The words in each of a session's pictures, oldest first, the last picture at the end.
    /// Read once: kept beside them as text.json.
    nonisolated static func read(folder: URL) -> [Shot] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        let pictures = names.filter { $0.hasSuffix(".jpg") && !$0.hasPrefix(".") }.sorted { a, b in
            (seconds(of: a) ?? .max) < (seconds(of: b) ?? .max)
        }
        guard !pictures.isEmpty else { return [] }
        let cache = folder.appendingPathComponent("text.json")
        if let data = try? Data(contentsOf: cache), let kept = try? JSONDecoder().decode([Shot].self, from: data),
           kept.map(\.name) == pictures,
           let cacheDate = (try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date,
           !pictures.contains(where: { name in
               ((try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.modificationDate] as? Date ?? .distantFuture) > cacheDate
           }) {
            return kept
        }
        var unread = false
        let shots = pictures.map { name -> Shot in
            let lines = recognize(folder.appendingPathComponent(name))
            if lines == nil { unread = true }
            return Shot(name: name, seconds: seconds(of: name), lines: lines ?? [])
        }
        // Kept only when every picture could be read: Vision failing once (it can't load its
        // model in a sandboxed test) is no reason to remember a screen as blank.
        if !unread, let data = try? JSONEncoder().encode(shots) { try? data.write(to: cache, options: .atomic) }
        return shots
    }

    /// "030s.jpg" → 30; "last.jpg" → nil.
    nonisolated static func seconds(of name: String) -> Int? {
        guard name.hasSuffix("s.jpg") else { return nil }
        return Int(name.dropLast(5))
    }

    /// The lines of text Vision finds in a picture, top to bottom; nil when it couldn't read it.
    nonisolated static func recognize(_ url: URL) -> [String]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return nil }
        return results
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }   // Vision's origin is bottom left
            .compactMap { observation -> String? in
                guard let best = observation.topCandidates(1).first, best.confidence >= 0.4 else { return nil }
                let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.filter(\.isLetter).count >= 2 ? text : nil
            }
    }

    /// What kind of screen these words make.
    nonisolated static func kind(of lines: [String]) -> Kind {
        let text = lines.joined(separator: " ").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["error", "failed", "unable to", "can't", "cannot", "could not", "couldn't", "crash"]) {
            return has(["connect", "online", "network", "server", "internet", "sign in", "signed in", "sign-in", "log in", "login", "account", "epic", "steam"])
                ? .connection : .error
        }
        if has(["connect", "online service", "network", "server", "internet", "signing in", "sign in", "sign-in",
                "logging in", "log in", "offline", "authenticat"]) { return .connection }
        if has(["press any", "press start", "press enter", "press a ", "press ⓐ", "press space", "press any key",
                "press any button", "to start", "to continue", "click to"]) { return .pressToStart }
        if has(["loading", "please wait", "saving"]) { return .loading }
        // A game's menu: two or more of its usual choices on one screen ("Play Solo · Play Co-op ·
        // Quit", Cat Quest II, 10 October). A game showing one has got going.
        let choices = ["new game", "continue", "load game", "play solo", "play co-op", "co-op", "single player",
                       "multiplayer", "options", "settings", "extras", "credits", "quit", "exit game", "start game", "resume"]
        if choices.filter({ text.contains($0) }).count >= 2 { return .menu }
        return .other
    }

    /// A screen's words, short enough to quote: its first lines, up to about 120 characters.
    nonisolated static func quote(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            let next = out.isEmpty ? line : out + " · " + line
            if next.count > 120 { if out.isEmpty { out = String(line.prefix(117)) + "…" }; break }
            out = next
        }
        return out
    }

    /// What was on screen when it closed: the last picture with words, else the latest timed one.
    nonisolated static func atClose(_ shots: [Shot]) -> Shot? {
        if let last = shots.last(where: \.isLast), !last.lines.isEmpty { return last }
        return shots.last { !$0.isLast && !$0.lines.isEmpty }
    }

    /// One line for the launch log: each screen whose words changed, then the one at the close.
    nonisolated static func logLine(title: String, shots: [Shot]) -> String? {
        var parts: [String] = []
        var previous: [String]?
        for shot in shots where !shot.isLast && !shot.lines.isEmpty && shot.lines != previous {
            // A long session's pictures, every 10 minutes: "20 min", not "1200 s".
            let s = shot.seconds ?? 0
            parts.append("\(s >= 600 && s % 60 == 0 ? "\(s / 60) min" : "\(s) s") “\(quote(shot.lines))”")
            previous = shot.lines
        }
        if let close = atClose(shots) { parts.append("at the end “\(quote(close.lines))”") }
        guard !parts.isEmpty else { return shots.isEmpty ? nil : "screens: \(title) — no words on screen to read" }
        return "screens: \(title) — " + parts.joined(separator: ", ")
    }
}
