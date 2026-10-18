import Foundation

/// DXVK as a game's graphics setting: its DLLs in the container, and D3DMetal's put back after.
///
/// Choosing DXVK used to only change WINEDLLOVERRIDES to "d3d9,d3d10core,d3d11,dxgi=n". The DLLs
/// were never copied into the container, so Wine found its own placeholders in system32, which
/// a native-only load order refuses: a DirectX game on DXVK couldn't load DirectX at all. And
/// "native only" for d3d9 broke every DirectX 9 game there, because DXVK for macOS has no d3d9.
///
/// What the engines hold (checked 10 October in Mythic Engine 2.6.1 and 3.0 and WhiskyWine 2.5):
/// - lib/wine/x86_64-windows/d3d10, d3d11, d3d12 and dxgi are D3DMetal's. So a 64-bit game's
///   DirectX 10, 11 and 12 go through D3DMetal under every setting except DXVK, WineD3D included:
///   these engines carry no 64-bit Wine renderer for them.
/// - lib/wine/i386-windows holds Wine's own: D3DMetal is 64-bit only. A 32-bit DirectX 10 or 11
///   game "on D3DMetal" was drawn by WineD3D on macOS's OpenGL 4.1, which can't give DirectX 11
///   games the feature level most of them need to start.
/// - d3d9 is Wine's own, drawn with OpenGL, under every setting.
/// - <engine>-dxvk holds DXVK for macOS: d3d10core, d3d11 and dxgi, 64-bit (x64) and 32-bit
///   (x32), drawn with Vulkan through MoltenVK.
///
/// So DXVK is for a 64-bit DirectX 11 game when chosen, and for a 32-bit DirectX 10 or 11 game
/// unless WineD3D is chosen: D3DMetal can't draw one. Anything else is drawn the way it can be.
/// Files are swapped by rename, so a program already running in the container keeps the copy it
/// loaded.
enum DXVKSetup {
    /// The DLLs DXVK for macOS ships.
    nonisolated static let dlls = ["d3d10core", "d3d11", "dxgi"]
    /// The WINEDLLOVERRIDES that load them, falling back to the engine's own if one is missing.
    nonisolated static let overrides = "d3d10core,d3d11,dxgi=n,b"
    nonisolated static let stampName = ".anvil-dxvk"

