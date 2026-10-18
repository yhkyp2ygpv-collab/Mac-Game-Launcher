// 0.25.0, against the real game and logs, read-only, in a throwaway home: LEGO Star Wars'
// keep-running switch found in its own program; stretches drawn behind other apps and the
// loading before a game's first scene left out of play; the offline session flag; Auto-Tune
// learning from sessions after it decided; and the check-up's look at Wine servers.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/OfflineLoadTest.swift -o $TMPDIR/OfflineLoadTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/OfflineLoadTest <LEGO exe> <real game.log> <other exe>
import Foundation

@main struct OfflineLoadHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/") else { print("refusing: not in a throwaway home"); exit(2) }
        let args = CommandLine.arguments
        let lego = URL(fileURLWithPath: args[1]), gameLog = URL(fileURLWithPath: args[2]), other = URL(fileURLWithPath: args[3])
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }

        // 1. The keep-running switch, read from the program and remembered.
        var t = Date()
        let found = KeepRunning.supportedSwitch(for: lego)
        let first = Date().timeIntervalSince(t)
        check(found == "-NoFocus_Process", "LEGO Star Wars' program carries -NoFocus_Process (\(String(format: "%.0f ms", first * 1000)))")
        t = Date()
        check(KeepRunning.supportedSwitch(for: lego) == "-NoFocus_Process" && Date().timeIntervalSince(t) < 0.05, "…remembered: the second look reads nothing")
        check(KeepRunning.supportedSwitch(for: other) == nil, "a program without it gets nothing (\(other.lastPathComponent))")

        // 2. Stretches behind other apps, and loading, aren't play.
        let line: Substring = "22:24:51.345 [anvil] displayed 30.0 fps | 1% LOW 29.7 fps | STEADY 100.0% | worst gap 33.3 ms | rendered 30.0 fps (game could 158.6) | real=4197 | GPU 22% busy | busiest threads 21% and 12% of a core | steady 80: 120 or as ready (0 held) | behind 600"
        let w = FrameLog.parse(line)
        check(w?.behind == 600 && w?.wasBehind == true, "a stretch drawn behind another app is read as such")
        let text = try! String(contentsOf: gameLog, encoding: .utf8)
        let title = "LEGO® Star Wars™: The Skywalker Saga"
        check(Gameplay.loadsIntoHeavy(title: title, text: text), "LEGO's sessions load into a heavy first scene")
        func session(_ stamp: String) -> [FrameWindow] {
            guard let r = text.range(of: "=== \(title) — \(stamp)") else { return [] }
            var out: [FrameWindow] = []
            for l in text[r.upperBound...].split(separator: "\n").dropFirst() {
                if l.hasPrefix("=== ") { break }
                if let w = FrameLog.parse(l) { out.append(w) }
            }
            return out
        }
        let stuck = session("2026-10-03T05:24:17Z")
        check(!stuck.isEmpty && Gameplay.split(stuck).play.count > 0, "the offline start on its loading screen counted as play before (\(Gameplay.split(stuck).play.count) stretches)")
        check(Gameplay.split(stuck, loadsIntoHeavy: true).play.isEmpty, "…and counts as none now")
        let played = session("2026-10-03T05:21:45Z")
        let split = Gameplay.split(played, loadsIntoHeavy: true)
        check(!split.play.isEmpty && split.play.allSatisfy { ($0.gpuBusy ?? 0) > 0 }, "a session that reached its first scene still has play (\(split.play.count) stretches)")
        let behindAdded = played + [w!, w!]
        check(Gameplay.split(behindAdded, loadsIntoHeavy: true).play.count == split.play.count, "stretches behind another app are left out of play")

        // 3. The offline session flag.
        let container = Container(name: "Test", runtimeID: "none")
        Launcher.setOffline(true, for: container)
        check(FileManager.default.fileExists(atPath: Launcher.offlineFlag(for: container).path), "an offline start leaves its flag for the session")
        Launcher.setOffline(false, for: container)
        check(!FileManager.default.fileExists(atPath: Launcher.offlineFlag(for: container).path), "…and an online one, or the session's end, takes it away")

        // 4. The check-up's look at this user's processes.
        let mine = CheckUp.environment(of: getpid())
        check(mine["HOME"] != nil, "a process's environment can be read (KERN_PROCARGS2)")
        let real = gameLog.deletingLastPathComponent()      // Anvil's own folder, where its engines are
        let servers = CheckUp.anvilWineServers(under: real)
        print("info: Anvil Wine servers running now: \(servers.count)" + servers.map { " | pid \($0.pid) prefix \($0.prefix ?? "?")" }.joined())

        print(failures == 0 ? "offline and loading: all checks passed" : "offline and loading: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
