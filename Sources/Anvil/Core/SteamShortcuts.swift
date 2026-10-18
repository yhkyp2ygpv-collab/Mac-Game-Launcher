import AppKit
import Foundation

/// A game of Anvil's in Steam's library, started through Anvil.
///
/// Steam can list any program as a "non-Steam game". Started by Steam, LEGO Star Wars' .exe
/// would run in Steam's own container, on Steam's engine, with no Epic sign-in and none of
/// Anvil's frame pacing, FSR, controller fixes or save backups. So the shortcut Steam gets is
/// Wine's winebrowser with the game's anvil:// link: Steam's Play opens the link on the Mac
/// (winebrowser hands it to /usr/bin/open), and Anvil starts the game exactly as its own Play
/// button does. Its cover goes in as Steam's grid art.
///
/// Steam keeps its shortcuts in userdata/<account>/config/shortcuts.vdf, in Valve's binary
/// key-value format, and reads it as it starts: the file is written with Steam closed.
enum SteamShortcuts {
    // MARK: Valve's binary key-values

    indirect enum Value: Equatable {
        case map([(String, Value)])
        case string(String)
        case int(Int32)
        case uint64(UInt64)
        case float(Float)

        static func == (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case (.string(let x), .string(let y)): x == y
            case (.int(let x), .int(let y)): x == y
            case (.uint64(let x), .uint64(let y)): x == y
            case (.float(let x), .float(let y)): x == y
            case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: false
            }
        }

