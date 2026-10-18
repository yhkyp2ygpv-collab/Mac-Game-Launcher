import Foundation

/// 0.23.0 on copies of the real library, Auto-Tune results, launch log and engines, in a
/// throwaway home:
/// 1. the engine-trial rule that weighs what a new engine takes away (the Switch Pro mode),
///    and the one-time re-judgement of trials kept under the old rule — LEGO Star Wars on
///    Engine 3.0 at 84 fps typical against 95 on 2.6.1;
/// 2. Steam's own update read from its bootstrap log, and Health calling a stopped update
///    what it is rather than a failed start.
/// CFFIXED_USER_HOME=…/rejudge/home rejudgetest <Runtimes folder> <Anvil support folder>
@main struct RejudgeHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/rejudge/home/") else { print("refusing"); exit(2) }
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: rejudgetest <Runtimes> <support>"); exit(2) }
        let fm = FileManager.default
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let real = URL(fileURLWithPath: args[2])

        // Copies, before anything loads them.
        try? fm.createDirectory(at: RuntimeManager.support, withIntermediateDirectories: true)
        for name in ["library.json", "anvil.log"] {
            try? fm.removeItem(at: RuntimeManager.support.appendingPathComponent(name))
            try! fm.copyItem(at: real.appendingPathComponent(name), to: RuntimeManager.support.appendingPathComponent(name))
        }
        try? fm.createDirectory(at: RuntimeManager.runtimesDir, withIntermediateDirectories: true)
        for id in ["mythic-engine-2.6.1", "mythic-engine-3.0.0"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp")
            p.arguments = ["-Rc", URL(fileURLWithPath: args[1]).appendingPathComponent(id).path, RuntimeManager.runtimesDir.appendingPathComponent(id).path]
            try! p.run(); p.waitUntilExit()
        }
        RuntimeManager.shared.discover()
        Library.shared.load()
        guard let lego = Library.shared.games.first(where: { $0.title.contains("LEGO") }),
              let cat = Library.shared.games.first(where: { $0.title.contains("Cat Quest") }) else { print("no games"); exit(3) }

        // 1. The rule.
        let before = EngineTrial.Baseline(fps: 95, shareAt80: 0.90, minutes: 5.6)
        check(!EngineTrial.keeps(fps: 84, shareAt80: 0.91, than: before, losesFeatures: true),
              "84 fps against 95, as smooth, losing the Switch Pro mode: not kept")
        check(EngineTrial.keeps(fps: 84, shareAt80: 0.91, than: before, losesFeatures: false),
              "…the same numbers losing nothing: kept, as before")
        check(EngineTrial.keeps(fps: 101, shareAt80: 0.91, than: before, losesFeatures: true),
              "clearly faster (101 against 95): kept even so")
        check(!EngineTrial.keeps(fps: 80, shareAt80: 0.70, than: before, losesFeatures: false),
              "clearly slower: not kept, as before")
        let log = AnvilLog.url
        check(Autopilot.playedWithSwitchPad(title: lego.title, log: log), "LEGO has been played with a Switch pad (launch log)")
        check(!Autopilot.playedWithSwitchPad(title: "No Such Game", log: log), "…a game never launched hasn't")
        _ = cat

        // 2. The re-judgement, once — from the state it was written for, rebuilt here: the real
        // library has moved on (0.23.0 already judged it again on this Mac, and cleared
        // Auto-Tune's results with the switch).
        guard var box = Library.shared.container(id: lego.containerID) else { print("no container"); exit(3) }
        // LEGO's own settings file, so Auto-Tune sees its graphics levels as on this Mac.
        let config = box.driveC.appendingPathComponent("users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT")
        try? fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: config)
        try? fm.copyItem(at: real.appendingPathComponent("Containers/\(box.id.uuidString)/drive_c/users/crossover/AppData/Roaming/Warner Bros. Interactive Entertainment/LEGO Star Wars - The Skywalker Saga/PCCONFIG.TXT"), to: config)
        // On Engine 3.0, kept after its trial against 2.6.1's 95 fps and 90%…
        box.runtimeID = "mythic-engine-3.0.0"
        box.engineTrial = EngineTrial(fromRuntimeID: "mythic-engine-2.6.1", toRuntimeID: "mythic-engine-3.0.0", goodSessions: 3,
                                      before: EngineTrial.Baseline(fps: 95, shareAt80: 0.90, minutes: 5.6), judged: true, byAutopilot: true)
        box.rejectedEngines = []
        box.rejectedAtSupport = nil
        Library.shared.update(box)
        // …with Auto-Tune having counted the session played on it: the real one, 19:27, 5 min.
        let gameText = try! String(contentsOf: real.appendingPathComponent("game.log"), encoding: .utf8)
        let cut = gameText.range(of: "=== Cat Quest II — 2026-10-01T19:34")?.lowerBound ?? gameText.endIndex
        guard let session = FrameLog.lastSession(of: lego.title, text: String(gameText[..<cut])) else { print("no 19:27 session"); exit(3) }
        check(Tuner.shared.autoStart(lego, container: box, played: Gameplay.split(session.windows)), "Auto-Tune counts the 19:27 session on Engine 3.0")
        print("LEGO's container:", box.runtimeID, "trial:", box.engineTrial.map { "\($0.fromRuntimeID) → \($0.toRuntimeID), judged \($0.judged)" } ?? "none",
              "auto-tune:", Tuner.shared.state(for: lego)?.trials.compactMap { t in t.stats.map { String(format: "%.1f min %.0f fps %.0f%%", t.minutes, $0.typicalFPS, $0.shareAt80 * 100) } } ?? [])
        if let trial = box.engineTrial {
            check(Autopilot.shared.lostFeatures(game: lego, trial: trial) != nil, "Engine 3.0 loses LEGO's Switch Pro mode")
        }
        Autopilot.shared.rejudgeKeptTrialsOnce()
        box = Library.shared.container(id: lego.containerID)!
        check(box.runtimeID == "mythic-engine-2.6.1" && box.engineTrial == nil, "judged again: back on Engine 2.6.1")
        check(box.rejectedEngines.contains("mythic-engine-3.0.0") && !box.mayTry(RuntimeManager.shared.runtime(id: "mythic-engine-3.0.0")!),
              "…and Engine 3.0 not tried again until Anvil supports it better")
        let finding = Autopilot.shared.report(for: lego)?.findings.first { $0.id == "engine-trial" }
        print("Health:", finding?.title ?? "-", "—", finding?.detail.prefix(160) ?? "")
        check(finding?.title.contains("loses the Switch Pro mode") == true, "Health says why")
        AnvilLog.rotateIfNeeded(limit: .max)   // on the log's own queue: the writes before it have landed
        check((try? String(contentsOf: log, encoding: .utf8))?.contains("was no faster and loses the Switch Pro mode") == true, "…and the launch log")
        // Once only.
        var again = box
        again.runtimeID = "mythic-engine-3.0.0"
        again.engineTrial = EngineTrial(fromRuntimeID: "mythic-engine-2.6.1", toRuntimeID: "mythic-engine-3.0.0", goodSessions: 3,
                                        before: before, judged: true, byAutopilot: true)
        Library.shared.update(again)
        Autopilot.shared.rejudgeKeptTrialsOnce()
        check(Library.shared.container(id: box.id)!.runtimeID == "mythic-engine-3.0.0", "the re-judgement runs once only")

        // 3. Steam's own update.
        let stoppedLog = """
            [2026-10-01 12:48:33] Startup - updater built May 20 2024 14:26:54
            [2026-10-01 12:48:37] Downloading update (3,693 of 336,229 KB)...
            [2026-10-01 12:48:47] Downloading update (14,454 of 336,229 KB)...
            [2026-10-01 12:48:47] Shutdown
            [2026-10-01 12:48:47] Cancelling download 1 - 1 - 0
            """
        let s = SteamSupport.parseUpdate(stoppedLog)
        check(s == SteamSupport.UpdateState(doneKB: 14454, totalKB: 336229, stopped: true, finished: false), "1 October's log: stopped at 14 of 328 MB (\(s?.amounts ?? "-"))")
        let finished = SteamSupport.parseUpdate(stoppedLog.replacingOccurrences(of: "Shutdown", with: "Download Complete.") + "\n[x] Shutdown")
        check(finished?.finished == true && finished?.stopped == false, "a finished download isn't 'stopped' by a later shutdown")
        let resumed = SteamSupport.parseUpdate(stoppedLog + "\n[2026-10-01 13:00:00] Startup - updater built May 20 2024 14:26:54\n[2026-10-01 13:00:02] Verifying installation...")
        check(resumed == nil, "a new start that hasn't downloaded yet isn't the old stopped one")
        let running = SteamSupport.parseUpdate("[t] Startup - x\n[t] Downloading update (100,000 of 336,229 KB)...")
        check(running?.percent == 29 && running?.stopped == false && running?.finished == false, "a download under way: 29%")

        // 4. Health for that Steam session.
        let steamLines: [Substring] = ["[2026-10-01 12:48:47] Saving metrics to disk"]
        let evidence = SessionEvidence(startedAt: Date(), gameLines: steamLines, launchLines: ["  starting without Anvil's library (switched off for this game)"],
                                       windows: [], outcome: .init(status: 254, seconds: 15.3, userClosed: false))
        let context = DoctorContext(title: "Steam", executableName: "steam.exe", enhancementsOff: true, autopilot: false,
                                    graphicsLevels: false, graphicsLevel: nil, autoTuneMeasuring: false, autoTuneChoice: nil,
                                    directX: false, engine: nil, newerEngineInstalled: nil, newerEngineAvailable: nil,
                                    engineTrial: nil, previousEngineName: nil, leftovers: nil, steamUpdate: s)
        let ids = GameDoctor.diagnose(evidence, context).findings.map(\.id)
        print("Steam's findings:", ids)
        check(ids.contains("steam-update-stopped") && !ids.contains("failed-start"), "a stopped update, not a failed start")
        check(!ids.contains("enhancements-off"), "Steam running without enhancements isn't a problem")
        var plainGame = context
        plainGame.title = "Some Game"; plainGame.executableName = "game.exe"; plainGame.steamUpdate = nil
        let gameIDs = GameDoctor.diagnose(evidence, plainGame).findings.map(\.id)
        check(gameIDs.contains("failed-start") && gameIDs.contains("enhancements-off"), "a game exiting the same way still is one")

        // 5. Game Mode on Engine 3.0 (0.23.1): the program macOS is told the process is.
        let contents = GameModeEngine.storeDir.appendingPathComponent("test-engine/Anvil Game.app/Contents")
        try? fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "wine-preloader",
                                                                          "CFBundleIdentifier": "dev.anvil.game.test-engine"],
                                                        format: .xml, options: 0)
        try! plist.write(to: contents.appendingPathComponent("Info.plist"))
        try! Data().write(to: contents.appendingPathComponent("MacOS/wine-preloader"))
        let copy = Runtime(id: "test-engine", displayName: "Test", version: "1", root: contents, isManaged: true)
        check(GameModeEngine.processPath(for: copy)?.path == contents.appendingPathComponent("MacOS/wine-preloader").path,
              "a Game Mode copy: its app's own program")
        let original = RuntimeManager.shared.runtime(id: "mythic-engine-3.0.0")!
        check(GameModeEngine.processPath(for: original) == nil, "the engine itself: nothing set")
        var wrongName = copy
        try! PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "missing"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        wrongName.id = "test-engine-2"
        check(GameModeEngine.processPath(for: wrongName) == nil, "a program the bundle doesn't have: nothing set")

        // 6. Steam couldn't connect (0.23.2): read from its logs, said by Health.
        let connectionSample = """
            [2026-10-01 13:48:53] Client version: 1788652215
            [2026-10-01 13:56:41] [Connected, 0, 15] [U:1:0] RecvMsgClientLogOnResponse() : 'Try another CM' / 'Failure', ignored since we're not waiting for a logon response
            [2026-10-01 13:56:45] [Connecting, 0, 0] [U:1:0] PingWebSocketCM() (ext1-jnb1.steamserver.net:27019) failed talking to cm (timeout/neterror - Invalid)
            [2026-10-01 13:56:45] [Connecting, 0, 0] [U:1:0] PingWebSocketCM() (cmp2-lhr1.steamserver.net:443) failed talking to cm (timeout/neterror - Invalid)
            [2026-10-01 13:56:46] [Connecting, 0, 0] [U:1:0] PingWebSocketCM() (cmp2-fra2.steamserver.net:27019) failed talking to cm (timeout/neterror - Invalid)
            [2026-10-01 13:56:46] [Connecting, 0, 0] [U:1:0] PingWebSocketCM() (cmp1-fra2.steamserver.net:27019) failed talking to cm (timeout/neterror - Invalid)
            [2026-10-01 13:56:47] [Connecting, 0, 0] [U:1:0] PingWebSocketCM() (cmp1-sto1.steamserver.net:27021) failed talking to cm (timeout/neterror - Invalid)
            """
        let consoleSample = """
            [2026-10-01 13:48:45] Client version: 1788652215
            [2026-10-01 13:49:42] src\\steamUI\\webuitransportcontroller.cpp (165) : Failed to reconnect to websocket: wine
            [2026-10-01 13:51:04] Crypto API failed certificate check, error flags 0x00000008 for '/CN=cmp2-ams1.steamserver.net'
            [2026-10-01 13:52:45] LogonFailure No Connection
            [2026-10-01 13:54:00] LogonFailure No Connection
            """
        let report = SteamSupport.parseConnection(connectionLog: connectionSample, consoleLog: consoleSample,
                                                  cefLog: "[296:380:1001/134859.612:WARNING:net_errors_win.cc(119)] Unknown error 10045 mapped to net::ERR_FAILED")
        check(report == SteamSupport.ConnectionReport(signedIn: false, serversFailed: 5, noConnection: 2, certificateFailures: 1,
                                                       places: ["Frankfurt", "Johannesburg", "London", "Stockholm"], socketUnsupported: true),
              "Steam's logs read: never signed in, 5 servers failed, Frankfurt first (\(report?.places.joined(separator: ", ") ?? "-"))")
        check(report?.couldNotConnect == true, "…which is couldn't connect")
        let fine = SteamSupport.parseConnection(connectionLog: connectionSample + "\n[2026-10-01 14:00:00] [Logged On, 0, 0] [U:1:1] Logged on", consoleLog: consoleSample, cefLog: "")
        check(fine?.signedIn == true && fine?.couldNotConnect == false, "a session that signed in in the end isn't flagged")
        let older = SteamSupport.parseConnection(connectionLog: connectionSample + "\n[2026-10-01 15:00:00] Client version: 1788652215\n[2026-10-01 15:00:05] [Logged On, 0, 0] [U:1:1] x",
                                                 consoleLog: consoleSample + "\n[2026-10-01 15:00:00] Client version: 1788652215", cefLog: "")
        check(older?.serversFailed == 0 && older?.noConnection == 0 && older?.signedIn == true, "only Steam's last session counts")
        // The real logs from this Mac's Steam, read the same way.
        let steamLogs = real.appendingPathComponent("Containers/9E636B71-55DC-4255-9963-600B317BAEF8/drive_c/Program Files (x86)/Steam/logs")
        func text(_ name: String) -> String { (try? String(contentsOf: steamLogs.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        if let realReport = SteamSupport.parseConnection(connectionLog: text("connection_log.txt"), consoleLog: text("console_log.txt"),
                                                         cefLog: text("cef_log.txt"), transportLog: text("transport_steamui.txt")) {
            // Read, not judged: the logs change with every Steam session on this Mac.
            print("this Mac's Steam:", realReport.signedIn ? "signed in" : "not signed in", "· servers failed \(realReport.serversFailed) · no connection \(realReport.noConnection) · window turned away \(realReport.windowRejected) · \(realReport.places.prefix(5).joined(separator: ", "))")
            check(!(realReport.windowRejected > 0 && realReport.couldNotConnect), "this Mac's Steam: a turned-away window isn't taken for no connection")
        }
        // 0.31: Steam turning its own window away (4 October) — not a connection or VPN problem.
        let transportSample = """
            [2026-10-04 16:11:45] Client version: 1788652215
            [2026-10-04 16:11:45] WebUITransportController: Initialized
            [2026-10-04 16:11:50] WebUITransport: Connection from: 127.0.0.1:54897
            [2026-10-04 16:11:50] WebUITransport: Connection rejected
            [2026-10-04 16:11:51] WebUITransport: Connection from: 127.0.0.1:54901
            [2026-10-04 16:11:51] WebUITransport: Connection rejected
            """
        let turnedAway = SteamSupport.parseConnection(connectionLog: connectionSample, consoleLog: consoleSample, cefLog: "", transportLog: transportSample)
        check(turnedAway?.windowRejected == 2 && turnedAway?.couldNotConnect == false, "Steam's window turned away twice, read as that and not as no connection")
        let acceptedLater = SteamSupport.parseConnection(connectionLog: connectionSample, consoleLog: consoleSample, cefLog: "",
                                                         transportLog: transportSample + "\n[2026-10-07 07:50:03] Client version: 1788652215\n[2026-10-07 07:50:49] WebUITransport: Connection from: 127.0.0.1:59640")
        check(acceptedLater?.windowRejected == 0, "a later Steam session whose window got in isn't flagged")
        // Health.
        var steamContext = context
        steamContext.steamUpdate = nil
        steamContext.steamConnection = report
        steamContext.vpn = "ProtonVPN"
        steamContext.engine = DoctorContext.Engine(id: "mythic-engine-3.0.0", name: "Mythic Engine 3.0.0", d3dMetal: "3.0")
        steamContext.steamTestedEngine = "Mythic Engine 2.6.1"
        let okEvidence = SessionEvidence(startedAt: Date(), gameLines: [], launchLines: [], windows: [],
                                         outcome: .init(status: 0, seconds: 504, userClosed: false))
        let vpnFinding = GameDoctor.diagnose(okEvidence, steamContext).findings.first { $0.id == "steam-no-connection" }
        print("Health:", vpnFinding?.detail ?? "-")
        check(vpnFinding?.kind == .problem && vpnFinding?.detail.contains("through ProtonVPN") == true
              && vpnFinding?.detail.contains("Frankfurt") == true && vpnFinding?.fix == .steamTestedEngine,
              "Health: couldn't connect, through ProtonVPN, with Engine 2.6.1 offered")
        steamContext.vpn = nil
        steamContext.steamTestedEngine = nil
        let plainFinding = GameDoctor.diagnose(okEvidence, steamContext).findings.first { $0.id == "steam-no-connection" }
        check(plainFinding != nil && plainFinding?.detail.contains("VPN") == false && plainFinding?.fix == nil,
              "without a VPN or another engine: no VPN advice, no button")
        steamContext.steamConnection = turnedAway
        let rejectedFindings = GameDoctor.diagnose(okEvidence, steamContext).findings
        check(rejectedFindings.contains { $0.id == "steam-window-rejected" && $0.kind == .problem }
              && !rejectedFindings.contains { $0.id == "steam-no-connection" },
              "Health: Steam turned its own window away — said as that, with no VPN or server advice")
        steamContext.steamConnection = fine
        check(!GameDoctor.diagnose(okEvidence, steamContext).findings.contains { $0.id == "steam-no-connection" || $0.id == "steam-window-rejected" }, "a Steam that signed in: nothing said")
        print("VPN here:", Connectivity.activeVPN() ?? "none seen (this sandbox can't read network settings)")

        // 7. Epic offline starts without legendary (0.23.3).
        let app = "c390e58246ea4a778acd26473a489b48"
        let online = ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=0123456789abcdef0123456789abcdef", "-AUTH_TYPE=exchangecode",
                      "-epicapp=\(app)", "-epicenv=Prod", "-epicovt=ownership.token", "-EpicPortal", "-epicusername=Player",
                      "-epicuserid=00000000000000000000000000000001", "-epiclocale=en", "-epicsandboxid=9c59efaabb6a48f19b3485d5d9416032"]
        let offlineArgs = EpicOfflineStart.offline(from: online)
        check(offlineArgs.contains("-AUTH_PASSWORD=") && !offlineArgs.contains { $0.hasPrefix("-epicovt=") }
              && !offlineArgs.joined().contains("0123456789abcdef"), "offline: no sign-in code, no ownership token — as legendary's own offline start")
        check(offlineArgs.count == online.count - 1 && offlineArgs.contains("-epicuserid=00000000000000000000000000000001"), "…everything else as it was")
        check(EpicOfflineStart.arguments(appName: app) == nil, "nothing kept before an online start")
        EpicOfflineStart.remember(online, appName: app)
        check(EpicOfflineStart.arguments(appName: app) == offlineArgs, "kept after an online start, and read back")
        let onDisk = (try? Data(contentsOf: EpicOfflineStart.file)) ?? Data()
        check(!onDisk.isEmpty && onDisk.range(of: Data("epicuserid".utf8)) == nil && onDisk.prefix(4) == Data("ANVV".utf8),
              "…sealed on disk: the account isn't readable in the file")
        EpicOfflineStart.remember(["-epicapp=other"], appName: "other")
        check(EpicOfflineStart.arguments(appName: "other") == nil, "arguments without an account aren't kept")
        EpicOfflineStart.forget()
        check(EpicOfflineStart.arguments(appName: app) == nil, "dropped when another account signs in")

        print(failures == 0 ? "rejudge: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
