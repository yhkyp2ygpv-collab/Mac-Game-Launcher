import Foundation

/// Forward-compatible decoding.
///
/// Swift's synthesised `Decodable` treats a missing key as a failure even when the
/// property has a default value. That means the moment Anvil gains a new setting,
/// every library file written by an older build stops decoding — and a launcher that
/// silently empties your library on update is worse than one that never shipped the
/// setting. So decoding goes through here: the stored object is layered over a
/// freshly-encoded default, filling in whatever the old file didn't know about.
enum Migration {

    static func decode<T: Codable>(_ type: T.Type, from data: Data, default fallback: T) throws -> T {
        let decoder = JSONDecoder()
        // Fast path: a current-format file needs none of this.
        if let value = try? decoder.decode(type, from: data) { return value }

        let stored = try JSONSerialization.jsonObject(with: data)
        let template = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback))
        let merged = fill(stored, from: template)
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Decode a library element by element, keeping everything that survives.
    ///
    /// The rule this enforces: one unreadable record must never cost you the whole
    /// library. Anvil used to decode the file as a single value, so a single game
    /// written by an older build — one missing `flowDivisor`, say — failed the entire
    /// decode and the library was set aside as unreadable. Four such files had
    /// accumulated on the machine this was found on.
    static func salvage<Element: Codable & Identifiable>(
        _ type: Element.Type, from raw: Any?, default fallback: Element
    ) -> (kept: [Element], lost: Int) {
        guard let array = raw as? [Any] else { return ([], 0) }
        var kept: [Element] = []
        var lost = 0
        let template = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(fallback)))

        for element in array {
            let merged = template.map { fill(element, from: $0) } ?? element
            guard let data = try? JSONSerialization.data(withJSONObject: merged),
                  let decoded = try? JSONDecoder().decode(type, from: data) else {
                lost += 1
                continue
            }
            kept.append(decoded)
        }
        return (kept, lost)
    }

    /// Recursively supply anything `stored` is missing from `template`.
    /// Values present in `stored` always win — a migration must never quietly
    /// reset a setting the user actually chose.
    private static func fill(_ stored: Any, from template: Any) -> Any {
        if let storedDict = stored as? [String: Any], let templateDict = template as? [String: Any] {
            var out = storedDict
            for (key, templateValue) in templateDict {
                if let existing = out[key] {
                    out[key] = fill(existing, from: templateValue)
                } else {
                    out[key] = templateValue
                }
            }
            return out
        }
        if let storedArray = stored as? [Any], let templateArray = template as? [Any],
           let element = templateArray.first {
            // Arrays of objects — each element gets the same treatment.
            return storedArray.map { fill($0, from: element) }
        }
        return stored
    }
}
