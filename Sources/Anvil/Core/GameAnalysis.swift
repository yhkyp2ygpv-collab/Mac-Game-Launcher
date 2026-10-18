import Foundation

/// What a game is, read from its own files: which DirectX it draws with, which engine
/// it was built on, and whether it is a 64-bit program.
///
/// Read once per build of the game and kept in Cache/GameAnalysis.json, keyed by the
/// executable's path, size and date — reading a 100 MB executable is a fraction of a
/// second, but there is no reason to do it twice, and none at all to need a connection.
struct GameAnalysis: Codable, Hashable {
    enum API: String, Codable, CaseIterable, Comparable {
        case d3d9, d3d10, d3d11, d3d12, vulkan, opengl

        var title: String {
            switch self {
            case .d3d9: "DirectX 9"
            case .d3d10: "DirectX 10"
            case .d3d11: "DirectX 11"
            case .d3d12: "DirectX 12"
            case .vulkan: "Vulkan"
            case .opengl: "OpenGL"
            }
        }

        private var rank: Int { API.allCases.firstIndex(of: self) ?? 0 }
        static func < (a: API, b: API) -> Bool { a.rank < b.rank }
    }

    enum Engine: String, Codable {
        case unity, unreal, ttGames, other

        var title: String {
            switch self {
            case .unity: "Unity"
            case .unreal: "Unreal Engine"
            case .ttGames: "TT Games' engine"
            case .other: "its own engine"
            }
        }
    }

    /// Every graphics API the game can use, and the one it draws with.
    var apis: Set<API>
    var primary: API?
    var engine: Engine
    var is64Bit: Bool
    /// Draws at whatever size its window is, so rendering fewer pixels is Anvil's to do
    /// (Unity does; a game with its own resolution setting, like LEGO Star Wars, does not).
    var rendersAtWindowSize: Bool

    var summary: String {
        var parts: [String] = []
        if let primary { parts.append(primary.title) }
        parts.append(engine == .other ? "own engine" : engine.title)
        parts.append(is64Bit ? "64-bit" : "32-bit")
        return parts.joined(separator: " · ")
    }

    // MARK: Reading

