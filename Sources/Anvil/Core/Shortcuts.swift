import AppKit
import CoreServices

/// A small app per game in ~/Applications/Anvil Games, so a game starts from Spotlight,
/// Launchpad or the Dock like any other app.
///
/// Each one is a bundle whose program is a two-line script that opens
/// anvil://play/<game id> in Anvil — the approach Steam takes for its own Mac
/// shortcuts. Everything a launch needs (the prefix, Epic sign-in, controller mapping,
/// Game Mode) stays in Anvil, so a shortcut never goes stale when a setting changes.
/// It carries the game's artwork as its icon, and is renamed or redrawn when the game
/// is renamed or its artwork changes.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    /// Games that have a shortcut, and where it is.
    @Published private(set) var shortcuts: [UUID: URL] = [:]

    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Anvil Games", isDirectory: true)
    }

    private init() { rescan() }

    private struct Record {
        let url: URL
        let title: String
        let artworkStamp: String
        let format: Int
    }

    /// Bumped when the bundle layout changes, so older shortcuts are rebuilt.
    private static let format = 1

    private func records() -> [UUID: Record] {
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return [:] }
        var out: [UUID: Record] = [:]
        for app in apps where app.pathExtension == "app" {
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let raw = info["AnvilGameID"] as? String, let id = UUID(uuidString: raw) else { continue }
            out[id] = Record(url: app, title: info["AnvilTitle"] as? String ?? "",
                             artworkStamp: info["AnvilArtworkStamp"] as? String ?? "",
                             format: info["AnvilShortcutFormat"] as? Int ?? 0)
        }
        return out
    }

    func rescan() {
        shortcuts = records().mapValues(\.url)
    }

    func has(_ game: Game) -> Bool { shortcuts[game.id] != nil }

    /// Make the game's shortcut, replacing any it had.
    @discardableResult
    func create(for game: Game) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let old = records()[game.id]?.url { try? fm.removeItem(at: old) }

        let app = uniqueLocation(for: game.title)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        do {
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)

            // open -b asks for Anvil by its identifier, wherever it has been moved; the
            // plain open is the fallback if Launch Services has not seen it yet.
            let link = QuickLaunch.url(for: game).absoluteString
            let script = """
            #!/bin/sh
            # Starts \(game.title.replacingOccurrences(of: "\n", with: " ")) through Anvil. Made by Anvil; safe to delete.
            /usr/bin/open -b dev.anvil.launcher "\(link)" 2>/dev/null || exec /usr/bin/open "\(link)"

            """
            let program = macOS.appendingPathComponent("launch")
            try Data(script.utf8).write(to: program)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)

            try GameIcon.icns(for: game).write(to: resources.appendingPathComponent("GameIcon.icns"))

            let info: [String: Any] = [
                "CFBundleName": game.title,
                "CFBundleDisplayName": game.title,
                "CFBundleIdentifier": "dev.anvil.shortcut." + game.id.uuidString.lowercased(),
                "CFBundleExecutable": "launch",
                "CFBundleIconFile": "GameIcon",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "CFBundleInfoDictionaryVersion": "6.0",
                "LSMinimumSystemVersion": "14.0",
                "LSApplicationCategoryType": "public.app-category.games",
                // The script hands over to Anvil and exits; it needs no Dock icon of its own.
                "LSUIElement": true,
                "AnvilGameID": game.id.uuidString,
                "AnvilURL": link,
                "AnvilTitle": game.title,
                "AnvilArtworkStamp": Self.artworkStamp(for: game),
                "AnvilShortcutFormat": Self.format,
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        } catch {
            try? fm.removeItem(at: app)
            throw error
        }

        // Known to Spotlight, Launchpad and the Dock straight away, with its icon.
        _ = LSRegisterURL(app as CFURL, true)
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        AnvilLog.write("shortcut: made \(app.path) for \(game.title)")
        shortcuts[game.id] = app
        return app
    }

    func remove(for game: Game) {
        guard let url = records()[game.id]?.url else { return }
        try? FileManager.default.removeItem(at: url)
        AnvilLog.write("shortcut: removed \(url.lastPathComponent)")
        shortcuts[game.id] = nil
    }

    /// Rebuild a game's shortcut if its name or artwork no longer matches the game.
    func refresh(for game: Game) {
        guard let record = records()[game.id] else { return }
        guard record.title != game.title
                || record.artworkStamp != Self.artworkStamp(for: game)
                || record.format != Self.format else { return }
        _ = try? create(for: game)
    }

    /// At startup: bring every shortcut up to date with its game. A shortcut whose game
    /// is gone is left alone — the library may simply have failed to load — and says
    /// so when it is opened.
    func refreshAll(_ games: [Game]) {
        let found = records()
        for game in games where found[game.id] != nil { refresh(for: game) }
        rescan()
    }

    // MARK: Helpers

    private func uniqueLocation(for title: String) -> URL {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "Game" + name }
        var candidate = Self.folder.appendingPathComponent(name + ".app", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = Self.folder.appendingPathComponent("\(name) \(n).app", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Changes whenever the game's artwork file does.
    private static func artworkStamp(for game: Game) -> String {
        let url = ArtworkStore.directory.appendingPathComponent("\(game.id.uuidString).png")
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "none" }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(date))"
    }
}

