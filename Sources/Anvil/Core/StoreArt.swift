import AppKit

/// Cover art for a store's own app in the library — Steam, run in a container of its own —
/// drawn by Anvil. A store carries no cover of itself among its files (the one image Steam calls
/// its "library logo" is a sample: Google Chrome's), and a store's logo is its maker's, so the
/// tile is Anvil's: the store's colours, the symbol the sidebar uses for it, and its name.
enum StoreArt {
    enum Store {
        case steam, epic

        var name: String { self == .steam ? "Steam" : "Epic Games" }
        var symbol: String { self == .steam ? "cloud.fill" : "bag.fill" }
        var colors: [NSColor] {
            switch self {
            case .steam: [NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
                          NSColor(srgbRed: 0.11, green: 0.16, blue: 0.22, alpha: 1),
                          NSColor(srgbRed: 0.16, green: 0.28, blue: 0.37, alpha: 1)]
            case .epic: [NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1),
                         NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                         NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1)]
            }
        }
    }

    /// Which store's app a library entry is, if it is one.
    static func store(of game: Game) -> Store? {
        if SteamSupport.isSteamClient(game) { return .steam }
        if game.executableURL.lastPathComponent.caseInsensitiveCompare("EpicGamesLauncher.exe") == .orderedSame { return .epic }
        return nil
    }

    /// The tile, 1280 × 720: a diagonal gradient, the symbol and the name.
    static func image(for store: Store) -> NSImage {
        let size = NSSize(width: 1280, height: 720)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: store.colors)?.draw(in: rect, angle: 35)
            // A soft light behind the symbol.
            let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])
            glow?.draw(fromCenter: NSPoint(x: rect.midX, y: rect.midY + 60), radius: 0,
                       toCenter: NSPoint(x: rect.midX, y: rect.midY + 60), radius: 420, options: [])
            let config = NSImage.SymbolConfiguration(pointSize: 230, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: store.symbol, accessibilityDescription: store.name)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 + 70, width: s.width, height: s.height))
            }
            let title = NSAttributedString(string: store.name, attributes: [
                .font: NSFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            let t = title.size()
            title.draw(at: NSPoint(x: rect.midX - t.width / 2, y: rect.midY - 230))
            return true
        }
    }

    /// Every store's app in the library gets its tile, once — art set by hand is left alone.
    @MainActor
    static func ensureAll() {
        for game in Library.shared.games {
            guard let store = store(of: game), ArtworkStore.shared.image(for: game) == nil else { continue }
            if (try? ArtworkStore.shared.setArtwork(image(for: store), for: game)) != nil {
                AnvilLog.write("artwork: \(game.title) — Anvil's \(store.name) tile")
            }
        }
    }
}
