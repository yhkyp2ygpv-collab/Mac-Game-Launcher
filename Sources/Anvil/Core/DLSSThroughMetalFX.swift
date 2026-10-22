import Foundation

/// Apple's DLSS-to-MetalFX translation, set up for a game that ships DLSS.
///
/// D3DMetal 3.0 (Game Porting Toolkit 3; Mythic Engine 3.0 here) answers a game's DLSS calls
/// with MetalFX: its temporal upscaler for DLSS, and MetalFX frame interpolation for DLSS frame
/// generation — read out of the framework itself: it links MetalFX and carries
/// D3DM_ENABLE_METALFX, TemporalScaler, FrameInterpolator and every DLSSG parameter. Both work
/// from the motion vectors and depth the game hands DLSS, which is what makes this the real
/// thing: the kind of upscaling FSR 3 does, on Apple's hardware path.
///
/// The engine ships the pieces under a name Wine never looks for — nvngx-on-metalfx.dll and
/// its Unix half — where a game asks for nvngx.dll. Apple's instructions rename them inside the
/// toolkit and copy them into system32. Anvil leaves its engines exactly as sealed, so the
/// renamed copies live in Anvil's own folder, which Wine is told to search (WINEDLLPATH: Wine
/// takes a builtin library from there along with its Unix half), and in the container's
/// system32, where Apple puts them and where a game's DLSS looks for the file. Nothing goes
/// into the game's folder. D3DM_ENABLE_METALFX=1 switches the translation on.
enum DLSSThroughMetalFX {
    /// The engine's own files, when it has the translation.
    nonisolated static func files(in runtime: Runtime) -> (dll: URL, so: URL, nvapi: URL)? {
        let lib = runtime.root.appendingPathComponent("lib/wine")
        let dll = lib.appendingPathComponent("x86_64-windows/nvngx-on-metalfx.dll")
        let so = lib.appendingPathComponent("x86_64-unix/nvngx-on-metalfx.so")
        let nvapi = lib.appendingPathComponent("x86_64-windows/nvapi64.dll")
        let fm = FileManager.default
        guard fm.fileExists(atPath: dll.path), fm.fileExists(atPath: so.path) else { return nil }
        return (dll, so, nvapi)
    }

    nonisolated static func available(in runtime: Runtime) -> Bool { files(in: runtime) != nil }

    /// Anvil's folder for this engine — by where it is, as the engine and Anvil's Game Mode copy
    /// of it are two places with one id — with the pieces named as Wine looks for them.
    nonisolated static func folder(for runtime: Runtime) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in runtime.root.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return RuntimeManager.support.appendingPathComponent("MetalFX DLSS", isDirectory: true)
            .appendingPathComponent("\(runtime.id)-\(String(hash, radix: 16).prefix(8))", isDirectory: true)
    }

    private nonisolated static func system32(_ container: Container) -> URL {
        container.prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
    }

    /// Everything in place for a start: the folder for WINEDLLPATH, or why not.
    nonisolated static func prepare(container: Container, runtime: Runtime) -> Result<URL, Error> {
        guard let source = files(in: runtime) else { return .failure(SetupError.notInEngine(runtime.displayName)) }
        let fm = FileManager.default
        let root = folder(for: runtime)
        let windows = root.appendingPathComponent("x86_64-windows", isDirectory: true)
        let unix = root.appendingPathComponent("x86_64-unix", isDirectory: true)
        do {
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            try fm.createDirectory(at: unix, withIntermediateDirectories: true)
            try place(source.dll, at: windows.appendingPathComponent("nvngx.dll"))
            // The Unix half is D3DMetal's own library, as d3d11's and dxgi's are: in Engine 3.0
            // nvngx-on-metalfx.so is a link to lib/external/libd3dshared.dylib. So this is a
            // link to that same file of this engine — the one the game already has loaded, never
            // a second D3DMetal beside it.
            try link(unix.appendingPathComponent("nvngx.so"), to: source.so.resolvingSymlinksInPath())
            let sys = system32(container)
            guard fm.fileExists(atPath: sys.path) else { return .failure(SetupError.noSystem32) }
            try place(source.dll, at: sys.appendingPathComponent("nvngx.dll"))
            // Wine puts its own in when it sets a container up; put in only when it hasn't.
            let nvapi = sys.appendingPathComponent("nvapi64.dll")
            if !fm.fileExists(atPath: nvapi.path), fm.fileExists(atPath: source.nvapi.path) {
                try fm.copyItem(at: source.nvapi, to: nvapi)
            }
            return .success(root)
        } catch {
            return .failure(error)
        }
    }

    /// Set up already, as `prepare` leaves it: the folder for WINEDLLPATH.
    nonisolated static func ready(container: Container, runtime: Runtime) -> URL? {
        let root = folder(for: runtime)
        let fm = FileManager.default
        guard available(in: runtime),
              fm.fileExists(atPath: root.appendingPathComponent("x86_64-windows/nvngx.dll").path),
              fm.fileExists(atPath: root.appendingPathComponent("x86_64-unix/nvngx.so").path),
              fm.fileExists(atPath: system32(container).appendingPathComponent("nvngx.dll").path) else { return nil }
        return root
    }

    /// Whether D3DMetal showed the container's games an NVIDIA GPU — DLSS offered — at its last start with the
    /// translation on. It does that when it finds nvngx.dll, and then writes NGX's own registry key, FullPath under
    /// HKLM\Software\Nvidia Corporation\Global\NGXCore, to where it found it (read out of D3DMetal 3.0: DXGIAdapter's
    /// vendor becomes 0x10DE when nvngxDLLLocation finds the file). Hogwarts Legacy's setup had it on 21 October.
    nonisolated static func shownNVIDIA(_ container: Container) -> Bool {
        guard let reg = try? String(contentsOf: container.prefixURL.appendingPathComponent("system.reg"), encoding: .utf8),
              let key = reg.range(of: "[Software\\\\Nvidia Corporation\\\\Global\\\\NGXCore]", options: .caseInsensitive) else { return false }
        let block = reg[key.upperBound...].prefix { $0 != "[" }
        return block.contains("\"FullPath\"=")
    }

    /// A link in Anvil's folder to a file of the engine, by its full path.
    private nonisolated static func link(_ at: URL, to target: URL) throws {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: at.path), existing == target.path { return }
        if (try? at.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: at.path)) != nil {
            try fm.removeItem(at: at)      // Anvil's own link or copy, in Anvil's own folder
        }
        try fm.createSymbolicLink(at: at, withDestinationURL: target)
    }

    /// A copy of the engine's file, replaced when the engine's changed. One that isn't
    /// Anvil's goes to the Trash rather than being overwritten.
    private nonisolated static func place(_ source: URL, at target: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            if fm.contentsEqual(atPath: source.path, andPath: target.path) { return }
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: target)
    }

    enum SetupError: LocalizedError {
        case notInEngine(String)
        case noSystem32
        var errorDescription: String? {
            switch self {
            case .notInEngine(let name): "\(name) doesn't have Apple's DLSS-to-MetalFX translation"
            case .noSystem32: "the container's Windows folder isn't set up yet"
            }
        }
    }
}
