// 0.36.0, in a throwaway home: Auto start — what Play does with a game that needs internet to
// start (online: start; store not answering: wait; no connection: another copy that starts
// offline, else wait), how copies of a game are matched across stores, and the wait itself:
// started at once or waited for, Start Offline Anyway, Cancel, and another game's Play.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/AutoStartTest.swift -o $T/AutoStartTest
//   CFFIXED_USER_HOME=<dir>/autostart/home $T/AutoStartTest
import AppKit
import Foundation

@main struct AutoStartHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/autostart/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        _ = NSApplication.shared
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default

        // Programs that exist, so copies of a game count as installed.
        let dir = RuntimeManager.support.appendingPathComponent("games")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func exe(_ name: String) -> String {
            let url = dir.appendingPathComponent(name)
            try? Data("MZ".utf8).write(to: url)
            return url.path
        }

        // LEGO as its record stands here: six offline starts that didn't get going, every way tried.
        var stuck = OfflineRecord()
        stuck.viaEpic = true
        stuck.recent = Array(repeating: .stuck, count: 6)
        stuck.epicWaysFailed = EpicOfflineWay.allCases
        stuck.epicWay = .programAlone
        var lego = Game(title: "LEGO® Star Wars™: The Skywalker Saga", executablePath: exe("LEGO_EPIC.exe"), containerID: UUID())
        lego.epicAppName = "c390e58246ea4a778acd26473a489b48"
        lego.offlineRecord = stuck
        check(OfflineStarts.needsConnection(lego), "LEGO's record: needs internet to start")
        check(AutoStart.signsInToEpic(lego) && AutoStart.storeName(of: lego) == "Epic", "LEGO signs in to Epic at start")

        var catQuest = Game(title: "Cat Quest II", executablePath: exe("CatQuestII.exe"), containerID: UUID())
        catQuest.epicAppName = "6a2cc8b03e684bbd9096a338f96a7ba2"

        // 1. The plan.
        typealias P = AutoStart.Plan
        check(AutoStart.plan(for: catQuest, in: [lego, catQuest], networkUp: false, storeReachable: nil) == P.start,
              "a game that starts offline (or isn't known yet) starts as it is, connection or not")
        check(AutoStart.plan(for: lego, in: [lego], networkUp: true, storeReachable: true) == P.start, "online, Epic answering: started at once")
        check(AutoStart.plan(for: lego, in: [lego], networkUp: true, storeReachable: nil) == P.start, "online, Epic not looked at: started")
        check(AutoStart.plan(for: lego, in: [lego], networkUp: true, storeReachable: false) == P.wait(.storeUnreachable("Epic")),
              "connected but Epic doesn't answer: waits, not into its loading screen")
        check(AutoStart.plan(for: lego, in: [lego, catQuest], networkUp: false, storeReachable: nil) == P.wait(.noConnection),
              "no connection, no other copy: waits")

        // 2. Another copy of it: its Steam edition, which starts in Steam's Offline Mode.
        var steamLego = Game(title: "LEGO Star Wars: The Skywalker Saga", executablePath: exe("LEGO_STEAM.exe"), containerID: UUID())
        steamLego.steamAppID = "920210"
        check(AutoStart.titleKey(lego.title) == AutoStart.titleKey(steamLego.title),
              "titles match across stores, ® and ™ aside (\(AutoStart.titleKey(lego.title)))")
        check(AutoStart.plan(for: lego, in: [lego, steamLego, catQuest], networkUp: false, storeReachable: nil) == P.startInstead(steamLego.id),
              "no connection: its Steam copy starts instead")
        check(AutoStart.plan(for: lego, in: [lego, steamLego], networkUp: true, storeReachable: true) == P.start,
              "online: the copy that was played, not the other one")

        var stuckSteam = steamLego
        stuckSteam.offlineRecord = OfflineRecord()
        stuckSteam.offlineRecord?.recent = [.stuck, .stuck]
        check(AutoStart.otherCopy(of: lego, in: [lego, stuckSteam]) == nil, "a copy that needs internet too isn't one")
        var gone = steamLego
        gone.executablePath = dir.appendingPathComponent("not-installed.exe").path
        check(AutoStart.otherCopy(of: lego, in: [lego, gone]) == nil, "a copy no longer installed isn't one")
        let steamApp = Game(title: "LEGO Star Wars The Skywalker Saga", executablePath: exe("steam.exe"), containerID: UUID())
        check(AutoStart.otherCopy(of: lego, in: [lego, steamApp]) == nil, "a store's own app isn't a copy, whatever it's called")
        check(AutoStart.otherCopy(of: lego, in: [lego, catQuest]) == nil, "another game isn't a copy")
        var playedOffline = Game(title: "LEGO® Star Wars™ — The Skywalker Saga", executablePath: exe("LEGO_OTHER.exe"), containerID: UUID())
        playedOffline.offlineRecord = OfflineRecord()
        playedOffline.offlineRecord?.recent = [.played]
        check(AutoStart.otherCopy(of: lego, in: [lego, steamLego, playedOffline])?.id == playedOffline.id,
              "one that has played offline here comes first")
        check(AutoStart.otherCopy(of: lego, in: [lego, playedOffline, steamLego].reversed())?.id == playedOffline.id, "whatever the order")

        // 3. What its page says.
        check(AutoStart.summary(for: catQuest, in: [catQuest], networkUp: false) == nil, "nothing to say for a game that starts offline")
        let online = AutoStart.summary(for: lego, in: [lego], networkUp: true) ?? ""
        let waits = AutoStart.summary(for: lego, in: [lego], networkUp: false) ?? ""
        let instead = AutoStart.summary(for: lego, in: [lego, steamLego], networkUp: false) ?? ""
        check(online.contains("starts it online at once"), "online: \(online)")
        check(waits.contains("waits and starts it by itself"), "offline: \(waits)")
        check(instead.contains("from Steam") && instead.contains("saves are its own"), "offline with a Steam copy: \(instead)")

        // 4. The wait. In this sandbox the connection may or may not reach Epic, so Play either
        // starts LEGO at once or waits for Epic; with no network it waits for one.
        let library = Library.shared
        library.games = [lego, catQuest]
        let auto = AutoStart.shared
        var started: [String] = []
        auto.play(catQuest) { started.append($0.title) }
        check(started == ["Cat Quest II"] && auto.waiting == nil, "a game that starts offline: started at once, no wait")
        started = []
        auto.play(lego) { started.append($0.title) }
        for _ in 0..<50 where started.isEmpty && auto.waiting == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let networkUp = Connectivity.networkUpNow
        if let w = auto.waiting {
            print("   waiting: \(w.reason.text) (network up: \(networkUp))")
            check(started.isEmpty && w.gameID == lego.id, "LEGO waited for, not started")
            check(networkUp ? w.reason == .storeUnreachable("Epic") : w.reason == .noConnection, "for the right thing")
            auto.play(lego) { started.append("second Play: " + $0.title) }
            check(auto.waiting?.gameID == lego.id && started.isEmpty, "Play again while waiting: still one wait, nothing started")
            auto.startOfflineAnyway()
            check(started == [lego.title] && auto.waiting == nil, "Start Offline Anyway: started, the wait over")

            started = []
            auto.play(lego) { started.append($0.title) }
            for _ in 0..<50 where auto.waiting == nil { try? await Task.sleep(for: .milliseconds(100)) }
            auto.cancel()
            try? await Task.sleep(for: .seconds(4))
            check(started.isEmpty && auto.waiting == nil, "Cancel: nothing started, even after the next look at the connection")

            auto.play(lego) { started.append($0.title) }
            for _ in 0..<50 where auto.waiting == nil { try? await Task.sleep(for: .milliseconds(100)) }
            auto.play(catQuest) { started.append($0.title) }
            check(auto.waiting == nil && started == ["Cat Quest II"], "another game's Play ends the wait and starts that one")
        } else {
            print("   Epic answered here: LEGO started at once")
            check(networkUp && started == [lego.title], "online with Epic answering: started at once")
        }

        // 5. The wording a player reads.
        check(OfflineStarts.howToPlayOffline.contains("Auto start"), "the offline advice names Auto start")

        print(failures == 0 ? "auto start: all passed" : "auto start: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
