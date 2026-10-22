// 0.27.0, in a throwaway home: the graphics scan against LEGO Star Wars' real program and
// Anvil's real engines (read only), and against made-up games with DLSS, FSR and DirectX 9;
// what the first session showed, read from the real game.log; the crash that was Metal's and
// not FSR's, read from the real anvil.log; and DLSS through MetalFX set up in a test container.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil -name '*.swift' ! -name AnvilApp.swift) \
//     Native/Tools/tests/GraphicsScanTest.swift -o $TMPDIR/GraphicsScanTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/GraphicsScanTest <LEGO exe> <Runtimes> <game.log> <anvil.log> <notepad.exe>
import Foundation

@main struct GraphicsScanHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/") else { print("refusing: not in a throwaway home"); exit(2) }
        let args = CommandLine.arguments
        let lego = URL(fileURLWithPath: args[1]), runtimes = URL(fileURLWithPath: args[2])
        let gameLog = URL(fileURLWithPath: args[3]), anvilLog = URL(fileURLWithPath: args[4]), notepad = URL(fileURLWithPath: args[5])
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        func engine(_ id: String) -> Runtime {
            Runtime(id: id, displayName: "Mythic Engine \(id.split(separator: "-").last ?? "")", version: "1",
                    root: runtimes.appendingPathComponent(id), isManaged: true)
        }
        let e26 = engine("mythic-engine-2.6.1"), e30 = engine("mythic-engine-3.0.0")

        // 1. LEGO Star Wars as it is: DirectX 11 on D3DMetal, nothing of its own, Anvil's FSR.
        var t = Date()
        let legoScan = GraphicsScan.scan(executable: lego, backend: .d3dmetal, runtime: e26)
        print("info: LEGO scanned in \(String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000)): \(legoScan.summary)")
        check(legoScan.api == "DirectX 11" && legoScan.engine == "TT Games' engine", "LEGO: DirectX 11, TT Games' engine")
        check(legoScan.path == .d3dMetal && legoScan.plan.anvilFSR && legoScan.plan.anvilFrameGen, "LEGO: through D3DMetal, so Anvil's FSR and frame generation")
        check(!legoScan.hasTemporal && !legoScan.plan.dlssThroughMetalFX, "LEGO: no temporal upscaler of its own, nothing to translate")
        check(!legoScan.metalFXForDLSS && DLSSThroughMetalFX.available(in: e30), "the translation is in Engine 3.0 and not in 2.6.1")

        // 2. A made-up Unreal game with DLSS 3.7.10 and its frame generation, and FSR 3.1.
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("games-\(UUID().uuidString)")
        func pe(_ url: URL, version: [UInt16], extra: [String] = []) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var d = (try? Data(contentsOf: notepad)) ?? Data()
            var fixed: [UInt8] = [0xBD, 0x04, 0xEF, 0xFE, 0, 0, 1, 0]
            for v in [UInt32(version[0]) << 16 | UInt32(version[1]), UInt32(version[2]) << 16 | UInt32(version[3])] {
                fixed += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]
            }
            if url.pathExtension == "dll" { d.append(contentsOf: fixed) }
            for s in extra {
                d.append(contentsOf: Array(s.utf8))
                for b in s.utf8 { d.append(b); d.append(0) }      // and as UTF-16
            }
            do { try d.write(to: url) } catch { print("info: couldn't write \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        let ue = root.appendingPathComponent("Fake")
        let shipping = ue.appendingPathComponent("Fake/Binaries/Win64/Fake-Win64-Shipping.exe")
        pe(shipping, version: [1, 0, 0, 0], extra: ["d3d12.dll", "D3D12CreateDevice", "r.NGX.DLSS.Enable"])
        let plugin = ue.appendingPathComponent("Engine/Plugins/Runtime/Nvidia/DLSS/Binaries/ThirdParty/Win64")
        pe(plugin.appendingPathComponent("nvngx_dlss.dll"), version: [3, 7, 10, 0])
        pe(plugin.appendingPathComponent("nvngx_dlssg.dll"), version: [3, 7, 10, 0])
        pe(ue.appendingPathComponent("Fake/Binaries/Win64/amd_fidelityfx_dx12.dll"), version: [1, 1, 3, 0])
        // The scan looks above Binaries/Win64 and, beside an Engine folder, one further up.
        t = Date()
        let dlss30 = GraphicsScan.scan(executable: shipping, backend: .d3dmetal, runtime: e30)
        print("info: made-up Unreal game scanned in \(String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000)): \(dlss30.summary)")
        let kinds = Set(dlss30.builtins.map(\.kind))
        check(kinds == [.dlss, .dlssFrameGen, .fsr31], "found DLSS, DLSS frame generation and FSR 3.1 (\(dlss30.builtins.map(\.title)))")
        check(dlss30.builtins.first { $0.kind == .dlss }?.version == "3.7.10", "DLSS's version read from the library: 3.7.10")
        check(dlss30.builtins.first { $0.kind == .fsr31 }?.version == "1.1.3", "FidelityFX's version read: 1.1.3")
        check(dlss30.api == "DirectX 12" && dlss30.engine == "Unreal Engine" && dlss30.path == .d3dMetal, "DirectX 12, Unreal, through D3DMetal")
        check(dlss30.plan.dlssThroughMetalFX && dlss30.metalFXForDLSS, "on Engine 3.0: DLSS through MetalFX")
        check(dlss30.plan.inGame.contains { $0.contains("Choose DLSS") } && dlss30.plan.inGame.contains { $0.contains("frame interpolation") },
              "says to choose DLSS in the game, and what its frame generation becomes")
        check(dlss30.plan.inGame.contains { $0.contains("Choose FSR 3.1") }, "and that its own FSR 3.1 is there too")
        let dlss26 = GraphicsScan.scan(executable: shipping, backend: .d3dmetal, runtime: e26)
        check(!dlss26.plan.dlssThroughMetalFX && dlss26.plan.inGame.contains { $0.contains("D3DMetal 3.0") },
              "on Engine 2.6.1: not translated, and says which engine would")
        // With anti-cheat in the install folder, beside Engine: nothing added.
        try? fm.createDirectory(at: ue.appendingPathComponent("EasyAntiCheat"), withIntermediateDirectories: true)
        let guarded = GraphicsScan.scan(executable: shipping, backend: .d3dmetal, runtime: e30)
        check(!guarded.plan.dlssThroughMetalFX && guarded.antiCheat == ["Easy Anti-Cheat"], "with Easy Anti-Cheat: DLSS isn't set up")
        try? fm.removeItem(at: ue.appendingPathComponent("EasyAntiCheat"))
        // The cvar alone, with no library: Unreal's DLSS built into the program.
        try? fm.removeItem(at: ue.appendingPathComponent("Engine"))
        let cvarOnly = GraphicsScan.scan(executable: shipping, backend: .d3dmetal, runtime: e30)
        check(cvarOnly.builtins.contains { $0.kind == .dlss && $0.source == "the game's program" }, "DLSS found from Unreal's own console setting in the program")

        // 3. Where FSR can't reach, said: DirectX 9 is Wine's OpenGL on every setting — D3DMetal and
        // DXVK for macOS have no d3d9 (0.39.0; this said MoltenVK for DXVK before).
        let old = root.appendingPathComponent("Old/old.exe")
        pe(old, version: [1, 0, 0, 0], extra: ["d3d9.dll", "Direct3DCreate9"])
        let dx9 = GraphicsScan.scan(executable: old, backend: .d3dmetal, runtime: e26)
        check(dx9.api == "DirectX 9" && dx9.path == .wineOpenGL && !dx9.plan.anvilFSR && dx9.plan.anvilFSRWhyNot != nil,
              "DirectX 9 on the D3DMetal setting: Wine's OpenGL, FSR can't reach it, and why")
        check(GraphicsScan.scan(executable: old, backend: .dxvk, runtime: e26).path == .wineOpenGL,
              "DirectX 9 with DXVK chosen: still Wine's OpenGL — DXVK for macOS has no d3d9")

        // 4. What the last LEGO session showed, from the real game.log.
        let text = try! String(contentsOf: gameLog, encoding: .utf8)
        let title = "LEGO® Star Wars™: The Skywalker Saga"
        if let header = text.range(of: "=== \(title) — ", options: .backwards) {
            let lines = text[header.upperBound...].split(separator: "\n").dropFirst().prefix { !$0.hasPrefix("=== ") }
            let live = GraphicsScan.live(from: Array(lines), at: Date())
            // 3024x1934 before 0.30, when the layer was sized short of the screen; its own 3024x1964 since.
            check(live?.fsrRan == true && live?.gameSize == "1512x982" && ["3024x1934", "3024x1964"].contains(live?.shownSize ?? "") && live?.pixelFormat == 80,
                  "LEGO's session: FSR ran, 1512x982 shown at the display's size, format 80 (\(String(describing: live?.gameSize)) → \(String(describing: live?.shownSize)))")
            print("info: \(GraphicsScan(api: nil, engine: "", is64Bit: true, builtins: [], antiCheat: [], engineName: "", d3dMetal: nil, path: .d3dMetal, metalFXForDLSS: false, displayPixels: [], displayHz: 0, plan: legoScan.plan, scannedAt: Date(), live: live).liveText ?? "nothing")")
        } else {
            check(false, "a LEGO session in game.log")
        }
        let sample: [Substring] = [
            "12:00:00.000 [anvil] graphics: libd3dshared.dylib sets a layer to 1512x982, pixel format 81",
            "12:00:00.001 [anvil] graphics: winemac.so sets a layer to 1512x982, pixel format 80",
            "12:00:00.002 [anvil] FSR to the display: not for this game's frames (pixel format 115, HDR colour beyond the standard range) — shown as the game draws them",
            "12:00:05.000 [anvil] metal guard: the game asked for a depth-stencil state with 5 values out of range — set to Direct3D's defaults (keep, always) instead of letting Metal stop the game",
            "12:00:10.000 [anvil] displayed 120.0 fps | real=600 | generated 590 of 1190 shown",
        ]
        let s = GraphicsScan.live(from: sample, at: Date())
        check(s?.drawnBy == ["libd3dshared.dylib", "winemac.so"] && s?.fsrRan == false && s?.fsrWhyNot == "pixel format 115, HDR colour beyond the standard range",
              "a made-up session: who drew it, and why FSR didn't run (\(String(describing: s?.fsrWhyNot)))")
        check(s?.generated == 590 && s?.shown == 1190 && s?.guardCorrections == 1, "…frames generated, and the guard's correction")

        // 5. The crash on 3 October: Metal's, not FSR's — from the real anvil.log.
        let log = try! String(contentsOf: anvilLog, encoding: .utf8).split(separator: "\n")
        // The 3 October one: the code-9 exit whose session has Metal's assertion in it (later ones,
        // like the test end of 10 October, were force quits of a game still running).
        let ends = log.indices.filter { log[$0].contains("exited: \(title) code=9") }
        let frozen = ends.compactMap { end -> (Int, Int)? in
            guard let start = log[..<end].lastIndex(where: { $0.contains("prepareAndLaunch: \(title) ") }),
                  log[start...end].contains(where: { $0.contains("failed assertion") }) else { return nil }
            return (start, end)
        }.last
        if let (start, end) = frozen {
            let cause = GameDoctor.crashCause(launchLines: Array(log[start...end]), gameLines: [])
            check(cause?.contains("depth-stencil") == true, "LEGO's freeze on 3 October: \(cause ?? "no cause found")")
        } else {
            check(false, "LEGO's 3 October session in anvil.log")
        }
        check(GameDoctor.crashCause(launchLines: ["game| -[MTLComputeCommandEncoder dispatch]: failed assertion `x'"], gameLines: []) == nil,
              "a compute-pass assertion — the kind Anvil's own passes could cause — isn't excused")
        check(GameDoctor.crashCause(launchLines: ["exited: X code=5"], gameLines: []) == nil, "a crash with nothing named isn't excused")

        // 6. DLSS through MetalFX, set up in a test container on Engine 3.0.
        var container = Container(name: "DLSS", runtimeID: e30.id)
        container.backend = .d3dmetal
        let sys32 = container.prefixURL.appendingPathComponent("drive_c/windows/system32")
        try? fm.createDirectory(at: sys32, withIntermediateDirectories: true)
        switch DLSSThroughMetalFX.prepare(container: container, runtime: e30) {
        case .success(let folder):
            let dll = folder.appendingPathComponent("x86_64-windows/nvngx.dll"), so = folder.appendingPathComponent("x86_64-unix/nvngx.so")
            let engineFiles = DLSSThroughMetalFX.files(in: e30)!
            check(fm.contentsEqual(atPath: dll.path, andPath: engineFiles.dll.path), "Anvil's nvngx.dll is the engine's nvngx-on-metalfx.dll")
            check(so.resolvingSymlinksInPath().path == engineFiles.so.resolvingSymlinksInPath().path
                  && so.resolvingSymlinksInPath().lastPathComponent == "libd3dshared.dylib",
                  "its nvngx.so is the engine's own D3DMetal library (\(so.resolvingSymlinksInPath().path))")
            check(fm.contentsEqual(atPath: sys32.appendingPathComponent("nvngx.dll").path, andPath: engineFiles.dll.path)
                  && fm.fileExists(atPath: sys32.appendingPathComponent("nvapi64.dll").path), "nvngx.dll and nvapi64.dll in the container's system32")
            check(!fm.fileExists(atPath: e30.root.appendingPathComponent("lib/wine/x86_64-windows/nvngx.dll").path), "nothing added to the engine")
        case .failure(let error):
            check(false, "set up: \(error.localizedDescription)")
        }
        check(DLSSThroughMetalFX.ready(container: container, runtime: e30) != nil, "ready for a start")
        if case .failure = DLSSThroughMetalFX.prepare(container: container, runtime: e26) {} else { check(false, "Engine 2.6.1 refuses") }
        // The launch environment, for a game whose scan says so.
        var game = Game(title: "Fake", executablePath: shipping.path, containerID: container.id)
        game.dlssThroughMetalFX = true
        let key = GraphicsScan.key(executable: shipping, runtimeID: e30.id, backend: .d3dmetal)!
        GraphicsScan.keep(GraphicsScan.scan(executable: shipping, backend: .d3dmetal, runtime: e30), gameID: game.id, key: key)
        let env = Launcher.shared.environment(for: game, in: container, runtime: e30)
        check(env["D3DM_ENABLE_METALFX"] == "1" && env["WINEDLLPATH"] == DLSSThroughMetalFX.folder(for: e30).path
              && (env["WINEDLLOVERRIDES"] ?? "").contains("nvngx=b"), "the start switches it on: D3DM_ENABLE_METALFX, WINEDLLPATH, nvngx builtin")
        game.dlssThroughMetalFX = false
        check(Launcher.shared.environment(for: game, in: container, runtime: e30)["D3DM_ENABLE_METALFX"] == nil, "…and not when it's switched off")
        let legoGame = Game(title: "LEGO", executablePath: lego.path, containerID: container.id)
        check(Launcher.shared.environment(for: legoGame, in: container, runtime: e30)["D3DM_ENABLE_METALFX"] == nil, "nor for a game without DLSS")

        // 7. Kept per build: the second launch reads it; a new build is scanned again.
        let first = await GraphicsScan.forLaunch(game: legoGame, container: container, runtime: e30)
        let second = await GraphicsScan.forLaunch(game: legoGame, container: container, runtime: e30)
        check(first?.fresh == true && second?.fresh == false, "scanned once, then read back")
        var otherEngine = container
        otherEngine.runtimeID = e26.id
        let third = await GraphicsScan.forLaunch(game: legoGame, container: otherEngine, runtime: e26)
        check(third?.fresh == true, "another engine is scanned again")

        // 8. Anvil's own injection isn't the game's. On 3–4 October LEGO was scanned as having
        // "FSR 3.1 (FidelityFX SDK 1.0.1.41314)" whenever the FidelityFX payload Anvil had
        // force-injected was in its folder, and as having nothing once Autopilot had taken it out
        // again — the same program on the same engine. Here a made-up DirectX 11 game has the
        // payload put in and taken out by Anvil's own injection code.
        let plain = root.appendingPathComponent("Plain/plain.exe")
        pe(plain, version: [1, 0, 0, 0], extra: ["d3d11.dll", "D3D11CreateDevice"])
        let payload = FSRRuntime(id: "fidelityFX-test", version: "unknown", installedAt: Date(),
                                 libraryNames: ["amd_fidelityfx_dx12.dll", "amd_fidelityfx_vk.dll", "amd_ags_x64.dll"])
        for name in ["amd_fidelityfx_dx12.dll", "amd_fidelityfx_vk.dll"] {
            pe(payload.root.appendingPathComponent(name), version: [1, 0, 1, 41314])
        }
        pe(payload.root.appendingPathComponent("amd_ags_x64.dll"), version: [6, 2, 0, 0])
        let bare = GraphicsScan.scan(executable: plain, backend: .d3dmetal, runtime: e26)
        let bareKey = GraphicsScan.key(executable: plain, runtimeID: e26.id, backend: .d3dmetal)!
        check(bare.api == "DirectX 11" && bare.builtins.isEmpty, "a DirectX 11 game with nothing of its own: nothing found (\(bare.builtins.map(\.title)))")
        let plainID = UUID()
        GraphicsScan.keep(bare, gameID: plainID, key: bareKey)
        do {
            let report = try UpscalerManager.shared.forceInject(payload, intoGameAt: plain.path)
            check(report.copied.sorted() == ["amd_fidelityfx_dx12.dll", "amd_fidelityfx_vk.dll"],
                  "Anvil's injection put its two FidelityFX libraries beside the game (\(report.copied))")
        } catch {
            check(false, "injected: \(error.localizedDescription)")
        }
        let injected = (0..<5).map { _ in GraphicsScan.scan(executable: plain, backend: .d3dmetal, runtime: e26) }
        check(injected.allSatisfy { $0.builtins.isEmpty && $0.summary == bare.summary },
              "with Anvil's FidelityFX injected beside it, five scans in a row: still nothing of its own (\(injected.map { $0.builtins.map(\.title) }))")
        let injectedKey = GraphicsScan.key(executable: plain, runtimeID: e26.id, backend: .d3dmetal)!
        check(injectedKey != bareKey && GraphicsScan.current(gameID: plainID, key: injectedKey) == nil,
              "the libraries beside the game are part of what a kept scan is of: with them changed it's scanned again, not read back")
        try? UpscalerManager.shared.removeInjection(fromGameAt: plain.path)
        let removedKey = GraphicsScan.key(executable: plain, runtimeID: e26.id, backend: .d3dmetal)!
        check(removedKey == bareKey && GraphicsScan.scan(executable: plain, backend: .d3dmetal, runtime: e26).builtins.isEmpty,
              "taken out again: the same key as before it went in, and the same answer")
        // A scan kept by the older reading (no libraries in its key) is made again — what LEGO's
        // "FSR 3.1" scan of 3 October was — and what its session showed stays with the new one.
        var olderKey = bareKey
        olderKey.libraries = nil
        olderKey.reading = nil
        var olderScan = bare
        olderScan.live = GraphicsScan.Live(at: Date(), drawnBy: ["libd3dshared.dylib"], gameSize: "1512x982", shownSize: "3024x1964",
                                           pixelFormat: 80, fsrRan: true, fsrWhyNot: nil, generated: 0, shown: 0, guardCorrections: 0)
        GraphicsScan.keep(olderScan, gameID: plainID, key: olderKey)
        check(GraphicsScan.current(gameID: plainID, key: bareKey) == nil, "a scan kept by the older reading isn't read back")
        GraphicsScan.keep(GraphicsScan.scan(executable: plain, backend: .d3dmetal, runtime: e26), gameID: plainID, key: bareKey)
        check(GraphicsScan.current(gameID: plainID, key: bareKey)?.live?.fsrRan == true, "…and the new one keeps what the same build's session showed")
        // LEGO's own folder, as it is: the same answer every time.
        let legoAgain = (0..<3).map { _ in GraphicsScan.scan(executable: lego, backend: .d3dmetal, runtime: e26).summary }
        check(legoScan.builtins.isEmpty && legoAgain.allSatisfy { $0 == legoScan.summary }, "LEGO, scanned three more times: nothing of its own each time")

        // A game that really ships the library — byte for byte AMD's, as a payload is — has it found.
        let shipped = root.appendingPathComponent("Shipped/shipped.exe")
        pe(shipped, version: [1, 0, 0, 0], extra: ["d3d12.dll", "D3D12CreateDevice"])
        try? Data(contentsOf: payload.root.appendingPathComponent("amd_fidelityfx_dx12.dll"))
            .write(to: shipped.deletingLastPathComponent().appendingPathComponent("amd_fidelityfx_dx12.dll"))
        let ownFSR = GraphicsScan.scan(executable: shipped, backend: .d3dmetal, runtime: e26)
        check(ownFSR.builtins.map(\.title) == ["FSR 3.1 (FidelityFX SDK 1.0.1.41314)"],
              "a game shipping AMD's own library, the same bytes as Anvil's payload: its FSR 3.1 found (\(ownFSR.builtins.map(\.title)))")
        // One with its own FidelityFX 1.1.4 and Anvil's injected over it: the game's, set aside, is the one told.
        let updated = root.appendingPathComponent("Updated/updated.exe")
        pe(updated, version: [1, 0, 0, 0], extra: ["d3d12.dll", "D3D12CreateDevice"])
        pe(updated.deletingLastPathComponent().appendingPathComponent("amd_fidelityfx_dx12.dll"), version: [1, 1, 4, 0])
        _ = try? UpscalerManager.shared.forceInject(payload, intoGameAt: updated.path)
        let setAside = GraphicsScan.scan(executable: updated, backend: .d3dmetal, runtime: e26)
        check(setAside.builtins.map(\.title) == ["FSR 3.1 (FidelityFX SDK 1.1.4)"],
              "its own FidelityFX under Anvil's injected one: the game's 1.1.4 is told, not Anvil's 1.0.1.41314 (\(setAside.builtins.map(\.title)))")

        // 9. The Upscaling page's own scan (UpscalerManager.scan(gameAt:)) had the same blind spot
        // until after 0.29.0's Graphics Scan fix: with Anvil's FidelityFX injected, a game with no
        // FSR "integrated FSR", and "FSR 3 temporal — only if the game already has FSR" launched
        // as if it would do something. An OptiScaler-style payload, with XeSS's and DLSS's names
        // too, says "FSR 3.1.5" in its libraries; a game's own FidelityFX says "FSR 2.2.1".
        let upscalers = UpscalerManager.shared
        let shim = FSRRuntime(id: "optiScaler-test", version: "3.1.5", installedAt: Date(),
                              libraryNames: ["amd_fidelityfx_dx12.dll", "amd_fidelityfx_vk.dll", "libxess.dll", "nvngx.dll"])
        for name in shim.libraryNames { pe(shim.root.appendingPathComponent(name), version: [1, 0, 1, 41314], extra: ["FSR 3.1.5"]) }
        func caps(_ c: UpscalerCapability) -> String {
            "FSR \(c.hasFSR)\(c.fsrVersionFound.map { " \($0)" } ?? ""), DLSS \(c.hasDLSS), XeSS \(c.hasXeSS)"
        }
        func launches(_ mode: UpscalerMode, _ cap: UpscalerCapability, forced: Bool = false) -> UpscalerMode {
            var config = UpscalerConfig()
            config.mode = mode
            config.capability = cap
            config.forceInjection = forced
            return config.effectiveMode
        }
        let none = root.appendingPathComponent("None/none.exe")
        pe(none, version: [1, 0, 0, 0], extra: ["d3d11.dll", "D3D11CreateDevice"])
        let noneBare = upscalers.scan(gameAt: none.path)
        check(noneBare.scanned && !noneBare.hasFSR && !noneBare.hasDLSS && !noneBare.hasXeSS && noneBare.bestAvailableMode == .fsr3Every,
              "Upscaling scan, a game with nothing of its own: nothing (\(caps(noneBare)))")
        do {
            let report = try upscalers.forceInject(shim, intoGameAt: none.path)
            check(report.copied.count == 4, "Anvil's injection put the shim's four libraries beside it (\(report.copied))")
        } catch {
            check(false, "injected: \(error.localizedDescription)")
        }
        let noneInjected = (0..<5).map { _ in upscalers.scan(gameAt: none.path) }
        check(noneInjected.allSatisfy { $0 == noneBare },
              "Upscaling scan with Anvil's FidelityFX, XeSS and DLSS names injected beside it, five in a row: still nothing (\(noneInjected.map(caps)))")
        check(launches(.fsr3Native, noneInjected[0]) == .fsr3Every && launches(.fsr3Translated, noneInjected[0]) == .fsr3Every,
              "…so a mode that needs the game's FSR, DLSS or XeSS launches as FSR 3 for every game, as the page says it will")
        check(launches(.fsr3Native, noneInjected[0], forced: true) == .fsr3Every,
              "…forced or not, since 0.62: the retired modes run as FSR 3 for every game")
        try? upscalers.removeInjection(fromGameAt: none.path)
        check(upscalers.scan(gameAt: none.path) == noneBare, "taken out again: the same answer")
        // A game's own FidelityFX 2.2.1 with Anvil's injected over it: the game's, set aside, is told.
        let ownFFX = root.appendingPathComponent("OwnFFX/ownffx.exe")
        pe(ownFFX, version: [1, 0, 0, 0], extra: ["d3d12.dll", "D3D12CreateDevice"])
        pe(ownFFX.deletingLastPathComponent().appendingPathComponent("amd_fidelityfx_dx12.dll"), version: [1, 0, 0, 0], extra: ["FSR 2.2.1"])
        let ownBare = upscalers.scan(gameAt: ownFFX.path)
        _ = try? upscalers.forceInject(shim, intoGameAt: ownFFX.path)
        let ownInjected = upscalers.scan(gameAt: ownFFX.path)
        check(ownBare.hasFSR && ownBare.fsrVersionFound == "2.2.1" && ownInjected == ownBare,
              "its own FSR 2.2.1 under Anvil's 3.1.5: FSR 2.2.1 told, no DLSS or XeSS (\(caps(ownBare)) → \(caps(ownInjected)))")
        check(launches(.fsr3Native, ownInjected) == .fsr3Every && launches(.fsr3Translated, ownInjected) == .fsr3Every,
              "…and since 0.62 neither retired mode runs as itself: a game's own FSR is chosen on its page (GameUpscaler)")
        // Shipping AMD's library byte for byte as the payload has it, with no injection: the game's.
        let sameBytes = root.appendingPathComponent("SameBytes/samebytes.exe")
        pe(sameBytes, version: [1, 0, 0, 0], extra: ["d3d12.dll", "D3D12CreateDevice"])
        try? Data(contentsOf: shim.root.appendingPathComponent("amd_fidelityfx_dx12.dll"))
            .write(to: sameBytes.deletingLastPathComponent().appendingPathComponent("amd_fidelityfx_dx12.dll"))
        let sameScan = upscalers.scan(gameAt: sameBytes.path)
        check(sameScan.hasFSR && sameScan.fsrVersionFound == "3.1.5",
              "a game shipping the same bytes as Anvil's payload, not injected: its FSR 3.1.5 found (\(caps(sameScan)))")
        // LEGO's own folder, as it is.
        let legoCaps = upscalers.scan(gameAt: lego.path)
        check(!legoCaps.hasFSR && !legoCaps.hasDLSS && !legoCaps.hasXeSS, "LEGO, Upscaling scan: nothing of its own (\(caps(legoCaps)))")

        try? fm.removeItem(at: root)
        print(failures == 0 ? "graphics scan: all checks passed" : "graphics scan: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
