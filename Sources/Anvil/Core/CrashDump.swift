import Foundation

/// A Windows game's own crash record — the minidump its crash handler writes (LEGO Star Wars' into
/// CRASHDATA beside its settings) — read for where it crashed: the exception, the module the faulting
/// instruction is in, and the modules return addresses on the crashed thread's stack point into.
///
/// On 17 October LEGO Star Wars closed 2 seconds after the Mac woke from 27 minutes asleep with it in
/// the background, and Autopilot, seeing FSR 3 on, switched FSR 3 off for it — and with it Smooth
/// Motion, made from FSR 3's pictures, for the next two hours of play. Its minidump said otherwise: an
/// access violation in the game's own code with Epic Online Services (EOSSDK) all over its stack and
/// no graphics code anywhere — its online code, with the network still off from the sleep.
enum CrashDump {
    struct Report: Equatable {
        var code: UInt32
        var faultModule: String?
        /// Modules of the return addresses on the crashed thread's stack, nearest first, each once.
        var stackModules: [String]
    }

    /// Graphics: Direct3D, DXGI, the Mac's window driver and Wine's other graphics paths, the shader compiler.
    static let graphicsModules = ["d3d11.dll", "d3d12.dll", "d3d12core.dll", "dxgi.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll",
                                  "d3d10core.dll", "winemac.drv", "opengl32.dll", "vulkan-1.dll", "nvapi64.dll",
                                  "amd_ags_x64.dll", "d3dcompiler_47.dll", "dxvk", "libanvil"]
    /// Online services a game links in, as their DLLs are named, and as said.
    static let onlineServices: [(String, String)] = [("eossdk", "Epic Online Services"), ("steam_api", "Steam's API"),
                                                      ("galaxy", "GOG Galaxy"), ("eosovh", "Epic Online Services")]

    // MARK: Reading

