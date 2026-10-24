import AppKit
import Foundation

/// Hands the keyboard, the mouse and the controller to the game, and takes them back
/// when it exits.
///
/// This is not a nicety. macOS will not let a process launched by the active
/// application steal focus from it, so a game started from Anvil opens *behind*
/// Anvil's window. Exclusive fullscreen used to paper over that by changing the
/// display mode, which forces the window forward — but that is exactly the call that
/// crashed the game, so Anvil now asks for borderless fullscreen, and a borderless
/// window comes up politely and stays where it was put.
///
/// Two things follow from a game running unfocused, and both were reported:
///
///  * It looks like the Play button did nothing. The game is running, rendering, and
///    completely invisible behind the launcher.
///  * Controller input stops. An unfocused Unity window ignores the gamepad, which is
///    why switching to another app and back "fixed" it — that hands focus back.
///
/// So Anvil steps aside on launch and returns when the game is gone.
@MainActor
enum GameFocus {

    private static var hidden = false

    /// Get out of the way, then bring the game forward once it has a window.
    static func handOff(to game: Game, startedAt: Date) {
        // Resigning active is what allows anything else to come forward at all.
        // Guarded because the headless self-test runs this path with no application
        // object at all, and a crash there would hide the very failure it exists to
        // find.
        guard NSApplication.shared.isRunning else { return }
        NSApp.hide(nil)
        hidden = true

        let wanted = game.executableURL.deletingPathExtension().lastPathComponent

        Task { @MainActor in
            // A Windows game takes a few seconds to get as far as a window, and the
            // process that owns it is Wine's, not the one Anvil spawned — so it is
            // found by name and start time rather than by pid. Looked for at once as
            // well, so Show on a game that is already up is immediate.
            for attempt in 0..<61 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                if let app = candidate(named: wanted, after: startedAt) {
                    app.activate()
                    return
                }
            }
        }
    }

    /// Anvil in front with its window hidden while a game runs — nothing of Anvil's to see or use — hands the front back
    /// to the game. On 23 October, three seconds after the lid of a MacBook was opened on Hogwarts Legacy, Anvil came to
    /// the front this way, and the game, on screen and being played, was held to 30 and then 10 fps as if behind another
    /// app for 23 minutes, until it was switched away from and back to. Opened from the Dock or with ⌘-Tab, Anvil's
    /// window shows — that's left alone.
    static func watchActivation() {
        guard NSApplication.shared.isRunning else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard hidden, !Launcher.shared.sessions.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard hidden, NSApp.isActive, NSApp.isHidden, let session = Launcher.shared.sessions.first else { return }
                let game = session.game
                let wanted = game.executableURL.deletingPathExtension().lastPathComponent
                guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "").hasPrefix("dev.anvil.game.") })
                        ?? candidate(named: wanted, after: .distantPast) else { return }
                NSApp.yieldActivation(to: app)
                app.activate()
                AnvilLog.write("focus: Anvil came to the front with its window hidden — the front handed back to \(game.title)")
            }
        }
    }

    /// Come back once the game has exited.
    static func reclaim() {
        guard hidden, NSApplication.shared.isRunning else { return }
        hidden = false
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    private static func candidate(named wanted: String, after: Date) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        // Wine renames its process after the executable, so the game usually appears
        // under its own name.
        if let byName = apps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(wanted)
        }) { return byName }

        // Otherwise take a Wine process that started after this launch did, which
        // rules out a wineserver left over from an earlier session.
        return apps.first {
            let name = ($0.localizedName ?? "").lowercased()
            guard name.contains("wine") else { return false }
            guard let launched = $0.launchDate else { return false }
            return launched >= after.addingTimeInterval(-2)
        }
    }
}
