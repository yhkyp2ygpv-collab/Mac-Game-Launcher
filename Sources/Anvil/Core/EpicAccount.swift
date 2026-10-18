import Foundation
import CryptoKit

/// Anvil's own connection to Epic Games, so no other launcher has to be installed.
///
/// Games from Epic are signed in by legendary, the open-source Epic client Mythic and
/// Heroic are built on. Anvil used to borrow both from Mythic: its copy of legendary,
/// and its sign-in and game list. Now it keeps its own —
/// - legendary itself, downloaded from the legendary project's own releases on GitHub
///   and checked against the SHA-256 GitHub publishes for it;
/// - its own sign-in and game list in Application Support/Anvil/Epic, brought over once
///   from Mythic (or Heroic) so nobody has to sign in again, and signed in afresh here
///   when needed.
///
/// Epic replaces the sign-in each time it is used, so once Anvil uses its own copy the
/// one Mythic kept stops working — Mythic asks to sign in again if it is ever opened.
@MainActor
final class EpicAccount: ObservableObject {
    static let shared = EpicAccount()

    /// What is happening, for the page; nil when nothing is.
    @Published private(set) var status: String?
    @Published private(set) var version: String?
    /// Epic turned the sign-in down (it lasts a few weeks unused): the page asks for a new one.
    @Published var signInExpired = false
    /// The account's display name, as legendary shows it — kept so the page says whose games
    /// these are without asking Epic each time.
    @Published private(set) var accountName: String? {
        didSet { UserDefaults.standard.set(accountName, forKey: "epic.accountName") }
    }

    private init() {
        version = Self.installedVersion
        accountName = UserDefaults.standard.string(forKey: "epic.accountName")
    }

    /// The display name, from `legendary status --offline --json`: legendary's own summary,
    /// read from its sign-in without going to Epic. Nothing else of the sign-in is read.
    func readAccountName() async {
        guard Self.isSignedIn, let tool = Self.legendary ?? EpicLink.otherLegendary() else { return }
        let (status, output) = await Self.run(tool, ["status", "--offline", "--json"], timeout: 60)
        guard status == 0, let name = Self.accountName(fromStatus: output) else { return }
        accountName = name
    }

