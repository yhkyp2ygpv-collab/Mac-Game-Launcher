import Foundation

/// Finds games already installed by other launchers.
///
/// Mythic and Heroic both drive Epic's `legendary` backend and share its
/// `installed.json`, which carries the real title, install path, executable and
/// expected size — far better than guessing from a folder scan. Other sources fall
/// back to walking the prefix's Program Files.
@MainActor
final class GameImporter: ObservableObject {

    struct DiscoveredGame: Identifiable, Hashable {
        var id: String { executablePath }
        var title: String
        var executablePath: String
        var installPath: String
        var source: String
        /// Size the launcher recorded at install time, when it knows one.
        var expectedBytes: Int64?
        var artworkPath: String?

        var exists: Bool { FileManager.default.fileExists(atPath: executablePath) }
        var sizeDescription: String {
            guard let expectedBytes else { return "—" }
            return ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
        }
    }

    @Published private(set) var discovered: [DiscoveredGame] = []
    @Published var scanning = false
    @Published var status: String?

    static let shared = GameImporter()
    private let fm = FileManager.default
    private init() {}

    func scan() {
        scanning = true
        defer { scanning = false }

        var found: [DiscoveredGame] = []
        let home = fm.homeDirectoryForCurrentUser

        // Epic-backed launchers, via legendary's manifest — Anvil's own first.
        found += legendaryGames(at: EpicAccount.configDir.appendingPathComponent("installed.json"), source: "Epic (Anvil)")
        found += legendaryGames(
            at: home.appendingPathComponent("Library/Application Support/Mythic/Epic/installed.json"),
            source: "Mythic")
        found += legendaryGames(
            at: home.appendingPathComponent("Library/Application Support/heroic/legendaryConfig/legendary/installed.json"),
            source: "Heroic")
        found += legendaryGames(
            at: home.appendingPathComponent("Library/Application Support/heroic/gog_store/installed.json"),
            source: "Heroic (GOG)")

        // Anything installed inside another launcher's prefix.
        found += prefixGames()

        // Deduplicate by executable; the same game can be registered twice.
        var seen = Set<String>()
        discovered = found.filter { seen.insert($0.executablePath.lowercased()).inserted }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func legendaryGames(at url: URL, source: String) -> [DiscoveredGame] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        return root.values.compactMap { value in
            guard let entry = value as? [String: Any],
                  let title = entry["title"] as? String,
                  let installPath = entry["install_path"] as? String else { return nil }

            // Some entries are DLC or add-ons with no executable of their own.
            let executable = (entry["executable"] as? String) ?? ""
            guard !executable.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

            let exePath = installPath + "/" + executable
            let size = (entry["install_size"] as? NSNumber)?.int64Value

            return DiscoveredGame(title: title,
                                  executablePath: exePath,
                                  installPath: installPath,
                                  source: source,
                                  expectedBytes: size,
                                  artworkPath: ArtworkStore.shared
                                      .findBundledArtwork(near: exePath)?.path)
        }
    }

    /// Games installed inside another launcher's Wine prefix, which legendary knows
    /// nothing about — anything installed by hand, or from a storefront's own client.
    private func prefixGames() -> [DiscoveredGame] {
        var found: [DiscoveredGame] = []
        for prefix in SaveTransfer.shared.prefixes {
            for programFiles in ["Program Files", "Program Files (x86)"] {
                let root = prefix.driveC.appendingPathComponent(programFiles)
                guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                else { continue }
                for entry in entries where entry.hasDirectoryPath {
                    // Skip the runtimes every prefix has.
                    let name = entry.lastPathComponent
                    if ["Common Files", "Internet Explorer", "Windows NT", "Windows Media Player"]
                        .contains(name) { continue }
                    guard let exe = Library.shared.discoverExecutables(in: entry).first else { continue }
                    found.append(DiscoveredGame(title: name,
                                                executablePath: exe.path,
                                                installPath: entry.path,
                                                source: "\(prefix.launcher) prefix",
                                                expectedBytes: nil,
                                                artworkPath: ArtworkStore.shared
                                                    .findBundledArtwork(near: exe.path)?.path))
                }
            }
        }
        return found
    }

    struct SyncResult {
        var added: [String] = []
        var repaired: [String] = []
        var missing: [String] = []

        var isEmpty: Bool { added.isEmpty && repaired.isEmpty && missing.isEmpty }
        var summary: String {
            if isEmpty { return "Everything is already up to date." }
            var parts: [String] = []
            if !added.isEmpty { parts.append("\(added.count) added") }
            if !repaired.isEmpty { parts.append("\(repaired.count) path\(repaired.count == 1 ? "" : "s") repaired") }
            if !missing.isEmpty { parts.append("\(missing.count) no longer installed") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Bring the library back in line with what the other launchers currently have.
    ///
    /// Three things drift: a game gets installed elsewhere and is missing here, a
    /// game is moved or updated and its recorded path goes stale, or a game is
    /// uninstalled and its entry is left pointing at nothing. Sync handles all three,
    /// and never deletes anything — a missing game is reported, not removed, because
    /// an unplugged external drive looks exactly like an uninstall.
    @discardableResult
    func sync(into container: Container) -> SyncResult {
        scan()
        var result = SyncResult()
        let library = Library.shared

        for found in discovered where found.exists {
            // Match on executable first, then on title, so a game that moved is
            // recognised rather than duplicated.
            if let existing = library.games.first(where: {
                $0.executablePath == found.executablePath
            }) {
                _ = existing
                continue
            }
            if var stale = library.games.first(where: {
                $0.title.compare(found.title, options: .caseInsensitive) == .orderedSame
                    || URL(fileURLWithPath: $0.executablePath).lastPathComponent
                        == URL(fileURLWithPath: found.executablePath).lastPathComponent
            }) {
                if !stale.exists {
                    stale.executablePath = found.executablePath
                    stale.title = found.title
                    library.update(stale)
                    result.repaired.append(found.title)
                }
                continue
            }
            `import`(found, into: container)
            result.added.append(found.title)
        }

        for game in library.games where !game.exists {
            let stillKnown = discovered.contains {
                $0.title.compare(game.title, options: .caseInsensitive) == .orderedSame
            }
            if !stillKnown { result.missing.append(game.title) }
        }

        status = result.summary
        return result
    }

    /// Add a discovered game to a container, bringing its artwork with it.
    func `import`(_ game: DiscoveredGame, into container: Container) {
        let art = game.artworkPath
        Task {
            // Installed inside another launcher's Wine setup: a container of its own, made
            // from that setup (see Library.addGameKeepingItsSetup).
            let added = await Library.shared.addGameKeepingItsSetup(
                title: game.title,
                executable: URL(fileURLWithPath: game.executablePath),
                otherwise: container)
            // Art shipped beside the executable takes precedence; otherwise addGame's
            // own lookup covers it.
            if let art {
                _ = try? ArtworkStore.shared.setArtwork(from: URL(fileURLWithPath: art), for: added)
            }
        }
    }
}
