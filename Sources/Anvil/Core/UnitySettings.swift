import Foundation
import CoreGraphics

/// Fullscreen for Unity games, set the way Unity itself sets it.
///
/// Anvil used to append `-screen-fullscreen 1` to the command line. That argument
/// crashed the game. Unity handles it by asking Windows to change the display mode,
/// which under Wine goes through `win32u`, and the game died there a second or two
/// after the first scene finished loading — read as "I load in and the game just
/// closes". It took a control run with the flag removed to see it, because every
/// earlier control run had the flag too, so the crash looked like the game's own.
///
/// Unity reads the same setting from its own preferences on startup, and that path
/// does not change the display mode. So Anvil writes the preference instead of
/// passing an argument, and asks for *borderless* fullscreen rather than exclusive:
/// borderless never touches the display mode at all, and alt-tabs cleanly.
@MainActor
enum UnitySettings {

    /// Unity hashes each preference name into the registry value name, and the
    /// suffixes below are the hashes of these exact strings — stable across Unity
    /// versions. All four were read back out of a real game's prefix before being
    /// used here rather than taken from documentation.
    private enum Key {
        static let fullscreenMode   = "Screenmanager Fullscreen mode_h3630240806"
        static let isFullscreen     = "Screenmanager Is Fullscreen mode_h3981298716"
        static let width            = "Screenmanager Resolution Width_h182942802"
        static let height           = "Screenmanager Resolution Height_h2627697771"
    }

    enum Mode: Int {
        case exclusive = 1        // changes the display mode — the one that crashed
        case borderless = 2       // a window the size of the screen
        case maximized = 3
        case windowed = 4
    }

    /// Company and product, as Unity itself records them beside the executable.
    /// Returns nil for anything that is not a Unity game, and Anvil then does nothing.
    static func identity(for executable: URL) -> (company: String, product: String)? {
        let base = executable.deletingPathExtension().lastPathComponent
        let info = executable.deletingLastPathComponent()
            .appendingPathComponent("\(base)_Data/app.info")
        guard let text = try? String(contentsOf: info, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        return (lines[0], lines[1])
    }

    /// The display's real pixel size, which is what a Retina fullscreen wants.
    static func displayPixels() -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return (1920, 1080) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    /// Write the preference.
    ///
    /// This used to be four separate `wine reg add` invocations, and it cost
    /// **22 seconds** on every launch — each one starts wine and waits on wineserver.
    /// Measured from a launch log: Play was pressed, and the game did not start for
    /// 22 seconds, with nothing on screen to say why. That is indistinguishable from
    /// a broken button, and it was reported as one.
    ///
    /// Now it is a single `regedit` import of one file, and it is skipped entirely
    /// once the prefix already has the settings — so only the first launch after a
    /// change pays anything at all.
    /// Returns true only when wine was actually run to write the setting.
    @discardableResult
    static func applyFullscreen(_ mode: Mode, game: Game, container: Container,
                                runtime: Runtime,
                                size: (width: Int, height: Int)? = nil) async -> Bool {
        guard let id = identity(for: game.executableURL) else { return false }
        let pixels = size ?? { let p = displayPixels(); return (p.0, p.1) }()

        // Already applied? Then this launch costs nothing.
        let stamp = container.prefixURL
            .appendingPathComponent(".anvil-unity-\(game.id.uuidString)")
        let want = "\(mode.rawValue)|\(pixels.width)x\(pixels.height)"
        if let have = try? String(contentsOf: stamp, encoding: .utf8),
           have.trimmingCharacters(in: .whitespacesAndNewlines) == want {
            return false
        }

        let path = "HKEY_CURRENT_USER\\Software\\\(id.company)\\\(id.product)"
        func dword(_ v: Int) -> String { String(format: "dword:%08x", v) }

        var body = """
        Windows Registry Editor Version 5.00

        [\(path.replacingOccurrences(of: "\\", with: "\\\\"))]
        "\(Key.fullscreenMode)"=\(dword(mode.rawValue))
        "\(Key.isFullscreen)"=\(dword(mode == .windowed ? 0 : 1))
        """
        if mode != .windowed {
            body += """
            \n"\(Key.width)"=\(dword(pixels.width))
            "\(Key.height)"=\(dword(pixels.height))
            """
        }
        body += "\n"

        // regedit reads a path inside the prefix, so the file has to live in drive_c.
        let onDisk = container.driveC.appendingPathComponent("anvil-screen.reg")
        guard (try? body.write(to: onDisk, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: onDisk) }

        let ok = await run(["regedit", "C:\\anvil-screen.reg"], container: container, runtime: runtime)
        if ok { try? want.write(to: stamp, atomically: true, encoding: .utf8) }
        return ok
    }

    @discardableResult
    private static func run(_ arguments: [String], container: Container,
                            runtime: Runtime) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = runtime.wine64
            p.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = container.prefixURL.path
            env["WINEDEBUG"] = "-all"
            env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus == 0) }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
    }
}
