// 0.38.0, in a throwaway home: D3DMetal's shader cache kept and put back only when D3DMetal will
// use it (its version stamp — D3DMetal build and macOS), and LEGO Star Wars' shadows left as the
// game draws them at every level, with what earlier levels turned down put back.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/LookTest.swift -o $T/LookTest
//   CFFIXED_USER_HOME=<dir>/look/home $T/LookTest [real d3dm cache dir for LEGO]
import Foundation

@main struct LookHarness {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/look/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        typealias C = ShaderCacheManager

        // 1. Stamps, as D3DMetal 2.1 writes them (version.bin from this Mac, 10 October).
        func stamp(_ macOS: String, build: UInt8 = 0x65) -> Data {
            var d = Data([build, 0x13, 0xf4, 0xc9]) + Data(repeating: 0x27, count: 28)
            d += Data([0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x01]) + Data(repeating: 0, count: 24)
            d += Data("air64-apple-macosx\(macOS)".utf8)
            return d
        }
        check(C.macOS(inStamp: stamp("27.0.1")) == "27.0.1" && C.macOS(inStamp: stamp("27.0.0")) == "27.0.0", "the macOS a cache was made for, read from its stamp")
        if CommandLine.arguments.count > 1,
           let real = C.stamp(of: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)) {
            check(C.macOS(inStamp: real) != nil, "and from LEGO's real cache: macOS \(C.macOS(inStamp: real) ?? "?")")
        }

        // 2. What goes back before a start.
        let now = "27.0.1"
        let old = stamp("27.0.0"), new = stamp("27.0.1"), otherBuild = stamp("27.0.1", build: 0x7a)
        func restore(_ live: (Data?, Int64), _ stored: (Data?, Int64)) -> Bool { C.shouldRestore(live: live, stored: stored, macOS: now).0 }
        check(!restore((new, 142_000_000), (old, 168_000_000)),
              "10 October: a bigger copy from macOS 27.0.0 is NOT put back over 27.0.1's own — D3DMetal would throw it away and compile everything again")
        check(!restore((nil, 0), (old, 168_000_000)), "none live, and the copy is from another macOS: not put back either")
        check(restore((nil, 0), (new, 168_000_000)), "purged by macOS, the copy made for this macOS: put back")
        check(restore((new, 40_000_000), (new, 168_000_000)), "same stamp, live has lost pipelines: put back")
        check(!restore((new, 168_000_000), (new, 140_000_000)), "same stamp, live is as complete: left")
        check(!restore((new, 100), (otherBuild, 168_000_000)), "another D3DMetal's copy (the engine was switched): left")
        check(!restore((nil, 0), (nil, 168_000_000)), "a copy D3DMetal never stamped: left")
        let (_, why) = C.shouldRestore(live: (new, 1), stored: (old, 2), macOS: now)
        check(why.contains("macOS 27.0.0") && why.contains("macOS 27.0.1"), "and says why (\(why))")

        // 3. What's kept after a session.
        check(C.shouldCapture(live: (new, 142_000_000), stored: (old, 168_000_000)), "a newer stamp is kept even though it's smaller")
        check(C.shouldCapture(live: (new, 150), stored: (new, 100)), "same stamp, grown: kept")
        check(!C.shouldCapture(live: (new, 100), stored: (new, 150)), "same stamp, smaller: not kept")
        check(!C.shouldCapture(live: (nil, 150), stored: (new, 100)), "nothing D3DMetal stamped: not kept")

        // 4. The real files: restore and capture on folders laid out as D3DMetal's.
        let live = RuntimeManager.support.appendingPathComponent("live/d3dm/Game.exe", isDirectory: true)
        func lay(_ dir: URL, _ s: Data, bytes: Int) {
            let fam = dir.appendingPathComponent("shaders.cache/MTLGPUFamilyApple9_0", isDirectory: true)
            try? fm.createDirectory(at: fam, withIntermediateDirectories: true)
            try? s.write(to: fam.appendingPathComponent("version.bin"))
            try? Data(repeating: 7, count: bytes).write(to: fam.appendingPathComponent("stage_cache.bin"))
        }
        lay(live, new, bytes: 4000)
        check(C.stamp(of: live) == new, "the stamp found in a laid-out cache")
        let store = C.storeRoot.appendingPathComponent("Game.exe", isDirectory: true)
        lay(store, old, bytes: 9000)
        check(C.shouldCapture(live: (C.stamp(of: live), C.size(of: live)), stored: (C.stamp(of: store), C.size(of: store))),
              "laid out as on this Mac: the live 27.0.1 cache would replace the kept 27.0.0 one")

        // 5. LEGO's shadows: the settings file as it was on 10 October, tuned at Light by 0.37.
        let tuningDir = RuntimeManager.support.appendingPathComponent("GameTuning", isDirectory: true)
        try? fm.createDirectory(at: tuningDir, withIntermediateDirectories: true)
        GameTuning.recordsDirectory = tuningDir
        let box = Container(name: "Star Wars", runtimeID: "none")
        let lego = Game(title: "LEGO® Star Wars™: The Skywalker Saga",
                        executablePath: "/Games/LEGOSTARWARSSKYWALKERSAGA_DX11.exe", containerID: box.id)
        guard let profile = GameTuning.profile(for: lego) else { print("FAIL: no LEGO profile"); exit(1) }
        check(profile.version == 4, "LEGO's tuning is at version 4")
        for level in [GraphicsLevel.light, .medium] {
            let keys = Set(profile.settings(for: level).map(\.key))
            check(keys.isDisjoint(with: ["SoftShadowsEnabled", "SSAOEnabled", "ShadowQuality"]),
                  "\(level.title) leaves soft shadows, ambient occlusion and shadow quality to the game (\(keys.sorted()))")
        }
        let settings = box.driveC.appendingPathComponent("users/crossover/" + profile.settingsFile)
        try? fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = """
        ShadowQuality\t\t\t\t\t\t\t\t3
        SoftShadowsEnabled\t\t\t\t\t\t\t0
        SSAOEnabled\t\t\t\t\t\t\t\t\t0
        ScreenSpaceReflectionsEnabled\t\t\t\t0
        DoFEnabled\t\t\t\t\t\t\t\t\t0
        MotionBlurEnabled\t\t\t\t\t\t\t1
        SpeedBlurEnabled\t\t\t\t\t\t\t1
        WaterDistortionEnabled\t\t\t\t\t\t0
        TemporalAAEnabled\t\t\t\t\t\t\t1
        """
        try? Data(file.utf8).write(to: settings)
        let record = #"{"version":2,"level":"light","original":{"MotionBlurEnabled":"1","DoFEnabled":"1","ScreenSpaceReflectionsEnabled":"1","WaterDistortionEnabled":"1","SSAOEnabled":"1","ShadowQuality":"2","SoftShadowsEnabled":"1","SpeedBlurEnabled":"1"},"applied":{"SoftShadowsEnabled":"0","DoFEnabled":"0","ScreenSpaceReflectionsEnabled":"0","WaterDistortionEnabled":"0","SSAOEnabled":"0","MotionBlurEnabled":"0","ShadowQuality":"0","SpeedBlurEnabled":"0"}}"#
        try? Data(record.utf8).write(to: tuningDir.appendingPathComponent("\(lego.id.uuidString).json"))
        let line = GameTuning.prepare(lego, in: box, level: .light) ?? ""
        print("   \(line)")
        let after = GameTuning.values(in: (try? String(contentsOf: settings, encoding: .utf8)) ?? "")
        check(after["SoftShadowsEnabled"] == "1" && after["SSAOEnabled"] == "1", "soft shadows and ambient occlusion back on, as the game had them")
        check(after["ShadowQuality"] == "3", "shadow quality as the player set it in the game (3), not touched")
        // 0.41: the game turns its two motion blurs back on by itself; at Light and Medium they're kept off.
        check(after["MotionBlurEnabled"] == "0" && after["SpeedBlurEnabled"] == "0" && line.contains("again: the game had turned them back on"),
              "the game's motion blurs off again, every start, and said so")
        check(after["ScreenSpaceReflectionsEnabled"] == "0" && after["DoFEnabled"] == "0" && after["WaterDistortionEnabled"] == "0",
              "the heavy effects that show little stay off at Light")
        check(GameTuning.prepare(lego, in: box, level: .light) == nil, "the next start: nothing more to do")
        // Turned on again since: off again, and nothing else touched.
        try? Data(GameTuning.replacing(["SpeedBlurEnabled": "1"], in: (try? String(contentsOf: settings, encoding: .utf8)) ?? "").utf8).write(to: settings)
        let again = GameTuning.prepare(lego, in: box, level: .light) ?? ""
        let afterAgain = GameTuning.values(in: (try? String(contentsOf: settings, encoding: .utf8)) ?? "")
        check(afterAgain["SpeedBlurEnabled"] == "0" && afterAgain["ShadowQuality"] == "3" && again.contains("Speed blur off again"),
              "speed blur back on by the next start: off again, the rest as it was (\(again))")
        // The game's own temporal anti-aliasing, read from the same file.
        check(GameTuning.smoothsItsOwnEdges(lego, in: box), "temporal AA on in its file: the game smooths its own edges")
        try? Data(GameTuning.replacing(["TemporalAAEnabled": "0"], in: (try? String(contentsOf: settings, encoding: .utf8)) ?? "").utf8).write(to: settings)
        check(!GameTuning.smoothsItsOwnEdges(lego, in: box), "and off: it doesn't")

        print(failures == 0 ? "look: all passed" : "look: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
