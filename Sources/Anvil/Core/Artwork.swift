import Foundation
import AppKit

/// Cover art for library tiles.
///
/// Images are copied into Anvil's own store rather than referenced in place, so
/// artwork does not vanish when the original is moved, renamed, or was sitting in a
/// Downloads folder that has since been cleared.
@MainActor
final class ArtworkStore: ObservableObject {
    static let shared = ArtworkStore()

    nonisolated static var directory: URL {
        RuntimeManager.support.appendingPathComponent("Artwork", isDirectory: true)
    }

    private var cache: [UUID: NSImage] = [:]
    /// Tile-sized copies. The stored artwork is up to 2048 pixels wide, and a tile is
    /// 190 points: drawing the full image into every tile on every redraw is work the
    /// grid does not need.
    private var thumbnails: [UUID: NSImage] = [:]
    private var banners: [UUID: NSImage] = [:]
    private let fm = FileManager.default

    private init() {
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    func url(for game: Game) -> URL {
        Self.directory.appendingPathComponent("\(game.id.uuidString).png")
    }

    func image(for game: Game) -> NSImage? {
        if let cached = cache[game.id] { return cached }
        let path = url(for: game)
        guard fm.fileExists(atPath: path.path), let image = NSImage(contentsOf: path) else { return nil }
        cache[game.id] = image
        return image
    }

    /// The artwork at tile size (480 pixels wide at most), made once per image.
    func thumbnail(for game: Game) -> NSImage? {
        scaled(for: game, width: 480, cache: &thumbnails)
    }

    /// Wide enough for the library's banner on a Retina display, without drawing a
    /// ten-megabyte original into it on every frame.
    func banner(for game: Game) -> NSImage? {
        scaled(for: game, width: 1800, cache: &banners)
    }

    private func scaled(for game: Game, width: CGFloat, cache: inout [UUID: NSImage]) -> NSImage? {
        if let hit = cache[game.id] { return hit }
        guard let full = image(for: game) else { return nil }
        let pixels = full.representations.map { CGFloat($0.pixelsWide) }.max() ?? full.size.width
        guard pixels > width, full.size.width > 0 else { cache[game.id] = full; return full }
        let target = NSSize(width: width, height: (width * full.size.height / full.size.width).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return full }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        full.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let thumb = NSImage(size: target)
        thumb.addRepresentation(rep)
        cache[game.id] = thumb
        return thumb
    }

    /// Store artwork for a game, normalising to PNG so any source format works.
    @discardableResult
    func setArtwork(from source: URL, for game: Game) throws -> NSImage {
        guard let image = NSImage(contentsOf: source) else { throw ArtworkError.unreadable }
        try store(image, for: game)
        return image
    }

    func setArtwork(_ image: NSImage, for game: Game) throws {
        try store(image, for: game)
    }

    private func store(_ image: NSImage, for game: Game) throws {
        // Downscale anything enormous: a 4K promo image would sit in memory for a
        // tile drawn at 190pt.
        let maxDimension: CGFloat = 1024
        let target: NSImage
        if max(image.size.width, image.size.height) > maxDimension {
            let scale = maxDimension / max(image.size.width, image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            target = NSImage(size: size)
            target.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            target.unlockFocus()
        } else {
            target = image
        }

        guard let tiff = target.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw ArtworkError.unreadable
        }
        try png.write(to: url(for: game), options: .atomic)
        cache[game.id] = target
        thumbnails[game.id] = nil; banners[game.id] = nil
        objectWillChange.send()
        ShortcutStore.shared.refresh(for: game)
    }

    func removeArtwork(for game: Game) {
        try? fm.removeItem(at: url(for: game))
        cache[game.id] = nil
        thumbnails[game.id] = nil; banners[game.id] = nil
        objectWillChange.send()
        ShortcutStore.shared.refresh(for: game)
    }

    /// Look for cover art the game already ships with. Many installers drop one
    /// beside the executable, which saves the user hunting for an image.
    func findBundledArtwork(near executablePath: String) -> URL? {
        let dir = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let names = ["cover", "boxart", "header", "capsule", "logo", "icon", "banner",
                     "splash", "background"]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        let images = entries.filter { ["png", "jpg", "jpeg", "bmp"].contains($0.pathExtension.lowercased()) }
        // A recognised name first; otherwise the largest image, which is usually art
        // rather than a UI element.
        if let named = images.first(where: { url in
            names.contains { url.deletingPathExtension().lastPathComponent.lowercased().contains($0) }
        }) { return named }
        return images.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }

    enum ArtworkError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file isn't an image Anvil can read." }
    }
}
