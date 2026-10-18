import Foundation

// The game's picture at each graphics level (GameTuning.prepare: 0.52's Medium keeps the reflections and turns the
// water distortion off), and made ready for FSR (GameTuning.prepareForFSR), at every graphics level since 0.51: LEGO Star
// Wars' sharpening, edge blur and both motion blurs off while FSR upscales — at the game's own look too, where
// its reflections are on — and put back as it had them when FSR is off. Run with CFFIXED_USER_HOME set to a
// scratch folder: it writes a container of its own there.
@main struct LookPrepHarness {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } }
        guard RuntimeManager.support.path.contains("/home/") || ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else {
            print("FAIL: run with CFFIXED_USER_HOME, not on the real library"); exit(1)
        }
        let container = Container(name: "LookPrep", runtimeID: "mythic-engine-2.6.1")
        let game = Game(title: "LEGO Star Wars", executablePath: "/nowhere/LEGOSTARWARSSKYWALKERSAGA_DX11.exe", containerID: container.id)
        guard let profile = GameTuning.profile(for: game) else { print("FAIL: no LEGO profile"); exit(1) }
        let file = container.driveC.appendingPathComponent("users/crossover").appendingPathComponent(profile.settingsFile)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "ScreenSpaceReflectionsEnabled 1\nMotionBlurEnabled 1\nSpeedBlurEnabled 1\nSharpeningEnabled 1\nEdgeAAEnabled 1\nDoFEnabled 1\n"
        try? Data(original.utf8).write(to: file)
        func read() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        func has(_ key: String, _ value: String) -> Bool { read().contains("\(key) \(value)\n") }

        // The game's own look, upscaled: its reflections and depth of field untouched; blurs and sharpening off.
        let line = GameTuning.prepareForFSR(game, in: container, upscaling: true, level: .full)
        check(line?.contains("motion blur off") == true && line?.contains("speed blur off") == true, "said: \(line ?? "nothing")")
        check(has("MotionBlurEnabled", "0") && has("SpeedBlurEnabled", "0") && has("SharpeningEnabled", "0") && has("EdgeAAEnabled", "0"),
              "made ready for FSR at the game's own look: \(read())")
        check(has("ScreenSpaceReflectionsEnabled", "1") && has("DoFEnabled", "1"), "its reflections and depth of field left on: \(read())")
        // Again: nothing more to change.
        check(GameTuning.prepareForFSR(game, in: container, upscaling: true, level: .full) == nil, "a second start: nothing to say")
        // Not upscaled: everything back as it had it.
        _ = GameTuning.prepareForFSR(game, in: container, upscaling: false, level: .full)
        check(read() == original, "FSR off: as the game had it: \(read())")

        // 0.52's levels: Light turns the reflections off with the rest; Medium has them on, and the water and heat
        // distortion off; Full puts everything back as the game had it.
        let fresh = original + "WaterDistortionEnabled 1\n"
        try? Data(fresh.utf8).write(to: file)
        _ = GameTuning.prepare(game, in: container, level: .light)
        check(has("ScreenSpaceReflectionsEnabled", "0") && has("WaterDistortionEnabled", "0") && has("DoFEnabled", "0"), "Light: \(read())")
        _ = GameTuning.prepare(game, in: container, level: .medium)
        check(has("ScreenSpaceReflectionsEnabled", "1") && has("WaterDistortionEnabled", "0") && has("DoFEnabled", "0")
              && has("MotionBlurEnabled", "0"), "Medium: reflections on, water distortion off: \(read())")
        _ = GameTuning.prepare(game, in: container, level: .full)
        check(read() == fresh, "Full: as the game had it: \(read())")

        // 0.52's Ray Tracing switch, and the reflections a step lighter at Light and Medium — on an entry-level GPU since
        // 0.55 (a standard one, a base M4, until then); a standard one gets the game's own.
        let withQuality = fresh + "ScreenSpaceReflectionsQuality 3\n"
        try? Data(withQuality.utf8).write(to: file)
        var switched = game
        _ = GameTuning.prepare(switched, in: container, level: .medium, tier: .entry)
        check(has("ScreenSpaceReflectionsEnabled", "1") && has("ScreenSpaceReflectionsQuality", "2"), "Medium on an entry-level GPU: quality 2: \(read())")
        _ = GameTuning.prepare(switched, in: container, level: .medium, tier: .base)
        check(has("ScreenSpaceReflectionsEnabled", "1") && has("ScreenSpaceReflectionsQuality", "3"),
              "Medium on a base GPU (0.55): the game's own quality, the step Anvil took put back: \(read())")
        _ = GameTuning.prepare(switched, in: container, level: .medium, tier: .pro)
        check(has("ScreenSpaceReflectionsQuality", "3"), "Medium on a Pro GPU: the game's own quality: \(read())")
        switched.rayTracing = false
        _ = GameTuning.prepare(switched, in: container, level: .medium, tier: .base)
        check(has("ScreenSpaceReflectionsEnabled", "0") && has("ScreenSpaceReflectionsQuality", "3"), "switched off at Medium: \(read())")
        switched.rayTracing = true
        _ = GameTuning.prepare(switched, in: container, level: .light, tier: .entry)
        check(has("ScreenSpaceReflectionsEnabled", "1") && has("ScreenSpaceReflectionsQuality", "2") && has("WaterDistortionEnabled", "0"),
              "switched on at Light, entry-level GPU: on, a step lighter, the rest of Light kept: \(read())")
        _ = GameTuning.prepare(switched, in: container, level: .light, tier: .base)
        check(has("ScreenSpaceReflectionsEnabled", "1") && has("ScreenSpaceReflectionsQuality", "3") && has("WaterDistortionEnabled", "0"),
              "switched on at Light, base GPU: on at the game's own quality, the rest of Light kept: \(read())")
        switched.rayTracing = false
        _ = GameTuning.prepare(switched, in: container, level: .full, tier: .base)
        check(has("ScreenSpaceReflectionsEnabled", "0") && has("WaterDistortionEnabled", "1") && has("ScreenSpaceReflectionsQuality", "3"),
              "switched off at Full: only that, the rest the game's own: \(read())")
        switched.rayTracing = nil
        _ = GameTuning.prepare(switched, in: container, level: .full, tier: .base)
        check(read() == withQuality, "back to Full with the switch left to Anvil: as the game had it: \(read())")
        let plan = GameTuning.rayTracingPlan(for: switched, in: container, level: .medium, tier: .entry) ?? ""
        check(plan.hasPrefix("On:") && plan.contains("quality 2") && plan.contains("a step below"), "the plan at Medium on an entry-level GPU: \(plan)")
        let planBase = GameTuning.rayTracingPlan(for: switched, in: container, level: .medium, tier: .base) ?? ""
        check(planBase.hasPrefix("On:") && planBase.contains("quality 3") && planBase.contains("as the game has them"),
              "the plan at Medium on a base GPU: \(planBase)")

        try? FileManager.default.removeItem(at: container.prefixURL)
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("look prep: all checks passed")
    }
}