        subscript(key: String) -> Value? {
            guard case .map(let entries) = self else { return nil }
            return entries.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
        }
        var text: String? { if case .string(let s) = self { return s }; return nil }
    }

    enum Failure: LocalizedError {
        case unreadable, noSteam, noAccount, steamBusy
        var errorDescription: String? {
            switch self {
            case .steamBusy: "Steam is running beside a game. Close the game, then add it."
            case .unreadable: "Steam's list of non-Steam games couldn't be read, so it was left as it is."
            case .noSteam: "Steam isn't set up in Anvil yet."
            case .noAccount: "Steam hasn't been signed in to here yet — sign in once, then add the game."
            }
        }
    }

    /// The top-level map of a binary key-values file.
    static func parse(_ data: Data) throws -> [(String, Value)] {
        var i = data.startIndex
        func byte() throws -> UInt8 { guard i < data.endIndex else { throw Failure.unreadable }; defer { i += 1 }; return data[i] }
        func cString() throws -> String {
            guard let end = data[i...].firstIndex(of: 0) else { throw Failure.unreadable }
            let s = String(decoding: data[i..<end], as: UTF8.self)
            i = end + 1
            return s
        }
        func bytes(_ n: Int) throws -> Data {
            guard i + n <= data.endIndex else { throw Failure.unreadable }
            defer { i += n }
            return data[i..<i + n]
        }
        func map() throws -> [(String, Value)] {
            var out: [(String, Value)] = []
            while true {
                let type = try byte()
                if type == 0x08 { return out }
                let key = try cString()
                switch type {
                case 0x00: out.append((key, .map(try map())))
                case 0x01: out.append((key, .string(try cString())))
                case 0x02: out.append((key, .int(try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })))
                case 0x03: out.append((key, .float(try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) })))
                case 0x07: out.append((key, .uint64(try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })))
                default: throw Failure.unreadable
                }
            }
        }
        let top = try map()
        return top
    }

    static func encode(_ entries: [(String, Value)]) -> Data {
        var d = Data()
        func cString(_ s: String) { d.append(contentsOf: Array(s.utf8)); d.append(0) }
        func map(_ entries: [(String, Value)]) {
            for (key, value) in entries {
                switch value {
                case .map(let inner): d.append(0x00); cString(key); map(inner)
                case .string(let s): d.append(0x01); cString(key); cString(s)
                case .int(let v): d.append(0x02); cString(key); withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
                case .float(let v): d.append(0x03); cString(key); withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
                case .uint64(let v): d.append(0x07); cString(key); withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
                }
            }
            d.append(0x08)
        }
        map(entries)
        return d
    }

    // MARK: Steam's ids for a shortcut

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    /// The id Steam gives a shortcut — its grid art is named by it.
    static func appID(exe: String, name: String) -> UInt32 { crc32(Array((exe + name).utf8)) | 0x8000_0000 }
    /// What steam://rungameid/ takes to start it.
    static func gameID(appID: UInt32) -> UInt64 { (UInt64(appID) << 32) | 0x0200_0000 }

    // MARK: Where things are

    /// The game's anvil:// link — QuickLaunch.url's, built here off the main actor.
    static func link(for game: Game) -> String { "anvil://play/\(game.id.uuidString)" }

    static let browserExe = #""C:\windows\system32\winebrowser.exe""#
    static let browserDir = #""C:\windows\system32\""#

    /// The signed-in account's config folder: the one whose localconfig.vdf changed last.
    static func configDir(in c: Container) -> URL? {
        let root = SteamSupport.steamDir(in: c).appendingPathComponent("userdata", isDirectory: true)
        let fm = FileManager.default
        let accounts = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { Int($0) != nil && $0 != "0" }
        func changed(_ a: String) -> Date {
            (try? root.appendingPathComponent("\(a)/config/localconfig.vdf").resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        guard let account = accounts.max(by: { changed($0) < changed($1) }) else { return nil }
        return root.appendingPathComponent("\(account)/config", isDirectory: true)
    }

    // MARK: Adding

    /// The shortcut for `game`, as Steam lists it.
    static func entry(for game: Game) -> (appID: UInt32, fields: [(String, Value)]) {
        let id = appID(exe: browserExe, name: game.title)
        let fields: [(String, Value)] = [
            ("appid", .int(Int32(bitPattern: id))),
            ("AppName", .string(game.title)),
            ("Exe", .string(browserExe)),
            ("StartDir", .string(browserDir)),
            ("icon", .string("")),
            ("ShortcutPath", .string("")),
            ("LaunchOptions", .string(link(for: game))),
            ("IsHidden", .int(0)),
            ("AllowDesktopConfig", .int(1)),
            // Steam's overlay would go into winebrowser, which is gone a moment later; the
            // game itself is Anvil's, in its own container.
            ("AllowOverlay", .int(0)),
            ("OpenVR", .int(0)),
            ("Devkit", .int(0)),
            ("DevkitGameID", .string("")),
            ("DevkitOverrideAppID", .int(0)),
            ("LastPlayTime", .int(0)),
            ("FlatpakAppID", .string("")),
            ("tags", .map([("0", .string("Anvil"))])),
        ]
        return (id, fields)
    }

    /// `shortcuts.vdf` with `game` in it: an entry already starting this game is replaced,
    /// every other one kept as it was.
    static func adding(_ game: Game, to existing: Data?) throws -> (data: Data, appID: UInt32) {
        var list: [(String, Value)] = []
        if let existing, !existing.isEmpty {
            let top = try parse(existing)
            guard let shortcuts = top.first(where: { $0.0.caseInsensitiveCompare("shortcuts") == .orderedSame }),
                  case .map(let entries) = shortcuts.1 else { throw Failure.unreadable }
            list = entries
        }
        let link = link(for: game)
        let mine = entry(for: game)
        var kept = list.map(\.1).filter { $0["LaunchOptions"]?.text != link }
        kept.append(.map(mine.fields))
        let numbered = kept.enumerated().map { (String($0.offset), $0.element) }
        return (encode([("shortcuts", .map(numbered))]), mine.appID)
    }

    /// `shortcuts.vdf` without `game`: every entry starting it taken out, every other one kept
    /// as it was and numbered from 0 again. Also the ids of the entries taken out, whose grid art
    /// goes with them.
    static func removing(_ game: Game, from existing: Data) throws -> (data: Data, appIDs: [UInt32]) {
        let top = try parse(existing)
        guard let shortcuts = top.first(where: { $0.0.caseInsensitiveCompare("shortcuts") == .orderedSame }),
              case .map(let entries) = shortcuts.1 else { throw Failure.unreadable }
        let link = link(for: game)
        let (gone, kept) = (entries.map(\.1).filter { $0["LaunchOptions"]?.text == link },
                            entries.map(\.1).filter { $0["LaunchOptions"]?.text != link })
        let ids = gone.compactMap { entry -> UInt32? in
            if case .int(let v)? = entry["appid"] { return UInt32(bitPattern: v) }
            return nil
        }
        let numbered = kept.enumerated().map { (String($0.offset), $0.element) }
        return (encode([("shortcuts", .map(numbered))]), ids)
    }

    /// The Anvil games in Steam's list, by their id in Anvil.
    static func listed(in c: Container) -> Set<UUID> {
        guard let dir = configDir(in: c), let data = try? Data(contentsOf: dir.appendingPathComponent("shortcuts.vdf")),
              let top = try? parse(data), case .map(let entries)? = top.first?.1 else { return [] }
        let prefix = "anvil://play/"
        return Set(entries.compactMap { entry -> UUID? in
            guard let link = entry.1["LaunchOptions"]?.text, link.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(link.dropFirst(prefix.count)))
        })
    }

    /// Whether `game` is in Steam's list already.
    static func contains(_ game: Game, in c: Container) -> Bool {
        listed(in: c).contains(game.id)
    }

    /// Writes the shortcut and its grid art. Steam must be closed (it reads the file as it
    /// starts, and keeps its own copy until then).
    @discardableResult
    static func write(_ game: Game, in c: Container, cover: NSImage?) throws -> UInt32 {
        guard SteamSupport.isInstalled(in: c) else { throw Failure.noSteam }
        guard let dir = configDir(in: c) else { throw Failure.noAccount }
        let file = dir.appendingPathComponent("shortcuts.vdf")
        let existing = try? Data(contentsOf: file)
        let (data, id) = try adding(game, to: existing)
        if let existing, !existing.isEmpty {
            try? existing.write(to: dir.appendingPathComponent("shortcuts.vdf.anvil-before"))
        }
        try data.write(to: file)
        if let cover { writeGrid(cover, appID: id, in: dir) }
        return id
    }

    /// Takes the game's shortcut and its grid art out of Steam's list. Steam must be closed.
    /// The player's own shortcuts are left as they are. True when there was one to take out.
    @discardableResult
    static func unwrite(_ game: Game, in c: Container) throws -> Bool {
        guard let dir = configDir(in: c) else { throw Failure.noAccount }
        let file = dir.appendingPathComponent("shortcuts.vdf")
        guard let existing = try? Data(contentsOf: file), !existing.isEmpty else { return false }
        let (data, ids) = try removing(game, from: existing)
        guard !ids.isEmpty || data != existing else { return false }
        try? existing.write(to: dir.appendingPathComponent("shortcuts.vdf.anvil-before"))
        try data.write(to: file)
        let grid = dir.appendingPathComponent("grid", isDirectory: true)
        for id in ids {
            for suffix in ["p", "", "_hero"] {
                try? FileManager.default.removeItem(at: grid.appendingPathComponent("\(id)\(suffix).png"))
            }
        }
        return true
    }

    // MARK: Grid art

    /// Steam's three library images, cut from the game's cover: portrait 600 × 900, header
    /// 920 × 430 and hero 1920 × 620.
    static func writeGrid(_ cover: NSImage, appID: UInt32, in configDir: URL) {
        let grid = configDir.appendingPathComponent("grid", isDirectory: true)
        try? FileManager.default.createDirectory(at: grid, withIntermediateDirectories: true)
        for (suffix, size) in [("p", NSSize(width: 600, height: 900)), ("", NSSize(width: 920, height: 430)),
                               ("_hero", NSSize(width: 1920, height: 620))] {
            if let png = filled(cover, to: size) {
                try? png.write(to: grid.appendingPathComponent("\(appID)\(suffix).png"))
            }
        }
    }

    /// The cover scaled to fill `size`, centred and cropped, as PNG.
    static func filled(_ image: NSImage, to size: NSSize) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = max(size.width / w, size.height / h)
        let drawn = CGSize(width: w * scale, height: h * scale)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                width: drawn.width, height: drawn.height))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

