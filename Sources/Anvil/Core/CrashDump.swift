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
        /// A C++ exception the game threw and nothing caught (code 0xE06D7363): the program that threw it, as Windows
        /// names it, and where in it the description of what was thrown is (`thrown`, read from the program).
        var thrower: String? = nil
        var throwInfoRVA: UInt32? = nil
        /// What was thrown, most derived first ("winrt::hresult_class_not_registered", "winrt::hresult_error"), and —
        /// for a Windows component that isn't there — the ones the program asks for that the Windows setup doesn't
        /// have. Filled in by `explain`, which reads the program and the setup.
        var thrownTypes: [String] = []
        var missingClasses: [String] = []
    }

    /// The code Microsoft's C++ compiler raises a `throw` with.
    static let cppException: UInt32 = 0xE06D_7363

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
        var modules: [(base: UInt64, size: UInt64, name: String, path: String)] = []
        if let list = streams[4], let n = u32(list.rva), n < 4096 {
            for i in 0..<Int(n) {
                let o = list.rva + 4 + i * 108
                guard let base = u64(o), let size = u32(o + 8), let nameRVA = u32(o + 20), let len = u32(Int(nameRVA)),
                      Int(nameRVA) + 4 + Int(len) <= data.count, len < 2048 else { continue }
                let bytes = data.subdata(in: Int(nameRVA) + 4 ..< Int(nameRVA) + 4 + Int(len))
                let path = String(data: bytes, encoding: .utf16LittleEndian) ?? ""
                let name = path.split(separator: "\\").last.map(String.init) ?? path
                modules.append((base, UInt64(size), name, path))
            }
        }
        func module(at address: UInt64) -> String? {
            modules.first { address >= $0.base && address < $0.base &+ $0.size }?.name
        }
        // The exception (stream 6): its code and address, and the crashed thread's context (rsp for its stack).
        guard let ex = streams[6], let code = u32(ex.rva + 8), let address = u64(ex.rva + 8 + 16) else { return nil }
        // A C++ throw: its parameters are the compiler's magic number, the object, its ThrowInfo and the image base
        // of the program that threw (x64), so the ThrowInfo is at that program's base plus an RVA.
        var thrower: String?
        var throwInfoRVA: UInt32?
        if code == cppException, let n = u32(ex.rva + 8 + 24), n >= 4,
           let magic = u64(ex.rva + 40), magic & ~0xF == 0x1993_0520,
           let info = u64(ex.rva + 40 + 16), let base = u64(ex.rva + 40 + 24), info > base, info - base < 0x8000_0000,
           let owner = modules.first(where: { $0.base == base }) {
            thrower = owner.path
            throwInfoRVA = UInt32(info - base)
        }
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
        return Report(code: code, faultModule: module(at: address), stackModules: stack, thrower: thrower, throwInfoRVA: throwInfoRVA)
    }

    // MARK: A C++ exception, read from the program that threw it

    /// What the program that threw says it threw, and — for a Windows component the setup doesn't have — which. Read
    /// from the program's file and the setup's registry (`prefix`).
    ///
    /// On 21 October Hogwarts Legacy closed at its pause menu after 16 minutes: an unhandled
    /// `winrt::hresult_class_not_registered`, thrown by the game when Windows had no
    /// Windows.UI.ViewManagement.Core.CoreInputView — the on-screen keyboard, which Wine 9 doesn't have. Autopilot,
    /// seeing no online code on its stack, took FSR's one pass from it.
    static func explain(_ report: Report, prefix: URL) -> Report {
        var r = report
        guard let windowsPath = r.thrower, let rva = r.throwInfoRVA, let file = unixPath(windowsPath, prefix: prefix),
              let pe = PEFile(file) else { return r }
        r.thrownTypes = pe.thrownTypes(throwInfoRVA: rva)
        if r.thrownTypes.contains("winrt::hresult_class_not_registered") {
            let registry = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
            r.missingClasses = pe.runtimeClasses().filter { !registry.contains("ActivatableClassId\\\\\($0)]") }
        }
        return r
    }

    /// A Windows path from the dump as a file on this Mac: Z: is the Mac's own disk, C: the setup's drive C.
    static func unixPath(_ windows: String, prefix: URL) -> URL? {
        let parts = windows.split(separator: "\\").map(String.init)
        guard let drive = parts.first?.lowercased(), drive.count == 2, drive.hasSuffix(":") else { return nil }
        let rest = parts.dropFirst().joined(separator: "/")
        switch drive {
        case "z:": return URL(fileURLWithPath: "/" + rest)
        case "c:": return prefix.appendingPathComponent("drive_c").appendingPathComponent(rest)
        default: return prefix.appendingPathComponent("dosdevices/\(drive)").resolvingSymlinksInPath().appendingPathComponent(rest)
        }
    }

    /// A Windows runtime class in words, for the ones a game is known to ask for.
    static func words(forClass name: String) -> String? {
        switch name {
        case "Windows.UI.ViewManagement.Core.CoreInputView", "Windows.UI.ViewManagement.InputPane": "Windows' on-screen keyboard"
        case "Windows.Media.SpeechSynthesis.SpeechSynthesizer": "Windows' text-to-speech"
        case _ where name.hasPrefix("Windows.Gaming.Input."): "Windows' game controller interface"
        case _ where name.hasPrefix("Windows.Gaming.XboxLive.") || name.hasPrefix("Microsoft.Xbox."): "Xbox Live"
        default: nil
        }
    }

    /// Just enough of a Windows program to read a C++ exception's type and the Windows runtime classes it names,
    /// without reading the whole file (Hogwarts Legacy's is 458 MB).
    struct PEFile {
        let handle: FileHandle
        let url: URL
        let sections: [(va: UInt32, size: UInt32, offset: UInt32)]

        init?(_ url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            self.handle = handle
            self.url = url
            func at(_ o: UInt64, _ n: Int) -> Data? {
                guard (try? handle.seek(toOffset: o)) != nil, let d = try? handle.read(upToCount: n), d.count == n else { return nil }
                return d
            }
            guard let dos = at(0, 64), dos.prefix(2) == Data("MZ".utf8) else { return nil }
            let peAt = UInt64(dos.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0x3C, as: UInt32.self) }.littleEndian)
            guard let head = at(peAt, 24), head.prefix(4) == Data([0x50, 0x45, 0, 0]) else { return nil }
            let count = Int(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }.littleEndian)
            let optional = UInt64(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt16.self) }.littleEndian)
            guard count > 0, count < 128, let table = at(peAt + 24 + optional, count * 40) else { return nil }
            sections = (0..<count).map { i in
                table.withUnsafeBytes { b in
                    (b.loadUnaligned(fromByteOffset: i * 40 + 12, as: UInt32.self).littleEndian,
                     b.loadUnaligned(fromByteOffset: i * 40 + 8, as: UInt32.self).littleEndian,
                     b.loadUnaligned(fromByteOffset: i * 40 + 20, as: UInt32.self).littleEndian)
                }
            }
        }

        private func read(rva: UInt32, _ n: Int) -> Data? {
            guard let s = sections.first(where: { rva >= $0.va && rva < $0.va &+ max($0.size, 1) }),
                  (try? handle.seek(toOffset: UInt64(s.offset) + UInt64(rva - s.va))) != nil,
                  let d = try? handle.read(upToCount: n), d.count == n else { return nil }
            return d
        }

        private func u32(rva: UInt32) -> UInt32? {
            read(rva: rva, 4).map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        }

        /// The types a ThrowInfo says can catch what was thrown — its own first — from their type descriptors'
        /// decorated names (".?AUhresult_class_not_registered@winrt@@" → "winrt::hresult_class_not_registered").
        func thrownTypes(throwInfoRVA: UInt32) -> [String] {
            guard let array = u32(rva: throwInfoRVA &+ 12), let n = u32(rva: array), n > 0, n < 32 else { return [] }
            return (0..<n).compactMap { i -> String? in
                guard let catchable = u32(rva: array &+ 4 &+ 4 * i), let descriptor = u32(rva: catchable &+ 4),
                      let raw = read(rva: descriptor &+ 16, 160) else { return nil }
                let name = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                return PEFile.undecorate(name)
            }
        }

        static func undecorate(_ name: String) -> String? {
            guard name.hasPrefix(".?A"), name.count > 4 else { return nil }
            let body = name.dropFirst(4).replacingOccurrences(of: "@@", with: "")
            return body.split(separator: "@").reversed().joined(separator: "::")
        }

        /// The Windows runtime classes the program names ("Windows.UI.ViewManagement.Core.CoreInputView"), from its
        /// UTF-16 strings.
        func runtimeClasses() -> [String] {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
            let needle = Array("Windows.".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            var found: [String] = []
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var at = 0
                while at < raw.count, found.count < 64,
                      let hit = needle.withUnsafeBytes({ memmem(base + at, raw.count - at, $0.baseAddress, needle.count) }) {
                    let start = base.distance(to: UnsafeRawPointer(hit))
                    var units: [UInt16] = []
                    var o = start
                    while o + 1 < raw.count, units.count < 160 {
                        let u = UInt16(raw[o]) | UInt16(raw[o + 1]) << 8
                        // Letters, digits, "." and "_" only.
                        guard (65...90).contains(u) || (97...122).contains(u) || (48...57).contains(u) || u == 46 || u == 95 else { break }
                        units.append(u)
                        o += 2
                    }
                    let name = String(decoding: units, as: UTF16.self)
                    // "Windows.X.Y" with a class at the end: a capital after its last dot.
                    if name.split(separator: ".").count >= 3, name.split(separator: ".").last?.first?.isUppercase == true,
                       !found.contains(name) { found.append(name) }
                    at = max(o, start + needle.count)
                }
            }
            return found
        }
    }

    /// What it says about graphics, in words, when it rules them out; nil when graphics could be in it.
    static func notGraphics(_ r: Report) -> String? {
        func isGraphics(_ name: String) -> Bool { graphicsModules.contains { name.lowercased().contains($0) } }
        // A Windows runtime component the game asked for and couldn't have, thrown as C++/WinRT does and caught by
        // nothing: what failed is Windows' own interface, named by the exception itself, not anything that draws.
        if r.code == cppException, let type = r.thrownTypes.first, type.hasPrefix("winrt::") {
            let program = r.thrower.flatMap { $0.split(separator: "\\").last.map(String.init) } ?? "the game"
            if type == "winrt::hresult_class_not_registered" {
                let named = r.missingClasses.map { name in words(forClass: name).map { "\(name) (\($0))" } ?? name }
                let which = named.isEmpty ? "a part of Windows" : named.joined(separator: " or ")
                return "\(program) asked Windows for \(which), which Wine doesn't have, and stopped on the error (\(type)) — not graphics code"
            }
            return "\(program) stopped on an error from a part of Windows it uses (\(type)) — not graphics code"
        }
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
                  let words = notGraphics(explain(report, prefix: s.prefix)) else { continue }
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
