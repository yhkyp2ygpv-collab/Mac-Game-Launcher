import Foundation

/// What's in a game's saves, read from the save files themselves where Anvil knows their format: where the player
/// is, and how far through the game. On 21 October dates and sizes alone didn't tell LEGO Star Wars' finished game
/// (Episode Select, 34.3%) from the new start made over it (Coruscant, Episode I, 0.9%) — the new start was newer,
/// so it was picked. With this, the furthest is picked, and every copy says what it holds.
///
/// Known so far: TT Games' LEGO games. Each slot's SAVEGAMEMETA.BLOB is what the game's own slot screen shows: an
/// "Area name" ("EPSELECT_TITLE", "PLANET_CORUSCANT"), a "Route name" ("FULLTITLE_EPISODE1"), a picture, then the
/// "Game Percentage" as a 32-bit float.
enum SaveReader {
    struct Summary: Hashable, Sendable {
        /// Where the player is, in words ("Episode Select", "Coruscant · Episode I").
        var place: String
        /// How far through the whole game, as the game counts it (0–100).
        var percent: Double?
        /// How many save slots were read; the summary is of the furthest.
        var slots: Int

        var text: String {
            let pct = percent.map { String(format: "%.1f%% complete", $0) }
            return [place, pct].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Whether Anvil can read this save file (a path or a zip entry's name).
    nonisolated static func isReadable(_ path: String) -> Bool { path.uppercased().hasSuffix("SAVEGAMEMETA.BLOB") }

    /// The furthest of the slots under these folders.
    nonisolated static func summary(ofFolders folders: [URL]) -> Summary? {
        var blobs: [Data] = []
        for folder in folders {
            SaveTransfer.walk(folder, limit: 5_000) { url, values in
                guard isReadable(url.path), (values.fileSize ?? 0) < 1_000_000, let data = try? Data(contentsOf: url) else { return }
                blobs.append(data)
            }
        }
        return summary(of: blobs)
    }

    /// The same from an export, its readable entries unpacked one at a time — never the whole zip.
    nonisolated static func summary(ofZip zip: URL, entries: [String]) -> Summary? {
        summary(of: entries.filter(isReadable).prefix(16).compactMap { unzip(zip, $0) })
    }

    nonisolated static func summary(of blobs: [Data]) -> Summary? {
        let read = blobs.compactMap(ttMeta)
        guard let best = read.max(by: { ($0.percent ?? -1) < ($1.percent ?? -1) }) else { return nil }
        return Summary(place: placeName(area: best.area, route: best.route), percent: best.percent, slots: read.count)
    }

    // MARK: TT Games' LEGO games

    struct Meta: Hashable { var area: String; var route: String?; var percent: Double? }

    /// The slot screen's line from a SAVEGAMEMETA.BLOB: the strings after its "OLST" mark, then the percentage just
    /// after the last of them (the picture's name).
    nonisolated static func ttMeta(_ data: Data) -> Meta? {
        let b = [UInt8](data)
        guard let start = find(Array("OLST".utf8), in: b) else { return nil }
        var strings: [(text: String, end: Int)] = []
        var i = start
        func plain(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2E || c == 0x2D }
        while i < b.count {
            guard plain(b[i]) else { i += 1; continue }
            var j = i
            while j < b.count, plain(b[j]) { j += 1 }
            if j - i >= 3 { strings.append((String(decoding: b[i..<j], as: UTF8.self), j)) }
            i = j
        }
        let named = strings.filter { $0.text != "OLST" && $0.text != "MOBJ" }
        guard let area = named.first, area.text.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { return nil }
        let route = named.dropFirst().first { $0.text.hasPrefix("FULLTITLE_") }?.text
        var percent: Double?
        if let picture = named.last(where: { $0.text.contains(".") }), picture.end + 5 <= b.count, b[picture.end] == 0 {
            let raw = UInt32(b[picture.end + 1]) | UInt32(b[picture.end + 2]) << 8 | UInt32(b[picture.end + 3]) << 16 | UInt32(b[picture.end + 4]) << 24
            let value = Double(Float(bitPattern: raw))
            if value.isFinite, value >= 0, value <= 100 { percent = value }
        }
        return Meta(area: area.text, route: route, percent: percent)
    }

    /// "EPSELECT_TITLE" → "Episode Select"; "PLANET_CORUSCANT" with "FULLTITLE_EPISODE1" → "Coruscant · Episode I";
    /// "EP3LEVEL02" → "Episode III, level 2"; "SECTOR_NABOO" → "Naboo, in space".
    nonisolated static func placeName(area: String, route: String?) -> String {
        let episode = route.flatMap { r -> String? in
            guard r.hasPrefix("FULLTITLE_EPISODE"), let n = Int(r.dropFirst("FULLTITLE_EPISODE".count)) else { return nil }
            return "Episode \(roman(n))"
        }
        var place: String
        if area == "EPSELECT_TITLE" { return "Episode Select" }
        if area.hasPrefix("EP"), let level = area.range(of: "LEVEL"), let ep = Int(area[area.index(area.startIndex, offsetBy: 2)..<level.lowerBound]),
           let n = Int(area[level.upperBound...]) {
            return "Episode \(roman(ep)), level \(n)"
        } else if area.hasPrefix("PLANET_") {
            place = words(String(area.dropFirst(7)))
        } else if area.hasPrefix("SECTOR_") {
            place = words(String(area.dropFirst(7))) + ", in space"
        } else {
            place = words(area)
        }
        return [place, episode].compactMap { $0 }.joined(separator: " · ")
    }

    private nonisolated static let knownNames = [
        "AJANKLOSS": "Ajan Kloss", "CANTOBIGHT": "Canto Bight", "KEFBIR": "Kef Bir", "DEATHSTAR": "Death Star",
        "DEATHSTAR2": "Death Star II", "STARKILLER": "Starkiller Base", "STARKILLERBASE": "Starkiller Base",
        "YAVIN": "Yavin 4", "YAVIN4": "Yavin 4", "CLOUDCITY": "Cloud City", "MOSESPA": "Mos Espa", "MOSEISLEY": "Mos Eisley",
    ]

    private nonisolated static func words(_ code: String) -> String {
        if let known = knownNames[code] { return known }
        return code.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    private nonisolated static func roman(_ n: Int) -> String {
        let table = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out.isEmpty ? "\(n)" : out
    }

    private nonisolated static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle { return i }
        return nil
    }

    private nonisolated static func unzip(_ zip: URL, _ entry: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip reads its own wildcards in a name; LEGO's have none, but a "[" would — so they're escaped.
        p.arguments = ["-p", zip.path, entry.replacingOccurrences(of: "[", with: "\\[")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !data.isEmpty ? data : nil
    }
}
