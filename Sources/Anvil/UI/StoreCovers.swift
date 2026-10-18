import AppKit
import SwiftUI

/// Store covers for the Stores pages, kept small on disk.
///
/// Epic's page loaded every cover from Epic at full size each time it opened — 209 of them on
/// 10 October, often a megabyte or more each, shown 40 points wide. Now each is fetched once,
/// at the size the page shows it (Epic's image server resizes on request), scaled down here
/// and kept in Anvil's cache, so the page shows them at once from then on.
enum CoverCache {
    nonisolated static var directory: URL { DiskCache.directory.appendingPathComponent("Covers", isDirectory: true) }
    /// Pixels kept: twice the page's 40 × 54 points, with room to spare.
    nonisolated static let size = CGSize(width: 120, height: 160)

    private static let memory = NSCache<NSString, NSImage>()

    nonisolated static func file(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".jpg")
    }

    /// Epic's image server sends a smaller copy when asked; anything else is fetched as it is.
    nonisolated static func sized(_ url: URL) -> URL {
        guard (url.host ?? "").hasSuffix("epicgames.com"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        items += [URLQueryItem(name: "h", value: "320"), URLQueryItem(name: "w", value: "240"),
                  URLQueryItem(name: "resize", value: "1"), URLQueryItem(name: "quality", value: "medium")]
        parts.queryItems = items
        return parts.url ?? url
    }

    @MainActor static func cached(_ key: String) -> NSImage? {
        if let image = memory.object(forKey: key as NSString) { return image }
        guard let image = NSImage(contentsOf: file(for: key)) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    /// The cover for `key`: kept, or read from `local`, or fetched from `remote` — kept either way.
    static func load(_ key: String, local: URL?, remote: URL?) async -> NSImage? {
        if let image = await MainActor.run(body: { cached(key) }) { return image }
        let data: Data? = await Task.detached(priority: .utility) {
            if let local, let d = try? Data(contentsOf: local) { return d }
            guard let remote else { return nil }
            var request = URLRequest(url: sized(remote))
            request.timeoutInterval = 20
            guard let (d, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return d
        }.value
        guard let data, let small = await Task.detached(priority: .utility, operation: { thumbnail(data) }).value else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? small.write(to: file(for: key))
        return await MainActor.run {
            guard let image = NSImage(data: small) else { return nil }
            memory.setObject(image, forKey: key as NSString)
            return image
        }
    }

    /// The image filled to `size`, centred, as JPEG.
    nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = max(size.width / w, size.height / h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2, width: w * scale, height: h * scale))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

/// A store cover: from Anvil's cache at once, else loaded and kept.
struct CachedCover: View {
    let key: String
    var local: URL? = nil
    var remote: URL? = nil
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 40, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: key) {
            if image == nil { image = CoverCache.cached(key) }
            if image == nil { image = await CoverCache.load(key, local: local, remote: remote) }
        }
    }
}
