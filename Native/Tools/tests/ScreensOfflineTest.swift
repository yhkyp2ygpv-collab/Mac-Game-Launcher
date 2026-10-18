// 0.32.0, in a throwaway home: the words read off a session's pictures of the screen
// (ScreenReader), what kind of screen they make, and what the check-up says of a game closed on
// one; each game's record of its starts with no connection (OfflineStarts), from made-up logs
// and from the real anvil.log, read-only.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/ScreensOfflineTest.swift -o $TMPDIR/ScreensOfflineTest
//   CFFIXED_USER_HOME=<dir>/home HOME=<dir>/home $TMPDIR/ScreensOfflineTest <real anvil.log>
import AppKit
import CoreText
import Foundation
import ImageIO

@main struct ScreensOfflineHarness {
    /// A frame like a game's, at libanvil's picture size, with these lines of text on it.
    static func picture(_ lines: [String], to url: URL) {
        let w = 756, h = 491
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
        for (i, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [
                .font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
            let ctLine = CTLineCreateWithAttributedString(text)
            ctx.textPosition = CGPoint(x: 60, y: CGFloat(h) - 120 - CGFloat(i) * 60)
            CTLineDraw(ctLine, ctx)
        }
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/home/") else { print("refusing: not in a throwaway home"); exit(2) }
        let realLog = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default

        // 1. A session's pictures, named as libanvil names them, read.
        let gameID = UUID()
        let started = ISO8601DateFormatter().date(from: "2026-10-08T00:16:49Z")!
        let folder = ScreenReader.folder(gameID: gameID, startedAt: started)
        check(folder.path.hasSuffix("/Screens/\(gameID.uuidString)/2026-10-08T00.16.49Z"), "a session's folder is named by its line in game.log (\(folder.lastPathComponent))")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        picture(["WARNER BROS. GAMES"], to: folder.appendingPathComponent("005s.jpg"))
        picture(["LOADING"], to: folder.appendingPathComponent("030s.jpg"))
        picture(["PRESS ANY BUTTON"], to: folder.appendingPathComponent("045s.jpg"))
        picture(["Unable to connect to online services", "Press A to continue"], to: folder.appendingPathComponent("last.jpg"))
        var t = Date()
        let shots = ScreenReader.read(folder: folder)
        let firstRead = Date().timeIntervalSince(t)
        check(shots.map(\.name) == ["005s.jpg", "030s.jpg", "045s.jpg", "last.jpg"], "pictures in order, the last one last (\(shots.map(\.name)))")
        check(shots.first?.seconds == 5 && shots.last?.isLast == true, "times read from the names")
        for s in shots { print("   \(s.name): \(s.lines)") }
        check(shots[1].lines.joined(separator: " ").uppercased().contains("LOADING"), "the loading screen's word is read")
        check(shots[2].lines.joined(separator: " ").uppercased().contains("PRESS ANY BUTTON"), "the title screen's words are read")
        check(ScreenReader.kind(of: shots[2].lines) == .pressToStart, "…and taken for a screen waiting for a button")
        check(ScreenReader.kind(of: shots[1].lines) == .loading, "LOADING is a loading screen")
        check(ScreenReader.kind(of: shots[3].lines) == .connection, "a connection message is one, though it also says press A")
        check(ScreenReader.atClose(shots)?.name == "last.jpg", "what was on screen at the close is the last picture")
        check(fm.fileExists(atPath: folder.appendingPathComponent("text.json").path), "what was read is kept beside the pictures")
        t = Date()
        let again = ScreenReader.read(folder: folder)
        let secondRead = Date().timeIntervalSince(t)
        check(again == shots && secondRead < firstRead / 3, String(format: "…and read back, not read again (%.0f ms, first %.0f ms)", secondRead * 1000, firstRead * 1000))
        try? await Task.sleep(for: .seconds(1.1))
        picture(["Saving, please wait"], to: folder.appendingPathComponent("last.jpg"))
        let changed = ScreenReader.read(folder: folder)
        check(ScreenReader.kind(of: changed.last?.lines ?? []) == .loading, "a picture newer than what was kept is read again (\(changed.last?.lines ?? []))")
        let line = ScreenReader.logLine(title: "Test Game", shots: shots) ?? ""
        print("   \(line)")
        check(line.hasPrefix("screens: Test Game — 5 s “") && line.contains("at the end “"), "one line for the launch log")
        check(ScreenReader.quote(["A", String(repeating: "x", count: 200)]).count <= 120, "a long screen is quoted short")
        // A long session's pictures, every 10 minutes from 0.41: named by seconds, said in minutes.
        let long = [ScreenReader.Shot(name: "300s.jpg", seconds: 300, lines: ["Dagobah"]),
                    ScreenReader.Shot(name: "1200s.jpg", seconds: 1200, lines: ["Naboo"]),
                    ScreenReader.Shot(name: "last.jpg", seconds: nil, lines: ["Quit?"])]
        let longLine = ScreenReader.logLine(title: "Long", shots: long) ?? ""
        check(longLine == "screens: Long — 300 s “Dagobah”, 20 min “Naboo”, at the end “Quit?”" && ScreenReader.seconds(of: "1200s.jpg") == 1200,
              "a long session's pictures said in minutes (\(longLine))")
        let blank = ScreenReader.root.appendingPathComponent("blank-test", isDirectory: true)
        try? fm.createDirectory(at: blank, withIntermediateDirectories: true)
        picture([], to: blank.appendingPathComponent("005s.jpg"))
        let none = ScreenReader.read(folder: blank)
        check(none.count == 1 && none[0].lines.isEmpty && ScreenReader.atClose(none) == nil, "a screen with no words reads as none")
        check(ScreenReader.read(folder: folder.appendingPathComponent("missing")).isEmpty, "no pictures, nothing read")

        // 2. Only a game's newest sessions are kept.
        for i in 0..<11 {
            try? fm.createDirectory(at: ScreenReader.folder(gameID: gameID, startedAt: started.addingTimeInterval(Double(i + 1) * 60)), withIntermediateDirectories: true)
        }
        ScreenReader.prune(gameID: gameID)
        let left = (try? fm.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path))?.sorted() ?? []
        check(left.count == 8 && !left.contains(folder.lastPathComponent) && left.last == "2026-10-08T00.27.49Z", "the newest eight sessions are kept (\(left.count))")

        // 3. The check-up on a game closed on a screen.
        let title = "Test Game"
        func evidence(_ lines: [String], screens: [[String]], seconds: Double = 40, closed: Bool = true) -> SessionEvidence {
            let launch = (["\(ISO8601DateFormatter().string(from: started))  prepareAndLaunch: \(title) container=x runtime=y exe=z"] + lines
                          + ["2026-10-08T00:16:52Z  focus: GAME.exe (Mythic) came to the front (as dev.anvil.game.x, bundle Anvil Game.app)"])
                .map { Substring($0) }
            var e = SessionEvidence(startedAt: started, gameLines: [], launchLines: launch, windows: [],
                                    outcome: .init(status: 0, seconds: seconds, userClosed: closed))
            e.screens = screens.enumerated().map { i, l in ScreenReader.Shot(name: i == screens.count - 1 ? "last.jpg" : "0\(i)5s.jpg", seconds: i == screens.count - 1 ? nil : i * 5 + 5, lines: l) }
            return e
        }
        let context = DoctorContext(title: title, executableName: "GAME.exe", enhancementsOff: false, autopilot: true,
                                    graphicsLevels: false, graphicsLevel: nil, autoTuneMeasuring: false, autoTuneChoice: nil,
                                    directX: true, engine: nil, newerEngineInstalled: nil, newerEngineAvailable: nil,
                                    engineTrial: nil, previousEngineName: nil, leftovers: nil)
        func finding(_ e: SessionEvidence, _ c: DoctorContext = context, _ id: String = "screen-at-close") -> HealthFinding? {
            GameDoctor.diagnose(e, c).findings.first { $0.id == id }
        }
        let press = finding(evidence([], screens: [["LOADING"], ["PRESS ANY BUTTON"]]))
        check(press?.title.contains("waiting for a button press") == true && press?.detail.contains("“PRESS ANY BUTTON”") == true, "closed on its title screen: “\(press?.title ?? "none")”")
        let offlineLine = "2026-10-08T00:16:49Z    network: offline at the start — Offline Mode is on"
        let connection = finding(evidence([offlineLine], screens: [["Unable to connect to online services"]]))
        check(connection?.title.contains("connection") == true && connection?.detail.contains("started with no connection") == true, "closed on a connection message, offline: said so (\(connection?.kind.rawValue ?? "none"))")
        let error = finding(evidence([], screens: [["A fatal error occurred"]]))
        check(error?.kind == .problem, "closed on an error: a problem")
        check(finding(evidence([], screens: [["PRESS ANY BUTTON"]], closed: false)) == nil, "not when the game closed by itself")
        check(finding(evidence([], screens: [["PRESS ANY BUTTON"]], seconds: 3600)) == nil, "not after an hour in front")
        check(finding(evidence([], screens: [[]])) == nil, "not when nothing on screen could be read")

        // 4. Offline starts: how each went, from the launch log.
        func session(_ at: String, offline: Bool, seconds: Double, closed: Bool = true, frontFor: Double? = nil, epic: Bool = true,
                     way: EpicOfflineWay? = nil) -> String {
            let start = ISO8601DateFormatter().date(from: at)!
            func stamp(_ s: Double) -> String { ISO8601DateFormatter().string(from: start.addingTimeInterval(s)) }
            var lines = ["\(at)  prepareAndLaunch: \(title) container=x runtime=y exe=z"]
            if offline { lines.append("\(at)    network: offline at the start — this Mac has no connection") }
            if epic {
                lines.append(offline ? "\(at)    Epic: this Mac is offline — started offline as the signed-in account" + (way.map { " (\($0.logMark))" } ?? "")
                                     : "\(at)    Epic: signed in through Anvil's legendary (x); 0 DLC installed")
            }
            lines.append("\(stamp(2))  focus: GAME.exe (Mythic) came to the front (as dev.anvil.game.x, bundle Anvil Game.app)")
            if let f = frontFor { lines.append("\(stamp(2 + f))  focus: Finder came to the front") }
            lines.append("\(stamp(seconds))  exited: \(title) code=0 after \(seconds)s, \(Int(seconds)) s of it awake\(closed ? " (closed from Anvil)" : "")")
            return lines.joined(separator: "\n")
        }
        var log = [session("2026-10-01T10:00:00Z", offline: false, seconds: 3000, epic: true),
                   session("2026-10-02T10:00:00Z", offline: true, seconds: 40),
                   session("2026-10-03T10:00:00Z", offline: true, seconds: 900, frontFor: 45)].joined(separator: "\n")
        var record = OfflineStarts.history(title: title, launchLog: log)
        check(record.recent == [.stuck, .stuck], "an online start doesn't count; 40 s, and 15 min with 45 s in front, are offline starts that didn't get going (\(record.recent))")
        check(record.viaEpic && !record.doesntGetGoing && record.epicWaysFailed == [.keptArguments] && record.currentWay == .epicOfflineMode,
              "…two in a row with Epic's kept arguments: the next offline start is Epic Offline Mode's (\(record.epicWaysFailed), \(record.currentWay))")
        log += "\n" + session("2026-10-04T08:00:00Z", offline: true, seconds: 50, way: .keptArguments)
        check(OfflineStarts.history(title: title, launchLog: log).currentWay == .epicOfflineMode, "a start the old way after that doesn't move the ladder")
        log += "\n" + session("2026-10-04T09:00:00Z", offline: true, seconds: 50, way: .epicOfflineMode)
        record = OfflineStarts.history(title: title, launchLog: log)
        check(record.currentWay == .programAlone && !record.doesntGetGoing, "one stuck start as Epic Offline Mode: next is the program on its own")
        log += "\n" + session("2026-10-04T09:30:00Z", offline: true, seconds: 50, way: .programAlone)
        record = OfflineStarts.history(title: title, launchLog: log)
        check(record.allEpicWaysTried && record.doesntGetGoing, "every way tried and none got going: Anvil asks before the next, and starts it online when it can")
        let ladder = log
        log += "\n" + session("2026-10-04T10:00:00Z", offline: true, seconds: 1800, way: .programAlone)
        record = OfflineStarts.history(title: title, launchLog: log)
        check(record.recent.last == .played && !record.doesntGetGoing, "once played offline, it isn't asked about")
        log += "\n" + session("2026-10-05T10:00:00Z", offline: true, seconds: 60, closed: false)
        check(OfflineStarts.history(title: title, launchLog: log).recent.count == 6, "a start that ended by itself says nothing either way")
        let other = [session("2026-10-02T10:00:00Z", offline: true, seconds: 40, epic: false),
                     session("2026-10-03T10:00:00Z", offline: true, seconds: 50, epic: false)].joined(separator: "\n")
        check(OfflineStarts.history(title: title, launchLog: other).doesntGetGoing, "a game that isn't Epic's: two in a row and Anvil asks")

        // The ways, one by one.
        let kept = ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=", "-AUTH_TYPE=exchangecode", "-epicapp=x", "-epicenv=Prod", "-EpicPortal",
                    "-epicusername=Player", "-epicuserid=0001", "-epiclocale=en", "-epicsandboxid=y"]
        check(EpicOfflineWay.keptArguments.arguments(from: kept) == kept, "kept arguments: as kept")
        check(EpicOfflineWay.epicOfflineMode.arguments(from: kept + ["-epicovt=t"])
                == ["-epicapp=x", "-epicenv=Prod", "-EpicPortal", "-epicusername=Player", "-epicuserid=0001", "-epiclocale=en", "-epicsandboxid=y"],
              "Epic Offline Mode: the account's name and id, no sign-in arguments")
        check(EpicOfflineWay.programAlone.arguments(from: kept).isEmpty, "the program on its own: nothing from Epic")
        check(OfflineStarts.epicWay(["  network: offline at the start — x", "    Epic: this Mac is offline — started offline as its program on its own (offline way: programAlone)"]) == .programAlone,
              "the way read back from the launch log")
        check(OfflineStarts.epicWay(["  network: offline at the start — x", "    Epic: this Mac is offline — started offline as the signed-in account"]) == .keptArguments,
              "a start from before the ways: Epic's kept arguments")
        check(OfflineStarts.epicWay(["    Epic: signed in through Anvil's legendary (x)"]) == nil, "an online start has no way")
        var played = OfflineRecord(); played.viaEpic = true
        played.add(.played, session: started, way: .keptArguments)
        played.add(.stuck, session: started.addingTimeInterval(1), way: .keptArguments)
        check(played.currentWay == .keptArguments, "a way that has played isn't dropped for one quick close")
        played.add(.stuck, session: started.addingTimeInterval(2), way: .keptArguments)
        check(played.currentWay == .epicOfflineMode, "…but two in a row move it on")
        let legacy = try? JSONDecoder().decode(OfflineRecord.self, from: Data(#"{"recent":["stuck","stuck","stuck"],"viaEpic":true}"#.utf8))
        check(legacy?.epicWaysFailed == [.keptArguments] && legacy?.currentWay == .epicOfflineMode && legacy?.doesntGetGoing == false,
              "a record from 0.33.0 that hadn't got going goes on to the next way")
        let saved = (try? JSONEncoder().encode(record)).flatMap { try? JSONDecoder().decode(OfflineRecord.self, from: $0) }
        check(saved == record, "the ladder survives being saved")
        var r = OfflineRecord()
        r.add(.stuck, session: started); r.add(.stuck, session: started)
        check(r.recent.count == 1, "the same session counted once")
        for i in 0..<9 { r.add(.stuck, session: started.addingTimeInterval(Double(i + 1))) }
        check(r.recent.count == 6, "the last six kept")
        let decoded = try? JSONDecoder().decode(OfflineRecord.self, from: Data(#"{"recent":["stuck","played"]}"#.utf8))
        check(decoded?.recent == [.stuck, .played] && decoded?.viaEpic == false, "a record missing keys still reads")
        var game = Game(title: title, executablePath: "/x/GAME.exe", containerID: UUID())
        check(OfflineStarts.summary(for: game).text.hasPrefix("Not started offline here yet"), "a game with no record: said")
        game.offlineRecord = OfflineStarts.history(title: title, launchLog: [session("2026-10-02T10:00:00Z", offline: true, seconds: 40),
                                                                             session("2026-10-03T10:00:00Z", offline: true, seconds: 50)].joined(separator: "\n"))
        let midway = OfflineStarts.summary(for: game)
        check(midway.warn && midway.text.contains("next one starts as Epic Offline Mode"), "midway, its page says which way is next: \(midway.text)")
        game.offlineRecord = OfflineStarts.history(title: title, launchLog: ladder)
        game.offlineRecord?.lastScreen = "LOADING"
        let summary = OfflineStarts.summary(for: game)
        check(summary.warn && summary.text.contains("(“LOADING”)"), "its page warns, with what it showed: \(summary.text)")
        var c2 = context; c2.offline = game.offlineRecord
        let stuck = finding(evidence([offlineLine], screens: [["LOADING"]]), c2, "offline-stuck")
        check(stuck?.detail.contains("Epic Offline Mode's own start") == true, "the check-up says it hasn't got going offline, any way")
        var c3 = context
        c3.offline = OfflineStarts.history(title: title, launchLog: [session("2026-10-02T10:00:00Z", offline: true, seconds: 40),
                                                                    session("2026-10-03T10:00:00Z", offline: true, seconds: 50)].joined(separator: "\n"))
        check(finding(evidence([offlineLine], screens: [["LOADING"]]), c3, "offline-next-way")?.detail.contains("Epic Offline Mode") == true,
              "midway, the check-up says which way is next")
        check(finding(evidence([], screens: []), c2, "offline-stuck") == nil, "…only after an offline start")

        // 5. The real log: LEGO Star Wars' offline starts, 3–8 October.
        if let realLog, let text = try? String(contentsOf: realLog, encoding: .utf8) {
            let lego = OfflineStarts.history(title: "LEGO® Star Wars™: The Skywalker Saga", launchLog: text)
            print("   LEGO offline starts in the real log: \(lego.recent.map(\.rawValue))")
            check(lego.recent.count >= 4 && lego.viaEpic && lego.epicWaysFailed == [.keptArguments] && lego.currentWay == .epicOfflineMode,
                  "LEGO's offline starts here didn't get going with Epic's kept arguments; the next way is Epic Offline Mode's")
            let cat = OfflineStarts.history(title: "Cat Quest II", launchLog: text)
            print("   Cat Quest II offline starts: \(cat.recent.map(\.rawValue))")
            check(!cat.doesntGetGoing, "Cat Quest II isn't marked")
        }

        print(failures == 0 ? "screens and offline: all passed" : "screens and offline: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
