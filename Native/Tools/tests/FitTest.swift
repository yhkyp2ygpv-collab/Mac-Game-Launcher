import Foundation
import AppKit

/// 0.19.2's fixes on copies: LEGO's display fitted to the screen, Engine 3.0's Game Mode copy
/// naming the binary the game runs as, and hand-set upscaling back to automatic.
/// CFFIXED_USER_HOME=…/fit/home fittest <PCCONFIG.TXT> <Engine 3.0 folder> <library.json> <Snapshots/index.json> <Engine 2.6.1 folder>
@main struct FitHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/fit/home/") else { print("refusing"); exit(2) }
        let args = CommandLine.arguments
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        _ = NSApplication.shared

        // Library: a copy of the real one.
        try? fm.createDirectory(at: RuntimeManager.support, withIntermediateDirectories: true)
        try? fm.removeItem(at: RuntimeManager.support.appendingPathComponent("library.json"))
        try! fm.copyItem(at: URL(fileURLWithPath: args[3]), to: RuntimeManager.support.appendingPathComponent("library.json"))
        Library.shared.load()
        guard var lego = Library.shared.games.first(where: { $0.title.contains("LEGO") }),
              let c = Library.shared.container(id: lego.containerID) else { print("no LEGO"); exit(3) }
        print("LEGO upscaling before:", lego.upscalerOverride.map { "frameGen \($0.frameGeneration), \($0.quality), forced \($0.forceInjection)" } ?? "automatic")

        // 1. Display.
        let config = c.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT")
        try? fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: config)
        try! fm.copyItem(at: URL(fileURLWithPath: args[1]), to: config)
        // As 0.30 left it — told 16:9 (1) — whatever the real file holds now.
        try! GameTuning.replacing(["AspectRatio": "1"], in: try! String(contentsOf: config, encoding: .utf8))
            .write(to: config, atomically: false, encoding: .utf8)
        // The library copy may still hold 0.30's default; 0.31 puts every game back on the screen's
        // own shape once at start-up (Housekeeping.trueShapeOnce), and a new game starts there.
        check(Game(title: "x", executablePath: "/x.exe", containerID: UUID()).pictureShape == .fill, "a game's picture keeps the screen's own shape by default")
        lego.pictureShape = .fill
        // This sandbox reaches no display; the app asks the real one. The 14" MacBook Pro's:
        let size = GameTuning.screenSize(for: c) ?? (width: 1512, height: 982)
        let line = GameTuning.fitDisplay(lego, in: c, screen: size)
        print("launch log:", line ?? "nothing")
        let v = GameTuning.values(in: try! String(contentsOf: config, encoding: .utf8))
        let screen = CGSize(width: size.width, height: size.height)
        print("screen \(Int(screen.width))×\(Int(screen.height)) points; config now:", ["ScreenWidth", "ScreenHeight", "WindowWidth", "WindowHeight", "Windowed", "BorderlessWindow", "FullscreenWindow", "ScreenRefreshRate", "AspectRatio", "ShadowQuality"].map { "\($0)=\(v[$0] ?? "-")" }.joined(separator: " "))
        check(v["Windowed"] == "0" && v["BorderlessWindow"] == "0", "fullscreen, as on Engine 2.6.1")
        check(v["ScreenWidth"] == String(Int(screen.width)) && v["ScreenHeight"] == String(Int(screen.height)), "at exactly the screen's size")
        // Against the file as it was, not fixed values: the game and Auto-Tune change its other
        // settings between sessions (ShadowQuality went from 1 to 3 on 1 October).
        let original = GameTuning.values(in: try! String(contentsOf: URL(fileURLWithPath: args[1]), encoding: .utf8))
        let display: Set<String> = ["ScreenWidth", "ScreenHeight", "WindowWidth", "WindowHeight", "WindowLeft", "WindowTop",
                                    "Windowed", "BorderlessWindow", "FullscreenWindow", "ScreenRefreshRate", "AspectRatio"]
        let touched = original.keys.filter { !display.contains($0) && v[$0] != original[$0] }
        check(touched.isEmpty, "nothing else in the file touched\(touched.isEmpty ? "" : ": " + touched.joined(separator: ", "))")
        // 7 October: told 16:9 on the MacBook's 3:2 screen, the picture looked distorted — the value
        // is the monitor's shape for the game. Back to the screen's own.
        let narrow = Double(size.width) / Double(size.height) < 1.70
        check(v["AspectRatio"] == "3", "0.30's 16:9 undone: the screen's own shape (AspectRatio \(v["AspectRatio"] ?? "-"))")
        check(line?.contains("16:9") != true, "the launch log mentions no 16:9")
        check(GameTuning.fitDisplay(lego, in: c, screen: size) == nil, "already fitted: nothing written the next time")
        lego.pictureShape = .whole
        let chosen = GameTuning.fitDisplay(lego, in: c, screen: size)
        check(GameTuning.values(in: try! String(contentsOf: config, encoding: .utf8))["AspectRatio"] == (narrow ? "1" : "3"), "the 16:9 layout when chosen, on a screen narrower than 16:9")
        check(!narrow || chosen?.contains("squeeze") == true, "and the launch log says it can squeeze the picture")
        _ = GameTuning.fitDisplay(lego, in: c, screen: (width: 1920, height: 1080))
        check(GameTuning.values(in: try! String(contentsOf: config, encoding: .utf8))["AspectRatio"] == "3", "on a 16:9 screen the whole picture is the screen's own shape")
        _ = GameTuning.fitDisplay(lego, in: c, screen: (width: 3440, height: 1440))
        check(GameTuning.values(in: try! String(contentsOf: config, encoding: .utf8))["AspectRatio"] == "3", "on an ultrawide too: the game widens its view itself")
        _ = GameTuning.fitDisplay(lego, in: c, screen: size)
        lego.graphicsTuning = .gameDefault
        try! fm.removeItem(at: config); try! fm.copyItem(at: URL(fileURLWithPath: args[1]), to: config)
        check(GameTuning.fitDisplay(lego, in: c, screen: size) == nil, "not touched when the player chose the game's own settings")
        lego.graphicsTuning = .automatic

        // 2. Game Mode copy of Engine 3.0.
        let engine = RuntimeManager.runtimesDir.appendingPathComponent("mythic-engine-3.0.0")
        try? fm.createDirectory(at: RuntimeManager.runtimesDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: engine)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp"); p.arguments = ["-Rc", args[2], engine.path]; try! p.run(); p.waitUntilExit()
        RuntimeManager.shared.discover()
        let r = RuntimeManager.shared.runtime(id: "mythic-engine-3.0.0")!
        do {
            let copy = try GameModeEngine.prepared(for: r)
            let info = NSDictionary(contentsOf: copy.root.appendingPathComponent("Info.plist"))
            print("Game Mode copy executable:", info?["CFBundleExecutable"] ?? "-", "category:", info?["LSApplicationCategoryType"] ?? "-")
            check(info?["CFBundleExecutable"] as? String == "wine-preloader", "Engine 3.0's Game Mode copy names wine-preloader, the binary the game runs in")
            check(copy.wine64.lastPathComponent == "wine" && copy.wine64.path.contains("Anvil Game.app"), "and the game is started from inside that bundle")
        } catch { failures += 1; print("FAIL: Game Mode copy: \(error)") }

        // 3. Automatic upscaling.
        let generatedBefore = Library.shared.container(id: lego.containerID)?.upscaler.frameGeneration
        Housekeeping.automaticUpscalingOnce()
        let after = Library.shared.games.first { $0.id == lego.id }!
        print("LEGO upscaling after:", after.upscalerOverride.map { "frameGen \($0.frameGeneration)" } ?? "automatic (the container's)")
        check(after.upscalerOverride == nil, "LEGO's hand-set upscaling is back to automatic")
        let container = Library.shared.container(id: after.containerID)!
        // Since 0.26 frame generation is the player's choice (on by default): putting LEGO back
        // to automatic leaves the container's choice as it was.
        check(container.upscaler.frameGeneration == generatedBefore, "and its container's frame generation is as the player set it")

        // 4. The engine kept without being measured goes back, once.
        let snaps = RuntimeManager.support.appendingPathComponent("Snapshots")
        try? fm.createDirectory(at: snaps, withIntermediateDirectories: true)
        try? fm.removeItem(at: snaps.appendingPathComponent("index.json"))
        try! fm.copyItem(at: URL(fileURLWithPath: args[4]), to: snaps.appendingPathComponent("index.json"))
        let e2 = RuntimeManager.runtimesDir.appendingPathComponent("mythic-engine-2.6.1")
        try? fm.removeItem(at: e2)
        let q = Process(); q.executableURL = URL(fileURLWithPath: "/bin/cp"); q.arguments = ["-Rc", args[5], e2.path]; try! q.run(); q.waitUntilExit()
        RuntimeManager.shared.discover()
        // As it was on 1 October before 0.19.3: Engine 3.0 kept with no trial running, nothing
        // rejected, no measured session on 2.6.1 yet. The real library has moved on since —
        // LEGO played on 2.6.1 and went onto a measured 3.0 trial — so that state is set here.
        var kept = Library.shared.container(id: lego.containerID)!
        kept.runtimeID = "mythic-engine-3.0.0"
        kept.engineTrial = nil
        kept.rejectedEngines = []
        kept.rejectedAtSupport = nil
        Library.shared.update(kept)
        var unmeasured = Library.shared.games.first { $0.id == lego.id }!
        unmeasured.lastSession = nil
        Library.shared.update(unmeasured)
        print("Star Wars before:", Library.shared.container(id: lego.containerID)!.runtimeID, "snapshots:", SnapshotManager.shared.snapshots(for: c).map(\.label))
        Autopilot.shared.undoUnmeasuredEngineSwitchesOnce()
        let sw = Library.shared.container(id: lego.containerID)!
        print("Star Wars after:", sw.runtimeID, "rejected:", sw.rejectedEngines, "—", Autopilot.shared.report(for: after)?.findings.first.map { "[\($0.kind.rawValue)] \($0.title)" } ?? "")
        check(sw.runtimeID == "mythic-engine-2.6.1" && sw.rejectedEngines == ["mythic-engine-3.0.0"], "LEGO's container back on 2.6.1, and 3.0 not offered again")
        await Autopilot.shared.considerEngineUpgrade(gameID: lego.id)
        check(Library.shared.container(id: lego.containerID)!.runtimeID == "mythic-engine-2.6.1", "Autopilot doesn't switch it back to 3.0")
        Autopilot.shared.undoUnmeasuredEngineSwitchesOnce()
        check(Library.shared.container(id: lego.containerID)!.rejectedEngines.count == 1, "only once")

        print(failures == 0 ? "fit: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
