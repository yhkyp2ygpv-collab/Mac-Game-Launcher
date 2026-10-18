import Foundation

/// Prepares a Wine prefix before the first launch into it.
///
/// Anvil used to have no step like this: it set `WINE_RETINA_MODE`, `WINEDPI` and
/// `WINE_RESOLUTION` as environment variables and let Wine create the prefix on its
/// own during the first launch. None of those three variables exist in Wine — the
/// settings they were meant to control live in the prefix's registry, so nothing was
/// applied and the game only ever saw a low-DPI display.
///
/// Getting this right matters beyond tidiness. With `RetinaMode` set, Wine reports
/// the display's real backing resolution, so the game's own resolution list contains
/// the HiDPI modes and the game chooses to render at them. Without it, Anvil could
/// only enlarge the drawable after the fact and let the game keep rendering its UI
/// at half scale.
@MainActor
enum Prefix {

    /// Registry paths Wine reads on startup.
    private static let macDriver = #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
    private static let desktop   = #"HKEY_CURRENT_USER\Control Panel\Desktop"#

    /// Written into the prefix once it has been prepared, so preparation is skipped
    /// on every later launch. Holds the settings that were applied, so changing one
    /// in the UI re-runs preparation instead of silently doing nothing.
    private static func stampURL(_ container: Container) -> URL {
        container.prefixURL.appendingPathComponent(".anvil-prefix", isDirectory: false)
    }

    /// Includes the engine: moving a container to a different Wine (7.7 to 9.0, say)
    /// upgrades the prefix on first launch, and doing that here — with "Preparing…"
    /// on screen — beats Wine doing it silently inside what looks like a hung launch.
    private static func fingerprint(_ c: Container, _ runtimeID: String) -> String {
        "v3|\(runtimeID)|\(c.scaling.rawValue)|\(c.dpi)|\(c.windowsVersion.rawValue)|\(c.customWidth)x\(c.customHeight)"
    }

    static func needsPreparation(_ container: Container, runtime: Runtime) -> Bool {
        let stamp = stampURL(container)
        guard let have = try? String(contentsOf: stamp, encoding: .utf8) else { return true }
        return have.trimmingCharacters(in: .whitespacesAndNewlines) != fingerprint(container, runtime.id)
    }

    /// Create the prefix if needed and write the settings that are actually registry
    /// keys. Safe to call before every launch; it returns immediately once the stamp
    /// matches.
    @discardableResult
    static func prepare(container: Container, runtime: Runtime,
                        log: @escaping (String) -> Void = { _ in }) async throws -> Bool {
        guard needsPreparation(container, runtime: runtime) else { return false }

        try FileManager.default.createDirectory(at: container.prefixURL, withIntermediateDirectories: true)

        // wineboot both creates a missing prefix and updates an existing one. It is
        // the supported way in; creating the tree by hand produces a prefix Wine then
        // has to repair on first run.
        log("Preparing container “\(container.name)”…")
        try await wine(["wineboot", "-u"], container: container, runtime: runtime)

        let retina = container.scaling != .native
        // The container's own resolution again, whatever a store's window was last given.
        try? FileManager.default.removeItem(at: scaleStampURL(container))
        try await reg(add: macDriver, name: "RetinaMode", type: "REG_SZ",
                      data: retina ? "y" : "n", container: container, runtime: runtime)

        // 96 is one-to-one. Wine's Mac driver treats 192 as the 2× Retina case; the
        // arbitrary values in between scale UI without changing backing resolution,
        // which is why the picker offers a DPI rather than a scale factor.
        let dpi = retina ? max(96, min(container.dpi, 480)) : 96
        try await reg(add: desktop, name: "LogPixels", type: "REG_DWORD",
                      data: String(dpi), container: container, runtime: runtime)

        // Reported Windows version. Some launchers and anti-tamper layers refuse to
        // start on anything they read as older than they expect.
        try await wine(["winecfg", "-v", container.windowsVersion.wineValue],
                       container: container, runtime: runtime)

        try? fingerprint(container, runtime.id).write(to: stampURL(container), atomically: true, encoding: .utf8)
        log("Container ready — Retina \(retina ? "on" : "off"), \(dpi) DPI, \(container.windowsVersion.title).")
        return true
    }

    // MARK: A store's window at point size, its games at Retina

    /// Steam's window is Chromium drawing every pixel on the CPU: under Wine Steam passes
    /// --disable-gpu to each process of its web helper whatever its own GPU setting says
    /// (ps, 9 October; neither -cef-force-gpu nor GPUAccelWebViewsV3 changed it). At Retina
    /// that is 2560 × 1600 for a 1280 × 800 window — 27 fps, frames of up to 92 ms, measured
    /// over a full-window repaint with requestAnimationFrame; at the display's point size, 46
    /// fps and 42 ms. RetinaMode and LogPixels are read by each Wine process as it starts, so
    /// Steam can start at point size and a game started beside it, in the same container, at
    /// Retina — the drawable Anvil's FSR upscales to.
    private static func scaleStampURL(_ c: Container) -> URL {
        c.prefixURL.appendingPathComponent(".anvil-scale", isDirectory: false)
    }