    /// The program that draws: for an Unreal Engine game started through its launcher — the small .exe at
    /// the top of its folder, beside Engine/, that checks for prerequisites and starts the real one — the
    /// program under <Project>/Binaries/Win64. Hogwarts Legacy's launcher is 290 KB and links no Direct3D;
    /// its game (Phoenix/Binaries/Win64/HogwartsLegacy.exe, 458 MB) draws with DirectX 12 and has Unreal's
    /// ray tracing. Read as the launcher until 0.59, it was "its own engine", and its ray tracing stayed off
    /// on an M4 that traces rays in hardware.
    static func drawingProgram(for executable: URL) -> URL {
        let folder = executable.deletingLastPathComponent()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.appendingPathComponent("Engine").path, isDirectory: &isDir), isDir.boolValue,
              let projects = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return executable }
        let base = executable.deletingPathExtension().lastPathComponent.lowercased()
        for project in projects where project.lastPathComponent != "Engine" {
            for bin in ["Binaries/Win64", "Binaries/WinGDK", "Binaries/Win32"] {
                let dir = project.appendingPathComponent(bin, isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                let exes = files.filter { $0.pathExtension.lowercased() == "exe" && !$0.lastPathComponent.lowercased().contains("crashreport") }
                if let same = exes.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == base })
                    ?? exes.first(where: { $0.lastPathComponent.lowercased().hasPrefix(base + "-win") })
                    ?? (exes.count == 1 ? exes.first : nil) {
                    return same
                }
            }
        }
        return executable
    }

    static func analyze(executable launched: URL) -> GameAnalysis {
        let url = drawingProgram(for: launched)
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        let pe = PEImports.read(data)
        let imports = Set(pe.dlls.map { $0.lowercased() })
        var apis = Set<API>()
        if imports.contains("d3d12.dll") { apis.insert(.d3d12) }
        if imports.contains("d3d11.dll") { apis.insert(.d3d11) }
        if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") { apis.insert(.d3d10) }
        if imports.contains("d3d9.dll") { apis.insert(.d3d9) }
        if imports.contains("vulkan-1.dll") { apis.insert(.vulkan) }
        if imports.contains("opengl32.dll") { apis.insert(.opengl) }

        // Many games load Direct3D at run time rather than linking it — LEGO Star Wars
        // links only dxgi — so the executable's own strings are read as well.
        let lowered = url.lastPathComponent.lowercased()
        func mentions(_ needle: String) -> Bool { contains(data, needle) || contains(data, needle.uppercased()) }
        if apis.isEmpty || !apis.contains(where: { $0 >= .d3d9 && $0 <= .d3d12 }) {
            if mentions("d3d12.dll") || mentions("D3D12CreateDevice") { apis.insert(.d3d12) }
            if mentions("d3d11.dll") || mentions("D3D11CreateDevice") { apis.insert(.d3d11) }
            if mentions("d3d9.dll") || mentions("Direct3DCreate9") { apis.insert(.d3d9) }
        }

        // Unity and Unreal keep their engine beside the executable, or in it.
        var engine = Engine.other
        let unityPlayer = folder.appendingPathComponent("UnityPlayer.dll").path
        if fm.fileExists(atPath: unityPlayer) || fm.fileExists(atPath: folder.appendingPathComponent("GameAssembly.dll").path) {
            engine = .unity
            // UnityPlayer.dll holds the renderer; its imports say which Direct3D it uses.
            if let player = try? Data(contentsOf: URL(fileURLWithPath: unityPlayer), options: .mappedIfSafe) {
                let pi = Set(PEImports.read(player).dlls.map { $0.lowercased() })
                if pi.contains("d3d11.dll") { apis.insert(.d3d11) }
                if pi.contains("d3d12.dll") { apis.insert(.d3d12) }
                if apis.isEmpty && (contains(player, "d3d11.dll") || contains(player, "D3D11CreateDevice")) { apis.insert(.d3d11) }
            }
        } else if lowered.contains("-win64-shipping") || lowered.contains("-wingdk-shipping")
                    || folder.path.contains("/Binaries/Win64") {
            engine = .unreal
        } else if contains(data, "nttAudioHAL") || contains(data, "NuLocaleManager") {
            engine = .ttGames
        }

        // Unreal links Direct3D 11 for its fallback and loads 12 when it runs: Hogwarts Legacy imports d3d11.dll
        // and draws with DirectX 12. Its program naming d3d12.dll is DirectX 12 it can use, and the newer wins.
        if engine == .unreal, !apis.contains(.d3d12), mentions("d3d12.dll") || mentions("D3D12CreateDevice") {
            apis.insert(.d3d12)
        }

        // A name that says which renderer this build is wins over everything else.
        var primary: API?
        if lowered.contains("dx12") || lowered.contains("d3d12") { primary = .d3d12; apis.insert(.d3d12) }
        else if lowered.contains("dx11") || lowered.contains("d3d11") { primary = .d3d11; apis.insert(.d3d11) }
        else if lowered.contains("dx9") { primary = .d3d9; apis.insert(.d3d9) }
        else if lowered.contains("vulkan") || lowered.contains("_vk") { primary = .vulkan; apis.insert(.vulkan) }
        if primary == nil {
            // The newest Direct3D it can use is what it will pick on Windows; otherwise
            // Vulkan, then OpenGL.
            primary = apis.filter { $0 <= .d3d12 }.max() ?? (apis.contains(.vulkan) ? .vulkan : (apis.contains(.opengl) ? .opengl : nil))
        }

        return GameAnalysis(apis: apis, primary: primary, engine: engine, is64Bit: pe.is64Bit ?? true,
                            rendersAtWindowSize: engine == .unity)
    }

    private static func contains(_ data: Data, _ needle: String) -> Bool {
        guard let bytes = needle.data(using: .ascii), !data.isEmpty else { return false }
        return data.range(of: bytes) != nil
    }

    // MARK: Ray tracing

    nonisolated(unsafe) private static var rayTracingSeen: [String: Bool] = [:]
    private static let rayTracingLock = NSLock()

    /// Whether a DirectX 12 game has ray-traced effects to offer: the names engines give ray tracing — DXR's
    /// own, Unreal's r.RayTracing settings, Unity's — in its executable, or in Unity's player beside it. A game
    /// with them only uses ray tracing where its own settings turn it on; D3DMetal then runs it on the GPU's
    /// ray-tracing hardware (M3 and later). Read once for each build of the game.
    static func offersRayTracing(executable url: URL) -> Bool {
        let key = url.path + "|" + String(((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0)
        rayTracingLock.lock()
        if let seen = rayTracingSeen[key] { rayTracingLock.unlock(); return seen }
        rayTracingLock.unlock()
        var files = [drawingProgram(for: url)]
        let player = url.deletingLastPathComponent().appendingPathComponent("UnityPlayer.dll")
        if FileManager.default.fileExists(atPath: player.path) { files.append(player) }
        let needles = ["D3D12_RAYTRACING", "r.RayTracing", "RayTracingAccelerationStructure", "RaytracingAccelerationStructure",
                       "RayTracingShader", "EnableRayTracing", "RayTracingEnabled", "RaytracingEnabled"]
        var found = false
        for file in files where !found {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            found = needles.contains { contains(data, $0) }
        }
        rayTracingLock.lock()
        rayTracingSeen[key] = found
        rayTracingLock.unlock()
        return found
    }

    // MARK: Cache

    /// `scheme` 2: read through an Unreal launcher to the program that draws (0.59). An analysis from before
    /// it has none and is read again.
    private struct Key: Codable, Hashable { var path: String; var size: Int; var modified: Double; var scheme: Int? = 2 }
    private struct Stored: Codable { var entries: [String: Entry] }
    private struct Entry: Codable { var key: Key; var analysis: GameAnalysis }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: Entry]?
    private static var cacheURL: URL { DiskCache.directory.appendingPathComponent("GameAnalysis.json") }

    private static func key(for url: URL) -> Key? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Key(path: url.path, size: size, modified: modified)
    }

    /// The analysis of this build of the game, read once and kept.
    static func cached(for executable: URL) -> GameAnalysis? {
        guard let key = key(for: executable) else { return nil }
        lock.lock()
        if memory == nil {
            memory = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }?.entries ?? [:]
        }
        if let entry = memory?[key.path], entry.key == key {
            lock.unlock()
            return entry.analysis
        }
        lock.unlock()

        let analysis = analyze(executable: executable)
        lock.lock()
        memory?[key.path] = Entry(key: key, analysis: analysis)
        let snapshot = Stored(entries: memory ?? [:])
        lock.unlock()
        try? FileManager.default.createDirectory(at: DiskCache.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { DiskCache.writeReplacing(data, to: cacheURL) }
        return analysis
    }
}

