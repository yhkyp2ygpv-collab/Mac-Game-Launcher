// 0.37.0, in a throwaway home: the Offline Test's judgement — on copies of LEGO Star Wars' real
// pictures from 10 October, kept as a fixture (online starts move on from the key-art loading
// screen by 10 s; offline ones are still on it at 30 s) and on made-up ones — finding a game's online starts in
// the launch log, what a test does to a game's offline record, which games Test All starts, and
// Steam's readiness for its Offline Mode.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/OfflineTestTest.swift -o $T/OfflineTestTest
//   CFFIXED_USER_HOME=<dir>/offlinetest/home $T/OfflineTestTest <fixtures/lego-screens>
import AppKit
import Foundation

@main struct OfflineTestHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/offlinetest/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        guard CommandLine.arguments.count > 1 else { print("usage: OfflineTestTest <LEGO's Screens folder>"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        typealias J = OfflineJudge

        // 1. LEGO's real pictures, copied (read-only use of the originals).
        let real = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let legoID = UUID(uuidString: "A2B27A63-9693-4E2D-8155-AE0264BD4E69")!
        let mine = ScreenReader.root.appendingPathComponent(legoID.uuidString, isDirectory: true)
        try? fm.createDirectory(at: mine, withIntermediateDirectories: true)
        let online = ["2026-10-10T02.43.30Z", "2026-10-10T02.44.24Z", "2026-10-10T02.47.12Z"]
        let offline = ["2026-10-10T02.38.09Z", "2026-10-10T02.18.47Z"]
        for name in online + offline {
            try? fm.copyItem(at: real.appendingPathComponent(name), to: mine.appendingPathComponent(name))
        }
        func pics(_ name: String) -> [J.Picture] { J.pictures(in: mine.appendingPathComponent(name)) }
        func refs(_ names: [String]) -> [(name: String, pictures: [J.Picture])] { names.map { ($0, pics($0)) } }
        check(pics(offline[0]).map(\.seconds) == [5, 10, 15, 20, 30], "an offline start's pictures read in order (\(pics(offline[0]).map(\.seconds)))")

        let stuck = J.judge(test: pics(offline[0]), references: refs(online), endedAloneAt: nil, shareInFront: 1, title: "LEGO")
        print("   offline start judged: \(stuck.verdict) — \(stuck.detail)")
        check(stuck.verdict == .needsInternet, "LEGO's offline start of 10 October: needs internet to start")
        check(stuck.picture == "030s.jpg" && stuck.referencePicture != nil && stuck.comparedWith != nil, "shown beside the same moment online (\(stuck.picture ?? "-") vs \(stuck.comparedWith ?? "-")/\(stuck.referencePicture ?? "-"))")

        let going = J.judge(test: pics("2026-10-10T02.44.24Z"), references: refs(online.filter { $0 != "2026-10-10T02.44.24Z" }),
                            endedAloneAt: nil, shareInFront: 1, title: "LEGO")
        print("   online start judged: \(going.verdict) — \(going.detail)")
        check(going.verdict == .plays, "an online start, judged the same way: plays")

        let alone = J.judge(test: pics(offline[0]), references: [], endedAloneAt: nil, shareInFront: 1, title: "LEGO")
        check(alone.verdict == .unclear, "the offline start with no online start to compare: can't tell a waiting menu from a stuck screen, so it asks")
        let movingAlone = J.judge(test: pics("2026-10-10T02.47.12Z"), references: [], endedAloneAt: nil, shareInFront: 1, title: "LEGO")
        check(movingAlone.verdict == .plays, "an online start with nothing to compare: its screen kept changing, so it plays")
        let early = J.judge(test: pics(offline[0]), references: refs(online), endedAloneAt: 12, shareInFront: 1, title: "LEGO")
        check(early.verdict == .unclear && early.detail.contains("closed 12 s") && early.picture != nil,
              "closed before the test was over (by itself or from outside Anvil) after showing something: asks, with its picture")
        check(J.judge(test: [], references: refs(online), endedAloneAt: 12, shareInFront: 1, title: "LEGO").verdict == .crashed,
              "closed before showing anything: said so")
        check(J.judge(test: pics(offline[0]), references: refs(online), endedAloneAt: nil, shareInFront: 0.3, title: "LEGO").verdict == .unclear,
              "behind other apps for most of it: can't tell")
        check(J.judge(test: [], references: refs(online), endedAloneAt: nil, shareInFront: 1, title: "Cat Quest II").verdict == .unclear,
              "no pictures at all (an engine Anvil gets no frames from): asks")
        let hidden = J.judge(test: [], references: refs(online), endedAloneAt: nil, shareInFront: 0.1, title: "Cat Quest II")
        check(hidden.verdict == .unclear && hidden.detail.contains("Another window was in front"),
              "no pictures because another window covered it (10 October: macOS's notification prompt over Cat Quest II): says so")

        // 2. Made-up screens: words.
        func flat(_ v: Float, _ s: Int, _ lines: [String] = []) -> J.Picture {
            var t = [Float](repeating: v, count: J.side.w * J.side.h)
            for i in stride(from: 0, to: t.count, by: 7) { t[i] = min(1, v + 0.3) }   // not blank
            return J.Picture(name: String(format: "%03ds.jpg", s), seconds: s, thumb: t, lines: lines)
        }
        let menu = [flat(0.2, 5), flat(0.5, 10, ["PRESS ANY BUTTON"]), flat(0.5, 20), flat(0.5, 30)]
        check(J.judge(test: menu, references: [], endedAloneAt: nil, shareInFront: 1, title: "X").verdict == .plays, "waiting for a button press: plays")
        let menuShot = [flat(0.3, 5), flat(0.5, 20, ["• Swap", "• Play Solo", "Play Co-op", "Quit"])]
        check(ScreenReader.kind(of: ["• Swap", "• Play Solo", "Play Co-op", "Quit"]) == .menu, "Cat Quest II's menu read as a menu")
        let atMenu = J.judge(test: menuShot, references: [], endedAloneAt: 22, shareInFront: 1, title: "Cat Quest II")
        check(atMenu.verdict == .plays && atMenu.detail.contains("its menu"), "10 October, again: closed at 22 s at its menu — it had got going (\(atMenu.detail))")
        check(J.judge(test: menuShot + [flat(0.5, 30, ["• Swap", "• Play Solo", "Play Co-op", "Quit"])], references: [], endedAloneAt: nil, shareInFront: 1, title: "X").verdict == .plays,
              "at its menu through the test: plays")
        check(ScreenReader.kind(of: ["Never Tell Me the Odds", "Defeat the pursuing TIE Fighters!"]) != .menu, "a level's objective isn't a menu")
        let story = [flat(0.4, 5, ["There was once a powerful weapon", "known as the 'Kingsblade'!"])]
        let catQuest = J.judge(test: story, references: [], endedAloneAt: 21, shareInFront: 1, title: "Cat Quest II")
        check(catQuest.verdict == .unclear && catQuest.detail.contains("Kingsblade"), "10 October: Cat Quest II closed at 21 s while telling its story — asks, quoting it")
        check(J.judge(test: [flat(0.3, 5, ["Unable to connect to online services"])], references: [], endedAloneAt: 9, shareInFront: 1, title: "X").verdict == .needsInternet,
              "closed early on a connection error: needs internet")
        let signIn = [flat(0.2, 5), flat(0.3, 20, ["Signing in to Epic Online Services"]), flat(0.3, 30, ["Unable to connect to online services"])]
        let s2 = J.judge(test: signIn, references: [], endedAloneAt: nil, shareInFront: 1, title: "X")
        check(s2.verdict == .needsInternet && s2.detail.contains("Unable to connect"), "still showing a sign-in error at the end: needs internet (\(s2.detail))")
        let passing = [flat(0.2, 5), flat(0.3, 20, ["Playing offline — online features unavailable"]), flat(0.7, 30), flat(0.1, 45)]
        check(J.judge(test: passing, references: [], endedAloneAt: nil, shareInFront: 1, title: "X").verdict == .plays,
              "an offline notice it then moves on from: plays")
        var blank = flat(0, 30); blank.thumb = [Float](repeating: 0, count: blank.thumb.count)
        check(J.isBlank(blank.thumb) && !J.isBlank(flat(0.4, 5).thumb), "black between scenes counts as nothing")

        // 3. Its online starts, from the launch log.
        let root = ScreenReader.root.appendingPathComponent(legoID.uuidString).path
        let log = """
        2026-10-10T02:18:47Z  prepareAndLaunch: LEGO container=Star Wars
        2026-10-10T02:18:47Z    offline test: started as with no connection
        2026-10-10T02:18:47Z    env ANVIL_SCREENS=\(root)/2026-10-10T02.18.47Z
        2026-10-10T02:38:09Z  prepareAndLaunch: LEGO container=Star Wars
        2026-10-10T02:38:09Z    network: offline at the start — this Mac has no connection
        2026-10-10T02:38:09Z    env ANVIL_SCREENS=\(root)/2026-10-10T02.38.09Z
        2026-10-10T02:43:30Z  prepareAndLaunch: LEGO container=Star Wars
        2026-10-10T02:43:30Z    env ANVIL_SCREENS=\(root)/2026-10-10T02.43.30Z
        2026-10-10T02:47:12Z  prepareAndLaunch: LEGO container=Star Wars
        2026-10-10T02:47:12Z    env ANVIL_SCREENS=\(root)/2026-10-10T02.47.12Z
        2026-10-10T02:20:00Z  prepareAndLaunch: LEGO container=Star Wars
        2026-10-10T02:20:00Z    env ANVIL_SCREENS=\(root)/gone
        """
        let found = OfflineTest.onlineFolders(gameID: legoID, launchLog: log).map(\.lastPathComponent)
        check(found == ["2026-10-10T02.47.12Z", "2026-10-10T02.43.30Z"], "only its online starts whose pictures are still there, newest first (\(found))")

        // 4. What a test does to a game's record.
        var plain = Game(title: "Some Game", executablePath: "/bin/ls", containerID: UUID())
        plain.offlineRecord = nil
        var r = OfflineRecord()
        r.test = OfflineTest.Result(date: Date(), verdict: .needsInternet, detail: "x")
        r.add(.stuck, session: Date(), way: nil, decisive: true)
        check(r.doesntGetGoing, "one test that saw it stuck: needs internet to start (a game not from Epic)")
        var epic = OfflineRecord(); epic.viaEpic = true
        epic.test = OfflineTest.Result(date: Date(), verdict: .needsInternet, way: .keptArguments, detail: "x")
        let next = epic.add(.stuck, session: Date(), way: .keptArguments, decisive: true)
        check(next == .epicOfflineMode && !epic.doesntGetGoing, "an Epic game's test that didn't get going moves it to its next way at once, not yet 'needs internet'")
        epic.add(.stuck, session: Date().addingTimeInterval(10), way: .epicOfflineMode, decisive: true)
        epic.add(.stuck, session: Date().addingTimeInterval(20), way: .programAlone, decisive: true)
        check(epic.allEpicWaysTried && epic.doesntGetGoing, "every way tested and none got going: needs internet")
        var good = OfflineRecord()
        good.test = OfflineTest.Result(date: Date(), verdict: .plays, detail: "x")
        good.add(.played, session: Date(), decisive: true)
        check(good.playedOffline && !good.doesntGetGoing, "a test that played: plays offline")
        if let data = try? JSONEncoder().encode(epic), let back = try? JSONDecoder().decode(OfflineRecord.self, from: data) {
            check(back == epic && back.test?.verdict == .needsInternet, "kept with the game and read back")
        } else { check(false, "record round trip") }
        let old = #"{"recent":["stuck"],"viaEpic":false}"#
        check((try? JSONDecoder().decode(OfflineRecord.self, from: Data(old.utf8)))?.test == nil, "a record from before tests still reads")

        // 5. What Test All starts.
        let dir = RuntimeManager.support.appendingPathComponent("games")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func exe(_ n: String) -> String { let u = dir.appendingPathComponent(n); try? Data("MZ".utf8).write(to: u); return u.path }
        var fresh = Game(title: "Fresh", executablePath: exe("fresh.exe"), containerID: UUID())
        var known = Game(title: "Known", executablePath: exe("known.exe"), containerID: UUID()); known.offlineRecord = good
        var lego = Game(title: "LEGO", executablePath: exe("lego.exe"), containerID: UUID()); lego.offlineRecord = epic
        var steamGame = Game(title: "A Steam Game", executablePath: exe("steamgame.exe"), containerID: UUID()); steamGame.steamAppID = "10"
        let steamApp = Game(title: "Steam", executablePath: exe("steam.exe"), containerID: UUID())
        var asked = Game(title: "Asked", executablePath: exe("asked.exe"), containerID: UUID())
        asked.offlineRecord = OfflineRecord(); asked.offlineRecord?.test = OfflineTest.Result(date: Date(), verdict: .unclear, detail: "x")
        var nextWay = Game(title: "Next Way", executablePath: exe("nextway.exe"), containerID: UUID())
        var nw = OfflineRecord(); nw.viaEpic = true
        nw.test = OfflineTest.Result(date: Date(), verdict: .needsInternet, way: .keptArguments, detail: "x")
        nw.add(.stuck, session: Date(), way: .keptArguments, decisive: true)
        nextWay.offlineRecord = nw
        fresh.epicAppName = nil
        let picked = OfflineTest.untested([fresh, known, lego, steamGame, steamApp, asked, nextWay]).map(\.title)
        check(picked == ["Fresh", "Next Way"], "Test All: never tested, or an Epic game with a way left — not ones known, waiting on the player, Steam's or a store app (\(picked))")
        check(OfflineTest.whyNot(steamGame)?.contains("Steam's own Offline Mode") == true, "a Steam game: tested through Steam's readiness instead")
        check(OfflineTest.whyNot(steamApp) != nil && OfflineTest.whyNot(fresh) == nil, "a store app isn't tested; a game is")

        // 6. A test isn't counted as an offline start of the player's.
        var e = SessionEvidence(startedAt: Date(), gameLines: [], launchLines: [
            "  network: offline at the start — an Offline Test: the game's own connections are held back",
            "  \(OfflineTest.logMark) started as with no connection"], windows: [], outcome: nil)
        e.outcome = .init(status: 0, seconds: 66, userClosed: true)
        check(OfflineStarts.outcome(of: e) == nil, "a test session isn't read as a player's offline start")
        e.launchLines.removeLast()
        check(OfflineStarts.outcome(of: e) == .stuck, "while the same session as play would be")

        // 7. Steam's readiness for its Offline Mode.
        let box = Container(name: "Steam Box", runtimeID: "none")
        let config = SteamSupport.steamDir(in: box).appendingPathComponent("config")
        try? fm.createDirectory(at: config, withIntermediateDirectories: true)
        check(SteamSupport.rememberedSignIn(in: box) == nil, "nobody signed in to Steam there: nothing to say")
        let users = { (remember: String) in """
        "users"
        {
            "76561198000000000"
            {
                "AccountName"       "someone"
                "RememberPassword"  "\(remember)"
                "MostRecent"        "1"
            }
        }
        """ }
        try? Data(users("0").utf8).write(to: config.appendingPathComponent("loginusers.vdf"))
        check(SteamSupport.rememberedSignIn(in: box) == false, "signed in without “Remember me”: not ready")
        try? Data(users("1").utf8).write(to: config.appendingPathComponent("loginusers.vdf"))
        check(SteamSupport.rememberedSignIn(in: box) == true, "remembered: ready for Steam's Offline Mode")

        print(failures == 0 ? "offline test: all passed" : "offline test: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
