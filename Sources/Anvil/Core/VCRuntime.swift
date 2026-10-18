import Foundation

/// Microsoft's Visual C++ Redistributable (2015–2022, version 14) in each Windows setup whose
/// games need it — what Windows has from the game's own installer, Steam's or Epic's.
///
/// Wine carries its own msvcp140 and vcruntime140, and most games run on them. Not every game
/// gets as far as loading them: Unreal Engine's launcher (the small .exe in a game's top folder)
/// first reads the key Microsoft's installer writes,
/// HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64, wants 14.24.28127.4 or later
/// there (read out of Hogwarts Legacy's), and without it shows "The following component(s) are
/// required to run this program: Microsoft Visual C++ Runtime" and exits with 9001 — code 41 once
/// macOS keeps its low byte. Hogwarts Legacy did exactly that on 17 October. Epic's own launcher
/// would have run the prerequisite first; legendary only does on Windows.
///
/// So Anvil runs Microsoft's own installer in the container, quietly, once: the same files and
/// key a Windows PC has. The installer comes from a game that ships it (Epic lists it as Cat
/// Quest II's prerequisite) or from Microsoft's site, and runs only once its Authenticode
/// signature checks out as Microsoft's. Its DLLs are then loaded ahead of Wine's own for that
/// container's games (WINEDLLOVERRIDES n,b, as winetricks' vcrun2022 does): Wine 9 measured on
/// this Mac keeps loading its own msvcp140 otherwise, with Microsoft's file right there in
/// system32.
enum VCRuntime {
    enum Arch: String, CaseIterable, Codable, Comparable {
        case x64, x86
        static func < (a: Arch, b: Arch) -> Bool { a.rawValue < b.rawValue }
        var downloadURL: URL { URL(string: "https://aka.ms/vs/17/release/vc_redist.\(rawValue).exe")! }
        /// Where its DLLs go: system32 for 64-bit programs, syswow64 for 32-bit ones.
        var systemFolder: String { self == .x64 ? "windows/system32" : "windows/syswow64" }
    }

