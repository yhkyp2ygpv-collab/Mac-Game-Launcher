import AppKit
import SwiftUI

/// Light and dark app icons.
///
/// A macOS `.appiconset` has no appearance variants — `actool` compiles the dark
/// images but leaves them unassigned, since per-appearance icons are an Icon
/// Composer `.icon` feature rather than an asset-catalog one. What does work is
/// setting the Dock icon at runtime, so Anvil watches the effective appearance and
/// swaps it. The Finder icon stays the light variant, which is what `.icns` holds.
@MainActor
final class AppIconController {
    static let shared = AppIconController()

    private var observation: NSKeyValueObservation?
    private var light: NSImage?
    private var dark: NSImage?

    private init() {}

    func start() {
        guard let resources = Bundle.main.resourceURL else { return }
        light = NSImage(contentsOf: resources.appendingPathComponent("AnvilIconLight.png"))
        dark  = NSImage(contentsOf: resources.appendingPathComponent("AnvilIconDark.png"))
        apply()

        // effectiveAppearance changes when the user switches theme, and also when
        // macOS flips automatically at sunset.
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.apply() }
        }
    }

    private func apply() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let image = isDark ? dark : light else { return }
        NSApp.applicationIconImage = image
    }
}
