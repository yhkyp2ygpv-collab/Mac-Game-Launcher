import Foundation
import CoreServices

/// Game Mode for games Wine runs.
///
/// macOS turns Game Mode on for the frontmost full-screen app when that app says it is
/// a game — `LSApplicationCategoryType` of `public.app-category.games` in its
/// Info.plist. Game Mode gives it first call on the CPU and GPU, holds back background
/// work, and doubles the polling rate of Bluetooth controllers. The process a Windows
/// game runs in is Wine's own launcher, and in both engines on this Mac (Whisky 2.5 and
/// Mythic Engine 2.6) its Info.plist — embedded in the binary, inherited from CrossOver —
/// has no category at all. So no game run through them has ever had Game Mode.
///
/// Anvil does not edit either engine. It keeps its own copy: an APFS clone of the engine
/// (copy-on-write, so it costs no disk beyond the one file that changes), with the
/// launcher's embedded Info.plist rewritten to add the category and nothing else. The
/// embedded list sits in a fixed-size section of the binary; the rewrite is compacted
/// and padded to exactly that size, and parsed back before it is used. Anything that
/// does not go exactly to plan leaves the original engine in use.
enum GameModeEngine {
    static var storeDir: URL {
        RuntimeManager.support.appendingPathComponent("GameModeEngines", isDirectory: true)
    }