    /// The engine's DXVK folder, when it has one with the 64-bit DLLs in it.
    nonisolated static func source(for runtime: Runtime) -> URL? {
        let dir = runtime.root.deletingLastPathComponent().appendingPathComponent(runtime.id + "-dxvk", isDirectory: true)
        let fm = FileManager.default
        return dlls.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent("x64/\($0).dll").path) }) ? dir : nil
    }

    /// What a chosen setting comes to for a game with this API on this engine, and why, when it
    /// isn't the one chosen.
    nonisolated static func effective(chosen: GraphicsBackend, api: GameAnalysis.API?, is64Bit: Bool = true,
                                      runtime: Runtime) -> (backend: GraphicsBackend, why: String?) {
        let hasDXVK = source(for: runtime) != nil
        // A 32-bit DirectX 10 or 11 game: D3DMetal has no 32-bit DLLs, DXVK has.
        if !is64Bit, chosen == .d3dmetal, api == .d3d10 || api == .d3d11, hasDXVK {
            return (.dxvk, "D3DMetal is 64-bit only; DXVK draws this 32-bit \(api!.title) game, through Vulkan and MoltenVK")
        }
        guard chosen == .dxvk else { return (chosen, nil) }
        let instead: GraphicsBackend = runtime.hasD3DMetal ? .d3dmetal : .wined3d
        if !hasDXVK {
            return (instead, "DXVK isn't part of \(runtime.displayName)")
        }
        switch api {
        case .d3d12?: return (instead, "DXVK doesn't do DirectX 12; \(is64Bit ? "D3DMetal" : "Wine") draws it")
        case .d3d10? where is64Bit: return (instead, "DXVK for macOS has no 64-bit DirectX 10 of its own; D3DMetal draws it")
        case .d3d9?: return (instead, "DXVK for macOS has no DirectX 9; Wine's own renderer draws it")
        default: return (.dxvk, nil)
        }
    }

    /// The setting a game starts with: what the player chose, as it comes to (see `effective`).
    nonisolated static func backend(for game: Game, in container: Container, runtime: Runtime) -> GraphicsBackend {
        let analysis = GameAnalysis.cached(for: game.executableURL)
        return effective(chosen: game.backendOverride ?? container.backend, api: analysis?.primary,
                         is64Bit: analysis?.is64Bit ?? true, runtime: runtime).backend
    }

    nonisolated static func stamp(in container: Container) -> URL {
        container.driveC.appendingPathComponent("windows/\(stampName)")
    }

    nonisolated static func installed(in container: Container) -> Bool {
        FileManager.default.fileExists(atPath: stamp(in: container).path)
    }

    /// Puts DXVK's DLLs in for `.dxvk`; for anything else, the engine's own back where DXVK's were.
    /// Returns a line for the launch log when something changed or failed, and whether the files
    /// are now as `backend` needs them.
    nonisolated static func apply(_ backend: GraphicsBackend, container: Container, runtime: Runtime) -> (ok: Bool, line: String?) {
        let fm = FileManager.default
        let windows = container.driveC.appendingPathComponent("windows", isDirectory: true)
        let sys32 = windows.appendingPathComponent("system32", isDirectory: true)
        let wow64 = windows.appendingPathComponent("syswow64", isDirectory: true)
        let hasWow = fm.fileExists(atPath: wow64.path)

        if backend == .dxvk {
            guard let src = source(for: runtime) else { return (false, "graphics: DXVK isn't part of \(runtime.displayName)") }
            var pairs = dlls.map { (src.appendingPathComponent("x64/\($0).dll"), sys32.appendingPathComponent("\($0).dll")) }
            if hasWow {
                pairs += dlls.map { (src.appendingPathComponent("x32/\($0).dll"), wow64.appendingPathComponent("\($0).dll")) }
                    .filter { fm.fileExists(atPath: $0.0.path) }
            }
            do {
                // Marked first, so files half put in are put back next time if this fails.
                try Data(runtime.id.utf8).write(to: stamp(in: container))
                let changed = try pairs.filter { try place($0.0, at: $0.1) }.count
                return (true, changed == 0 ? nil
                        : "graphics: DXVK's \(dlls.joined(separator: ", ")) put in “\(container.name)” (\(changed) files) — DirectX 11 through Vulkan and MoltenVK")
            } catch {
                // Never a mix of DXVK's and D3DMetal's: the engine's own go back.
                let undo = apply(.d3dmetal, container: container, runtime: runtime)
                return (false, "graphics: couldn't put DXVK in “\(container.name)” — \(error.localizedDescription)"
                        + (undo.ok ? "; the engine's own DirectX files are in place" : ""))
            }
        }

        guard installed(in: container) else { return (true, nil) }
        let lib = runtime.root.appendingPathComponent("lib/wine", isDirectory: true)
        var pairs = dlls.map { (lib.appendingPathComponent("x86_64-windows/\($0).dll"), sys32.appendingPathComponent("\($0).dll")) }
        if hasWow {
            pairs += dlls.map { (lib.appendingPathComponent("i386-windows/\($0).dll"), wow64.appendingPathComponent("\($0).dll")) }
        }
        pairs = pairs.filter { fm.fileExists(atPath: $0.0.path) }
        do {
            let changed = try pairs.filter { try place($0.0, at: $0.1) }.count
            try fm.removeItem(at: stamp(in: container))
            return (true, "graphics: \(runtime.displayName)'s own DirectX files back in “\(container.name)” in place of DXVK's (\(changed) files)")
        } catch {
            return (false, "graphics: couldn't put \(runtime.displayName)'s DirectX files back in “\(container.name)” — \(error.localizedDescription)")
        }
    }

    /// `from` at `to`, unless it's there already. Written beside it and renamed over it, so a
    /// process with the old one loaded keeps it. True when something was written.
    nonisolated private static func place(_ from: URL, at to: URL) throws -> Bool {
        let fm = FileManager.default
        let new = try Data(contentsOf: from)
        if let old = try? Data(contentsOf: to), old == new { return false }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).anvil-new")
        try? fm.removeItem(at: temp)
        try new.write(to: temp)
        guard rename(temp.path, to.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return true
    }
}
