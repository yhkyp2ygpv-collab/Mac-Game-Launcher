import Foundation
import AppKit

/// Runs the launch path exactly as the Play button does, then reports.
enum LaunchSelfTest {
    static func run() {
        let out: (String) -> Void = { print("[launch-test] \($0)"); AnvilLog.write("launch-test: \($0)") }

        MainActor.assumeIsolated {
            let library = Library.shared
            let runtimes = RuntimeManager.shared

            out("games=\(library.games.count) containers=\(library.containers.count) runtimes=\(runtimes.runtimes.count)")
            for r in runtimes.runtimes {
                out("  runtime \(r.id) usable=\(r.isUsable) d3dmetal=\(r.d3dMetalVersion ?? "none")")
            }
            guard let game = library.games.first else { out("NO GAMES"); exit(1) }
            guard let container = library.container(id: game.containerID) ?? library.containers.first else {
                out("NO CONTAINER for \(game.title)"); exit(1)
            }
            guard let runtime = runtimes.runtime(id: container.runtimeID) ?? runtimes.defaultRuntime else {
                out("NO RUNTIME for container \(container.name) (wants \(container.runtimeID))"); exit(1)
            }
            out("game=\(game.title) exists=\(game.exists) container=\(container.name) runtime=\(runtime.displayName)")

            Task { @MainActor in
                do {
                    let session = try await Launcher.shared.prepareAndLaunch(
                        game: game, container: container, runtime: runtime)
                    out("LAUNCHED pid=\(session.process.processIdentifier)")
                    try? await Task.sleep(for: .seconds(25))
                    let alive = session.process.isRunning
                    out("after 25s: running=\(alive)")
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    out("frontmost=\(front)")
                    session.process.terminate()
                    exit(alive ? 0 : 2)
                } catch {
                    out("THREW: \(error.localizedDescription)")
                    exit(3)
                }
            }
            RunLoop.main.run()
        }
    }
}
