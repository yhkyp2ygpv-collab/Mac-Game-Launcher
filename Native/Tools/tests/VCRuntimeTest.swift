// Microsoft's Visual C++ Runtime for the games that need it (VCRuntime, Authenticode), and Autopilot
// leaving graphics alone for a game that closed before its first frame.
//
// Run with a home of its own — nothing here may touch the real support folder:
//   CFFIXED_USER_HOME=$T/home HOME=$T/home VCRuntimeTest <hogwarts.exe> <fnaf.exe> <VC_redist.x64.exe> \
//       <tampered.exe> <wine builtin notepad.exe> <system.reg with the runtime> <real Epic prefix> \
//       <real game.log> [install]
// Before running: $T/home/Library/Application Support/Anvil/Epic/installed.json (a copy of the real one),
// and for "install" a link $T/home/Library/Application Support/Anvil/Runtimes → the real Runtimes.
import Foundation

@main
struct VCRuntimeTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    @MainActor
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 9 else { print("usage: see header"); exit(2) }
        let hogwarts = URL(fileURLWithPath: a[1]), fnaf = URL(fileURLWithPath: a[2])
        let redist = URL(fileURLWithPath: a[3]), tampered = URL(fileURLWithPath: a[4]), notepad = URL(fileURLWithPath: a[5])
        let withRuntimeReg = URL(fileURLWithPath: a[6]), epicPrefix = URL(fileURLWithPath: a[7]), gameLog = URL(fileURLWithPath: a[8])
        let install = a.count > 9 && a[9] == "install"
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
        check(RuntimeManager.support.path.hasPrefix(NSHomeDirectory()) && !RuntimeManager.support.path.hasPrefix(realHome + "/Library"),
              "a home of its own: \(RuntimeManager.support.path)")

        print("— what games need")
        let h = VCRuntime.need(executable: hogwarts)
        check(h?.checksRegistry == true, "Hogwarts Legacy's launcher reads Microsoft's key")
        check(h?.arches == [.x64], "x64 only: \(h?.arches.map(\.rawValue) ?? [])")
        check(h?.minimum == VCRuntime.Version(major: 14, minor: 24, build: 28127, rebuild: 4), "Unreal's minimum, 14.24.28127.4: \(h?.minimum.description ?? "-")")
        check(h?.reasons.contains { $0.contains("Phoenix") || $0.contains("HogwartsLegacy.exe uses") } == true,
              "and the game it starts uses the DLLs: \(h?.reasons ?? [])")
        // Its Unity player carries the C++ runtime inside itself (no msvcp140/vcruntime140 imported), and
        // nothing checks for Microsoft's key: it doesn't need it. Its start was held by Anvil's own regedit.
        let f = VCRuntime.need(executable: fnaf)
        check(f == nil, "Five Nights at Freddy's: Into the Pit (Unity, runtime built in) needs nothing: \(f?.reasons ?? [])")
        let byStore = VCRuntime.need(executable: notepad, storePrerequisites: ["Binaries/Windows/VC_redist.x64.exe", "VC_redist.x64"])
        check(byStore?.arches == [.x64], "a store's listed prerequisite counts: \(byStore?.reasons ?? [])")
        check(VCRuntime.need(executable: notepad) == nil, "Wine's own notepad needs nothing")
        check(VCRuntime.registryCheck(in: Data("nothing here".utf8)) == nil, "no key name, no check")

        print("— what a container has")
        let reg = (try? String(contentsOf: withRuntimeReg, encoding: .utf8)) ?? ""
        let v = VCRuntime.keyVersion(reg, endingWith: "microsoft\\\\visualstudio\\\\14.0\\\\vc\\\\runtimes\\\\x64]")
        check(v == VCRuntime.Version(major: 14, minor: 32, build: 31332, rebuild: 0), "the key Microsoft's installer wrote: \(v?.description ?? "-")")
        check(VCRuntime.installed(prefix: withRuntimeReg.deletingLastPathComponent())[.x64] == v, "and its DLLs are Microsoft's own there")
        check(VCRuntime.installed(prefix: epicPrefix).isEmpty, "the Epic Games setup today: Wine's own files, no key")
        check(!VCRuntime.isMicrosoftsOwn(epicPrefix.appendingPathComponent("drive_c/windows/system32/vcruntime140.dll")),
              "Wine's vcruntime140 is told from Microsoft's")
        let old = "[Software\\\\Microsoft\\\\VisualStudio\\\\14.0\\\\VC\\\\Runtimes\\\\x64] 1\n\"Installed\"=dword:00000001\n\"Major\"=dword:0000000e\n\"Minor\"=dword:00000010\n"
        let oldV = VCRuntime.keyVersion(old, endingWith: "microsoft\\\\visualstudio\\\\14.0\\\\vc\\\\runtimes\\\\x64]")
        check(oldV.map { $0 < VCRuntime.Version.unrealMinimum } == true, "14.16 is older than Unreal wants: \(oldV?.description ?? "-")")
        check(VCRuntime.keyVersion("[Software\\\\Other] 1\n\"Major\"=dword:0000000e\n", endingWith: "runtimes\\\\x64]") == nil, "another key isn't it")

        print("— Microsoft's installer, checked")
        check(VCRuntime.fileVersion(redist) == VCRuntime.Version(major: 14, minor: 32, build: 31332, rebuild: 0), "its version: \(VCRuntime.fileVersion(redist)?.description ?? "-")")
        let good = VCRuntime.verified(redist)
        check(good.ok, "signed by Microsoft, whole: \(good.why)")
        if case .success(let s) = Authenticode.check(redist) { print("     trust: \(s.trustDetail ?? "the Mac's own")") }
        let bad = VCRuntime.verified(tampered)
        check(!bad.ok && bad.why.contains("changed"), "one changed byte is caught: \(bad.why)")
        check(!VCRuntime.verified(notepad).ok, "an unsigned program isn't run: \(VCRuntime.verified(notepad).why)")
        check(!VCRuntime.verified(hogwarts).ok, "nor a signed-by-nobody launcher")

        print("— choosing one")
        let offline = await VCRuntime.installer(.x64, minimum: .unrealMinimum, games: [], online: false)
        if case .success(let i) = offline {
            check(i.url.path == redist.path, "offline: the one Epic delivered with Cat Quest II (\(i.source))")
        } else { check(false, "offline: found none — \(offline)") }
        let tooOld = await VCRuntime.installer(.x64, minimum: VCRuntime.Version(major: 14, minor: 40), games: [], online: false)
        if case .failure(let e) = tooOld { check(e.localizedDescription.contains("needs 14.40"), "too old for a newer need, said: \(e.localizedDescription)") }
        else { check(false, "a 14.32 installer accepted for 14.40") }
        // A download that isn't Microsoft's is thrown away, and the one on this Mac used instead.
        let forged = await VCRuntime.installer(.x64, minimum: .unrealMinimum, games: [], online: true) { _ in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("forged-\(UUID().uuidString).exe")
            try FileManager.default.copyItem(at: tampered, to: copy)
            return copy
        }
        if case .success(let i) = forged { check(i.url.path == redist.path, "a changed download is turned away; the local one used") }
        else { check(false, "after a bad download: \(forged)") }
        check(!FileManager.default.fileExists(atPath: VCRuntime.cacheFolder.appendingPathComponent("VC_redist.x64.exe").path), "and nothing bad was kept")
        let fetched = await VCRuntime.installer(.x64, minimum: .unrealMinimum, games: [], online: true) { _ in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("good-\(UUID().uuidString).exe")
            try FileManager.default.copyItem(at: redist, to: copy)
            return copy
        }
        if case .success(let i) = fetched { check(i.source == "from Microsoft", "a good download is kept and used: \(i.source)") }
        else { check(false, "a good download: \(fetched)") }
        var asked = false
        _ = await VCRuntime.installer(.x64, minimum: .unrealMinimum, games: [], online: true) { url in asked = true; throw URLError(.badURL) }
        check(!asked, "a download kept less than 90 days isn't fetched again")

        print("— Autopilot: closed before the first frame")
        let text = (try? String(contentsOf: gameLog, encoding: .utf8)) ?? ""
        func session(_ title: String) -> SessionEvidence {
            let r = text.range(of: "=== \(title) — ", options: .backwards)!
            let lines = text[r.upperBound...].split(separator: "\n").dropFirst().prefix { !$0.hasPrefix("=== ") }
            return SessionEvidence(startedAt: nil, gameLines: Array(lines), launchLines: [], windows: lines.compactMap { FrameLog.parse($0) })
        }
        check(!session("Hogwarts Legacy").drewFrames, "Hogwarts Legacy's 17 October start drew nothing")
        check(session("LEGO® Star Wars™: The Skywalker Saga").drewFrames, "LEGO's last session drew")
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("drew-\(UUID().uuidString).log")
        try? """

        === Cat Quest II — 2026-10-10T01:00:00Z — Anvil 0.40.0 ===
        12:00:00.000 [anvil] drawable 3024x1964 format=80 writable=1 srgb=0 -> ACTIVE
        === Hogwarts Legacy — 2026-10-18T05:04:09Z — Anvil 0.58.1 ===
        22:04:11.511 [anvil] shaders compiled from source in 511 ms
        """.write(to: logs, atomically: true, encoding: .utf8)
        let at = ISO8601DateFormatter().date(from: "2026-10-18T06:00:00Z")!
        check(VCRuntime.drewBefore(title: "Cat Quest II", installedAt: at, logs: [logs]), "a game that drew before the install ran without it")
        check(!VCRuntime.drewBefore(title: "Hogwarts Legacy", installedAt: at, logs: [logs]), "Hogwarts Legacy never drew")
        check(!VCRuntime.drewBefore(title: "Cat Quest II", installedAt: ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!, logs: [logs]),
              "a session after the install doesn't count as before")

        let engine = ProcessInfo.processInfo.environment["VC_TEST_ENGINE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if install, let engine, case let runtime = Runtime(id: "mythic-engine-3.0.0", displayName: "Mythic Engine 3.0.0", version: "3.0.0",
                                                            root: engine, isManaged: true, source: "test"), runtime.isUsable {
            print("— installed through Anvil, into a container of its own (Wine 9)")
            var c = Container(name: "VC test", runtimeID: runtime.id)
            c.id = UUID()
            try? FileManager.default.createDirectory(at: c.prefixURL, withIntermediateDirectories: true)
            let started = Date()
            _ = Launcher.runHelper(runtime.wine64, ["wineboot", "-u"], environment: ["WINEPREFIX": c.prefixURL.path, "WINEDEBUG": "-all"], timeout: 120)
            await Launcher.waitForWineserver(container: c, runtime: runtime, timeout: 30)
            check(VCRuntime.installed(in: c).isEmpty, String(format: "a new Windows setup has none (%.0f s to make)", Date().timeIntervalSince(started)))
            let chosen = await VCRuntime.installer(.x64, minimum: .unrealMinimum, games: [], online: false)
            guard case .success(let installer) = chosen else { check(false, "no installer"); exit(1) }
            let t = Date()
            let result = await VCRuntime.install(installer, arch: .x64, into: c, runtime: runtime)
            if case .success(let v) = result { check(v >= .unrealMinimum, String(format: "installed %@ in %.0f s", v.description, Date().timeIntervalSince(t))) }
            else { check(false, "install: \(result)") }
            check(h.map { VCRuntime.missing($0, in: c).isEmpty } == true, "Hogwarts Legacy's need is met there")
            check(VCRuntime.loadsMicrosofts(c), "its games load Microsoft's DLLs")
            VCRuntime.useWinesOwn(c, why: "test")
            check(!VCRuntime.loadsMicrosofts(c), "and Wine's own again once a game that ran before stops starting")
            try? FileManager.default.removeItem(at: VCRuntime.winesOwnMark(c))
            Launcher.killPrefix(wineserver: runtime.wineserver, prefix: c.prefixURL)
        } else if install {
            check(false, "no usable engine at VC_TEST_ENGINE")
        }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
