import Foundation

/// Runs the engine's own SDL with a launch's exact controller settings and reports
/// what the game will see — without launching the game.
///
/// "Anvil lists the pad" and "the game reads the pad" are different questions, and
/// after the macOS 27 update the answers differed: Anvil saw the PowerA, SDL saw
/// nothing. The only way to find that was to ask SDL itself, so this is that question
/// with a button on it.
@MainActor
final class ControllerTester: ObservableObject {

    @Published private(set) var lines: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var verdict: String?

    static let shared = ControllerTester()
    private var process: Process?

    func run(profile: ControllerProfile, runtime: Runtime?, seconds: Int = 8) {
        guard !isRunning else { return }
        lines = []; verdict = nil

        guard let probe = Bundle.main.resourceURL?.appendingPathComponent("anvil-sdl-probe"),
              FileManager.default.isExecutableFile(atPath: probe.path) else {
            verdict = "The tester is missing from this build of Anvil."
            return
        }
        guard let runtime = runtime ?? RuntimeManager.shared.defaultRuntime else {
            verdict = "No engine is installed, so there is no SDL to ask."
            return
        }
        let sdl = runtime.root.appendingPathComponent("lib/libSDL2-2.0.0.dylib")
        guard FileManager.default.fileExists(atPath: sdl.path) else {
            verdict = "\(runtime.displayName) has no libSDL2, so it cannot read controllers at all."
            return
        }
        if SystemInfo.needsRosetta(sdl) && !SystemInfo.rosettaWorks() {
            verdict = "Rosetta isn't installed, so the engine's SDL cannot run. Run: softwareupdate --install-rosetta --agree-to-license"
            return
        }

        ControllerManager.shared.refresh()
        var env = ProcessInfo.processInfo.environment
        env.merge(ControllerManager.shared.environment(
            profile: profile, controllers: ControllerManager.shared.controllers,
            sdlLibrary: sdl)) { _, new in new }
        env["PROBE_SECONDS"] = String(seconds)

        let p = Process()
        p.executableURL = probe
        p.arguments = [sdl.path]
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.lines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finish()
            }
        }
        isRunning = true
        process = p
        do { try p.run() } catch {
            isRunning = false
            verdict = "The tester could not start: \(error.localizedDescription)"
        }
    }

    private func finish() {
        isRunning = false
        process = nil
        let text = lines.joined(separator: "\n")
        let count = lines.first(where: { $0.contains("joysticks=") })
            .flatMap { $0.components(separatedBy: "joysticks=").last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let events = lines.first(where: { $0.contains("input events seen:") })
            .flatMap { $0.components(separatedBy: ":").last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        if count == 0 {
            verdict = "The game's SDL sees no controller. Check it is plugged in or paired, then test again."
        } else if !text.contains("gamepad=1") {
            verdict = "SDL sees a controller but not as a gamepad, so games won't treat it as one."
        } else if let events, events > 0 {
            verdict = "Working: the game's SDL sees your controller as a gamepad and read \(events) inputs."
        } else {
            verdict = "The game's SDL sees your controller as a gamepad, but no presses arrived during the test."
        }
    }
}
