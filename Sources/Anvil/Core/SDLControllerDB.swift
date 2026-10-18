import Foundation

/// The controller mappings compiled into the engine's own SDL.
///
/// SDL 2.30 ships with correct mappings for a long list of pads — Xbox, PlayStation,
/// Switch, 8BitDo, Logitech, Hori and more — and those are the mappings every other
/// SDL game on this Mac uses. Anvil used to send its own guessed mapping for every
/// connected pad, which replaces SDL's: correct for the PowerA pad it was checked on,
/// wrong for most of the rest. Anvil now reads the database out of the engine's
/// libSDL2 and only supplies a mapping for a pad the database does not cover.
enum SDLControllerDB {

    struct Entry {
        let bus: Int, vendor: Int, product: Int, version: Int
        let mapping: String          // full line: GUID,name,fields…
    }

    private static var cache: [String: [Entry]] = [:]
    private static let lock = NSLock()

    /// All mappings in the given libSDL2, parsed once per file.
    static func entries(in library: URL) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[library.path] { return hit }
        let parsed = parse(library)
        cache[library.path] = parsed
        return parsed
    }

    /// The built-in mapping for a device, if SDL has one. Prefers an entry for the
    /// same firmware version, and, where SDL keeps two variants that depend on the
    /// button-labels hint, the positional one — Anvil runs with labels off because
    /// Wine translates to XInput, which is positional.
    static func mapping(vendor: Int, product: Int, version: Int, bus: Int,
                        in library: URL) -> String? {
        let candidates = entries(in: library).filter {
            $0.vendor == vendor && $0.product == product && ($0.bus == bus || $0.bus == 0)
        }
        guard !candidates.isEmpty else { return nil }
        let ranked = candidates.sorted { a, b in
            func score(_ e: Entry) -> Int {
                var s = 0
                if e.version == version { s += 4 }
                if e.mapping.contains("hint:!SDL_GAMECONTROLLER_USE_BUTTON_LABELS") { s += 2 }
                else if !e.mapping.contains("hint:") { s += 1 }
                return s
            }
            return score(a) > score(b)
        }
        return ranked.first?.mapping
    }

    // MARK: Community database

    /// SDL_GameControllerDB — the community list SDL's own grows from — bundled as
    /// Resources/gamecontrollerdb.txt, with its zlib licence beside it.
    ///
    /// The engines' SDL (2.30 in Whisky, 2.32 in Mythic Engine) predates many pads, the
    /// PowerA Advantage pad for the Switch 2 among them. Without an entry Anvil built a
    /// mapping from the pad's descriptor, which says how many buttons there are but not
    /// which is which, and assumed the bottom button came first. On a Switch-style pad the first is Y: the
    /// database and SDL agree on Y, B, A, X for every PowerA and Hori Switch pad. So
    /// three of four face buttons landed one place round.
    ///
    /// Only macOS and Windows entries are used. Both number buttons and axes in HID
    /// usage order, as SDL's IOKit backend does; Linux numbers them by evdev code.
    static func communityMapping(vendor: Int, product: Int, version: Int,
                                 layout: HIDLayout) -> String? {
        let candidates = communityEntries().filter {
            $0.entry.vendor == vendor && $0.entry.product == product && fits($0.entry.mapping, layout)
        }
        let ranked = candidates.sorted { a, b in
            func score(_ c: (entry: Entry, mac: Bool)) -> Int {
                var s = c.mac ? 8 : 0
                if c.entry.version == version { s += 4 }
                if c.entry.mapping.contains("hint:!SDL_GAMECONTROLLER_USE_BUTTON_LABELS") { s += 2 }
                else if !c.entry.mapping.contains("hint:") { s += 1 }
                return s
            }
            return score(a) > score(b)
        }
        return ranked.first?.entry.mapping
    }

    private static var community: [(entry: Entry, mac: Bool)]?

    static func communityEntries(file: URL? = Bundle.main.resourceURL?
                                    .appendingPathComponent("gamecontrollerdb.txt")) -> [(entry: Entry, mac: Bool)] {
        lock.lock(); defer { lock.unlock() }
        if let community { return community }
        var out: [(entry: Entry, mac: Bool)] = []
        if let file, let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let mac = line.contains(",platform:Mac OS X,")
                guard mac || line.contains(",platform:Windows,") else { continue }
                let bytes = Array(line.utf8)
                guard bytes.count > 40, bytes[32] == UInt8(ascii: ","), let e = bytes.withUnsafeBufferPointer({
                    entry($0, 0, $0.count)
                }) else { continue }
                // A GUID in the vendor/product form has zeros around both ids; older
                // forms hash the name there instead and carry no ids to match on.
                let hex = line.prefix(32)
                guard hex.dropFirst(12).prefix(4) == "0000", hex.dropFirst(20).prefix(4) == "0000" else { continue }
                out.append((e, mac))
            }
        }
        community = out
        return out
    }

    /// Whether every button, axis and hat a mapping names exists on the pad — so an
    /// entry written for a different revision can never bind an input it lacks.
    static func fits(_ mapping: String, _ layout: HIDLayout) -> Bool {
        guard layout.buttonCount > 0 || !layout.axisUsages.isEmpty else { return true }
        for field in mapping.split(separator: ",").dropFirst(2) {
            guard let colon = field.firstIndex(of: ":") else { continue }
            var source = field[field.index(after: colon)...].drop { $0 == "+" || $0 == "-" }
            guard let kind = source.first, "abh".contains(kind) else { continue }
            source = source.dropFirst()
            guard let n = Int(source.prefix { $0.isNumber }) else { continue }
            switch kind {
            case "b": if n >= layout.buttonCount { return false }
            case "a": if n >= layout.axisUsages.count { return false }
            default: if n >= layout.hatCount { return false }
            }
        }
        return true
    }

    private static func parse(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [Entry] = []
        // Mappings are NUL-terminated ASCII strings of the form "<32 hex>,<name>,…".
        var start: Int? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<bytes.count {
                let b = bytes[i]
                let printable = b >= 0x20 && b < 0x7F
                if printable {
                    if start == nil { start = i }
                } else if let s = start {
                    if i - s > 40, let entry = entry(bytes, s, i) { out.append(entry) }
                    start = nil
                }
            }
        }
        return out
    }

    private static func entry(_ bytes: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> Entry? {
        // Quick shape check before building a String: 32 lowercase hex digits then ','.
        guard bytes[s + 32] == UInt8(ascii: ",") else { return nil }
        for k in 0..<32 {
            let c = bytes[s + k]
            guard (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) else { return nil }
        }
        let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[s..<e]), as: UTF8.self)
        guard line.contains(",a:") || line.contains(",leftx:") else { return nil }
        let hex = Array(line.prefix(32))
        func le16(_ offset: Int) -> Int {
            let lo = Int(String(hex[offset * 2...offset * 2 + 1]), radix: 16) ?? 0
            let hi = Int(String(hex[offset * 2 + 2...offset * 2 + 3]), radix: 16) ?? 0
            return lo | (hi << 8)
        }
        return Entry(bus: le16(0), vendor: le16(4), product: le16(8), version: le16(12),
                     mapping: line)
    }
}