    /// The container's own resolution, as `prepare` writes it.
    static func containerScale(_ c: Container) -> (retina: Bool, dpi: Int) {
        let retina = c.scaling != .native
        return (retina, retina ? max(96, min(c.dpi, 480)) : 96)
    }

    static func scaleName(retina: Bool, dpi: Int) -> String { retina ? "retina-\(dpi)" : "points" }

    /// What the registry holds now: the last scale written here, else the container's own.
    static func writtenScale(_ c: Container) -> String {
        if let s = try? String(contentsOf: scaleStampURL(c), encoding: .utf8), !s.isEmpty { return s }
        let own = containerScale(c)
        return scaleName(retina: own.retina, dpi: own.dpi)
    }

    /// Point size for a store's window (`points`), else the container's own resolution. One
    /// short Wine run, only when it changes. Returns whether Wine ran.
    @discardableResult
    static func setWindowScale(points: Bool, container c: Container, runtime: Runtime) async -> Bool {
        let (retina, dpi) = points ? (false, 96) : containerScale(c)
        let want = scaleName(retina: retina, dpi: dpi)
        guard writtenScale(c) != want else { return false }
        let file = c.driveC.appendingPathComponent("anvil-scale.reg")
        let text = "REGEDIT4\r\n\r\n[\(macDriver)]\r\n\"RetinaMode\"=\"\(retina ? "y" : "n")\"\r\n\r\n"
            + "[\(desktop)]\r\n\"LogPixels\"=dword:\(String(format: "%08x", dpi))\r\n"
        guard (try? Data(text.utf8).write(to: file)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? await wine(["reg", "import", #"C:\anvil-scale.reg"#], container: c, runtime: runtime)) != nil else { return false }
        try? want.write(to: scaleStampURL(c), atomically: false, encoding: .utf8)
        return true
    }

    // MARK: Trackpad and keyboard

    /// What Wine's Mac driver reads for the trackpad and keyboard, from the container's
    /// settings. Values are Wine's own: "y" or "n".
    static func inputSettings(_ c: Container) -> [(name: String, value: String)] {
        let steps = c.scrollInSteps ?? true, alt = c.optionIsAlt ?? true, ctrl = c.commandKeysAreCtrl
        return [("UsePreciseScrolling", steps ? "n" : "y"),
                ("LeftOptionIsAlt", alt ? "y" : "n"),
                ("RightOptionIsAlt", "n"),
                ("LeftCommandIsCtrl", ctrl ? "y" : "n"),
                ("RightCommandIsCtrl", ctrl ? "y" : "n")]
    }

    /// The same, as the .reg file Wine imports in one run.
    static func inputRegFile(_ c: Container) -> String {
        "REGEDIT4\r\n\r\n[\(macDriver)]\r\n"
            + inputSettings(c).map { "\"\($0.name)\"=\"\($0.value)\"" }.joined(separator: "\r\n") + "\r\n"
    }

    private static func inputStampURL(_ container: Container) -> URL {
        container.prefixURL.appendingPathComponent(".anvil-input", isDirectory: false)
    }

    static func inputFingerprint(_ c: Container) -> String {
        "v1|" + inputSettings(c).map { "\($0.name)=\($0.value)" }.joined(separator: ",")
    }

    static func needsInput(_ container: Container) -> Bool {
        (try? String(contentsOf: inputStampURL(container), encoding: .utf8)) != inputFingerprint(container)
    }

    /// Write the trackpad and keyboard settings when they changed — once per container,
    /// one short Wine run. Returns whether Wine ran.
    @discardableResult
    static func applyInput(container: Container, runtime: Runtime) async -> Bool {
        guard needsInput(container) else { return false }
        let file = container.driveC.appendingPathComponent("anvil-input.reg")
        guard (try? Data(inputRegFile(container).utf8).write(to: file)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? await wine(["reg", "import", #"C:\anvil-input.reg"#], container: container, runtime: runtime)) != nil else { return false }
        try? inputFingerprint(container).write(to: inputStampURL(container), atomically: false, encoding: .utf8)
        return true
    }

    /// Force preparation to run again, for the case where a prefix has been edited
    /// outside Anvil and its registry no longer matches what the UI shows.
    static func invalidate(_ container: Container) {
        try? FileManager.default.removeItem(at: stampURL(container))
    }

    // MARK: Process

    private static func reg(add key: String, name: String, type: String, data: String,
                            container: Container, runtime: Runtime) async throws {
        try await wine(["reg", "add", key, "-v", name, "-t", type, "-d", data, "-f"],
                       container: container, runtime: runtime)
    }

    private static func wine(_ arguments: [String], container: Container, runtime: Runtime) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = runtime.wine64
            p.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = container.prefixURL.path
            env["WINEDEBUG"] = "-all"
            // Preparation must never run with the injector attached: it would hook a
            // process that draws nothing and only slows the step down.
            env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                // wineboot on a fresh prefix legitimately exits non-zero on some
                // builds while still having done the work, so a bad status is
                // reported by the caller's own checks rather than thrown here.
                _ = proc.terminationStatus
                cont.resume()
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