    struct Version: Comparable, Codable, Hashable, CustomStringConvertible {
        var major = 0, minor = 0, build = 0, rebuild = 0
        static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor, a.build, a.rebuild) < (b.major, b.minor, b.build, b.rebuild)
        }
        var description: String { "\(major).\(minor).\(build).\(rebuild)" }
        /// Unreal Engine 4.27's launcher's minimum (BootstrapPackagedGame: Major 14, Minor 24, Bld 28127, Rbld 4).
        static let unrealMinimum = Version(major: 14, minor: 24, build: 28127, rebuild: 4)
        static let any14 = Version(major: 14)
    }

    /// What a game needs, and why, in words.
    struct Need: Equatable {
        var arches: Set<Arch>
        var minimum: Version
        var reasons: [String]
        /// Its launcher reads the registry key and won't start the game without it.
        var checksRegistry: Bool
    }

    /// The DLLs Microsoft's installer puts in, loaded ahead of Wine's own once it has.
    static let dlls = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids",
                       "vcamp140", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"]
    static var overrides: String { dlls.joined(separator: ",") + "=n,b" }

    // MARK: - What a game needs

    nonisolated(unsafe) private static var needs: [String: Need?] = [:]
    private static let needsLock = NSLock()

    /// Nil when nothing says the game needs it. Read once per build of the game.
    static func need(for game: Game) -> Need? {
        let exe = game.executableURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: exe.path)
        let key = "\(exe.path)|\((attributes?[.size] as? NSNumber)?.intValue ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        needsLock.lock()
        if let known = needs[key] { needsLock.unlock(); return known }
        needsLock.unlock()
        let found = need(executable: exe, storePrerequisites: epicPrerequisites(for: exe))
        needsLock.lock(); needs[key] = found; needsLock.unlock()
        return found
    }

    static func need(executable exe: URL, storePrerequisites: [String] = []) -> Need? {
        let folder = exe.deletingLastPathComponent()
        let fm = FileManager.default
        var arches = Set<Arch>()
        var reasons: [String] = []
        var minimum = Version.any14
        var checks = false

        let data = (try? Data(contentsOf: exe, options: .mappedIfSafe)) ?? Data()
        let pe = PEImports.read(data)
        let own: Arch = pe.is64Bit == false ? .x86 : .x64

        // An Unreal launcher, or anything else that reads Microsoft's key before starting.
        if data.count < 64_000_000, let arch = registryCheck(in: data) {
            arches.insert(arch)
            checks = true
            minimum = max(minimum, .unrealMinimum)
            reasons.append("its launcher checks for Microsoft's Visual C++ Runtime before it starts the game")
        }
        // The runtime's DLLs in its imports — its own, and those of the program an Unreal launcher
        // starts (<Project>/Binaries/Win64) or Unity's player beside it.
        var programs: [URL] = [exe]
        if let projects = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for project in projects {
                for bin in ["Binaries/Win64", "Binaries/Win32"] {
                    let dir = project.appendingPathComponent(bin, isDirectory: true)
                    if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        programs += files.filter { $0.pathExtension.lowercased() == "exe" }.prefix(4)
                    }
                }
            }
        }
        let unity = folder.appendingPathComponent("UnityPlayer.dll")
        if fm.fileExists(atPath: unity.path) { programs.append(unity) }
        for program in programs {
            guard let d = try? Data(contentsOf: program, options: .mappedIfSafe) else { continue }
            let r = PEImports.read(d)
            let wanted = r.dlls.map { $0.lowercased() }.filter { name in dlls.contains { name == $0 + ".dll" } }
            if !wanted.isEmpty {
                arches.insert(r.is64Bit == false ? .x86 : .x64)
                if reasons.count < 3 { reasons.append("\(program.lastPathComponent) uses \(wanted.sorted().joined(separator: ", "))") }
            }
        }
        // Listed by its store, or shipped beside it, as something to install first.
        for item in storePrerequisites where isRedistName(item) {
            arches.insert(arch(ofInstallerNamed: item) ?? own)
            reasons.append("its store lists \(URL(fileURLWithPath: item.replacingOccurrences(of: "\\", with: "/")).lastPathComponent) as something to install first")
        }
        for shipped in shippedInstallers(in: folder) {
            arches.insert(arch(ofInstallerNamed: shipped.lastPathComponent) ?? own)
            if reasons.count < 4 { reasons.append("it comes with \(shipped.lastPathComponent)") }
        }
        guard !arches.isEmpty else { return nil }
        return Need(arches: arches, minimum: minimum, reasons: reasons, checksRegistry: checks)
    }

    /// "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" in the program's own strings (UTF-16).
    static func registryCheck(in data: Data) -> Arch? {
        for arch in Arch.allCases {
            let needle = Data("VC\\Runtimes\\\(arch.rawValue)".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            if data.range(of: needle) != nil { return arch }
        }
        return nil
    }

    static func isRedistName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("vc_redist") || n.contains("vcredist") || n.contains("prereqsetup")
    }

    static func arch(ofInstallerNamed name: String) -> Arch? {
        let n = name.lowercased()
        if n.contains("x86") || n.contains("_x32") { return .x86 }
        if n.contains("x64") { return .x64 }
        return nil
    }

    /// Visual C++ 2015 and later installers in a game's folder, a few levels down (Steam's
    /// _CommonRedist, Unreal's Engine/Extras/Redist): never the whole of a 90 GB game.
    static func shippedInstallers(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 5_000 { break }
            if walker.level >= 5 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            // The 2015+ installers are VC_redist.*; "vcredist_x64.exe" is 2013 and before, which Wine's
            // own msvcr100–120 stand in for. Unreal's prerequisite setup installs the 2015+ one.
            if name.hasSuffix(".exe"), name.hasPrefix("vc_redist") || name.contains("prereqsetup") { found.append(url) }
            // A folder of the game's assets holds no installers.
            if ["content", "paks", "streamingassets", "data"].contains(name) { walker.skipDescendants() }
        }
        return found
    }

    /// The installers legendary was told to run first for the game installed at `exe`'s folder.
    static func epicPrerequisites(for exe: URL) -> [String] {
        let url = EpicAccount.configDir.appendingPathComponent("installed.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        let exePath = exe.standardizedFileURL.path
        var out: [String] = []
        for entry in root.values {
            guard let path = entry["install_path"] as? String,
                  exePath.hasPrefix(URL(fileURLWithPath: path).standardizedFileURL.path + "/"),
                  let prereq = entry["prereq_info"] as? [String: Any] else { continue }
            if let p = prereq["path"] as? String, !p.isEmpty { out.append(p) }
            if let ids = prereq["ids"] as? [String] { out += ids }
        }
        return out
    }

    // MARK: - What a container has

    /// The versions Microsoft's installer recorded in the container, with its DLLs in place.
    static func installed(in container: Container) -> [Arch: Version] {
        installed(prefix: container.prefixURL)
    }

    static func installed(prefix: URL) -> [Arch: Version] {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return [:] }
        var out: [Arch: Version] = [:]
        for arch in Arch.allCases {
            let suffix = "microsoft\\\\visualstudio\\\\14.0\\\\vc\\\\runtimes\\\\\(arch.rawValue)]"
            guard let version = keyVersion(text, endingWith: suffix) else { continue }
            let dll = prefix.appendingPathComponent("drive_c").appendingPathComponent(arch.systemFolder).appendingPathComponent("vcruntime140.dll")
            if isMicrosoftsOwn(dll) { out[arch] = version }
        }
        return out
    }

    /// Major/Minor/Bld/Rbld of the first key whose name ends with `suffix` (either registry view).
    static func keyVersion(_ systemReg: String, endingWith suffix: String) -> Version? {
        var inKey = false, found = false
        var v = Version()
        var installed = false
        for line in systemReg.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                if inKey { break }
                let name = line.prefix { $0 != " " }.lowercased()
                inKey = name.hasSuffix(suffix)
                found = found || inKey
                continue
            }
            guard inKey, line.hasPrefix("\""), let eq = line.firstIndex(of: "=") else { continue }
            let name = line[line.index(after: line.startIndex)..<eq].dropLast()
            let value = line[line.index(after: eq)...]
            guard value.hasPrefix("dword:"), let n = Int(value.dropFirst(6), radix: 16) else { continue }
            switch name {
            case "Major": v.major = n
            case "Minor": v.minor = n
            case "Bld": v.build = n
            case "Rbld": v.rebuild = n
            case "Installed": installed = n == 1
            default: break
            }
        }
        return found && installed && v.major >= 14 ? v : nil
    }

    /// A real DLL rather than Wine's stand-in (Wine marks its own "Wine builtin DLL").
    static func isMicrosoftsOwn(_ dll: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: dll), let head = try? h.read(upToCount: 0x80) else { return false }
        try? h.close()
        return head.count == 0x80 && head.prefix(2) == Data("MZ".utf8)
            && head.range(of: Data("Wine builtin DLL".utf8)) == nil && head.range(of: Data("Wine placeholder DLL".utf8)) == nil
    }

    /// What's missing for a game in a container: the arches still to install.
    static func missing(_ need: Need, in container: Container) -> Set<Arch> {
        let have = installed(in: container)
        return need.arches.filter { arch in (have[arch].map { $0 < need.minimum } ?? true) }
    }

    /// Whether launches into the container load Microsoft's DLLs ahead of Wine's: once installed,
    /// unless a game that ran before stopped starting with them (see `useWinesOwn`).
    static func loadsMicrosofts(_ container: Container) -> Bool {
        !installed(in: container).isEmpty && !FileManager.default.fileExists(atPath: winesOwnMark(container).path)
    }

    static func winesOwnMark(_ container: Container) -> URL { container.prefixURL.appendingPathComponent(".anvil-vcruntime-wine") }
    /// When Anvil installed it there, for telling a game that ran before it from one that never has.
    static func installedMark(_ container: Container) -> URL { container.prefixURL.appendingPathComponent(".anvil-vcruntime-at") }
    static func installedAt(_ container: Container) -> Date? {
        (try? String(contentsOf: installedMark(container), encoding: .utf8)).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Back to Wine's own DLLs for this container's games; Microsoft's stay installed for the key.
    static func useWinesOwn(_ container: Container, why: String) {
        try? Data(why.utf8).write(to: winesOwnMark(container))
    }

    /// Whether a session of `title` before `installedAt` drew frames: the game ran without it.
    static func drewBefore(title: String, installedAt: Date, logs: [URL] = [Launcher.gameLogURL,
                           Launcher.gameLogURL.deletingPathExtension().appendingPathExtension("old.log")]) -> Bool {
        let iso = ISO8601DateFormatter()
        for url in logs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var inSession = false
            for line in text.split(separator: "\n") {
                if line.hasPrefix("=== ") {
                    inSession = false
                    guard line.hasPrefix("=== \(title) — ") else { continue }
                    let rest = line.dropFirst("=== \(title) — ".count)
                    if let date = rest.split(separator: " ").first.flatMap({ iso.date(from: String($0)) }), date < installedAt { inSession = true }
                    continue
                }
                if inSession, line.contains("[anvil] displayed ") || line.contains("-> ACTIVE") { return true }
            }
        }
        return false
    }

    // MARK: - Microsoft's installer

    struct Installer {
        var url: URL
        var version: Version
        var source: String
    }

    enum InstallError: LocalizedError {
        case noInstaller(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .noInstaller(let why): "No Microsoft Visual C++ installer to run: \(why)"
            case .failed(let why): "Microsoft's Visual C++ installer didn't finish: \(why)"
            }
        }
    }

    static var cacheFolder: URL { RuntimeManager.support.appendingPathComponent("Cache/Redist", isDirectory: true) }

    /// The program's file version, from its version resource (VS_FIXEDFILEINFO).
    static func fileVersion(_ url: URL) -> Version? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let signature = Data([0xBD, 0x04, 0xEF, 0xFE])
        guard let r = d.range(of: signature), r.lowerBound + 16 <= d.count else { return nil }
        func u32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(d[d.startIndex + o + $1]) << (8 * $1) } }
        let ms = u32(r.lowerBound + 8), ls = u32(r.lowerBound + 12)
        return Version(major: ms >> 16, minor: ms & 0xFFFF, build: ls >> 16, rebuild: ls & 0xFFFF)
    }

    /// Microsoft's, signed and whole: the only installer Anvil runs.
    static func verified(_ url: URL) -> (ok: Bool, why: String) {
        switch Authenticode.check(url) {
        case .failure(let f): return (false, "\(f)")
        case .success(let s):
            guard s.digestMatches else { return (false, "it has been changed since it was signed") }
            guard s.signatureValid else { return (false, "its signature doesn't check out") }
            guard s.trusted else { return (false, "its certificate isn't one Anvil trusts (\(s.trustDetail ?? "unknown"))") }
            guard s.organization == "Microsoft Corporation" else { return (false, "it was signed by \(s.signer), not Microsoft") }
            return (true, "signed by Microsoft Corporation")
        }
    }

    /// Installers already on this Mac: one a game shipped, or one Anvil downloaded before.
    static func localInstallers(_ arch: Arch, games: [Game]) -> [URL] {
        var urls: [URL] = []
        if let cached = try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil) {
            urls += cached.filter { $0.lastPathComponent.lowercased() == "vc_redist.\(arch.rawValue).exe" }
        }
        let epic = EpicAccount.configDir.appendingPathComponent("installed.json")
        if let data = try? Data(contentsOf: epic),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for entry in root.values {
                guard let base = entry["install_path"] as? String,
                      let path = (entry["prereq_info"] as? [String: Any])?["path"] as? String, isRedistName(path) else { continue }
                urls.append(URL(fileURLWithPath: base).appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/")))
            }
        }
        for game in games { urls += shippedInstallers(in: game.executableURL.deletingLastPathComponent()) }
        let fm = FileManager.default
        return urls.filter { url in
            fm.fileExists(atPath: url.path) && url.lastPathComponent.lowercased().hasPrefix("vc_redist")
                && (VCRuntime.arch(ofInstallerNamed: url.lastPathComponent) ?? .x64) == arch
        }
    }

    /// The newest verified installer: Microsoft's current one, downloaded once and kept, else the
    /// best one already on this Mac. Never one that doesn't check out as Microsoft's.
    static func installer(_ arch: Arch, minimum: Version, games: [Game], online: Bool,
                          download: (URL) async throws -> URL = Self.download) async -> Result<Installer, InstallError> {
        var candidates: [Installer] = []
        var turnedAway: [String] = []
        let fm = FileManager.default
        let cached = cacheFolder.appendingPathComponent("VC_redist.\(arch.rawValue).exe")
        let age = (try? fm.attributesOfItem(atPath: cached.path)[.modificationDate] as? Date).map { -$0.timeIntervalSinceNow } ?? .infinity
        // Microsoft's current one, at most once every 90 days.
        if online, age > 90 * 86_400 {
            do {
                let fetched = try await download(arch.downloadURL)
                let check = verified(fetched)
                if check.ok, let v = fileVersion(fetched), v.major == 14 {
                    try? fm.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
                    try? fm.removeItem(at: cached)
                    try fm.moveItem(at: fetched, to: cached)
                } else {
                    turnedAway.append("the download from Microsoft (\(check.why))")
                    try? fm.removeItem(at: fetched)
                }
            } catch {
                turnedAway.append("the download from Microsoft (\(error.localizedDescription))")
            }
        }
        var seen = Set<String>()
        for url in [cached] + localInstallers(arch, games: games) where fm.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL.path).inserted {
            let check = verified(url)
            guard check.ok else { turnedAway.append("\(url.lastPathComponent) at \(url.deletingLastPathComponent().path) (\(check.why))"); continue }
            guard let v = fileVersion(url), v.major == 14 else { continue }
            candidates.append(Installer(url: url, version: v,
                                        source: url.path.hasPrefix(cacheFolder.path) ? "from Microsoft" : "shipped with a game, at \(url.path)"))
        }
        if let best = candidates.filter({ $0.version >= minimum }).max(by: { $0.version < $1.version }) { return .success(best) }
        if let best = candidates.max(by: { $0.version < $1.version }) {
            return .failure(.noInstaller("the newest on this Mac is \(best.version), and the game needs \(minimum) or later" + (online ? "" : "; connect to the internet so Anvil can get Microsoft's current one")))
        }
        return .failure(.noInstaller((online ? "" : "this Mac is offline and no game here ships one. ") + (turnedAway.isEmpty ? "none was found" : "turned away: " + turnedAway.joined(separator: "; "))))
    }

    static func download(_ url: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("vc_redist-\(UUID().uuidString).exe")
        try FileManager.default.moveItem(at: temp, to: dest)
        guard (response as? HTTPURLResponse)?.statusCode == 200, SteamSupport.looksLikeInstaller(dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw InstallError.noInstaller("Microsoft's site didn't send an installer")
        }
        return dest
    }

    /// Run Microsoft's installer in the container, quietly, and check what it left.
    static func install(_ installer: Installer, arch: Arch, into container: Container, runtime: Runtime) async -> Result<Version, InstallError> {
        let env = ["WINEPREFIX": container.prefixURL.path, "WINEDEBUG": "-all"]
        let wine = runtime.wine64
        let code = await Task.detached(priority: .userInitiated) {
            Launcher.runHelper(wine, [installer.url.path, "/install", "/quiet", "/norestart"], environment: env, timeout: 300)
        }.value
        await Launcher.waitForWineserver(container: container, runtime: runtime, timeout: 30)
        // 0 done; 3010 done, wants a restart Wine doesn't need; 1638 a newer one was there already.
        if let v = installed(in: container)[arch] { return .success(v) }
        return .failure(.failed(code.map { "it exited with code \($0) and the runtime isn't there" } ?? "it was still running after five minutes"))
    }
}

