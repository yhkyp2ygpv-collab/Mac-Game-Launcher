import Foundation
import AppKit

/// Finds cover art for a game automatically.
///
/// Launchers already cache the storefront metadata for everything they installed,
/// including artwork URLs, so the match is made locally from files on disk rather
/// than by searching the internet for a title string. Only the image itself is
/// fetched, and only when a local match was found.
@MainActor
final class ArtworkFetcher: ObservableObject {
    static let shared = ArtworkFetcher()
    private init() {}

    @Published var status: String?
    /// Games whose art waits for the connection to come back.
    private var waiting = Set<UUID>()

    struct Candidate {
        var title: String
        var url: URL
        /// Epic's own naming: DieselGameBox is the wide key art, DieselGameBoxTall
        /// the portrait cover. Wide suits Anvil's tiles.
        var kind: String
        var width: Int
        var height: Int
    }

    /// Every metadata store a launcher on this Mac might have written.
    private static var metadataDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            // Anvil's own Epic connection first: every game it installed, or signed in with.
            EpicAccount.configDir.appendingPathComponent("metadata"),
            home.appendingPathComponent("Library/Application Support/Mythic/Epic/metadata"),
            home.appendingPathComponent("Library/Application Support/heroic/legendaryConfig/legendary/metadata"),
            home.appendingPathComponent("Library/Application Support/heroic/gog_store/metadata"),
        ]
    }

    /// Look for artwork belonging to this title in the launchers' own caches.
    func findLocalArtwork(for title: String) -> Candidate? {
        let fm = FileManager.default
        let wanted = Self.normalise(title)
        var best: Candidate?

        for directory in Self.metadataDirectories {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let appTitle = (root["app_title"] as? String)
                    ?? ((root["metadata"] as? [String: Any])?["title"] as? String)
                    ?? (root["title"] as? String) ?? ""
                guard !appTitle.isEmpty, Self.normalise(appTitle) == wanted else { continue }

                let images = ((root["metadata"] as? [String: Any])?["keyImages"] as? [[String: Any]])
                    ?? (root["keyImages"] as? [[String: Any]]) ?? []
                for image in images {
                    guard let kind = image["type"] as? String,
                          let link = image["url"] as? String,
                          let url = URL(string: link) else { continue }
                    let candidate = Candidate(title: appTitle, url: url, kind: kind,
                                              width: image["width"] as? Int ?? 0,
                                              height: image["height"] as? Int ?? 0)
                    // Prefer the wide key art; it matches the tile's shape.
                    if kind == "DieselGameBox" { return candidate }
                    if best == nil { best = candidate }
                }
            }
        }
        return best
    }

    /// Titles differ in punctuation between stores — "LEGO® Star Wars™: The
    /// Skywalker Saga" against "LEGO Star Wars The Skywalker Saga" — so matching is
    /// done on letters and digits alone.
    private static func normalise(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// Fetch and install artwork for a game. Returns false when nothing was found,
    /// which is not an error — plenty of games have no cached metadata.
    @discardableResult
    func fetchArtwork(for game: Game) async -> Bool {
        // Something local beside the executable always wins: no network, and it is
        // the art the game itself shipped.
        if let bundled = ArtworkStore.shared.findBundledArtwork(near: game.executablePath) {
            _ = try? ArtworkStore.shared.setArtwork(from: bundled, for: game)
            status = "Used artwork found beside \(game.title)."
            return true
        }

        guard let candidate = findLocalArtwork(for: game.title) else { return false }

        // Offline: the art is fetched as soon as the connection comes back.
        guard Connectivity.shared.isOnline else {
            let id = game.id
            if waiting.insert(id).inserted {
                Connectivity.shared.whenOnline { [weak self] in
                    Task { @MainActor in
                        self?.waiting.remove(id)
                        guard let game = Library.shared.games.first(where: { $0.id == id }),
                              ArtworkStore.shared.image(for: game) == nil else { return }
                        await self?.fetchArtwork(for: game)
                    }
                }
            }
            status = "Cover art for \(game.title) will be fetched when you're back online."
            return false
        }

        do {
            var request = URLRequest(url: candidate.url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return false }
            try ArtworkStore.shared.setArtwork(image, for: game)
            status = "Cover art added for \(game.title)."
            return true
        } catch {
            status = "Couldn't fetch artwork for \(game.title): \(error.localizedDescription)"
            return false
        }
    }

    /// Fill in artwork for every game that has none: a store's own app gets Anvil's tile for it
    /// (StoreArt), a Steam game the cover Steam downloaded, the rest from the launchers' caches.
    func fetchMissing(in games: [Game]) async -> Int {
        var added = 0
        StoreArt.ensureAll()
        for game in games where ArtworkStore.shared.image(for: game) == nil {
            if let appID = game.steamAppID, let c = Library.shared.container(id: game.containerID),
               let art = SteamSupport.cachedArtwork(appID: appID, in: c),
               (try? ArtworkStore.shared.setArtwork(from: art, for: game)) != nil {
                added += 1
                continue
            }
            if await fetchArtwork(for: game) { added += 1 }
        }
        status = added == 0 ? "No new artwork found." : "Added artwork for \(added) game\(added == 1 ? "" : "s")."
        return added
    }
}