// MARK: Adding and taking out, with Steam closed

extension SteamShortcuts {
    /// Puts `game` in Steam's library — only ever when the player asks, from Settings or the
    /// game's page. Steam open on its own is closed with its own `-shutdown` first and opened
    /// again after; Steam beside a running game is left alone.
    @MainActor
    static func add(_ game: Game) async throws -> UInt32 {
        try await change(adding: [game], removing: []).first ?? 0
    }

    /// Takes `game` out of Steam's library, the same way.
    @MainActor
    static func remove(_ game: Game) async throws {
        _ = try await change(adding: [], removing: [game])
    }

    /// Any number in and out, with Steam closed once. The ids of the games put in.
    @MainActor
    static func change(adding: [Game], removing: [Game]) async throws -> [UInt32] {
        let steam = SteamSupport.shared
        guard let c = steam.container else { throw Failure.noSteam }
        guard !adding.isEmpty || !removing.isEmpty else { return [] }
        let client = steam.clientGame(in: c)
        var reopen = false
        if steam.clientRunning(in: c) {
            guard let client, let session = Launcher.shared.session(for: client) else { throw Failure.steamBusy }
            reopen = true
            AnvilLog.write("steam: closing Steam to change its library")
            let wine = session.baseRuntime.wine64, exe = SteamSupport.steamExe(in: c).path
            let env = Launcher.storeClientEnvironment(session.helperEnvironment)
            _ = await Task.detached { Launcher.runHelper(wine, [exe, "-shutdown"], environment: env, timeout: 20) }.value
            for _ in 0..<40 where Launcher.shared.session(for: client) != nil { try? await Task.sleep(for: .milliseconds(500)) }
            if Launcher.shared.session(for: client) != nil {
                Launcher.shared.quit(client)
                for _ in 0..<40 where Launcher.shared.session(for: client) != nil { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        // Steam opens again whatever happens below.
        defer {
            if reopen, let client {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    QuickLaunch.play(client)
                }
            }
        }
        for game in removing {
            if try unwrite(game, in: c) { AnvilLog.write("steam: \(game.title) taken out of Steam's library") }
        }
        var ids: [UInt32] = []
        for game in adding {
            let id = try write(game, in: c, cover: ArtworkStore.shared.image(for: game))
            ids.append(id)
            AnvilLog.write("steam: \(game.title) added to Steam's library (shortcut \(id), game id \(gameID(appID: id))) — Steam's Play starts it through Anvil")
        }
        return ids
    }

    /// The games that can go in Steam's library: everything in Anvil's but Steam's own games and
    /// the store apps.
    @MainActor
    static func candidates(in library: [Game]) -> [Game] {
        library.filter { $0.steamAppID == nil && StoreArt.store(of: $0) == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