// MARK: - Putting it in

/// Puts Microsoft's runtime into the containers whose games need it: before a launch, and for
/// every game in the library when nothing is running (CheckUp).
@MainActor
final class VCRuntimeSetup: ObservableObject {
    static let shared = VCRuntimeSetup()
    @Published private(set) var status: String?
    private var running: [UUID: Task<String?, Never>] = [:]

    /// Before a launch: install what the game needs into its container, once. Returns the log
    /// line, or nil when there was nothing to do.
    func prepare(_ game: Game, container: Container, runtime: Runtime, progress: @escaping (String) -> Void) async -> String? {
        guard let need = VCRuntime.need(for: game) else { return nil }
        let missing = VCRuntime.missing(need, in: container)
        guard !missing.isEmpty else { return nil }
        if let task = running[container.id] { return await task.value }
        let games = Library.shared.games
        let online = Connectivity.isOnlineNow
        let task = Task { () -> String? in
            var lines: [String] = []
            for arch in missing.sorted() {
                progress("Installing Microsoft's Visual C++ Runtime (\(arch.rawValue)) into “\(container.name)” — once, for \(game.title)…")
                self.status = "Installing Microsoft's Visual C++ Runtime into “\(container.name)”…"
                switch await VCRuntime.installer(arch, minimum: need.minimum, games: games, online: online) {
                case .failure(let error):
                    lines.append("visual c++ runtime: \(game.title) needs it (\(need.reasons.joined(separator: "; "))), but \(error.localizedDescription)")
                case .success(let installer):
                    let started = Date()
                    switch await VCRuntime.install(installer, arch: arch, into: container, runtime: runtime) {
                    case .success(let v):
                        try? FileManager.default.removeItem(at: VCRuntime.winesOwnMark(container))
                        try? Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: VCRuntime.installedMark(container))
                        lines.append(String(format: "visual c++ runtime: Microsoft's %@ (%@) installed into “%@” in %.0f s, from %@ — for %@: %@; its DLLs load ahead of Wine's own there from now on",
                                            v.description, arch.rawValue, container.name, Date().timeIntervalSince(started),
                                            installer.source, game.title, need.reasons.joined(separator: "; ")))
                    case .failure(let error):
                        lines.append("visual c++ runtime: \(game.title) — \(error.localizedDescription)")
                    }
                }
            }
            self.status = nil
            return lines.joined(separator: "\n  ")
        }
        running[container.id] = task
        let line = await task.value
        running[container.id] = nil
        return line
    }

    /// Every game in the library that needs it and doesn't have it — for the check-up, when no
    /// game is running. Returns what was done, a line each.
    func ensureAll() async -> [String] {
        var done: [String] = []
        for container in Library.shared.containers {
            let games = Library.shared.games(in: container).filter { $0.exists && !SteamSupport.isSteamClient($0) }
            guard let game = games.first(where: { g in VCRuntime.need(for: g).map { !VCRuntime.missing($0, in: container).isEmpty } ?? false }),
                  !Library.shared.games(in: container).contains(where: { Launcher.shared.isBusy($0) }),
                  Launcher.shared.launching == nil,
                  let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) ?? RuntimeManager.shared.defaultRuntime
            else { continue }
            if let line = await prepare(game, container: container, runtime: runtime, progress: { _ in }) {
                AnvilLog.write(line)
                done.append(line)
            }
        }
        return done
    }
}
