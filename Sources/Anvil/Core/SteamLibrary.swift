import AppKit
import Foundation

/// The games a Steam account has, for the Stores page — listed like Epic's, each to install or
/// play — read from what Steam itself keeps on disk, with nothing asked of Steam's servers and
/// no sign-in of Anvil's own:
/// - appcache/librarycache: a folder (or, on older clients, files) for every app Steam's
///   library shows, holding the art it shows with;
/// - appcache/packageinfo.vdf: the packages the account's licences cover, and their apps;
/// - appcache/appinfo.vdf: every app's name and kind, so Steam's tools, SDKs, servers and
///   demos are left out.
/// Installing is Steam's own: `steam://install/<app>` opens its install window, and Steam
/// downloads and keeps the game up to date as it always does.
enum SteamLibrary {
    struct Title: Identifiable, Hashable, Sendable {
        var id: String { appID }
        var appID: String
        var name: String
        /// Steam's own portrait art for it, on this Mac; nil when it hasn't downloaded one.
        var localCover: URL?
        /// The same from Steam's public image server.
        var remoteCover: URL { URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appID)/library_600x900.jpg")! }
    }

    /// The account's games, sorted by name. Empty when Steam hasn't been signed in to there.
    nonisolated static func owned(in steamDir: URL) -> [Title] {
        let cache = steamDir.appendingPathComponent("appcache", isDirectory: true)
        var candidates = libraryCacheApps(in: cache.appendingPathComponent("librarycache", isDirectory: true))
        if let packages = try? Data(contentsOf: cache.appendingPathComponent("packageinfo.vdf")) {
            // Package 0 is the one every account has — Steam's own tools and the free games anyone
            // can add — so only apps from it that Steam's library already shows count.
            for (package, apps) in packageApps(packages) where package != 0 { candidates.formUnion(apps) }
        }
        guard !candidates.isEmpty, let info = try? Data(contentsOf: cache.appendingPathComponent("appinfo.vdf")) else { return [] }
        let kinds = appKinds(info, only: candidates)
        let librarycache = cache.appendingPathComponent("librarycache", isDirectory: true)
        return kinds.compactMap { appID, entry -> Title? in
            guard entry.type.lowercased() == "game", !entry.name.isEmpty,
                  !SteamSupport.notGames.contains(String(appID)) else { return nil }
            return Title(appID: String(appID), name: entry.name, localCover: cover(appID: String(appID), in: librarycache))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Apps with art in Steam's library cache: a folder per app, or "<app>_library_600x900.jpg"
    /// files on older clients.
    nonisolated static func libraryCacheApps(in librarycache: URL) -> Set<UInt32> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: librarycache.path)) ?? []
        return Set(names.compactMap { name in UInt32(name.prefix { $0.isNumber }) })
    }

    /// Steam's portrait art for an app: library_600x900 or, on newer clients, library_capsule —
    /// in the app's folder, one level down, or flat beside it.
    nonisolated static func cover(appID: String, in librarycache: URL) -> URL? {
        let fm = FileManager.default
        let flat = librarycache.appendingPathComponent("\(appID)_library_600x900.jpg")
        if fm.fileExists(atPath: flat.path) { return flat }
        let folder = librarycache.appendingPathComponent(appID, isDirectory: true)
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        var capsule: URL?
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix("library_600x900") { return url }
            if name.hasPrefix("library_capsule"), capsule == nil { capsule = url }
        }
        return capsule
    }

    // MARK: Valve's binary files

    /// Valve's binary key-values, as appinfo.vdf and packageinfo.vdf hold them: keys as text, or
    /// (appinfo.vdf from 2024, "v29") as numbers into a table of strings at the file's end.
    struct Reader {
        let data: Data
        var at: Int
        let strings: [String]?

        mutating func u8() -> UInt8? { guard at < data.count else { return nil }; defer { at += 1 }; return data[data.startIndex + at] }
        mutating func u32() -> UInt32? {
            guard at + 4 <= data.count else { return nil }
            defer { at += 4 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        }
        mutating func u64() -> UInt64? {
            guard at + 8 <= data.count else { return nil }
            defer { at += 8 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
        }
        mutating func cString() -> String? {
            let start = data.startIndex + at
            guard let end = data[start...].firstIndex(of: 0) else { return nil }
            at = end - data.startIndex + 1
            return String(decoding: data[start..<end], as: UTF8.self)
        }
        mutating func key() -> String? {
            if let strings { return u32().flatMap { Int($0) < strings.count ? strings[Int($0)] : nil } }
            return cString()
        }

        /// One map, up to its end marker. Only text values and maps are kept.
        mutating func map(depth: Int = 0) -> [String: Any]? {
            guard depth < 32 else { return nil }
            var out: [String: Any] = [:]
            while true {
                guard let type = u8() else { return nil }
                if type == 8 { return out }
                guard let key = key() else { return nil }
                switch type {
                case 0: guard let inner = map(depth: depth + 1) else { return nil }; out[key] = inner
                case 1: guard let s = cString() else { return nil }; out[key] = s
                case 2, 3, 4, 6: guard let v = u32() else { return nil }; out[key] = Int(Int32(bitPattern: v))
                case 7, 10: guard let v = u64() else { return nil }; out[key] = v
                default: return nil
                }
            }
        }
    }

    /// appinfo.vdf: the name and kind of each app in `only`, skipping the rest by their sizes.
    nonisolated static func appKinds(_ data: Data, only: Set<UInt32>) -> [UInt32: (name: String, type: String)] {
        apps(data, only: only).mapValues { app in
            let common = app["common"] as? [String: Any]
            return ((common?["name"] as? String) ?? "", (common?["type"] as? String) ?? "")
        }
    }

    /// appinfo.vdf: each app in `only` as Steam keeps it ("common", "depots", …).
    nonisolated static func apps(_ data: Data, only: Set<UInt32>) -> [UInt32: [String: Any]] {
        var r = Reader(data: data, at: 0, strings: nil)
        guard let magic = r.u32(), let _ = r.u32() else { return [:] }
        let version = magic & 0xFF
        guard magic >> 8 == 0x075644, (0x27...0x29).contains(version) else { return [:] }
        var strings: [String]?
        if version >= 0x29 {
            guard let offset = r.u64(), Int(offset) < data.count else { return [:] }
            var t = Reader(data: data, at: Int(offset), strings: nil)
            guard let count = t.u32() else { return [:] }
            var table: [String] = []
            table.reserveCapacity(Int(count))
            for _ in 0..<count { guard let s = t.cString() else { return [:] }; table.append(s) }
            strings = table
        }
        // After the app's id and size: state, last updated, token, SHA-1, change number, and from
        // v28 the binary SHA-1.
        let fixed = 4 + 4 + 8 + 20 + 4 + (version >= 0x28 ? 20 : 0)
        var out: [UInt32: [String: Any]] = [:]
        while let appID = r.u32(), appID != 0 {
            guard let size = r.u32() else { break }
            let end = r.at + Int(size)
            guard end <= data.count else { break }
            if only.contains(appID) {
                var entry = Reader(data: data, at: r.at + fixed, strings: strings)
                if let app = entry.map()?["appinfo"] as? [String: Any] { out[appID] = app }
            }
            r.at = end
        }
        return out
    }

    // MARK: DLC

    struct DLC: Identifiable, Hashable, Sendable {
        var id: String { appID }
        var appID: String
        var name: String
        /// With files of its own (a depot of the game's): Steam downloads them with the game. Without, it's unlocked by
        /// owning it alone.
        var hasFiles: Bool
        /// Its files are in the game's installed copy (the game's manifest lists its depot), or it has none to install.
        var installed: Bool
    }

    /// The DLC of a game the account owns, from the same files as its games: apps of the kind "DLC" whose parent is the
    /// game, among those its licences cover. Steam downloads owned DLC with the game and keeps it up to date itself.
    nonisolated static func dlc(of appID: String, in c: Container) -> [DLC] {
        guard let game = UInt32(appID) else { return [] }
        let cache = SteamSupport.steamDir(in: c).appendingPathComponent("appcache", isDirectory: true)
        guard let packages = try? Data(contentsOf: cache.appendingPathComponent("packageinfo.vdf")),
              let info = try? Data(contentsOf: cache.appendingPathComponent("appinfo.vdf")) else { return [] }
        var candidates = Set<UInt32>()
        for (package, apps) in packageApps(packages) where package != 0 { candidates.formUnion(apps) }
        candidates.insert(game)
        let found = apps(info, only: candidates)
        // The game's depots that belong to a DLC: "depots" › <id> › "dlcappid".
        var withFiles = Set<String>()
        for case let depot as [String: Any] in ((found[game]?["depots"] as? [String: Any]) ?? [:]).values {
            if let dlc = depot["dlcappid"] { withFiles.insert("\(dlc)") }
        }
        let installed = installedDLC(of: appID, in: c)
        return found.compactMap { id, app -> DLC? in
            guard id != game, let common = app["common"] as? [String: Any],
                  (common["type"] as? String)?.lowercased() == "dlc", "\(common["parent"] ?? "")" == appID else { return nil }
            let has = withFiles.contains(String(id))
            return DLC(appID: String(id), name: (common["name"] as? String) ?? "DLC \(id)", hasFiles: has,
                       installed: !has || installed.contains(String(id)))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The DLC whose files are in the game's installed copy: its appmanifest's "InstalledDepots" › <depot> › "dlcappid".
    nonisolated static func installedDLC(of appID: String, in c: Container) -> Set<String> {
        for folder in SteamSupport.libraryFolders(in: c) {
            guard let text = try? String(contentsOf: folder.appendingPathComponent("appmanifest_\(appID).acf"), encoding: .utf8),
                  let state = SteamSupport.parseVDF(text)["appstate"] as? [String: Any] else { continue }
            let depots = (state["installeddepots"] as? [String: Any]) ?? [:]
            return Set(depots.values.compactMap { ($0 as? [String: Any])?["dlcappid"] as? String })
        }
        return []
    }

    /// packageinfo.vdf: each package's apps.
    nonisolated static func packageApps(_ data: Data) -> [UInt32: Set<UInt32>] {
        var r = Reader(data: data, at: 0, strings: nil)
        guard let magic = r.u32(), let _ = r.u32(), magic >> 8 == 0x065655 else { return [:] }
        let version = magic & 0xFF
        var out: [UInt32: Set<UInt32>] = [:]
        while let package = r.u32(), package != 0xFFFF_FFFF {
            r.at += 20 + 4 + (version >= 0x28 ? 8 : 0)
            guard let root = r.map() else { break }
            let body = (root.values.first as? [String: Any]) ?? root
            let apps = (body["appids"] as? [String: Any])?.values.compactMap { ($0 as? Int).map { UInt32(truncatingIfNeeded: $0) } } ?? []
            out[package] = Set(apps)
        }
        return out
    }
}

// MARK: Installing, through Steam's own window

extension SteamSupport {
    /// Hands Steam a steam:// link — `steam://install/<app>` opens its install window. Steam
    /// already open gets it at once; otherwise Steam opens with it (see Launcher).
    func openInSteam(_ link: String, in c: Container) async throws {
        if let client = clientGame(in: c), let session = Launcher.shared.session(for: client) {
            let wine = session.baseRuntime.wine64, exe = Self.steamExe(in: c).path
            let env = Launcher.storeClientEnvironment(session.helperEnvironment)
            AnvilLog.write("steam: \(link) handed to Steam")
            _ = await Task.detached { Launcher.runHelper(wine, [exe, link], environment: env, timeout: 30) }.value
            return
        }
        let client = ensureClientEntry(in: c)
        guard let runtime = RuntimeManager.shared.runtime(id: c.runtimeID) else { throw SteamError.noEngine }
        nextLink = link
        AnvilLog.write("steam: opening Steam with \(link)")
        _ = try await Launcher.shared.prepareAndLaunch(game: client, container: c, runtime: runtime)
    }

    /// Install a game of the account's: Steam's own install window, where its folder and size
    /// are chosen as in Steam on Windows.
    func install(_ title: SteamLibrary.Title, in c: Container) async throws {
        try await openInSteam("steam://install/\(title.appID)", in: c)
    }
}
