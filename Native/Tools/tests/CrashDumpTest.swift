import Foundation

// 0.58: a Windows game's own crash record (CrashDump) read for where it crashed, and what that says about FSR and frame
// generation (GameDoctor.crashCause). Args: a real minidump (LEGO Star Wars' of 17 October, written 2 s after the Mac
// woke), anvil.log, and (0.62) Hogwarts Legacy's of 21 October with the Epic Games setup it ran in. Run with
// CFFIXED_USER_HOME set to a scratch folder.
@main struct CrashDumpHarness {
    /// A minidump of our own: modules, a stack, an exception at `fault`, the stack holding `onStack`.
    static func dump(modules: [(String, UInt64, UInt32)], fault: UInt64, onStack: [UInt64]) -> Data {
        var d = Data(count: 32)
        func put32(_ v: UInt32, at o: Int) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.replaceSubrange(o..<o + 4, with: $0) } }
        func put64(_ v: UInt64, at o: Int) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.replaceSubrange(o..<o + 8, with: $0) } }
        func grow(_ n: Int) -> Int { let at = d.count; d.append(Data(count: n)); return at }
        d.replaceSubrange(0..<4, with: Data("MDMP".utf8))
        put32(0xA793, at: 4); put32(3, at: 8)
        let dir = grow(3 * 12); put32(UInt32(dir), at: 12)
        // Names
        var nameRVAs: [Int] = []
        for m in modules {
            let utf16 = Array(("C:\\windows\\system32\\" + m.0).utf16)
            let at = grow(4 + utf16.count * 2 + 2)
            put32(UInt32(utf16.count * 2), at: at)
            for (i, c) in utf16.enumerated() { d[at + 4 + i * 2] = UInt8(c & 0xFF); d[at + 5 + i * 2] = UInt8(c >> 8) }
            nameRVAs.append(at)
        }
        // Module list
        let list = grow(4 + modules.count * 108)
        put32(UInt32(modules.count), at: list)
        for (i, m) in modules.enumerated() {
            put64(m.1, at: list + 4 + i * 108); put32(m.2, at: list + 4 + i * 108 + 8); put32(UInt32(nameRVAs[i]), at: list + 4 + i * 108 + 20)
        }
        // The stack: 64 slots, the addresses spread among junk
        let rsp: UInt64 = 0x8000_0000
        let stack = grow(64 * 8)
        for i in 0..<64 { put64(0x1234_5678_9ABC, at: stack + i * 8) }
        for (i, a) in onStack.enumerated() { put64(a, at: stack + (2 + i * 3) * 8) }
        let mem = grow(4 + 16)
        put32(1, at: mem); put64(rsp, at: mem + 4); put32(64 * 8, at: mem + 12); put32(UInt32(stack), at: mem + 16)
        // Context: rsp at 0x98
        let ctx = grow(0x4D0)
        put64(rsp, at: ctx + 0x98)
        // Exception stream
        let ex = grow(168)
        put32(1, at: ex); put32(0xC000_0005, at: ex + 8); put64(fault, at: ex + 8 + 16)
        put32(0x4D0, at: ex + 8 + 152); put32(UInt32(ctx), at: ex + 8 + 156)
        let entries: [(UInt32, Int, Int)] = [(4, 4 + modules.count * 108, list), (5, 20, mem), (6, 168, ex)]
        for (i, e) in entries.enumerated() {
            put32(e.0, at: dir + i * 12); put32(UInt32(e.1), at: dir + i * 12 + 4); put32(UInt32(e.2), at: dir + i * 12 + 8)
        }
        return d
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } }
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { print("FAIL: run with CFFIXED_USER_HOME"); exit(1) }
        let fm = FileManager.default

        // 1. Our own dumps.
        let exe = ("Game.exe", UInt64(0x1_4000_0000), UInt32(0x700_0000))
        let eos = ("EOSSDK-Win64-Shipping.dll", UInt64(0x8035_0000), UInt32(0x100_0000))
        let d3d = ("d3d11.dll", UInt64(0x1_13F6_0000), UInt32(0x10_0000))
        let ntdll = ("ntdll.dll", UInt64(0x1_7000_0000), UInt32(0x10_0000))
        let online = CrashDump.read(dump(modules: [exe, eos, d3d, ntdll], fault: exe.1 + 0x3227490,
                                         onStack: [exe.1 + 0xC8748, eos.1 + 0x27FBF8, ntdll.1 + 0x76113, exe.1 + 0x322806D]))
        check(online?.code == 0xC000_0005 && online?.faultModule == "Game.exe", "the exception and where: \(String(describing: online))")
        check(online?.stackModules == ["Game.exe", "EOSSDK-Win64-Shipping.dll", "ntdll.dll"], "the stack's modules, in order, once each: \(online?.stackModules ?? [])")
        let words = online.flatMap(CrashDump.notGraphics)
        check(words?.contains("Epic Online Services") == true && words?.contains("an access violation in Game.exe") == true, "online code, said: \(words ?? "nil")")
        let inD3D = CrashDump.read(dump(modules: [exe, eos, d3d], fault: d3d.1 + 0x100, onStack: [eos.1 + 0x10]))
        check(inD3D.flatMap(CrashDump.notGraphics) == nil, "in d3d11: graphics could be in it")
        let d3dOnStack = CrashDump.read(dump(modules: [exe, eos, d3d], fault: exe.1 + 0x100, onStack: [d3d.1 + 0x40, eos.1 + 0x10]))
        check(d3dOnStack.flatMap(CrashDump.notGraphics) == nil, "Direct3D on its stack: graphics could be in it")
        let plain = CrashDump.read(dump(modules: [exe, ntdll], fault: exe.1 + 0x100, onStack: [ntdll.1 + 0x10]))
        check(plain.flatMap(CrashDump.notGraphics) == nil, "the game's own code alone: not enough to rule graphics out")
        check(CrashDump.read(Data("not a dump".utf8)) == nil && CrashDump.read(Data()) == nil, "not a minidump")
        var cut = dump(modules: [exe, eos], fault: exe.1, onStack: [eos.1])
        cut = cut.prefix(cut.count / 2)
        _ = CrashDump.read(cut)   // cut short: read or not, without a crash

        // 2. LEGO Star Wars' own, of 17 October, in a prefix of ours, from the session's launch log.
        let args = CommandLine.arguments
        if args.count >= 2 {
            let prefix = URL(fileURLWithPath: home).appendingPathComponent("prefix", isDirectory: true)
            let folder = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/CRASHDATA/2026_10_17T20_29_21", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("CRASHDATA-MINI-2026_10_17T20_29_21.DMP")
            try? fm.removeItem(at: file)
            try? fm.copyItem(at: URL(fileURLWithPath: args[1]), to: file)
            let iso = ISO8601DateFormatter()
            try? fm.setAttributes([.modificationDate: iso.date(from: "2026-10-17T20:29:21Z")!], ofItemAtPath: file.path)
            let lego = CrashDump.read((try? Data(contentsOf: file)) ?? Data())
            check(lego?.code == 0xC000_0005 && lego?.faultModule == "LEGOSTARWARSSKYWALKERSAGA_DX11.exe"
                  && lego?.stackModules.contains("EOSSDK-Win64-Shipping.dll") == true, "LEGO's dump: \(String(describing: lego))")
            let title = "LEGO® Star Wars™: The Skywalker Saga"
            let log = """
            2026-10-17T19:29:12Z  prepareAndLaunch: \(title) container=Star Wars runtime=Mythic Engine 2.6.1 exe=/x.exe
            2026-10-17T19:29:20Z    env WINEPREFIX=\(prefix.path)
            2026-10-17T20:02:01Z  focus: loginwindow came to the front
            2026-10-17T20:29:19Z  focus: LEGOSTARWARSSKYWALKERSAGA_DX11.exe (Mythic) came to the front (as dev.anvil.game.mythic-engine-2.6.1, bundle Anvil Game.app)
            2026-10-17T20:29:32Z  exited: \(title) code=5 after 3612.0s, 1899 s of it awake
            """
            let lines = log.split(separator: "\n")
            let cause = GameDoctor.crashCause(launchLines: lines, gameLines: [])
            check(cause?.contains("Epic Online Services") == true && cause?.contains("2 s after the Mac woke from 29 minutes asleep") == true,
                  "the crash put where it was: \(cause ?? "nil")")
            print("LEGO, 17 October: \(cause ?? "nil")")
            // The same session with its record written long before it: not this crash's.
            try? fm.setAttributes([.modificationDate: iso.date(from: "2026-10-05T01:11:51Z")!], ofItemAtPath: file.path)
            check(GameDoctor.crashCause(launchLines: lines, gameLines: []) == nil, "a crash record from another day isn't this session's")
        } else {
            print("(no LEGO dump given: its part left out)")
        }

        // 3. The launch log itself, as Housekeeping's restore reads it (optional arg 2: anvil.log, with the real prefix).
        if args.count >= 3, let text = try? String(contentsOfFile: args[2], encoding: .utf8) {
            let lines = text.split(separator: "\n")
            let title = "LEGO® Star Wars™: The Skywalker Saga"
            if let off = lines.lastIndex(where: { $0.contains("autopilot: \(title) closed unexpectedly with FSR 3 on") }),
               let start = lines[..<off].lastIndex(where: { $0.contains("prepareAndLaunch: \(title) ") }) {
                let cause = GameDoctor.crashCause(launchLines: Array(lines[start..<off]), gameLines: [])
                check(cause?.contains("Epic Online Services") == true, "from the launch log as it is: \(cause ?? "nil")")
            } else {
                print("(no FSR 3 switch-off in this launch log)")
            }
        }

        // 4. (0.62) Hogwarts Legacy's own, of 21 October: an unhandled C++/WinRT exception at its pause menu (args 3 and 4:
        // its minidump, and the Epic Games setup it ran in, read for its registry).
        if args.count >= 5 {
            let real = URL(fileURLWithPath: args[4], isDirectory: true)
            let prefix = URL(fileURLWithPath: home).appendingPathComponent("hogwarts", isDirectory: true)
            let folder = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local/Phoenix/Saved/Crashes/D5A205B34C1B65B7B3A14A9ED32D527D", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Phoenix-Game-Shipping-204_2026.10.21_16.39.dmp")
            try? fm.removeItem(at: file)
            try? fm.copyItem(at: URL(fileURLWithPath: args[3]), to: file)
            try? fm.removeItem(at: prefix.appendingPathComponent("system.reg"))
            try? fm.copyItem(at: real.appendingPathComponent("system.reg"), to: prefix.appendingPathComponent("system.reg"))
            let iso = ISO8601DateFormatter()
            try? fm.setAttributes([.modificationDate: iso.date(from: "2026-10-21T23:39:58Z")!], ofItemAtPath: file.path)
            let report = CrashDump.read((try? Data(contentsOf: file)) ?? Data())
            check(report?.code == CrashDump.cppException && report?.thrower?.hasSuffix("\\HogwartsLegacy.exe") == true
                  && report?.throwInfoRVA == 0x90E_0C68, "a C++ exception thrown by the game: \(String(describing: report))")
            let explained = report.map { CrashDump.explain($0, prefix: prefix) }
            check(explained?.thrownTypes == ["winrt::hresult_class_not_registered", "winrt::hresult_error"],
                  "what was thrown, read from the game's program: \(explained?.thrownTypes ?? [])")
            check(explained?.missingClasses == ["Windows.UI.ViewManagement.Core.CoreInputView"],
                  "the Windows class it asks for that the setup hasn't: \(explained?.missingClasses ?? [])")
            let words = explained.flatMap(CrashDump.notGraphics)
            check(words?.contains("on-screen keyboard") == true && words?.contains("not graphics") == true, "said: \(words ?? "nil")")
            check(report.flatMap(CrashDump.notGraphics) == nil, "unread, the same dump rules nothing out")
            let title = "Hogwarts Legacy"
            let log = """
            2026-10-21T23:23:58Z  prepareAndLaunch: \(title) container=Epic Games runtime=Mythic Engine 3.0.0 exe=/x.exe
            2026-10-21T23:24:05Z    env WINEPREFIX=\(prefix.path)
            2026-10-21T23:40:30Z  exited: \(title) code=3 after 984.8s, 985 s of it awake
            """
            let cause = GameDoctor.crashCause(launchLines: log.split(separator: "\n"), gameLines: [])
            check(cause?.contains("Windows' on-screen keyboard") == true, "the crash put where it was: \(cause ?? "nil")")
            print("Hogwarts Legacy, 21 October: \(cause ?? "nil")")
            // From the launch log as it is, as Housekeeping's 0.62 restore reads it.
            if let text = try? String(contentsOfFile: args[2], encoding: .utf8) {
                let lines = text.split(separator: "\n")
                if let off = lines.lastIndex(where: { $0.contains("autopilot: \(title) closed unexpectedly with FSR in one pass") }),
                   let start = lines[..<off].lastIndex(where: { $0.contains("prepareAndLaunch: \(title) ") }) {
                    let real = GameDoctor.crashCause(launchLines: Array(lines[start..<off]), gameLines: [])
                    check(real?.contains("on-screen keyboard") == true, "from the launch log as it is: \(real ?? "nil")")
                } else {
                    print("(no one-pass switch-off for \(title) in this launch log)")
                }
            }
        } else {
            print("(no Hogwarts Legacy dump given: its part left out)")
        }

        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("crash dump: all checks passed")
    }
}