    /// For an engine that is one of Anvil's Game Mode copies: the path of the app's own
    /// program (Contents/MacOS/<CFBundleExecutable>), which macOS takes as the process's
    /// when CFProcessPath names it. Nil for any other engine.
    static func processPath(for runtime: Runtime) -> URL? {
        let contents = runtime.root.standardizedFileURL
        guard contents.path.hasPrefix(storeDir.standardizedFileURL.path + "/"),
              contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty else { return nil }
        let path = contents.appendingPathComponent("MacOS").appendingPathComponent(exe)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Binaries that can become the game's process, depending on the engine.
    private static let launchers = ["bin/wine64-preloader", "bin/wine-preloader", "bin/wine64", "bin/wine"]

    enum Failure: LocalizedError {
        case noLauncher, cloneFailed, noPlistSection(String), plistTooLarge(Int, Int), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noLauncher: "the engine has no Wine launcher binary"
            case .cloneFailed: "the engine could not be copied"
            case .noPlistSection(let f): "\(f) has no embedded Info.plist"
            case .plistTooLarge(let need, let have): "the rewritten Info.plist needs \(need) bytes and the binary has room for \(have)"
            case .unreadable(let f): "\(f) could not be read"
            }
        }
    }

    /// A copy of `runtime` whose game process declares itself a game. Throws when one
    /// cannot be made; the caller then launches with the original.
    static func prepared(for runtime: Runtime) throws -> Runtime {
        let fm = FileManager.default
        let sources = launchers.map { runtime.root.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard let firstLauncher = sources.first else { throw Failure.noLauncher }
        // The binary the game's own process runs as, which macOS must find named as the
        // bundle's executable to count the process as this app — and so as a game. Under
        // Wine 7.7 that is wine64-preloader. On Engine 3.0 (Wine 9) LEGO came to the front
        // as plain "wine", not as Anvil Game, with the copy naming the bash wrapper (0.19.1)
        // and then `wine` (0.19.2–0.21.0, with WINELOADER from 0.20.0) — no Game Mode either
        // way. Engine 3.0 has a preloader
        // of its own, bin/wine-preloader, and Wine starts it from beside the loader to run the
        // game in, exactly as Wine 7.7 starts wine64-preloader — the name that does work on
        // Engine 2.6.1. So the preloader is named when there is one, and `wine` only when not.
        let wine9 = !fm.fileExists(atPath: runtime.root.appendingPathComponent("bin/wine64-preloader").path)
            && Runtime.isMachOFile(runtime.root.appendingPathComponent("bin/wine"))
        let wine9Preloader = runtime.root.appendingPathComponent("bin/wine-preloader")
        let preloader = !wine9 ? firstLauncher
            : Runtime.isMachOFile(wine9Preloader) ? wine9Preloader : runtime.root.appendingPathComponent("bin/wine")

        let safeID = String(runtime.id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        let dest = storeDir.appendingPathComponent(safeID, isDirectory: true)
        // Wine lives inside an app bundle here, because macOS decides what an app is from
        // its bundle. Game Mode did not turn on with only the binary's own embedded
        // Info.plist rewritten (0.12.0, LEGO Star Wars): the launcher ran from a plain
        // bin/ folder, which is not an app as far as the system is concerned.
        // Contents/MacOS holds the engine's bin/, lib/ and share/ sit beside it where
        // Wine looks for them (bin/../lib), and bin is a link to MacOS so every path
        // Anvil builds from root keeps working. A program started through that link runs
        // from its real path, inside the bundle.
        let bundle = dest.appendingPathComponent("Anvil Game.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        // Beside the copy, not inside it: an engine can be installed read-only, and a
        // clone keeps its permissions.
        let stampURL = storeDir.appendingPathComponent(safeID + ".stamp")

        // Rebuilt whenever the engine it came from changes.
        let stamp = sources.map { url -> String in
            let a = try? fm.attributesOfItem(atPath: url.path)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
            let date = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(size)|\(date)"
        }.joined(separator: "\n") + "\nv4-bundle-\(preloader.lastPathComponent)"

        var copy = runtime
        copy.root = contents
        // The copy is sealed like an engine (see EngineSeal); one that changed is rebuilt.
        let sealID = "gamemode-" + safeID
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp {
            switch EngineSeal.check(root: dest, id: sealID, full: false) {
            case .intact, .resealed, .unverified:
                return copy
            case .notSealed:
                _ = try? EngineSeal.seal(root: dest, id: sealID)
                return copy
            case .changed(let files):
                AnvilLog.write("  Game Mode copy of \(runtime.displayName) differs from its seal (\(files.prefix(3).joined(separator: ", "))) — rebuilding it")
            }
        }

        removeCopy(dest)
        try? fm.removeItem(at: stampURL)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        do {
            let entries = try fm.contentsOfDirectory(atPath: runtime.root.path)
            for entry in entries where !entry.hasPrefix(".") {
                let target = contents.appendingPathComponent(entry == "bin" ? "MacOS" : entry)
                guard clone(runtime.root.appendingPathComponent(entry), to: target) else { throw Failure.cloneFailed }
            }
            try fm.createSymbolicLink(atPath: contents.appendingPathComponent("bin").path, withDestinationPath: "MacOS")

            // The bundle's own Info.plist: what the engine's launcher already declares,
            // plus that it is a game, under an identifier of its own so nothing macOS
            // has remembered about the engine's original identity applies to it.
            // The plist is read from the game's binary, or the first launcher that has one.
            let plistSource = [preloader, firstLauncher].first { url in
                (try? Data(contentsOf: url)).flatMap { infoPlistSection(in: $0) } != nil
            } ?? preloader
            guard let data = try? Data(contentsOf: plistSource),
                  let (offset, size) = infoPlistSection(in: data),
                  var info = (try? PropertyListSerialization.propertyList(
                      from: trimmedPlist(data.subdata(in: offset..<(offset + size))), format: nil)) as? [String: Any]
            else { throw Failure.noPlistSection(preloader.lastPathComponent) }
            info["CFBundleIdentifier"] = "dev.anvil.game." + safeID
            info["CFBundleName"] = "Anvil Game"
            info["CFBundleExecutable"] = preloader.lastPathComponent
            info["CFBundlePackageType"] = "APPL"
            info["LSApplicationCategoryType"] = "public.app-category.games"
            info["LSSupportsGameMode"] = true
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))

            // And the launchers' embedded copies, for anything that reads those instead.
            for rel in launchers {
                let file = contents.appendingPathComponent(rel.replacingOccurrences(of: "bin/", with: "MacOS/"))
                guard fm.fileExists(atPath: file.path),
                      (try? fm.destinationOfSymbolicLink(atPath: file.path)) == nil else { continue }
                try patch(file)
            }
            // Tell Launch Services about the bundle now rather than when it first runs.
            _ = LSRegisterURL(bundle as CFURL, true)
            try stamp.write(to: stampURL, atomically: false, encoding: .utf8)
            _ = try? EngineSeal.seal(root: dest, id: sealID)
        } catch {
            removeCopy(dest)
            throw error
        }
        return copy
    }

    private static func trimmedPlist(_ section: Data) -> Data {
        var trimmed = section
        while let last = trimmed.last, last == 0 || last == 0x0A || last == 0x20 || last == 0x09 { trimmed.removeLast() }
        return trimmed
    }

    /// A read-only engine clones into read-only folders, which removeItem cannot empty.
    private static func removeCopy(_ dest: URL) {
        guard FileManager.default.fileExists(atPath: dest.path) else { return }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+w", dest.path]
        chmod.standardOutput = FileHandle.nullDevice
        chmod.standardError = FileHandle.nullDevice
        try? chmod.run()
        chmod.waitUntilExit()
        try? FileManager.default.removeItem(at: dest)
    }

    private static func clone(_ from: URL, to: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", from.path, to.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: to.path)
    }

    /// Rewrite one binary's embedded Info.plist in place. Returns false for a binary
    /// with no such section (nothing to do), throws when a rewrite was attempted and
    /// could not be made safely.
    @discardableResult
    static func patch(_ file: URL) throws -> Bool {
        guard var data = try? Data(contentsOf: file) else { throw Failure.unreadable(file.lastPathComponent) }
        guard let (offset, size) = infoPlistSection(in: data) else { return false }
        let section = data.subdata(in: offset..<(offset + size))
        guard let replacement = try rewritten(section) else { return true }   // already a game
        data.replaceSubrange(offset..<(offset + size), with: replacement)

        // In place, so the file keeps its permissions — and on a clone only the
        // changed blocks stop being shared with the original. A read-only engine
        // clones to read-only files, so owner write is added for the edit and taken
        // away again after.
        let fm = FileManager.default
        let mode = ((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: file.path)
        defer { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: replacement)

        if hasCodeSignature(data) { resign(file) }
        return true
    }

    /// The section's new contents, exactly `section.count` bytes, or nil when the list
    /// already declares a category.
    static func rewritten(_ section: Data) throws -> Data? {
        // The section can carry trailing padding after the list.
        var trimmed = section
        while let last = trimmed.last, last == 0 || last == 0x0A || last == 0x20 || last == 0x09 { trimmed.removeLast() }
        guard var plist = (try? PropertyListSerialization.propertyList(from: trimmed, format: nil)) as? [String: Any]
        else { throw Failure.unreadable("the embedded Info.plist") }
        if plist["LSApplicationCategoryType"] != nil { return nil }
        plist["LSApplicationCategoryType"] = "public.app-category.games"
        plist["LSSupportsGameMode"] = true

        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        guard var text = String(data: xml, encoding: .utf8) else { throw Failure.unreadable("the rewritten Info.plist") }
        // Whitespace between elements carries nothing in a property list.
        text = text.replacingOccurrences(of: #">\s+<"#, with: "><", options: .regularExpression)
        var bytes = Data(text.utf8)
        guard bytes.count <= section.count else { throw Failure.plistTooLarge(bytes.count, section.count) }
        // Pad inside the document, between the dictionary and the closing tag, where
        // whitespace is ignored — the section is read whole.
        if let close = bytes.range(of: Data("</plist>".utf8), options: .backwards) {
            bytes.insert(contentsOf: Data(repeating: 0x20, count: section.count - bytes.count), at: close.lowerBound)
        }
        guard bytes.count == section.count,
              let check = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any],
              check["LSApplicationCategoryType"] as? String == "public.app-category.games",
              check.count == plist.count
        else { throw Failure.unreadable("the rewritten Info.plist") }
        return bytes
    }

    /// File offset and size of __TEXT,__info_plist in a thin 64-bit Mach-O.
    static func infoPlistSection(in data: Data) -> (Int, Int)? {
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
        func name(_ o: Int) -> String {
            String(decoding: data[o..<(o + 16)].prefix { $0 != 0 }, as: UTF8.self)
        }
        guard data.count > 32, u32(0) == 0xFEEDFACF else { return nil }   // MH_MAGIC_64
        let ncmds = Int(u32(16))
        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= data.count else { return nil }
            let cmd = u32(cursor), cmdsize = Int(u32(cursor + 4))
            if cmd == 0x19, name(cursor + 8) == "__TEXT" {                   // LC_SEGMENT_64
                let nsects = Int(u32(cursor + 64))
                var s = cursor + 72
                for _ in 0..<nsects {
                    if name(s) == "__info_plist" {
                        let size = Int(u64(s + 40)), offset = Int(u32(s + 48))
                        guard size > 0, offset + size <= data.count else { return nil }
                        return (offset, size)
                    }
                    s += 80
                }
            }
            cursor += cmdsize
        }
        return nil
    }

    private static func hasCodeSignature(_ data: Data) -> Bool {
        guard data.count > 32 else { return false }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        var cursor = 32
        for _ in 0..<Int(u32(16)) {
            guard cursor + 8 <= data.count else { return false }
            if u32(cursor) == 0x1D { return true }                            // LC_CODE_SIGNATURE
            cursor += Int(u32(cursor + 4))
        }
        return false
    }

    /// A signed binary edited in place fails its own signature; sign the copy ad hoc.
    private static func resign(_ file: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
