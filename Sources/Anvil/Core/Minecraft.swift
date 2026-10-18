import AppKit
import Foundation

/// Minecraft on this Mac, from its own page.
///
/// Java Edition is a Mac game: Mojang's own Minecraft Launcher runs it natively, and Anvil finds
/// and opens it. Bedrock Edition's PC version can't run here: it is a Microsoft Store app, which
/// arrives encrypted and needs Microsoft's Gaming Services — neither works under Wine, and getting
/// around either would be getting around the store's protection, which Anvil never does. 0.43.0
/// installed the open-source launcher for Bedrock's Android version instead; the player wanted the
/// PC version, not that one (11 October), and it was taken out in 0.43.1. Since 0.56 the page plays the
/// PC version itself, the genuine one, in Windows 11 for Arm through VMware Fusion (MinecraftPC).
@MainActor
final class Minecraft: ObservableObject {
    static let shared = Minecraft()

    @Published private(set) var javaApp: URL?
    @Published private(set) var javaVersion: String?
    @Published private(set) var openError: String?

    nonisolated static let javaBundleID = "com.mojang.minecraftlauncher"
    nonisolated static let javaDownloadPage = URL(string: "https://www.minecraft.net/download")!

    private init() { refresh() }

    func refresh() {
        javaApp = Self.findJava()
        javaVersion = javaApp.flatMap(Self.version(of:))
    }

    nonisolated static func findJava() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: javaBundleID) { return url }
        let standard = URL(fileURLWithPath: "/Applications/Minecraft.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: standard.path) ? standard : nil
    }

    /// The app's own version, or nil where it doesn't really say ("0", nothing).
    nonisolated static func version(of app: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let v = info[key] as? String, v.contains("."), v.contains(where: { $0 != "0" && $0 != "." }) { return v }
        }
        return nil
    }

    /// Mojang's launcher, or minecraft.net's download page when it isn't on this Mac.
    func openJava() {
        openError = nil
        guard let app = javaApp else { NSWorkspace.shared.open(Self.javaDownloadPage); return }
        AnvilLog.write("minecraft: opening Minecraft Launcher (Java Edition)\(javaVersion.map { " " + $0 } ?? "")")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            AnvilLog.write("minecraft: Minecraft Launcher didn't open — \(error.localizedDescription)")
            Task { @MainActor in Minecraft.shared.openError = "Minecraft Launcher didn't open: \(error.localizedDescription)" }
        }
    }
}