/// The DLL names a Windows executable imports, and whether it is 64-bit.
enum PEImports {
    struct Result { var dlls: [String]; var is64Bit: Bool? }

    static func read(_ data: Data) -> Result {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count >= 0x40, bytes[0] == 0x4D, bytes[1] == 0x5A else { return Result(dlls: [], is64Bit: nil) }
        func u16(_ o: Int) -> Int? {
            guard o + 2 <= data.count else { return nil }
            return Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8
        }
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= data.count else { return nil }
            var v = 0
            for i in 0..<4 { v |= Int(data[data.startIndex + o + i]) << (8 * i) }
            return v
        }
        guard let pe = u32(0x3C), u32(pe) == 0x0000_4550, let machine = u16(pe + 4),
              let sections = u16(pe + 6), let optionalSize = u16(pe + 20) else { return Result(dlls: [], is64Bit: nil) }
        let optional = pe + 24
        guard let magic = u16(optional) else { return Result(dlls: [], is64Bit: nil) }
        let is64 = magic == 0x20B
        let dataDirectories = optional + (is64 ? 112 : 96)
        guard let importRVA = u32(dataDirectories + 8), importRVA > 0 else {
            return Result(dlls: [], is64Bit: machine == 0x8664 || is64)
        }
        // Section table, to turn relative addresses into file offsets.
        var table: [(va: Int, size: Int, raw: Int)] = []
        let first = optional + optionalSize
        for i in 0..<min(sections, 96) {
            let o = first + i * 40
            guard let vsize = u32(o + 8), let va = u32(o + 12), let rsize = u32(o + 16), let raw = u32(o + 20) else { break }
            table.append((va, max(vsize, rsize), raw))
        }
        func offset(_ rva: Int) -> Int? {
            for s in table where rva >= s.va && rva < s.va + s.size { return rva - s.va + s.raw }
            return nil
        }
        var dlls: [String] = []
        guard var descriptor = offset(importRVA) else { return Result(dlls: [], is64Bit: is64) }
        for _ in 0..<512 {
            guard let nameRVA = u32(descriptor + 12), let thunk = u32(descriptor + 16) else { break }
            if nameRVA == 0 && thunk == 0 { break }
            if let at = offset(nameRVA) {
                var end = at
                while end < data.count, end - at < 256, data[data.startIndex + end] != 0 { end += 1 }
                if let name = String(data: data.subdata(in: (data.startIndex + at)..<(data.startIndex + end)), encoding: .ascii) {
                    dlls.append(name)
                }
            }
            descriptor += 20
        }
        return Result(dlls: dlls, is64Bit: is64)
    }
}