    static func read(_ data: Data) -> Report? {
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian
        }
        func u64(_ o: Int) -> UInt64? {
            guard o >= 0, o + 8 <= data.count else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }.littleEndian
        }
        guard data.count > 32, data.prefix(4) == Data("MDMP".utf8), let count = u32(8), let dir = u32(12), count < 4096 else { return nil }
        var streams: [UInt32: (size: Int, rva: Int)] = [:]
        for i in 0..<Int(count) {
            guard let type = u32(Int(dir) + i * 12), let size = u32(Int(dir) + i * 12 + 4), let rva = u32(Int(dir) + i * 12 + 8) else { return nil }
            if streams[type] == nil { streams[type] = (Int(size), Int(rva)) }
        }
        // Modules (stream 4): base, size, name (a UTF-16 string at its own RVA).
        var modules: [(base: UInt64, size: UInt64, name: String)] = []
        if let list = streams[4], let n = u32(list.rva), n < 4096 {
            for i in 0..<Int(n) {
                let o = list.rva + 4 + i * 108
                guard let base = u64(o), let size = u32(o + 8), let nameRVA = u32(o + 20), let len = u32(Int(nameRVA)),
                      Int(nameRVA) + 4 + Int(len) <= data.count, len < 2048 else { continue }
                let bytes = data.subdata(in: Int(nameRVA) + 4 ..< Int(nameRVA) + 4 + Int(len))
                let path = String(data: bytes, encoding: .utf16LittleEndian) ?? ""
                let name = path.split(separator: "\\").last.map(String.init) ?? path
                modules.append((base, UInt64(size), name))
            }
        }
        func module(at address: UInt64) -> String? {
            modules.first { address >= $0.base && address < $0.base &+ $0.size }?.name
        }
        // The exception (stream 6): its code and address, and the crashed thread's context (rsp for its stack).
        guard let ex = streams[6], let code = u32(ex.rva + 8), let address = u64(ex.rva + 8 + 16) else { return nil }
        var stack: [String] = []
        if let ctxSize = u32(ex.rva + 8 + 152), ctxSize >= 0x100, let ctxRVA = u32(ex.rva + 8 + 156),
           let rsp = u64(Int(ctxRVA) + 0x98), let memory = streams[5], let n = u32(memory.rva), n < 4_000_000 {
            for i in 0..<Int(n) {
                let o = memory.rva + 4 + i * 16
                guard let start = u64(o), let size = u32(o + 8), let rva = u32(o + 12),
                      rsp >= start, rsp < start &+ UInt64(size) else { continue }
                let from = Int(rva) + Int(rsp - start), to = min(Int(rva) + Int(size), from + 0x8000)
                var at = from
                while at + 8 <= to {
                    if let value = u64(at), let name = module(at: value), !stack.contains(name) { stack.append(name) }
                    at += 8
                }
                break
            }
        }
        return Report(code: code, faultModule: module(at: address), stackModules: stack)
    }

    /// What it says about graphics, in words, when it rules them out; nil when graphics could be in it.
    static func notGraphics(_ r: Report) -> String? {
        func isGraphics(_ name: String) -> Bool { graphicsModules.contains { name.lowercased().contains($0) } }
        if let f = r.faultModule, isGraphics(f) { return nil }
        guard r.faultModule != nil, !r.stackModules.prefix(24).contains(where: isGraphics),
              let service = onlineServices.first(where: { s in r.stackModules.contains { $0.lowercased().contains(s.0) } })?.1
        else { return nil }
        let what = r.code == 0xC000_0005 ? "an access violation" : String(format: "exception 0x%08X", r.code)
        return "\(what) in \(r.faultModule ?? "its own code") with \(service) under it on its stack and no graphics code anywhere near — the game's online code, which FSR and frame generation never touch"
    }

    // MARK: Finding the session's

    /// Minidumps written into the prefix's Windows user folders between `from` and `to`, newest first.
    static func written(prefix: URL, from: Date, to: Date) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: users, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Date)] = []
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > 60_000 { break }
            if walk.level > 9 { walk.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "dmp",
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= from.addingTimeInterval(-5), date <= to.addingTimeInterval(60) else { continue }
            found.append((url, date))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// From a session's launch log: its prefix, when it started and when it exited, and how long the Mac slept in it.
    struct Session { var prefix: URL; var started: Date; var exited: Date; var asleep: Double; var lastInFront: Date? }

    static func session(launchLines: [Substring]) -> Session? {
        let iso = ISO8601DateFormatter()
        func time(_ line: Substring) -> Date? { line.split(separator: " ", maxSplits: 1).first.flatMap { iso.date(from: String($0)) } }
        guard let first = launchLines.first(where: { time($0) != nil }), let started = time(first),
              let prefixLine = launchLines.first(where: { $0.contains("env WINEPREFIX=") }),
              let r = prefixLine.range(of: "env WINEPREFIX=") else { return nil }
        let prefix = URL(fileURLWithPath: String(prefixLine[r.upperBound...]).trimmingCharacters(in: .whitespaces), isDirectory: true)
        let exitLine = launchLines.last { $0.contains("  exited: ") }
        let exited = exitLine.flatMap(time) ?? launchLines.compactMap(time).last ?? started
        var asleep = 0.0
        // "exited: … code=5 after 3612.0s, 1899 s of it awake"
        if let line = exitLine, let m = line.range(of: #"after ([0-9.]+)s, ([0-9.]+) s of it awake"#, options: .regularExpression) {
            let parts = line[m].split(separator: " ")
            if parts.count >= 3, let total = Double(parts[1].dropLast(2)), let awake = Double(parts[2]) { asleep = max(0, total - awake) }
        }
        // When the game last came back to the front.
        let back = launchLines.last { $0.contains("  focus: ") && $0.contains(" came to the front (as dev.anvil.game") }.flatMap(time)
        return Session(prefix: prefix, started: started, exited: exited, asleep: asleep, lastInFront: back)
    }

    /// Why the session's game closed, from its own crash record, when that rules graphics out.
    static func cause(launchLines: [Substring]) -> String? {
        guard let s = session(launchLines: launchLines) else { return nil }
        for url in written(prefix: s.prefix, from: s.started, to: s.exited).prefix(3) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let report = read(data),
                  let words = notGraphics(report) else { continue }
            var text = "its own crash record says \(words)"
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? s.exited
            if s.asleep >= 60, let back = s.lastInFront, case let after = at.timeIntervalSince(back), after >= 0, after <= 90 {
                text += String(format: " — %.0f s after the Mac woke from %.0f minutes asleep with it in the background", after, s.asleep / 60)
            }
            return text
        }
        return nil
    }
}