    /// "account" from legendary's status JSON; nil for its "<not logged in>".
    nonisolated static func accountName(fromStatus output: String) -> String? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
              let name = json["account"] as? String, !name.isEmpty, !name.hasPrefix("<") else { return nil }
        return name
    }

    /// Signed out of Epic in Anvil: its sign-in removed from this Mac. Installed games stay
    /// installed, and ask for a sign-in again before they next start online.
    func signOut() {
        let fm = FileManager.default
        for name in ["user.json", "user.json.sealed"] {
            try? fm.removeItem(at: Self.configDir.appendingPathComponent(name))
        }
        accountName = nil
        signInExpired = false
        EpicLibrary.shared.forgetList()
        EpicOfflineStart.forget()
        AnvilLog.write("epic: signed out of Epic in Anvil")
    }

    // MARK: Where things live

    nonisolated static var configDir: URL { RuntimeManager.support.appendingPathComponent("Epic", isDirectory: true) }
    nonisolated static var toolsDir: URL {
        RuntimeManager.support.appendingPathComponent("Tools/legendary", isDirectory: true)
    }
    nonisolated static var binary: URL { toolsDir.appendingPathComponent("legendary") }

    /// Anvil's own legendary, once installed.
    nonisolated static var legendary: URL? {
        FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }
    nonisolated static var installedVersion: String? {
        (try? String(contentsOf: toolsDir.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Signed in here, or brought over from another launcher.
    nonisolated static var isSignedIn: Bool {
        EpicVault.hasSignIn
    }

    /// Where Mythic and Heroic keep legendary's sign-in and game list.
    nonisolated static var launcherConfigs: [(launcher: String, dir: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [("Mythic", home.appendingPathComponent("Library/Application Support/Mythic/Epic")),
                ("Heroic", home.appendingPathComponent("Library/Application Support/heroic/legendaryConfig/legendary"))]
    }

    // MARK: At launch

    /// legendary installed or brought up to date, and the sign-in brought over. Nothing
    /// here needs the player; offline it waits for the next start.
    func prepare() async {
        importSignInIfNeeded()
        await installLegendaryIfNeeded()
    }

    /// Mythic's (or Heroic's) sign-in and game list, copied into Anvil's own once. The
    /// files are cloned, never read here: the sign-in in them is Epic's and stays so.
    func importSignInIfNeeded() {
        guard !Self.isSignedIn else { return }
        let fm = FileManager.default
        guard let source = Self.launcherConfigs.first(where: {
            fm.fileExists(atPath: $0.dir.appendingPathComponent("user.json").path)
        }) else { return }
        let dest = Self.configDir
        // Anvil's own game list is there but its sign-in isn't — set aside because the key
        // that sealed it is gone (3 October): only the sign-in is brought in again.
        if fm.fileExists(atPath: dest.appendingPathComponent("installed.json").path) {
            let target = dest.appendingPathComponent("user.json")
            guard !fm.fileExists(atPath: target.path) else { return }
            guard SaveGuard.copy(source.dir.appendingPathComponent("user.json"), to: target) != .failed else { return }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            EpicVault.sealLeftover()
            AnvilLog.write("epic: \(source.launcher)'s Epic sign-in brought into Anvil again — Anvil had none it could open")
            return
        }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".Epic-importing")
        try? fm.removeItem(at: staging)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", source.dir.path, staging.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { try? fm.removeItem(at: staging); return }
        // An empty folder left from before is replaced; anything else in the way stays.
        if let rest = try? fm.contentsOfDirectory(atPath: dest.path), rest.allSatisfy({ $0.hasPrefix(".") }) {
            try? fm.removeItem(at: dest)
        }
        do { try fm.moveItem(at: staging, to: dest) } catch { try? fm.removeItem(at: staging); return }
        // Encrypted from here on: the plain copy brought over is sealed and removed.
        EpicVault.sealLeftover()
        UserDefaults.standard.set(source.launcher, forKey: "epic.importedFrom")
        AnvilLog.write("epic: \(source.launcher)'s Epic sign-in and game list brought into Anvil — Anvil signs its games in by itself now")
    }

    /// The legendary project's newest release for this Mac, when it differs from the one
    /// installed. Checked at most once a day.
    func installLegendaryIfNeeded(force: Bool = false) async {
        let key = "epic.legendaryCheckedAt"
        if !force, Self.legendary != nil,
           let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        guard Connectivity.isOnlineNow else { return }
        status = Self.legendary == nil ? "Installing Epic support…" : nil
        defer { status = nil }
        do {
            let release = try await Self.latestRelease()
            UserDefaults.standard.set(Date(), forKey: key)
            if release.tag == Self.installedVersion, Self.legendary != nil { return }
            try await Self.install(release)
            version = release.tag
            AnvilLog.write("epic: legendary \(release.tag) installed from the legendary project's release, SHA-256 checked")
        } catch {
            AnvilLog.write("epic: legendary not installed — \(error.localizedDescription)"
                           + (Self.legendary == nil ? "; the other launchers' copy is used meanwhile" : "; the installed one is kept"))
        }
    }

    // MARK: Signing in

    /// Sign in with the code Epic's web sign-in shows. The code is handed to legendary as
    /// an argument and written nowhere else.
    func signIn(code raw: String) async throws {
        let code = Self.authorizationCode(from: raw)
        guard !code.isEmpty else { throw Failure.noCode }
        if Self.legendary == nil { await installLegendaryIfNeeded(force: true) }
        guard let legendary = Self.legendary ?? EpicLink.otherLegendary() else { throw Failure.noLegendary }
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        status = "Signing in to Epic…"
        defer { status = nil }
        let (status, output) = await Self.run(legendary, ["auth", "--code", code, "--disable-webview"], timeout: 60)
        guard status == 0, Self.isSignedIn else {
            let why = output.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("rror") }
                .map(String.init)?.replacingOccurrences(of: code, with: "…")
            throw Failure.rejected(why ?? "legendary exited with status \(status)")
        }
        // Games installed through another launcher stay known: its game list comes along
        // if this Mac has one and Anvil has none yet.
        Self.bringGameListIfMissing()
        // The account may be another one: offline starts wait for its own first online start.
        EpicOfflineStart.forget()
        signInExpired = false
        let before = accountName
        accountName = nil
        await readAccountName()
        AnvilLog.write("epic: signed in to Epic in Anvil" + (accountName.map { " as \($0)" } ?? ""))
        // Its games, listed now — another account's list isn't kept.
        if before != accountName { EpicLibrary.shared.forgetList() }
        Task { await EpicLibrary.shared.refresh(); await EpicLibrary.shared.importInstalled() }
    }

    // MARK: Epic's sign-in page, in Anvil

    /// The page Epic's sign-in ends on: its redirect, with the one-time code for legendary's client.
    nonisolated static func isRedirectPage(_ url: URL) -> Bool {
        (url.host ?? "").hasSuffix("epicgames.com") && url.path.hasSuffix("/id/api/redirect")
    }

    /// The code in the launcher URL some of Epic's sign-ins end on: …/launcher/authorized?code=…
    nonisolated static func launcherCode(in url: URL) -> String? {
        guard url.path.contains("/launcher/authorized"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return code
    }

    /// The code from the text of Epic's redirect page; nil when it has none (not signed in yet).
    nonisolated static func code(fromRedirect text: String) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = json["authorizationCode"] as? String, !code.isEmpty { return code }
        if let redirect = json["redirectUrl"] as? String, let url = URL(string: redirect) { return launcherCode(in: url) }
        return nil
    }

    /// The code alone, whether the whole JSON the sign-in page shows was pasted or just it.
    nonisolated static func authorizationCode(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["authorizationCode"] as? String { return code }
        if let r = trimmed.range(of: #""authorizationCode"\s*:\s*"([^"]+)""#, options: .regularExpression) {
            let match = trimmed[r]
            if let q = match.range(of: #":\s*""#, options: .regularExpression) {
                return String(match[q.upperBound...].dropLast())
            }
        }
        return trimmed.filter { $0.isLetter || $0.isNumber }
    }

    private nonisolated static func bringGameListIfMissing() {
        let fm = FileManager.default
        let installed = configDir.appendingPathComponent("installed.json")
        guard !fm.fileExists(atPath: installed.path) else { return }
        for source in launcherConfigs {
            let theirs = source.dir.appendingPathComponent("installed.json")
            guard fm.fileExists(atPath: theirs.path) else { continue }
            try? fm.copyItem(at: theirs, to: installed)
            let metadata = source.dir.appendingPathComponent("metadata")
            if fm.fileExists(atPath: metadata.path) {
                try? fm.copyItem(at: metadata, to: configDir.appendingPathComponent("metadata"))
            }
            return
        }
    }

    // MARK: Installing legendary

    struct Release {
        var tag: String
        var asset: URL
        var sha256: String
        var size: Int
    }

    enum Failure: LocalizedError {
        case noRelease, noDigest, badDownload, checksumMismatch, wontRun(String), noCode, noLegendary, rejected(String)
        var errorDescription: String? {
            switch self {
            case .noRelease: "the legendary project's latest release has no build for this Mac"
            case .noDigest: "GitHub published no checksum for the build, so it wasn't installed"
            case .badDownload: "the download didn't complete"
            case .checksumMismatch: "the download didn't match the checksum GitHub published, so it was discarded"
            case .wontRun(let why): "the downloaded legendary doesn't run here (\(why))"
            case .noCode: "Paste the code the Epic sign-in page shows."
            case .noLegendary: "Epic support isn't installed yet, and needs a connection to install."
            case .rejected(let why): "Epic didn't accept the code: \(why). Codes work once and only for a few minutes — open the sign-in page again for a new one."
            }
        }
    }

    private nonisolated static var assetName: String {
        #if arch(arm64)
        "legendary_macOS_arm64"
        #else
        "legendary_macOS_x64"
        #endif
    }

    nonisolated static func latestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/legendary-gl/legendary/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Anvil", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseRelease(data)
    }

    /// A release as GitHub's API describes it: the build for this Mac and its checksum.
    nonisolated static func parseRelease(_ data: Data) throws -> Release {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString),
              url.scheme == "https" else { throw Failure.noRelease }
        guard let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"), digest.count == 71 else { throw Failure.noDigest }
        return Release(tag: tag, asset: url, sha256: String(digest.dropFirst(7)).lowercased(), size: asset["size"] as? Int ?? 0)
    }

    nonisolated static func install(_ release: Release) async throws {
        let (temp, response) = try await URLSession.shared.download(from: release.asset)
        guard (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else { throw Failure.badDownload }
        defer { try? FileManager.default.removeItem(at: temp) }
        try await installDownloaded(temp, release: release)
    }

    /// The downloaded build checked against GitHub's checksum, tried, and put in place.
    nonisolated static func installDownloaded(_ temp: URL, release: Release) async throws {
        let fm = FileManager.default
        guard try sha256(of: temp) == release.sha256 else { throw Failure.checksumMismatch }

        try fm.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        let staged = toolsDir.appendingPathComponent(".legendary-\(release.tag)")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: temp, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // It must run before it replaces anything. A build without a signature the Mac
        // accepts gets an ad-hoc one — its contents are already checked above.
        var (status, output) = await run(staged, ["--version"], timeout: 60)
        if status != 0 && !signatureVerifies(staged) {
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", staged.path]
            try? sign.run()
            sign.waitUntilExit()
            (status, output) = await run(staged, ["--version"], timeout: 60)
        }
        guard status == 0 else {
            try? fm.removeItem(at: staged)
            throw Failure.wontRun(output.split(separator: "\n").last.map(String.init) ?? "status \(status)")
        }
        try? fm.removeItem(at: binary)
        try fm.moveItem(at: staged, to: binary)
        try release.tag.write(to: toolsDir.appendingPathComponent("version"), atomically: false, encoding: .utf8)
    }

    private nonisolated static func signatureVerifies(_ url: URL) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", url.path]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do { try check.run() } catch { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Run legendary with Anvil's own config, returning its status and what it printed.
    nonisolated static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The sign-in is decrypted for this run only, and sealed again after it.
                EpicVault.open()
                defer { EpicVault.close() }
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["LEGENDARY_CONFIG_PATH"] = configDir.path
                for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("WINE") || key.hasPrefix("ANVIL_") {
                    env.removeValue(forKey: key)
                }
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                var output = Data()
                let reader = DispatchGroup()
                reader.enter()
                DispatchQueue.global().async { output = pipe.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
                do { try process.run() } catch {
                    try? pipe.fileHandleForWriting.close()
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                if reader.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    continuation.resume(returning: (-2, "timed out"))
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(data: output, encoding: .utf8) ?? ""))
            }
        }
    }
}