/// A game's icon, drawn from its artwork on Apple's icon grid.
enum GameIcon {

    /// A complete .icns: PNG images from 16 to 1024 pixels.
    @MainActor
    static func icns(for game: Game) -> Data {
        let master = render(ArtworkStore.shared.image(for: game), pixels: 1024)
        // Type codes for the PNG-carrying icon sizes, from Apple's icns format.
        let entries: [(String, Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
                                        ("ic07", 128), ("ic08", 256), ("ic13", 256), ("ic09", 512),
                                        ("ic14", 512), ("ic10", 1024)]
        var body = Data()
        for (type, pixels) in entries {
            guard let png = pixels == 1024 ? master : scaled(master, to: pixels) else { continue }
            body.append(contentsOf: Array(type.utf8))
            body.append(bigEndian(UInt32(png.count + 8)))
            body.append(png)
        }
        var out = Data("icns".utf8)
        out.append(bigEndian(UInt32(body.count + 8)))
        out.append(body)
        return out
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func bitmap(_ pixels: Int) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = NSSize(width: pixels, height: pixels)
        return rep
    }

    private static func draw(into rep: NSBitmapImageRep, _ body: (CGFloat) -> Void) -> Data? {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        body(CGFloat(rep.pixelsWide))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The artwork, cropped to fill a rounded square with Apple's margins and corner
    /// radius, over a soft shadow. Without artwork, a gradient and a controller.
    static func render(_ art: NSImage?, pixels: Int) -> Data? {
        guard let rep = bitmap(pixels) else { return nil }
        return draw(into: rep) { s in
            let inset = s * 100 / 1024
            let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            let radius = rect.width * 0.2237
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
            shadow.shadowBlurRadius = s * 0.025
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if let art, art.size.width > 0, art.size.height > 0 {
                // Fill, centred: key art is usually wide, and its middle is the subject.
                let scale = max(rect.width / art.size.width, rect.height / art.size.height)
                let w = art.size.width * scale, h = art.size.height * scale
                art.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                         from: .zero, operation: .copy, fraction: 1)
            } else {
                let gradient = NSGradient(colors: [NSColor.controlAccentColor.blended(withFraction: 0.1, of: .white) ?? .systemBlue,
                                                   NSColor.systemPurple.blended(withFraction: 0.35, of: .black) ?? .systemPurple])
                gradient?.draw(in: rect, angle: -60)
                let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.38, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let size = symbol.size
                    symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                           width: size.width, height: size.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()

            // A hairline edge, so dark artwork keeps its outline on a dark Dock.
            NSColor.white.withAlphaComponent(0.14).setStroke()
            shape.lineWidth = max(1, s / 400)
            shape.stroke()
        }
    }

    private static func scaled(_ png: Data?, to pixels: Int) -> Data? {
        guard let png, let source = NSImage(data: png), let rep = bitmap(pixels) else { return nil }
        return draw(into: rep) { s in
            source.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .copy, fraction: 1)
        }
    }
}
