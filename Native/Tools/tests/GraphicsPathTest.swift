// 0.39.0, in a throwaway home: DXVK as a graphics setting puts its DLLs in the container and the
// engine's own go back after, never a mix; a game DXVK can't draw stays on D3DMetal; the scan says
// what really draws each kind of game; a session's frame statistics are its own; and Steam's list
// takes a game out again as well as in.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/GraphicsPathTest.swift -o $T/GraphicsPathTest
//   CFFIXED_USER_HOME=<dir>/gpath/home $T/GraphicsPathTest
import AppKit
import Foundation

@main struct GraphicsPathHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/gpath/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        func put(_ text: String, _ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        // 1. An engine laid out as Mythic Engine 2.6.1 is: D3DMetal's DLLs as its own, DXVK beside it.
        let runtimes = RuntimeManager.support.appendingPathComponent("Runtimes", isDirectory: true)
        let root = runtimes.appendingPathComponent("test-engine-1.0", isDirectory: true)
        for d in DXVKSetup.dlls {
            put("D3DMetal 64 \(d)", root.appendingPathComponent("lib/wine/x86_64-windows/\(d).dll"))
            put("D3DMetal 32 \(d)", root.appendingPathComponent("lib/wine/i386-windows/\(d).dll"))
            put("DXVK 64 \(d)", runtimes.appendingPathComponent("test-engine-1.0-dxvk/x64/\(d).dll"))
            put("DXVK 32 \(d)", runtimes.appendingPathComponent("test-engine-1.0-dxvk/x32/\(d).dll"))
        }
        try? fm.createDirectory(at: root.appendingPathComponent("lib/external/D3DMetal.framework"), withIntermediateDirectories: true)
        let engine = Runtime(id: "test-engine-1.0", displayName: "Test Engine 1.0", version: "1.0", root: root, isManaged: true)
        let bare = Runtime(id: "bare-engine-1.0", displayName: "Bare Engine", version: "1.0",
                           root: runtimes.appendingPathComponent("bare-engine-1.0"), isManaged: true)
        try? fm.createDirectory(at: bare.root.appendingPathComponent("lib/external/D3DMetal.framework"), withIntermediateDirectories: true)
        check(DXVKSetup.source(for: engine) != nil && DXVKSetup.source(for: bare) == nil, "DXVK found beside the engine that has it, and only there")

        // 2. What a setting comes to.
        typealias B = GraphicsBackend
        func eff(_ b: B, _ api: GameAnalysis.API?, _ r: Runtime = engine) -> B { DXVKSetup.effective(chosen: b, api: api, runtime: r).backend }
        check(eff(.dxvk, .d3d11) == .dxvk, "DirectX 11 on DXVK: DXVK")
        check(eff(.dxvk, nil) == .dxvk, "not known yet, DXVK chosen: DXVK")
        check(eff(.dxvk, .d3d12) == .d3dmetal, "DirectX 12 on DXVK: D3DMetal (DXVK has none)")
        check(eff(.dxvk, .d3d10) == .d3dmetal, "DirectX 10 on DXVK: D3DMetal (the engine's d3d10 is D3DMetal's)")
        check(eff(.dxvk, .d3d9) == .d3dmetal, "DirectX 9 on DXVK: not DXVK — DXVK for macOS has no d3d9")
        check(eff(.dxvk, .d3d11, bare) == .d3dmetal, "an engine without DXVK: D3DMetal")
        check(eff(.d3dmetal, .d3d11) == .d3dmetal && eff(.wined3d, .d3d9) == .wined3d, "other settings as chosen")
        check(DXVKSetup.effective(chosen: .dxvk, api: .d3d12, runtime: engine).why?.contains("DirectX 12") == true, "and why")
        // 32-bit: D3DMetal has no 32-bit DLLs (the engines' i386-windows hold Wine's own).
        func eff32(_ b: B, _ api: GameAnalysis.API?, _ r: Runtime = engine) -> B {
            DXVKSetup.effective(chosen: b, api: api, is64Bit: false, runtime: r).backend
        }
        check(eff32(.d3dmetal, .d3d11) == .dxvk && eff32(.d3dmetal, .d3d10) == .dxvk,
              "a 32-bit DirectX 10 or 11 game on D3DMetal: DXVK, which has 32-bit DLLs (it was WineD3D on OpenGL 4.1)")
        check(eff32(.dxvk, .d3d10) == .dxvk, "32-bit DirectX 10 with DXVK chosen: DXVK (Wine's 32-bit d3d10 over DXVK's d3d10core)")
        check(eff32(.wined3d, .d3d11) == .wined3d, "WineD3D chosen for a 32-bit game: WineD3D")
        check(eff32(.d3dmetal, .d3d9) == .d3dmetal && eff32(.d3dmetal, .d3d11, bare) == .d3dmetal,
              "32-bit DirectX 9, or an engine without DXVK: left as it is")
        check(!DXVKSetup.overrides.contains("d3d9") && DXVKSetup.overrides.hasSuffix("=n,b"),
              "DXVK's overrides leave d3d9 to Wine and fall back to the engine's own (\(DXVKSetup.overrides))")

        // 3. The scan: what draws each kind of game.
        typealias P = GraphicsScan.Path
        func path(_ api: GameAnalysis.API, _ b: B) -> P { GraphicsScan.path(api: api, backend: b, runtime: engine) }
        check(path(.d3d10, .d3dmetal) == .d3dMetal, "DirectX 10 through D3DMetal — FSR reaches it (it said Wine's OpenGL)")
        check(path(.d3d11, .d3dmetal) == .d3dMetal && path(.d3d12, .d3dmetal) == .d3dMetal, "DirectX 11 and 12 through D3DMetal")
        check(path(.d3d11, .wined3d) == .d3dMetal, "DirectX 11 with WineD3D chosen: still D3DMetal, the engine has no other d3d11")
        check(path(.d3d9, .d3dmetal) == .wineOpenGL && path(.d3d9, .dxvk) == .wineOpenGL, "DirectX 9: Wine's OpenGL renderer under every setting")
        check(path(.d3d11, .dxvk) == .moltenVK, "DirectX 11 on DXVK: MoltenVK")
        check(path(.d3d12, .dxvk) == .d3dMetal, "DirectX 12 with DXVK chosen: D3DMetal")
        check(path(.vulkan, .d3dmetal) == .moltenVK && path(.opengl, .dxvk) == .wineOpenGL, "Vulkan and OpenGL as they are")
        check(GraphicsScan.path(api: .d3d11, backend: .d3dmetal, is64Bit: false, runtime: engine) == .moltenVK,
              "a 32-bit DirectX 11 game: through DXVK and MoltenVK")
        check(GraphicsScan.path(api: .d3d11, backend: .wined3d, is64Bit: false, runtime: engine) == .wineOpenGL,
              "and with WineD3D chosen: Wine's OpenGL renderer")

        // 4. The files: DXVK in, the engine's own back, nothing in between.
        let box = Container(name: "DXVK Box", runtimeID: engine.id)
        let sys32 = box.driveC.appendingPathComponent("windows/system32"), wow = box.driveC.appendingPathComponent("windows/syswow64")
        for d in DXVKSetup.dlls {
            put("D3DMetal 64 \(d)", sys32.appendingPathComponent("\(d).dll"))
            put("D3DMetal 32 \(d)", wow.appendingPathComponent("\(d).dll"))
        }
        put("Wine 64 d3d9", sys32.appendingPathComponent("d3d9.dll"))
        let running = try? FileHandle(forReadingFrom: sys32.appendingPathComponent("d3d11.dll"))   // a game already running there
        var r = DXVKSetup.apply(.dxvk, container: box, runtime: engine)
        print("   \(r.line ?? "-")")
        check(r.ok && DXVKSetup.installed(in: box), "DXVK put in")
        check(DXVKSetup.dlls.allSatisfy { read(sys32.appendingPathComponent("\($0).dll")) == "DXVK 64 \($0)" && read(wow.appendingPathComponent("\($0).dll")) == "DXVK 32 \($0)" },
              "64-bit in system32, 32-bit in syswow64")
        check(read(sys32.appendingPathComponent("d3d9.dll")) == "Wine 64 d3d9", "Wine's d3d9 left alone")
        check(running.flatMap { try? $0.readToEnd() }.map { String(decoding: $0, as: UTF8.self) } == "D3DMetal 64 d3d11",
              "a program that had the old d3d11 open still reads the old one (swapped by rename)")
        r = DXVKSetup.apply(.dxvk, container: box, runtime: engine)
        check(r.ok && r.line == nil, "a second start on DXVK: nothing to do")
        r = DXVKSetup.apply(.d3dmetal, container: box, runtime: engine)
        print("   \(r.line ?? "-")")
        check(r.ok && !DXVKSetup.installed(in: box), "D3DMetal again: DXVK's taken out")
        check(DXVKSetup.dlls.allSatisfy { read(sys32.appendingPathComponent("\($0).dll")) == "D3DMetal 64 \($0)" && read(wow.appendingPathComponent("\($0).dll")) == "D3DMetal 32 \($0)" },
              "the engine's own (D3DMetal's) back in both")
        r = DXVKSetup.apply(.d3dmetal, container: box, runtime: engine)
        check(r.ok && r.line == nil, "never on DXVK: nothing touched")
        // Half way: the third DLL can't be read.
        let blocked = runtimes.appendingPathComponent("test-engine-1.0-dxvk/x64/dxgi.dll")
        chmod(blocked.path, 0)
        r = DXVKSetup.apply(.dxvk, container: box, runtime: engine)
        chmod(blocked.path, 0o644)
        print("   \(r.line ?? "-")")
        check(!r.ok, "a DLL that can't be read: DXVK not set up")
        check(DXVKSetup.dlls.allSatisfy { read(sys32.appendingPathComponent("\($0).dll")) == "D3DMetal 64 \($0)" } && !DXVKSetup.installed(in: box),
              "and no mix of DXVK's and D3DMetal's left behind")
        check(!fm.fileExists(atPath: sys32.appendingPathComponent(".d3d11.dll.anvil-new").path), "no half-written file left")

        // 5. A session's frame statistics are its own: Steam's window, then LEGO started beside it.
        let stat = "12:00:00.000 [anvil] displayed 80.0 fps | 1% LOW 78.4 fps | STEADY 100.0% | rendered 80.0 fps"
        let log = RuntimeManager.support.appendingPathComponent("game.log")
        put((["=== Steam — 2026-10-10T19:45:52Z — Anvil 0.38.2 ===", "[anvil] Steam: no frame hook",
              "=== LEGO — 2026-10-10T19:46:33Z — Anvil 0.38.2 ==="] + Array(repeating: stat, count: 6)).joined(separator: "\n"), log)
        check(SessionStats.read(log: log, title: "Steam") == nil, "Steam's session takes no frame rate from LEGO's (it said 80 fps on 10 October)")
        check(SessionStats.read(log: log, title: "LEGO").map { Int($0.averageFPS.rounded()) } == 80, "LEGO's own: 80 fps")

        // 6. Steam's list: in and out again, the player's own shortcut kept.
        let steamBox = Container(name: "Steam", runtimeID: engine.id)
        let config = SteamSupport.steamDir(in: steamBox).appendingPathComponent("userdata/12345/config")
        put("x", SteamSupport.steamExe(in: steamBox))
        put("\"UserLocalConfigStore\" {}", config.appendingPathComponent("localconfig.vdf"))
        typealias V = SteamShortcuts.Value
        let theirs: [(String, V)] = [("appid", .int(-1_234_567)), ("AppName", .string("Their Game")), ("Exe", .string(#""C:\Games\their.exe""#))]
        try? SteamShortcuts.encode([("shortcuts", .map([("0", .map(theirs))]))]).write(to: config.appendingPathComponent("shortcuts.vdf"))
        let lego = Game(title: "LEGO® Star Wars™: The Skywalker Saga", executablePath: "/Games/LEGO.exe", containerID: UUID())
        let cat = Game(title: "Cat Quest II", executablePath: "/Games/Cat Quest II.exe", containerID: UUID())
        let cover = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        let legoID = (try? SteamShortcuts.write(lego, in: steamBox, cover: cover)) ?? 0
        _ = try? SteamShortcuts.write(cat, in: steamBox, cover: nil)
        check(SteamShortcuts.listed(in: steamBox) == [lego.id, cat.id], "both listed by their Anvil ids")
        let grid = config.appendingPathComponent("grid/\(legoID)p.png")
        check(fm.fileExists(atPath: grid.path), "LEGO's grid art written")
        check((try? SteamShortcuts.unwrite(lego, in: steamBox)) == true, "LEGO taken out")
        check(SteamShortcuts.listed(in: steamBox) == [cat.id] && !fm.fileExists(atPath: grid.path), "only Cat Quest II left, and LEGO's art gone with it")
        if let data = try? Data(contentsOf: config.appendingPathComponent("shortcuts.vdf")),
           let top = try? SteamShortcuts.parse(data), case .map(let list)? = top.first?.1 {
            check(list.map(\.0) == ["0", "1"] && list[0].1["AppName"]?.text == "Their Game", "the player's own shortcut kept, first; numbered from 0 (\(list.map(\.0)))")
        } else { check(false, "the list read back") }
        check((try? SteamShortcuts.unwrite(lego, in: steamBox)) == false, "taken out twice: nothing to do")
        check(SteamShortcuts.candidates(in: [lego, cat, Game(title: "Steam", executablePath: SteamSupport.steamExe(in: steamBox).path, containerID: steamBox.id)])
                .map(\.title) == ["Cat Quest II", lego.title], "Settings lists the games, not Steam itself")

        // 7. The save copy before a start: half a second at most, whatever the copy is waiting on
        // (10 October: Cat Quest II's waited on macOS's Documents prompt, and so did its start).
        let slow = Task.detached { () -> Int in try? await Task.sleep(for: .seconds(3)); return 1 }
        let began = Date()
        let got = await Launcher.firstOf(slow, orNilAfter: .milliseconds(500))
        let waited = Date().timeIntervalSince(began)
        check(got == nil && waited < 1.0, String(format: "a copy still running: the start goes on after %.2f s", waited))
        let quick = Task.detached { () -> Int in 7 }
        check(await Launcher.firstOf(quick, orNilAfter: .milliseconds(500)) == 7, "a copy already done: its result")

        // 8. Ended from outside with SIGKILL: not a crash for Autopilot to blame FSR for.
        let killedLog: [Substring] = ["prepareAndLaunch: LEGO", "  env ANVIL_FSR3=1",
                                      "exited: LEGO code=9 after 342.4s, 342 s of it awake \(Launcher.killedMark)"]
        check(GameDoctor.crashCause(launchLines: killedLog, gameLines: [])?.contains("SIGKILL") == true,
              "SIGKILL from outside is named as the cause, so FSR 3 stays on")
        check(GameDoctor.crashCause(launchLines: ["exited: LEGO code=1 after 30.0s"], gameLines: []) == nil,
              "an ordinary non-zero exit is still looked at as a crash")
        let frozeFirst: [Substring] = ["12:00:00.000 [anvil] displayed 80.0 fps | 1% LOW 78.4 fps",
                                       "12:00:05.000 [anvil] frames STOPPED: no frame for 1.5 s (after 742 frames)"]
        check(GameDoctor.crashCause(launchLines: killedLog, gameLines: frozeFirst) == nil,
              "force-quit after its frames had stopped: a freeze, looked at as a crash (FSR may be switched off)")
        check(GameDoctor.crashCause(launchLines: killedLog, gameLines: frozeFirst.reversed()) != nil,
              "frames going again after a stop, then killed: ended from outside")

        // 9. Saves in the Mac's own Documents: known from Anvil's own copies, without looking there.
        let catBox = Container(name: "Cat Quest", runtimeID: engine.id)
        let macDocs = RuntimeManager.support.appendingPathComponent("MacDocuments", isDirectory: true)
        try? fm.createDirectory(at: macDocs.appendingPathComponent("Cat Quest II"), withIntermediateDirectories: true)
        put("save", macDocs.appendingPathComponent("Cat Quest II/save_file1.dat"))
        let person = catBox.driveC.appendingPathComponent("users/crossover", isDirectory: true)
        try? fm.createDirectory(at: person, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: person.appendingPathComponent("Documents"), withDestinationURL: macDocs)
        let names = ["Cat Quest II", "Cat Quest II"]
        check(SaveGuard.linkedDocuments(in: catBox.driveC)?.resolvingSymlinksInPath().path == macDocs.resolvingSymlinksInPath().path,
              "the container's Documents found linked to the Mac's own")
        check(!SaveGuard.keptInDocuments(containerID: catBox.id, games: names), "no copy yet: not known to keep saves there")
        let copy = SaveGuard.root.appendingPathComponent("\(catBox.id.uuidString)/2026-10-10 19.10.22", isDirectory: true)
        put("save", copy.appendingPathComponent("drive_c/users/crossover/Documents/Cat Quest II/save_file1.dat"))
        put(#"{"bytes":4,"cloned":true,"containerName":"Cat Quest","date":"2026-10-11T02:10:22Z","files":1,"fingerprint":"x","reason":"Before playing Cat Quest II","version":1}"#,
            copy.appendingPathComponent("backup.json"))
        check(SaveGuard.keptInDocuments(containerID: catBox.id, games: names), "its copy holds Documents/Cat Quest II: known")
        check(!SaveGuard.keptInDocuments(containerID: catBox.id, games: ["LEGO Star Wars"]), "another game in it: not")
        check(SaveGuard.documentsAllowed(macDocs, games: names), "a folder Anvil may open: allowed")
        chmod(macDocs.appendingPathComponent("Cat Quest II").path, 0)
        check(!SaveGuard.documentsAllowed(macDocs, games: names), "a folder it may not: refused, and said")
        chmod(macDocs.appendingPathComponent("Cat Quest II").path, 0o755)
        check(SaveGuard.documentsAllowed(macDocs, games: ["Nothing Here"]), "a game with no folder there: nothing to ask about")

        print(failures == 0 ? "graphics path: all passed" : "graphics path: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
