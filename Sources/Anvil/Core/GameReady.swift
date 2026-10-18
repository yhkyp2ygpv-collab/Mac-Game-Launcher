import AppKit
import UserNotifications

/// Telling the player a game has finished loading.
///
/// LEGO Star Wars takes about 35–40 seconds from Play to its first scene on this Mac, online
/// or off — its own logos and loading, which nothing outside the game can skip — and a load
/// looks exactly like a game stuck. Since 0.25.0 a game that can carries on loading behind
/// other apps, so the player can leave it; this says when to come back. The end of a load is
/// what LoadTime measures: the first stretch with the GPU working, in a game whose sessions
/// always reach one.
@MainActor
final class GameReady: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GameReady()

    private var asked = false

    /// Called once at start, so a click on a notice brings the game forward.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// The game is ready. A notice only when it isn't already the app in front.
    func announce(_ game: Game, after seconds: Double, inFront: Bool) {
        guard !inFront else { return }
        say("\(game.title) is ready", "It finished loading in \(LoadTime.text(seconds)). Click to play.",
            id: "ready-\(game.id.uuidString)", gameID: game.id)
    }

    /// A notice, asking once for leave to show them.
    func say(_ title: String, _ body: String, id: String, gameID: UUID? = nil) {
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let gameID { content.userInfo = ["gameID": gameID.uuidString] }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        if asked {
            post()
        } else {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { Task { @MainActor in post() } }
            }
        }
    }

    // A click on the notice: the game, in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["gameID"] as? String
        Task { @MainActor in
            if let id, let session = Launcher.shared.sessions.first(where: { $0.game.id.uuidString == id }) {
                GameFocus.handOff(to: session.game, startedAt: session.startedAt)
            }
            completionHandler()
        }
    }

    // Shown even with Anvil in front: the Now Playing bar says it too, but the sound helps.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Whether the app in front is this game: by its process, or by the name Wine gives it.
    static func inFront(_ session: Launcher.Session) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if app.processIdentifier == session.process.processIdentifier { return true }
        let exe = session.game.executableURL.deletingPathExtension().lastPathComponent.lowercased()
        return (app.localizedName ?? "").lowercased().contains(exe)
    }
}
