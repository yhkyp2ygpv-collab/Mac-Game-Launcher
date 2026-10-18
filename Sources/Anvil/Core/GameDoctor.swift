import Foundation

// MARK: - What was found

/// One thing Anvil found about how a game ran, and what was done or can be done.
struct HealthFinding: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        /// Something wrong that needs the player, or a button here.
        case problem
        /// Something wrong that Anvil has already put right.
        case fixed
        /// What limits the game and what would help, where nothing is broken.
        case advice
        /// Working as it should.
        case good

        var order: Int {
            switch self {
            case .problem: 0
            case .fixed: 1
            case .advice: 2
            case .good: 3
            }
        }
    }

    /// What a finding's button does.
    enum Fix: String, Codable {
        case enhancementsOn
        case removeLeftovers
        case switchEngine
        case showEngines
        case switchBack
        case controllerAsConnected
        case bestContainer
        case epicSignIn
        case ownContainer
        case steamTestedEngine

        var label: String {
            switch self {
            case .steamTestedEngine: "Use Engine 2.6.1 for Steam"
            case .enhancementsOn: "Turn Enhancements Back On"
            case .removeLeftovers: "Remove Them"
            case .switchEngine: "Switch Engine…"
            case .showEngines: "Show Engines"
            case .switchBack: "Switch Back"
            case .controllerAsConnected: "Use As Connected"
            case .bestContainer: "Apply Best Settings"
            case .epicSignIn: "Sign In to Epic…"
            case .ownContainer: "Give It Its Own Container"
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var fix: Fix?
}

/// Everything found about one session.
struct HealthReport: Codable, Hashable {
    var checkedAt: Date
    var sessionStartedAt: Date?
    var playMinutes: Double
    var findings: [HealthFinding]

    var problems: Int { findings.filter { $0.kind == .problem }.count }
    var fixed: Int { findings.filter { $0.kind == .fixed }.count }

    /// One line for a banner or a log.
    var headline: String {
        var parts: [String] = []
        if fixed > 0 { parts.append("fixed \(fixed) thing\(fixed == 1 ? "" : "s")") }
        if problems > 0 { parts.append("\(problems) to look at") }
        let advice = findings.filter { $0.kind == .advice }.count
        if advice > 0 { parts.append("\(advice) suggestion\(advice == 1 ? "" : "s")") }
        return parts.isEmpty ? "everything ran as it should" : parts.joined(separator: ", ")
    }
}

// MARK: - The evidence

/// What a session left behind: its part of game.log, its part of anvil.log, and how it
/// ended.
struct SessionEvidence {
    struct Outcome {
        var status: Int32
        var seconds: Double
        var userClosed: Bool
    }

    var startedAt: Date?
    /// game.log after this session's header.
    var gameLines: [Substring]
    /// anvil.log from this session's launch to the next launch.
    var launchLines: [Substring]
    var windows: [FrameWindow]
    var outcome: Outcome?
    /// Its earlier sessions loaded into a heavy first scene; see Gameplay.split.
    var loadsIntoHeavy = false
    /// How long it usually takes to get there on this Mac.
    var loadEstimate: LoadTime.Estimate?
    /// The words on its screen, from the pictures Anvil kept of it (ScreenReader).
    var screens: [ScreenReader.Shot] = []

    /// Whether the game got as far as drawing: its first frame reached Anvil's presenter, where FSR,
    /// frame generation and everything else Anvil does to a picture starts. A game that closed before
    /// that — Hogwarts Legacy's launcher, missing Microsoft's Visual C++ Runtime, on 17 October — can't
    /// have been upset by any of them.
    var drewFrames: Bool {
        !windows.isEmpty || gameLines.contains { line in
            line.contains("[anvil] FSR to the display: the game draws") || line.contains("-> ACTIVE")
                || line.contains("[anvil] displayed ") || (line.contains("[anvil] graphics: ") && line.contains(" sets a layer to "))
        }
    }

    /// The last session of `title` in both logs. Nil when game.log has none.
    static func read(title: String, gameLog: URL, launchLog: URL, outcome: Outcome? = nil) -> SessionEvidence? {
        guard let gameText = try? String(contentsOf: gameLog, encoding: .utf8),
              let header = gameText.range(of: "=== \(title) — ", options: .backwards) else { return nil }
        let rest = gameText[header.upperBound...]
        let startedAt = rest.split(separator: " ", maxSplits: 1).first
            .flatMap { ISO8601DateFormatter().date(from: String($0)) }
        var gameLines: [Substring] = []
        var windows: [FrameWindow] = []
        for line in rest.split(separator: "\n").dropFirst() {
            if line.hasPrefix("=== ") { break }
            gameLines.append(line)
            if let w = FrameLog.parse(line) { windows.append(w) }
        }

        // anvil.log: only its tail can hold the session just played.
        var launchLines: [Substring] = []
        if let handle = try? FileHandle(forReadingFrom: launchLog) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let from = size > 1_500_000 ? size - 1_500_000 : 0
            try? handle.seek(toOffset: from)
            if let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) {
                let lines = text.split(separator: "\n")
                if let start = lines.lastIndex(where: { $0.contains("prepareAndLaunch: \(title) ") }) {
                    for line in lines[start...].dropFirst() {
                        if line.contains("prepareAndLaunch: ") { break }
                        launchLines.append(line)
                    }
                    launchLines.insert(lines[start], at: 0)
                }
            }
        }
        var evidence = SessionEvidence(startedAt: startedAt, gameLines: gameLines, launchLines: launchLines,
                                       windows: windows, outcome: outcome)
        if evidence.outcome == nil { evidence.outcome = evidence.outcomeFromLog(title: title) }
        evidence.loadsIntoHeavy = Gameplay.loadsIntoHeavy(title: title, text: gameText)
        evidence.loadEstimate = LoadTime.estimate(of: title, text: gameText)
        return evidence
    }

    /// "exited: <title> code=0 after 179.0s, 179 s of it awake (closed from Anvil)"
    func outcomeFromLog(title: String) -> Outcome? {
        guard let line = launchLines.last(where: { $0.contains("exited: \(title) code=") }),
              let code = line.range(of: "code="), let after = line.range(of: " after ", range: code.upperBound..<line.endIndex),
              let status = Int32(line[code.upperBound..<after.lowerBound]),
              let s = line.range(of: "s", range: after.upperBound..<line.endIndex),
              let seconds = Double(line[after.upperBound..<s.lowerBound]) else { return nil }
        return Outcome(status: status, seconds: seconds, userClosed: line.contains("(closed from Anvil)"))
    }
}

// MARK: - What the doctor knows about the game

struct DoctorContext {
    struct Engine: Hashable {
        var id: String
        var name: String
        var d3dMetal: String?
    }

    var title: String
    var executableName: String
    var enhancementsOff: Bool
    var autopilot: Bool
    /// Anvil can set the game's own graphics options (GameTuning).
    var graphicsLevels: Bool
    var graphicsLevel: GraphicsLevel?
    /// Auto-Tune's state for the game, in words, when it has one.
    var autoTuneMeasuring: Bool
    var autoTuneChoice: String?
    /// A DirectX 11 or 12 game, for which D3DMetal decides how it runs.
    var directX: Bool
    var engine: Engine?
    var newerEngineInstalled: Engine?
    /// A newer engine tried here and switched back from, which isn't offered again.
    var triedEngineName: String? = nil
    var newerEngineAvailable: String?
    var engineTrial: EngineTrial?
    /// The engine an engine trial switched from, by name.
    var previousEngineName: String?
    var leftovers: (files: Int, replacedOwn: [String])?
    /// Anything the autopilot did before the diagnosis, as findings.
    var actions: [HealthFinding] = []
    /// The other app's Wine setup the game is installed in, when that isn't its container.
    var foreignSetup: String? = nil
    var containerName: String = ""
    /// Steam itself: where its own download stood when it closed.
    var steamUpdate: SteamSupport.UpdateState? = nil
    /// Steam itself: how its last session went with Steam's servers.
    var steamConnection: SteamSupport.ConnectionReport? = nil
    /// The VPN this Mac's traffic goes through, when there is one.
    var vpn: String? = nil
    /// Steam is on a preview engine (Wine 9), and an engine Steam is better tested on is installed.
    var steamTestedEngine: String? = nil
    /// How its starts with no connection have gone here.
    var offline: OfflineRecord? = nil
}

// MARK: - The diagnosis

/// Reads what a session left behind and says what limited the game, what went wrong,
/// and what would help. No state and no side effects, so each rule can be checked on its
/// own against real logs.
enum GameDoctor {
    static func diagnose(_ e: SessionEvidence, _ c: DoctorContext) -> HealthReport {
        var out = c.actions
        func add(_ id: String, _ kind: HealthFinding.Kind, _ title: String, _ detail: String, _ fix: HealthFinding.Fix? = nil) {
            guard !out.contains(where: { $0.id == id }) else { return }
            out.append(HealthFinding(id: id, kind: kind, title: title, detail: detail, fix: fix))
        }
        let log = e.launchLines
        let game = e.gameLines

        // --- How it started and ended ---
        let isSteam = c.executableName.lowercased() == "steam.exe"
        let steamRestarted = e.outcome.map { !$0.userClosed && $0.status == 42 } == true && isSteam
        if steamRestarted {
            add("steam-restart", .good, "Steam updated itself",
                "It closed to finish the update, as Steam does, and Anvil started it again.")
        }
        // Steam's own first download, shut down part-way — from its window, not a crash.
        let steamUpdateStopped = isSteam && c.steamUpdate?.stopped == true
        if steamUpdateStopped, let u = c.steamUpdate {
            add("steam-update-stopped", .advice, "Steam's update was stopped part-way",
                "Steam was downloading itself (\(u.amounts), \(u.percent)%) when it was shut down — its window closed or quit before the download finished. Open Steam again from the library and leave it open until its window appears: it carries on where it stopped. Anvil shows the download's progress while it runs.")
        }
        if let o = e.outcome, !o.userClosed, o.status != 0, !steamRestarted, !steamUpdateStopped {
            if o.seconds < 25 {
                var detail = String(format: "It exited with code %d after %.0f s, before showing a frame for long.", o.status, o.seconds)
                if log.contains(where: { $0.contains("fails without Anvil's library too") }) {
                    detail += " It did the same without Anvil's enhancements, so they aren't the cause — the game or its engine is."
                } else if log.contains(where: { $0.contains("trying once without it") }) {
                    detail += " Anvil tried it once more without its enhancements."
                }
                if let line = crashLine(in: log + game) { detail += " The last error it printed: “\(line)”." }
                add("failed-start", .problem, "\(c.title) closed straight after starting", detail)
            } else {
                var detail = String(format: "It exited with code %d after %@ without being asked to.", o.status, minutesText(o.seconds / 60))
                if endedFromOutside(launchLines: log, gameLines: game) {
                    add("crash", .advice, "\(c.title) was ended from outside Anvil",
                        String(format: "It was ended after %@ by SIGKILL from outside Anvil — a force quit from another app, or macOS freeing memory when it ran short. That isn't the game crashing, and Anvil's settings were left as they were.", minutesText(o.seconds / 60)))
                } else {
                    if let line = crashLine(in: log + game) { detail += " The last error it printed: “\(line)”." }
                    // Its own crash record, where it keeps one (0.58): where it crashed, and when that was waking.
                    if let record = CrashDump.cause(launchLines: log) {
                        detail += " " + record.prefix(1).uppercased() + record.dropFirst() + "."
                        if record.contains("after the Mac woke") {
                            detail += " Its online code can fall over when the Mac wakes with it open: save before closing the lid or leaving the Mac to sleep."
                        }
                    }
                    add("crash", .problem, "\(c.title) closed unexpectedly", detail)
                }
            }
        }
        // Steam turned its own sign-in window away: Wine 9 on this macOS gave Windows no table of
        // connections to find the window's in. Anvil's library fixes that from 0.31 (anvil_net.mm).
        if isSteam, let r = c.steamConnection, !r.signedIn, r.windowRejected > 0 {
            add("steam-window-rejected", .problem, "Steam turned its own sign-in window away",
                "Steam checks which program each connection to it comes from, and its sign-in window's was refused "
                + "\(r.windowRejected == 1 ? "once" : "\(r.windowRejected) times") — so what was typed there never reached Steam. "
                + "Under Wine before 10 on this version of macOS, Windows was told of no connections at all. Anvil now gives Wine that "
                + "list whenever it starts Steam; open Steam from Anvil's library (not another launcher) and sign in again.")
        }
        // Steam couldn't reach Steam's servers — what it kept calling an error.
        if isSteam, let r = c.steamConnection, r.couldNotConnect {
            let shown = Array(r.places.prefix(5))
            let where_ = shown.count > 1 ? shown.dropLast().joined(separator: ", ") + " and " + shown.last! : (shown.first ?? "")
            var detail = "It never signed in"
                + (r.serversFailed > 0 ? ": \(r.serversFailed) of Steam's servers didn't answer\(where_.isEmpty ? "" : " (\(where_))")" : "")
                + (r.noConnection > 0 ? ", and its sign-in found no connection \(r.noConnection == 1 ? "once" : "\(r.noConnection) times")" : "") + "."
            if let vpn = c.vpn {
                detail += " This Mac's connection goes through \(vpn), so Steam sees you where the VPN comes out and picks servers far from you. Steam often can't sign in through a VPN: turn \(vpn) off, or choose a server in your own country, then open Steam again."
            } else {
                detail += " Check the connection, then open Steam again; Steam's servers are sometimes down for a few minutes."
            }
            if let engine = c.steamTestedEngine {
                detail += " If it still can't connect\(c.vpn == nil ? "" : " with the VPN off"), use \(engine) for Steam: \(c.engine?.name ?? "this engine") is a preview"
                    + (r.socketUnsupported ? ", and its Wine refused one of Steam's network calls (Windows socket error 10045)." : ".")
            }
            add("steam-no-connection", .problem, "Steam couldn't reach Steam's servers", detail,
                c.steamTestedEngine != nil ? .steamTestedEngine : nil)
        }
        // Steam itself runs without them on purpose: its own windows have nothing to pace.
        if c.enhancementsOff && !isSteam {
            add("enhancements-off", .problem, "Anvil's enhancements are off for this game",
                "They carry the frame pacing, the controller and audio fixes and the frame-rate measurements Auto-Tune and these checks use. "
                + "Anvil turns them off by itself only when a game starts without them and not with them — worth another try after an update.",
                .enhancementsOn)
        }

        // --- Installed in another app's Wine setup ---
        if let setup = c.foreignSetup {
            add("foreign-setup", .problem, "\(c.title) is installed in \(setup)",
                "But it runs in “\(c.containerName)”, whose Windows has none of what it installed there — its settings, sign-in, registry and updates. A container made from a copy of \(setup) runs it as it was installed; the original is left as it is.",
                .ownContainer)
        }

        // --- Leftovers in the game's folder ---
        if let left = c.leftovers {
            var detail = "\(left.files) file\(left.files == 1 ? "" : "s") from an upscaler Anvil once injected are still in the game's folder, and the game doesn't use them."
            if !left.replacedOwn.isEmpty {
                detail += " The game's own \(left.replacedOwn.joined(separator: ", ")) was replaced by the SDK's version; removing puts the game's back."
            }
            add("leftovers", .problem, "Unused upscaler files in the game's folder", detail, .removeLeftovers)
        }

        // --- Power and memory ---
        if log.contains(where: { $0.contains("power: Low Power Mode ON") }) {
            add("low-power", .problem, "Low Power Mode was on",
                "It holds the CPU and GPU well below their speed. Turn it off in System Settings › Battery while playing.")
        }
        if let line = log.first(where: { $0.contains("power: ") }),
           let thermal = ["serious", "critical"].first(where: { line.contains("thermal \($0)") }) {
            add("thermal", .advice, "The Mac was running hot",
                "macOS reported its thermal state as \(thermal), which slows the CPU and GPU. A hard, flat surface and open vents help.")
        }
        let atLaunch = memory(in: log, marker: "memory at launch: ")
        let atEnd = memory(in: log, marker: "memory after ")
        if let a = atLaunch, let b = atEnd, let s0 = a.swap, let s1 = b.swap, s1 - s0 >= 256 {
            add("swap", .advice, "macOS moved memory to the SSD during play",
                "Swap grew by \(s1 - s0) MB while the game ran — other apps were using memory it needed. Closing browsers and other large apps before playing keeps everything in RAM.")
        } else if let a = atLaunch, a.available < 3000 {
            add("low-memory", .advice, "Little memory was free at launch",
                "Only \(a.available) MB of \(a.total) MB was available. Closing other apps first keeps the game from being pushed to the SSD.")
        }

        // --- FSR and frame generation ---
        if let line = game.last(where: { $0.contains("[anvil] FSR to the display: the game draws ") }),
           let r = line.range(of: "the game draws ") {
            let sizes = line[r.upperBound...].prefix(while: { $0 != ";" })
            let to = line.range(of: "upscales it to the display's ").map { line[$0.upperBound...].prefix(while: { $0 != " " }) } ?? ""
            add("fsr-display", .good, "FSR to the display",
                "The game drew at \(sizes); AMD FSR 1 (EASU, then RCAS) took it to the display's \(to) instead of macOS's bilinear stretch.")
        } else if let line = game.last(where: { $0.contains("[anvil] FSR to the display: off for this session") }),
                  let r = line.range(of: "off for this session — ") {
            add("fsr-display", .advice, "FSR to the display didn't run",
                "It switched itself off: \(line[r.upperBound...].prefix(while: { $0 != ";" })). The game's frames went to the display as they were.")
        }
        // FSR 3 for every game: how many of the game's frames it took, or why it stopped.
        let fsr3Frames = game.reduce(0) { total, line in
            guard let r = line.range(of: "| FSR 3 on ") else { return total }
            return total + (Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0)
        }
        if let line = game.last(where: { $0.contains("[anvil] FSR 3: off for this session — ") }),
           let r = line.range(of: "off for this session — ") {
            add("fsr3", .advice, "FSR 3 stopped",
                "It switched itself off: \(line[r.upperBound...].prefix(while: { $0 != ";" })). FSR 1 took over for the rest of the session.")
        } else if fsr3Frames > 0 || game.contains(where: { $0.contains("[anvil] FSR 3: first frame") }) {
            // Eased to FSR 1 while the GPU couldn't hold an even 80 with it (fsr3Govern).
            let eased = game.filter { $0.contains("[anvil] FSR 3: FSR 1 for now — ") }.count
            let easedNote = eased == 0 ? ""
                : " In \(eased == 1 ? "one stretch" : "\(eased) stretches") the GPU was too busy to hold an even 80 with it, and FSR 1 stood in until it had room again."
            add("fsr3", .good, "FSR 3 ran",
                "Anvil's temporal FSR 3 took \(fsr3Frames > 0 ? "\(fsr3Frames.formatted()) of the game's frames" : "the game's frames"): motion measured from them, then upscaled, sharpened and blended with the frames before, so edges stay steady in motion." + easedNote)
        }
        // Long sessions: held to an even 80 on battery, in Low Power Mode or with the Mac hot.
        if let line = game.last(where: { $0.contains("[anvil] long sessions: ") && !$0.contains("long sessions: off") }),
           let r = line.range(of: "long sessions: ") {
            let why = line[r.upperBound...].prefix(while: { $0 != "—" }).trimmingCharacters(in: .whitespaces)
            add("long-session", .good, "Kept to an even 80 for a long session",
                "\(why.prefix(1).uppercased() + why.dropFirst()), so Anvil held the game to an even 80 with no reaching for 120, and ran FSR 3 only in the GPU's spare time — less power and heat for hours of play. Settings › Long sessions changes when this happens.")
        }
        // Hot during play, where it wasn't at launch (that is said under Power, above).
        let hotAtLaunch = log.first(where: { $0.contains("power: ") })
            .map { line in ["serious", "critical"].contains { line.contains("thermal \($0)") } } ?? false
        if !hotAtLaunch, game.contains(where: { $0.contains("[anvil] the Mac is hot (thermal state") }) {
            add("thermal", .advice, "The Mac got hot",
                "macOS reported a serious thermal state during the session. Anvil held an even 80 and used FSR 1 in place of FSR 3 until it cooled. A cooler room, a hard flat surface or a lower graphics level keeps it from slowing down.")
        }
        let generatedWindows = e.windows.filter { ($0.generatedShare ?? 0) > 0.02 }
        let generating = !generatedWindows.isEmpty
        // Smooth Motion with frames made between two of the game's, from both (0.48): what it shows of a
        // heavy scene is meant to be half made frames, and each one sees the motion from both sides.
        let smoothLines = game.filter { $0.contains("[anvil] Smooth Motion: the game makes") }
        let between = smoothLines.contains { $0.contains("a frame made between each two") }
        // Guesses stretched over more motion than one of the game's frames every second refresh:
        // LEGO Star Wars on 11 October, the game at 23–45 fps for minutes with half of what was
        // shown generated — the picture breaking up, and this check said all was well.
        let thin = generatedWindows.filter { !$0.wasBehind && ($0.generatedShare ?? 0) >= 0.3 && $0.displayed < DisplayProfile.maxHz / 2 - 2 }
        let thinMinutes = thin.reduce(0) { $0 + $1.seconds } / 60
        if thinMinutes >= 1 && !between {
            add("frame-gen-thin", .advice, "Generated frames stood in for a slow game",
                String(format: "For %@ the game made under %.0f fps of its own while frame generation filled the display, so each generated frame covered more motion than it can guess well — fast motion and edges can break up. A lower graphics level or resolution in the game helps; so does Frame generation off in the game's Upscaling settings.",
                       minutesText(thinMinutes), DisplayProfile.maxHz / 2))
        }
        if generating && smoothLines.isEmpty {
            let share = generatedWindows.map { $0.generatedShare ?? 0 }.reduce(0, +) / Double(generatedWindows.count)
            add("frame-gen", .good, "Frame generation filled the display",
                String(format: "While the game was below the display's rate, %.0f%% of the frames shown were generated by Anvil from the motion between the game's own — the game's own frames held to every second refresh, one generated between each. Fast motion and on-screen text can show a little smearing in generated frames; Frame generation in the game's Upscaling settings turns it off.", share * 100))
        }

        // --- Where the GPU's time went, and the game's shader compiles (anvil_gpuwork.mm) ---
        let timed = e.windows.filter { $0.gpuWorkMs != nil && !$0.wasBehind }
        if !timed.isEmpty {
            // The heavy stretches, where the frame rate fell: those are the ones to explain.
            let heavy = timed.filter { $0.capacity < DisplayProfile.maxHz / 2 }
            let sample = heavy.count >= 2 ? heavy : timed
            var kinds: [String: Double] = [:]
            for w in sample { for (k, v) in w.gpuKinds ?? [:] { kinds[k, default: 0] += v / Double(sample.count) } }
            let frame = sample.compactMap(\.gpuWorkMs).reduce(0, +) / Double(sample.count)
            let parts = kinds.sorted { $0.value > $1.value }.filter { $0.value >= 0.1 }.map { k, v in
                String(format: "%@ %.1f ms (%.0f%%)", k, v, frame > 0 ? 100 * v / frame : 0)
            }
            let seconds = sample.map(\.seconds).reduce(0, +)
            add("gpu-work", .good, heavy.count >= 2 ? "Where the GPU's time went in the heavy scenes" : "Where the GPU's time went",
                String(format: "Over %@ of %@, timed on the GPU itself: %.1f ms a frame — ", minutesText(seconds / 60),
                       heavy.count >= 2 ? "the stretches below \(Int(DisplayProfile.maxHz / 2)) fps" : "play", frame)
                + parts.joined(separator: ", ") + ". Shadows are the passes drawing into shadow maps; Anvil's part is FSR and frame generation."
                + heaviestText(timed))
        }
        // Smooth Motion (libanvil's genDecide): heavy scenes with a frame made halfway between.
        let smoothStarts = smoothLines.count
        if smoothStarts > 0 {
            let filled = e.windows.filter { ($0.generatedShare ?? 0) > 0.2 && $0.displayed < DisplayProfile.maxHz / 2 + 2 }
            let minutes = filled.map(\.seconds).reduce(0, +) / 60
            let own = filled.isEmpty ? 0 : filled.map(\.displayed).reduce(0, +) / Double(filled.count)
            if between {
                // How evenly the made and real frames reached the screen, in the stretches it ran.
                let medians = filled.compactMap(\.gapMedianMs), nineties = filled.compactMap(\.gap90Ms)
                let even = medians.isEmpty ? "" : String(format: " Half the gaps between frames shown were under %.1f ms and 90%% under %.1f ms.",
                                                          medians.reduce(0, +) / Double(medians.count),
                                                          nineties.isEmpty ? 0 : nineties.reduce(0, +) / Double(nineties.count))
                // Up to four frames for each of the game's (0.51): the most it showed, from its lines saying so.
                let most = game.compactMap { line -> Int? in
                    guard line.contains("frames shown for each of the game's"), let r = line.range(of: #"Smooth Motion: \d"#, options: .regularExpression) else { return nil }
                    return Int(line[r].suffix(1))
                }.max() ?? 2
                let shownText = most > 2
                    ? String(format: "up to %d frames for each of its own were shown — %.0f fps of its own shown as about %.0f at its slowest. Each of the game's frames reaches the screen a little later for it.", most, own, own * Double(most))
                    : String(format: "a frame made between each two of its frames, from both, was shown — about %.0f fps of its own shown as %.0f. Each of the game's frames reaches the screen half a frame later for it.", own, own * 2)
                // The made frames' check (0.52): how many were the nearer real frame instead.
                let checked = game.compactMap { line -> (Int, Int)? in
                    guard let r = line.range(of: #"(\d+) of (\d+) made frames the nearer real one instead"#, options: .regularExpression) else { return nil }
                    let n = line[r].split(separator: " ")
                    guard n.count > 2, let held = Int(n[0]), let of = Int(n[2]) else { return nil }
                    return (held, of)
                }
                let held = checked.map { $0.0 }.reduce(0, +), judged = checked.map { $0.1 }.reduce(0, +)
                let heldText = held > 0
                    ? " Where its two frames disagreed over much of the picture — reflections, heat, flames or motion too fast to follow — the nearer real frame was shown instead of a made one: \(held) of \(judged) in the stretches that said so."
                    : ""
                add("smooth-motion", .good, "Smooth Motion in the heavy scenes",
                    String(format: "%d time%@ the game fell below %.0f fps of its own; for %@ ", smoothStarts, smoothStarts == 1 ? "" : "s",
                           DisplayProfile.maxHz / 2, minutesText(minutes)) + shownText + even + heldText)
            } else {
                add("smooth-motion", .good, "Smooth Motion in the heavy scenes",
                    String(format: "%d time%@ the game fell to 24–62 fps of its own; for %@ a frame made halfway between each two of its frames was shown — about %.0f fps of its own shown as %.0f.",
                           smoothStarts, smoothStarts == 1 ? "" : "s", minutesText(minutes), own, own * 2))
            }
        }
        // Guardian (libanvil, Guardian.swift): what it checked, put right and learned while the game played.
        let guardLines = game.filter { $0.contains("[anvil] guardian:") }
        if let finding = guardianFinding(guardLines.map(String.init), paused: game.filter { $0.contains("frames between cost the game its own") }.count) {
            add("guardian", .good, "Guardian", finding)
        }
        // Stutters, as Guardian found them, and the memory warm-up before the start.
        if let (kind, text) = stutterFinding(guardLines.map(String.init), launch: log.map(String.init)) {
            add("stutters", kind, "Stutters", text)
        }
        let compiled = e.windows.compactMap(\.compiles).reduce(0, +)
        if compiled > 0 {
            let total = e.windows.compactMap(\.compileMs).reduce(0, +)
            let longest = e.windows.compactMap(\.compileLongestMs).max() ?? 0
            let stalls = e.windows.filter { ($0.compileLongestMs ?? 0) >= 50 }.count
            add("shader-compiles", stalls > 0 ? .advice : .good, "Shader compiling",
                String(format: "The game compiled %d shader pipelines this session, %.1f s in all, the longest %.0f ms", compiled, total / 1000, longest)
                + (stalls > 0 ? String(format: " — %d stretch%@ had one of 50 ms or more, which the frame waits for: a stutter the first time an area is seen. D3DMetal keeps every compiled shader, so the same places are smooth next time.", stalls, stalls == 1 ? "" : "es")
                              : ". None long enough to be felt."))
        }

        // Pipelines D3DMetal couldn't build (0.58): it leaves out what they draw. LEGO Star Wars had 4 on 17 October, 22 since
        // 3 October — in D3DMetal's own translation of the game's shaders ("Failed to compile stage in function"), before
        // any of Anvil's code; Anvil's compile timing never sees them fail.
        let noOps = log.filter { $0.contains("Failed to compile a pipeline, marking PSO") }.count
        if noOps > 0 {
            add("no-op-pipelines", .advice, "\(noOps) of the game's graphics pipelines couldn't be built",
                "D3DMetal — Apple's Direct3D for Macs, which the engine runs \(c.title) through — couldn't translate "
                + (noOps == 1 ? "one of its graphics pipelines" : "\(noOps) of its graphics pipelines")
                + " this session, and leaves out what " + (noOps == 1 ? "it draws" : "they draw")
                + ". If an effect was missing — a glow, sparks, part of an explosion — that's where it went. It happens inside D3DMetal, "
                + "before any of Anvil's code, so nothing in Anvil's settings changes it.")
        }

        // --- Performance ---
        let split = Gameplay.split(e.windows, loadsIntoHeavy: e.loadsIntoHeavy)
        let stats = TrialStats.from(play: split.play, hitches: split.hitches)
        let playMinutes = stats?.minutes ?? 0
        // With frames generated, the game's own frames were held to every second refresh on
        // purpose: below 80 then says nothing about what limits it.
        if let s = stats, s.minutes >= 0.75, !generating {
            let summary = String(format: "\(DisplayProfile.targetText) fps or more %.0f%% of the time, typically %.0f fps, 1%% lows around %.0f",
                                 s.shareAt80 * 100, s.typicalFPS, s.onePercentLow)
            if s.shareAt80 >= 0.95 && s.hitchesPerMinute <= 2 {
                add("smooth", .good, "Ran smoothly", summary + String(format: " over %@ of play.", minutesText(s.minutes)))
            } else {
                diagnoseSlow(split.play, s, c, summary: summary, add: add)
            }
            if s.hitchesPerMinute > 2 {
                let early = hitchesEarly(e.windows)
                add("hitches", .advice, "Pauses during play",
                    String(format: "%d pause%@ of a tenth of a second or more over %@.", split.hitches, split.hitches == 1 ? "" : "s", minutesText(s.minutes))
                    + (early ? " Most came early, in places the game was showing for the first time — shaders compiling, which Anvil keeps, so they fade as you play." : ""))
            }
        }

        // Freezes with the game in front: a stop the player saw, not the game pausing
        // itself in the background.
        let freezes = foregroundFreezes(e)
        if !freezes.isEmpty {
            let longest = freezes.max() ?? 0
            add("freezes", .problem, "The game froze \(freezes.count == 1 ? "once" : "\(freezes.count) times")",
                String(format: "The picture stopped for %.1f s at the longest while the game was in front.", longest)
                + " Anvil records what every thread was doing during the first freezes of a session, in Stalls beside the logs.")
        }

        // Frame pacing that kept changing its mind.
        let switches = game.filter { $0.contains("[anvil] steady ") && $0.contains("→") }.count
        if playMinutes >= 1, Double(switches) / playMinutes > 8 {
            add("pacing-flaps", .advice, "Frame pacing switched often",
                String(format: "It moved between 120 and an even 80 %.0f times a minute. Anvil now checks the GPU before trying for 120, which should end this; if it keeps happening, Up to 120 on the Performance tab shows every frame as it's ready instead.", Double(switches) / playMinutes))
        }

        // --- Engine ---
        if let trial = c.engineTrial, let engine = c.engine, engine.id == trial.toRuntimeID {
            let old = c.previousEngineName ?? trial.fromRuntimeID
            if let now = stats, now.minutes >= EngineTrial.minutesToJudge, let before = trial.before {
                let slower = EngineTrial.isClearlySlower(fps: now.typicalFPS, shareAt80: now.shareAt80, than: before)
                add("engine-trial", slower ? .problem : .good,
                    slower ? "\(engine.name) runs this game slower" : "\(engine.name) runs this game at least as well",
                    String(format: "On it: typically %.0f fps, \(DisplayProfile.targetText) or more %.0f%% of the time. On %@: %.0f fps, \(DisplayProfile.targetText) or more %.0f%%.",
                           now.typicalFPS, now.shareAt80 * 100, old, before.fps, before.shareAt80 * 100),
                    slower ? .switchBack : nil)
            } else {
                add("engine-trial", .advice, "On \(engine.name), on trial",
                    "Switched from \(old)\(trial.byAutopilot ? " by Autopilot" : ""). "
                    + String(format: "After %.0f minutes of play Anvil compares it with how the game ran before; ", EngineTrial.minutesToJudge)
                    + "if the game doesn't start or crashes on it, the container goes back by itself.")
            }
        }

        // --- Sound and controllers ---
        if let line = game.first(where: { $0.contains("[anvil] audio: 3D sound: the game's") }),
           let r = line.range(of: "3D sound: ") {
            add("audio-3d", .good, "3D sound",
                String(line[r.upperBound...]).prefix(1).uppercased() + String(line[r.upperBound...]).dropFirst() + ".")
        }
        // Anvil Surround's split of a 7.1 mix whose front pair alone had sound (the stereo ones say
        // so in the 3D sound line above).
        if let line = game.last(where: { $0.contains("[anvil] audio: Anvil Surround: ") }),
           let r = line.range(of: "Anvil Surround: ") {
            let said = String(line[r.upperBound...])
            add("audio-upmix", .good, "Anvil Surround", said.prefix(1).uppercased() + said.dropFirst() + ".")
        }
        if game.contains(where: { $0.contains("[anvil] audio:") && $0.contains("folding the mix into stereo") }) {
            add("audio-fold", .good, "Voices and surround folded into stereo",
                "The game mixes for 7.1 speakers; Anvil folds that into what this Mac plays, so dialogue on the centre channel is heard.")
        }
        // The game's sound arriving too late for the output (libanvil's drop-out count, every 30 s).
        let drops = game.compactMap { line -> (Int, Double)? in
            guard let r = line.range(of: "[anvil] audio: the game's sound arrived too late ") else { return nil }
            let rest = line[r.upperBound...]
            let count = Int(rest.prefix { $0.isNumber }) ?? 0
            let ms = rest.range(of: " s — ").flatMap { Double(rest[$0.upperBound...].prefix { $0.isNumber || $0 == "." }) } ?? 0
            return (count, ms)
        }
        if !drops.isEmpty {
            let count = drops.reduce(0) { $0 + $1.0 }, ms = drops.reduce(0) { $0 + $1.1 }
            add("audio-dropouts", .advice, "Sound cut out",
                "The game's sound reached the Mac too late \(count) time\(count == 1 ? "" : "s") (\(Int(ms.rounded())) ms in all), in \(drops.count) stretch\(drops.count == 1 ? "" : "es") of play: Wine had nothing new to play, so the sound — dialogue included — cut out for a moment. The game's own sound mixing fell behind, mostly where it is busiest; a lighter graphics level gives it room.")
        }
        if log.contains(where: { $0.contains("controller identity: Nintendo Switch Pro Controller") }),
           game.contains(where: { $0.contains("Pro Controller support ready") }),
           !game.contains(where: { $0.contains("completed the Pro Controller's USB handshake") }),
           game.contains(where: { $0.contains("the game never completed the handshake") }) || playMinutes >= 1 {
            add("pro-controller", .problem, "The Pro Controller didn't connect to the game",
                "Anvil showed the pad to the game as a Switch Pro Controller, but the game never finished its handshake with it, so its buttons may not reach the game. As connected shows it as an Xbox-style pad instead.",
                .controllerAsConnected)
        }

        if log.contains(where: { $0.contains("controller identity: Nintendo Switch Pro Controller") }),
           game.contains(where: { $0.contains("winebus is a build Anvil has not checked") }) {
            add("pro-controller-engine", .advice, "The Switch Pro mode isn't available on this engine",
                "Anvil's Pro Controller is built for the controller driver in Wine 7.7, which Mythic Engine 2.6 and Whisky use; this engine has a different one, so the pad reached the game as an Xbox-style pad instead. Everything works; the prompts may show Xbox letters.")
        }

        // --- Closed while still loading ---
        // What a game "stuck on the loading screen" looks like from here: closed by the player
        // before its first scene, in a game whose sessions always reach one.
        if e.loadsIntoHeavy, let o = e.outcome, o.userClosed,
           !log.contains(where: { $0.contains("closing it for the next setup") }),
           !e.windows.contains(where: { ($0.gpuBusy ?? 0) >= LoadTime.heavyGPU }) {
            let front = timeInFront(e, seconds: o.seconds)
            let keptRunning = log.contains { $0.contains("behind other apps: keeps running") }
            let heldOffline = log.contains { $0.contains("network: held back for the game") }
            var detail = String(format: "It was closed after %.0f s", o.seconds)
                + (front.map { String(format: ", %.0f s of them in front", $0) } ?? "")
            if let t = e.loadEstimate {
                detail += ", before its first scene — it usually gets there in about \(LoadTime.text(t.typical)) on this Mac."
            } else {
                detail += ", before its first scene."
            }
            if keptRunning {
                detail += " It keeps loading while other apps are in front, so it can be left to load and come back to."
            } else if let front, front < o.seconds - 5 {
                detail += " It stops loading whenever another app is in front, so only the time in front counted."
            }
            if let t = e.loadEstimate, let front, front > max(2.5 * t.typical, 60) {
                detail += " That was well past its usual time in front, so something held it up"
                    + (heldOffline ? " even with its connections held back for an offline start." : ".")
                    + " Anvil records what every thread was doing when a game stalls, in Stalls beside the logs."
            }
            add("closed-loading", .advice, "\(c.title) was closed while still loading", detail)
        }

        // --- What was on screen ---
        // Read off the pictures Anvil keeps of the screen (ScreenReader), for a game the player
        // closed within its first minutes: what a game "stuck on a screen" was showing.
        if let o = e.outcome, o.userClosed,
           !log.contains(where: { $0.contains("closing it for the next setup") }),
           let shot = ScreenReader.atClose(e.screens),
           (timeInFront(e, seconds: o.seconds) ?? o.seconds) < 600 {
            let quote = "“\(ScreenReader.quote(shot.lines))”"
            let offline = OfflineStarts.startedOffline(log)
            switch ScreenReader.kind(of: shot.lines) {
            case .pressToStart:
                add("screen-at-close", .advice, "\(c.title) was waiting for a button press",
                    "When it was closed it showed \(quote). Its screen waits for a key or a button: Return or Space on the keyboard, or A or Start on a controller. Click its window first, so it has the keyboard.")
            case .connection:
                add("screen-at-close", .advice, "\(c.title) was showing a message about its connection",
                    "When it was closed it showed \(quote)."
                    + (offline ? " It was started with no connection. Some games need their store's online sign-in to start, and wait on a screen like this without one." : ""))
            case .error:
                add("screen-at-close", .problem, "\(c.title) showed an error", "When it was closed it showed \(quote).")
            case .loading:
                add("screen-at-close", .advice, "\(c.title) was still loading", "When it was closed it showed \(quote).")
            case .other:
                add("screen-at-close", .advice, "What \(c.title) showed when it was closed", "\(quote).")
            case .menu:
                // Closed from its own menu: nothing was in the way.
                break
            }
        }

        // --- The store waiting on the player's account ---
        // Epic answered the game's own sign-in with "corrective action required": something waits on
        // the account itself — newer terms to accept, a date of birth, a display name. With no Epic
        // overlay under Wine the game sends the player to Epic's page in the browser instead, where it
        // is easy to miss behind the game (Cat Quest II, 10 October). Only the player can do it.
        if log.contains(where: { $0.contains("corrective_action_required") }) {
            add("epic-account-action", .problem, "Epic is waiting for you to finish something on your account",
                "When \(c.title) signed in, Epic said something on your account needs you first — usually newer terms to accept, or a detail to confirm. The game opened Epic's page in your web browser for it. Finish it there, or sign in at epicgames.com, and the game signs in as it should from then on.")
        } else if log.contains(where: { $0.contains("authorization_pending") && $0.contains("verification code") }) {
            add("epic-account-action", .advice, "\(c.title) asked you to sign in to Epic in your browser",
                "Its own sign-in opened Epic's page in your web browser with a code to enter. Finish it there and the game carries on signed in.")
        }

        // --- Offline starts that don't get going ---
        if let r = c.offline, r.doesntGetGoing, OfflineStarts.startedOffline(log) {
            add("offline-stuck", .advice, "\(c.title) needs internet to start",
                OfflineStarts.why(r)
                + (r.viaEpic ? " Anvil tried Epic's arguments from its last online start, Epic Offline Mode's own start, and the game's program on its own; Anvil can't sign a game in without Epic." : "")
                + " " + OfflineStarts.howToPlayOffline)
        } else if let r = c.offline, r.viaEpic, !r.epicWaysFailed.isEmpty, !r.epicWayPlayed, OfflineStarts.startedOffline(log) {
            add("offline-next-way", .advice, "\(c.title)'s next offline start tries another way",
                "Started with no connection as \(r.epicWaysFailed.map(\.title).joined(separator: ", then ")), it didn't get going. Its next start with no connection is as \(r.currentWay.title); whichever way gets it playing is kept.")
        }

        // --- Epic ---
        if log.contains(where: { $0.contains("Epic: not signed in") }) {
            add("epic", .problem, "Epic isn't signed in",
                "The game started without your Epic account, so its saves tied to the account and DLC didn't appear. Sign in to Epic once, while online; after that it starts offline as well.",
                .epicSignIn)
        } else if let line = log.last(where: { $0.contains("Epic: offline start failed (") }),
                  let r = line.range(of: "): ") {
            add("epic", .problem, "Epic's offline start didn't work",
                "The game started without your Epic account, so its saves tied to the account didn't appear. legendary said: “\(line[r.upperBound...])”. Signing in to Epic again, once while online, puts it right.",
                .epicSignIn)
        }
        if game.contains(where: { $0.contains("[anvil] offline: ") }) {
            add("offline-held", .good, "Started offline",
                "With Epic's offline start, and the game's own connections held back as on a Mac with no connection.")
        }
        let epicMarkers = ["Epic sign-in failed: ", "Epic sign-in skipped: "]
        if let line = log.last(where: { l in epicMarkers.contains { l.contains($0) } }),
           let r = epicMarkers.lazy.compactMap({ line.range(of: $0) }).first {
            let why = line[r.upperBound...].replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            let offline = log.contains { $0.contains("Epic: started offline as the signed-in account") }
            add("epic", .problem, "Epic sign-in didn't work",
                (offline ? "The game started offline as your account, so your saves were there, but owned DLC, cloud saves and achievements may have been missing. "
                         : "The game started without it, so owned DLC, cloud saves and achievements may be missing this time. ")
                + "legendary said: “\(why)”. If Epic's sign-in has expired, signing in again fixes it.",
                .epicSignIn)
        }

        out.sort { $0.kind.order < $1.kind.order }
        return HealthReport(checkedAt: Date(), sessionStartedAt: e.startedAt, playMinutes: playMinutes, findings: out)
    }

    /// What held a session below 80, from the stretches that were below it.
    private static func diagnoseSlow(_ play: [FrameWindow], _ s: TrialStats, _ c: DoctorContext, summary: String,
                                     add: (String, HealthFinding.Kind, String, String, HealthFinding.Fix?) -> Void) {
        let slow = play.filter { $0.displayed < DisplayProfile.steadyTarget - 0.5 }
        let slowTime = slow.reduce(0) { $0 + $1.seconds }
        guard slowTime > 0 else { return }
        func share(_ keep: (FrameWindow) -> Bool) -> Double { slow.filter(keep).reduce(0) { $0 + $1.seconds } / slowTime }
        let gpuBound = share { ($0.gpuBusy ?? 0) >= 85 }
        let cpuBound = share { ($0.topThread ?? 0) >= 90 && ($0.gpuBusy ?? 100) < 85 }
        let capped = share { w in
            [60.0, 30.0].contains { abs(w.rendered - $0) < 1.5 && w.capacity < $0 + 4 } && (w.gpuBusy ?? 0) < 75 && (w.topThread ?? 0) < 80
        }
        let gpuSamples = slow.compactMap { w in w.gpuBusy.map { (Double($0), w.seconds) } }
        let topSamples = slow.compactMap { w in w.topThread.map { (Double($0), w.seconds) } }
        let gpuTypical = TrialStats.percentile(gpuSamples, 0.5)
        let topTypical = TrialStats.percentile(topSamples, 0.5)
        // Sessions before Anvil 0.14 have no load readings.
        let measured = !gpuSamples.isEmpty && !topSamples.isEmpty
        let slowShare = 1 - s.shareAt80

        // What a newer engine would offer, said once, where it helps.
        var engineLine = ""
        var engineFix: HealthFinding.Fix?
        if c.directX, let engine = c.engine {
            if let newer = c.newerEngineInstalled {
                engineLine = " \(newer.name) is installed, with D3DMetal \(newer.d3dMetal ?? "newer") against \(engine.d3dMetal ?? "the older one") now — Apple's newer translator is the biggest change left for a DirectX game. Anvil takes a snapshot first and switches back by itself if the game doesn't start."
                engineFix = .switchEngine
            } else if let available = c.newerEngineAvailable {
                engineLine = " \(available) can be installed from the engine list — Apple's newer translator is the biggest change left for a DirectX game."
                engineFix = .showEngines
            } else if let tried = c.triedEngineName {
                engineLine = " \(tried) was tried here and switched back from — it ran this game no better, or lost something it uses — so it isn't offered again; the game's graphics level is what Auto-Tune works with."
            }
        }

        if capped >= 0.6 {
            add("game-cap", .problem, "The game is holding itself back",
                "Most of the time below \(DisplayProfile.targetText) it made exactly 60 or 30 frames with the GPU and CPU both idle — its own frame limit or V-Sync. In its display options choose 120 Hz, or unlimited, and V-Sync off.", nil)
        } else if gpuBound >= 0.5 {
            var detail = summary + String(format: ". Below \(DisplayProfile.targetText) — %.0f%% of play — the GPU was %.0f%% busy: it is the limit, not the CPU.", slowShare * 100, gpuTypical)
            var kind: HealthFinding.Kind = .advice
            if c.graphicsLevels {
                if c.autoTuneMeasuring {
                    detail += " Auto-Tune is measuring the game's graphics levels while you play and will keep the best look that holds \(DisplayProfile.targetText)."
                    kind = .fixed
                } else if let choice = c.autoTuneChoice {
                    detail += " Auto-Tune chose \(choice)."
                } else if c.graphicsLevel != .light {
                    detail += " A lighter graphics level on the Performance tab takes the most load off it."
                }
            }
            add("gpu-limit", kind, "The GPU is the limit in heavy scenes", detail + engineLine, engineFix)
        } else if cpuBound >= 0.5 {
            add("cpu-limit", .advice, "One of the game's threads is the limit",
                summary + String(format: ". Below \(DisplayProfile.targetText) its busiest thread was %.0f%% of a core while the GPU had room. Lighter graphics won't raise that; less work per frame on the CPU would.", topTypical)
                + engineLine, engineFix)
        } else if slowShare > 0.15 && measured && gpuTypical < 85 && topTypical < 85 {
            // Neither at its limit: the two wait for each other. D3DMetal 2's command
            // queue waits for a frame's submission before the game's thread goes on —
            // D3DMCommandQueue::WaitUntilSubmission took 42% of LEGO Star Wars' render
            // thread in a 71 fps stretch — so the CPU idles while the GPU works and the
            // other way round. D3DMetal 3.0 commits asynchronously by default
            // (D3DM_ENABLE_ASYNC_COMMIT, on unless set to 0).
            let older = c.engine?.d3dMetal.map { $0.hasPrefix("1") || $0.hasPrefix("2") } ?? false
            add("turns-limit", .advice, "The CPU and GPU are taking turns",
                summary + String(format: ". Below \(DisplayProfile.targetText) — %.0f%% of play — the GPU was typically %.0f%% busy and the game's busiest thread %.0f%% of a core: neither is at its limit, each waits for the other.", slowShare * 100, gpuTypical, topTypical)
                + (older ? " D3DMetal \(c.engine?.d3dMetal ?? "2") waits for each frame's work to be handed to the GPU before the game goes on; D3DMetal 3.0 hands it over without waiting, which is the change aimed at exactly this." : "")
                + engineLine, engineFix)
        } else if slowShare > 0.15 {
            add("mixed-limit", .advice, "Below \(DisplayProfile.targetText) some of the time",
                summary + (measured
                    ? String(format: ". Below \(DisplayProfile.targetText) the GPU was typically %.0f%% busy and the busiest thread %.0f%% of a core.", gpuTypical, topTypical)
                    : ". This session has no load readings to say what held it back; the next one will.")
                + engineLine, engineFix)
        }
    }

    // MARK: Reading the logs

    /// What stopped a game, when the session's logs name something Anvil's frame work never
    /// touches — so FSR and frame generation aren't blamed for it.
    ///
    /// On 3 October LEGO Star Wars froze seven minutes in on Metal's own assertion over a
    /// depth-stencil state D3DMetal had asked for with values out of range; it had to be force
    /// quit, and Autopilot switched FSR and frame generation off for it, though neither had
    /// anything to do with depth or stencil. Anvil's passes make compute work, blits, textures
    /// and drawables; a Metal assertion about render state they never create isn't theirs.
    /// Ended by SIGKILL from outside while it was still drawing: a force quit from another app, or
    /// macOS freeing memory. Not when its frames had stopped first — a frozen game force-quit is
    /// still a game that froze, and what froze it is looked for as with any crash.
    static func endedFromOutside(launchLines: [Substring], gameLines: [Substring]) -> Bool {
        guard launchLines.contains(where: { $0.contains(Launcher.killedMark) }) else { return false }
        let last = gameLines.last { $0.contains("[anvil] frames STOPPED") || $0.contains("[anvil] displayed ") }
        return last?.contains("frames STOPPED") != true
    }

    static func crashCause(launchLines: [Substring], gameLines: [Substring]) -> String? {
        let all = launchLines + gameLines
        guard let line = all.last(where: { $0.contains("failed assertion") }) else {
            if endedFromOutside(launchLines: launchLines, gameLines: gameLines) {
                return "it was ended from outside with SIGKILL while it was still running — a force quit from another app, or macOS freeing memory — which nothing inside it, FSR and frame generation included, can cause"
            }
            // The game's own crash record, where it keeps one (0.58, CrashDump).
            return CrashDump.cause(launchLines: launchLines)
        }
        // "-[_MTLDepthStencilState initWithDevice:depthStencilDescriptor:]:479: failed assertion …"
        let notAnvils: [(String, String)] = [
            ("MTLDepthStencilState", "a depth-stencil state"),
            ("MTLRenderPipeline", "a render pipeline"),
            ("MTLSamplerState", "a sampler"),
            ("MTLRenderCommandEncoder", "a draw"),
            ("MTLAccelerationStructure", "ray tracing"),
        ]
        guard let (_, what) = notAnvils.first(where: { line.contains($0.0) }) else { return nil }
        return "Metal stopped it over \(what) its graphics asked for — part of the game's own drawing that Anvil's FSR and frame generation never touch"
    }

    static func crashLine(in lines: [Substring]) -> String? {
        let signs = ["Unhandled page fault", "Unhandled exception", "EXCEPTION_ACCESS_VIOLATION", "Assertion failed",
                     "Segmentation fault", "fatal error", "Fatal error", "D3DMetal:ERROR"]
        guard let line = lines.last(where: { l in signs.contains { l.contains($0) } }) else { return nil }
        var text = String(line)
        if let bar = text.range(of: "game| ") { text = String(text[bar.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 160 ? String(text.prefix(157)) + "…" : text
    }

    /// "memory at launch: 9950 MB of 24576 MB available, swap in use 0 MB"
    static func memory(in lines: [Substring], marker: String) -> (available: Int, total: Int, swap: Int?)? {
        guard let line = lines.last(where: { $0.contains(marker) }),
              let m = line.range(of: #"(\d+) MB of (\d+) MB available, swap in use (\d+|unknown)"#, options: .regularExpression) else { return nil }
        let parts = line[m].split(separator: " ")
        // "9950 MB of 24576 MB available, swap in use 0"
        guard parts.count >= 10, let available = Int(parts[0]), let total = Int(parts[3]) else { return nil }
        return (available, total, Int(parts[9]))
    }

    /// Whether most hitches came in the first quarter of play.
    static func hitchesEarly(_ windows: [FrameWindow]) -> Bool {
        let total = windows.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return false }
        var t = 0.0, early = 0, all = 0
        for w in windows {
            if w.worstGapMs >= Gameplay.hitchMs {
                all += 1
                if t < total * 0.25 { early += 1 }
            }
            t += w.seconds
        }
        return all > 0 && Double(early) / Double(all) > 0.6
    }

    /// Lengths of the freezes game.log recorded while the game was the app in front.
    ///
    /// game.log stamps lines with the local time of day; anvil.log records every change
    /// of the app in front, in UTC. A stop that began after another app came to the front
    /// is the game pausing itself — LEGO Star Wars does when it loses focus — not a freeze.
    static func foregroundFreezes(_ e: SessionEvidence) -> [Double] {
        guard let start = e.startedAt else { return [] }
        let iso = ISO8601DateFormatter()
        var focus: [(Date, Bool)] = []
        for line in e.launchLines where line.contains("  focus: ") {
            guard let stamp = line.split(separator: " ").first, let at = iso.date(from: String(stamp)) else { continue }
            focus.append((at, line.contains("(as dev.anvil.game") || line.contains(".exe")))
        }
        let calendar = Calendar.current
        let day = calendar.dateComponents([.year, .month, .day], from: start)
        func localTime(_ line: Substring) -> Date? {
            let parts = line.prefix(12).split(separator: ":")
            guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Double(parts[2]) else { return nil }
            var comps = day
            comps.hour = h; comps.minute = m; comps.second = Int(s)
            guard var date = calendar.date(from: comps) else { return nil }
            date += s - Double(Int(s))
            if date < start.addingTimeInterval(-3600) { date += 86_400 }
            return date
        }
        func inFront(_ at: Date) -> Bool {
            focus.last(where: { $0.0 <= at })?.1 ?? true
        }
        var out: [Double] = []
        var stoppedAt: Date?
        for line in e.gameLines {
            if line.contains("[anvil] frames STOPPED") {
                stoppedAt = localTime(line).map { $0.addingTimeInterval(-1.5) }
            } else if line.contains("[anvil] frames RESUMED after "),
                      let r = line.range(of: "RESUMED after "), let end = line.range(of: " s", range: r.upperBound..<line.endIndex),
                      let seconds = Double(line[r.upperBound..<end.lowerBound]) {
                if let at = stoppedAt, inFront(at), !focus.contains(where: { $0.0 > at && $0.0 < at.addingTimeInterval(seconds) && !$0.1 }) {
                    out.append(seconds)
                }
                stoppedAt = nil
            }
        }
        return out
    }

    /// Seconds of the session's first `seconds` with the game in front, from anvil.log's
    /// record of the app in front. Nil when it has none.
    static func timeInFront(_ e: SessionEvidence, seconds: Double) -> Double? {
        guard let start = e.startedAt else { return nil }
        let iso = ISO8601DateFormatter()
        var changes: [(Date, Bool)] = []
        for line in e.launchLines where line.contains("  focus: ") {
            guard let stamp = line.split(separator: " ").first, let at = iso.date(from: String(stamp)) else { continue }
            // Wine 9 engines show a game as "wine" rather than by its program's name.
            changes.append((at, line.contains("(as dev.anvil.game") || line.contains(".exe")
                                 || line.contains("focus: wine came") || line.contains("wine64-preloader")))
        }
        guard changes.contains(where: { $0.1 }) else { return nil }
        let end = start.addingTimeInterval(seconds)
        var total = 0.0, front = false, from = start
        for (at, isGame) in changes where at > start && at < end {
            if front { total += at.timeIntervalSince(from) }
            front = isGame
            from = at
        }
        if front { total += end.timeIntervalSince(from) }
        return total
    }

    static func minutesText(_ minutes: Double) -> String {
        if minutes < 1 { return String(format: "%.0f s", minutes * 60) }
        if minutes < 90 { return String(format: "%.0f min", minutes) }
        return String(format: "%.1f hours", minutes / 60)
    }

    /// The session's heaviest timed frame, by its longest passes as libanvil named them — what in a
    /// heavy scene takes the time ("" when no stretch was heavy enough to name them).
    static func heaviestText(_ windows: [FrameWindow]) -> String {
        guard let w = windows.filter({ ($0.heaviestPasses?.isEmpty == false) && $0.heaviestFrameMs != nil })
                             .max(by: { ($0.heaviestFrameMs ?? 0) < ($1.heaviestFrameMs ?? 0) }),
              let ms = w.heaviestFrameMs, let passes = w.heaviestPasses else { return "" }
        return String(format: " In the heaviest frame timed (%.1f ms of GPU work), the longest passes: ", ms) + passes.joined(separator: "; ") + "."
    }

    /// The session's stutters as Guardian counted them (its last summary, or its lines for each when the session
    /// was too short for one), what they were mostly, and the memory warm-up's line from the launch. Nil when
    /// there's nothing to say.
    static func stutterFinding(_ lines: [String], launch: [String]) -> (HealthFinding.Kind, String)? {
        let warm = launch.last { $0.contains("memory warm-up:") }
        let warmText = warm.flatMap { line -> String? in
            guard let r = line.range(of: "memory warm-up: ") else { return nil }
            let rest = String(line[r.upperBound...])
            guard let dash = rest.range(of: " — ") else { return nil }
            return String(rest[dash.upperBound...])
        }
        var total = 0, reading = 0, compiling = 0, waiting = 0, own = 0
        var longest = 0.0
        var readGB: Double? = nil, readMs: Double? = nil
        if let summary = lines.last(where: { $0.contains("| stutters: ") }),
           let m = summary.range(of: #"stutters: (\d+) \((\d+) reading its data, (\d+) compiling shaders, (\d+) waiting on the GPU or the display, (\d+) the game's own work; longest (\d+) ms\)"#, options: .regularExpression) {
            let nums = summary[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 6 { (total, reading, compiling, waiting, own, longest) = (nums[0], nums[1], nums[2], nums[3], nums[4], Double(nums[5])) }
            if let g = summary.range(of: #"read [\d.]+ GB of its data, [\d.]+ ms a read"#, options: .regularExpression) {
                let v = summary[g].split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
                if v.count >= 2 { readGB = v[0]; readMs = v[1] }
            }
        } else {
            for line in lines where line.contains("guardian: stutter ") {
                total += 1
                if line.contains("mostly reading its data") { reading += 1 }
                else if line.contains("mostly compiling shaders") { compiling += 1 }
                else if line.contains("mostly waiting on") { waiting += 1 }
                else { own += 1 }
                if let r = line.range(of: #"stutter \d+ ms"#, options: .regularExpression),
                   let v = Double(line[r].split(separator: " ")[1]) { longest = max(longest, v) }
            }
        }
        guard total > 0 || warmText != nil else { return nil }
        var parts: [String] = []
        if total == 0 {
            parts.append("No stutters while the game was in front.")
        } else {
            var causes: [(Int, String)] = [(reading, "reading the game's data"), (compiling, "compiling shaders"),
                                           (waiting, "waiting on the GPU or the display"), (own, "the game's own work")]
            causes = causes.filter { $0.0 > 0 }.sorted { $0.0 > $1.0 }
            parts.append("\(total) stutter\(total == 1 ? "" : "s") — frames three times as long as those around them, the longest \(Int(longest)) ms: "
                         + causes.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + ".")
            if let readGB, let readMs {
                parts.append(String(format: "The game read %.1f GB of its data, %.1f ms a read on average.", readGB, readMs))
            }
            if reading > 0 && reading * 2 >= total {
                parts.append(warmText == nil
                             ? "Most came as the game read its data from disk. The memory warm-up (on the game's Graphics page) reads the parts played most into memory before each start, from what it notes this session."
                             : "Most came as the game read its data from disk: the memory warm-up reads more of what's played into memory each session.")
            } else if compiling > 0 && compiling * 2 >= total {
                parts.append("Most came as the game compiled shaders for somewhere new — once a place has been seen, its shaders are kept and it plays smoothly there after.")
            }
        }
        if let warmText { parts.append("Before the start: \(warmText).") }
        return (reading * 2 >= max(total, 1) && warmText == nil ? .advice : .good, parts.joined(separator: " "))
    }

    /// What Guardian did in a session, from its lines in game.log (libanvil's guardianStep and check-up): the
    /// check-ups, what it put right, its checks of Smooth Motion's worth and what it has learned on this Mac.
    /// Nil when it didn't run.
    static func guardianFinding(_ lines: [String], paused: Int) -> String? {
        guard !lines.isEmpty else { return nil }
        func after(_ marker: String, in line: String) -> String? {
            line.range(of: marker).map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        var parts: [String] = []
        // Its check-ups, from its last five-minute summary.
        if let summary = lines.last(where: { $0.contains(" check-ups, ") }),
           let m = summary.range(of: #"guardian: (\d+) check-ups, (\d+) fixes"#, options: .regularExpression) {
            let nums = summary[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2 {
                parts.append(nums[1] == 0
                             ? "Guardian checked \(nums[0]) times while the game played that what Anvil does was working, and everything was."
                             : "Guardian checked \(nums[0]) times while the game played that what Anvil does was working, and put \(nums[1]) thing\(nums[1] == 1 ? "" : "s") right.")
            }
        } else {
            parts.append("Guardian checked every few seconds while the game played that what Anvil does was working.")
        }
        var fixed: [String] = []
        if lines.contains(where: { $0.contains("presenter showed nothing") }) {
            fixed.append("Smooth Motion's presenter stalled and the game's own frames were put back at once")
        }
        if lines.contains(where: { $0.contains("guardian: Smooth Motion started") }) {
            fixed.append("Smooth Motion switching on and off often was slowed down")
        }
        if lines.contains(where: { $0.contains("guardian: Steady let go") }) {
            fixed.append("Steady switching between its even rate and as-ready often was slowed down")
        }
        if paused > 0 {
            fixed.append("frames between were paused \(paused) time\(paused == 1 ? "" : "s") where they cost the game its own frames")
        }
        if !fixed.isEmpty { parts.append("It noticed and handled: " + fixed.joined(separator: "; ") + ".") }
        // Its checks of frames between's worth this session.
        let checks = lines.compactMap { line -> (String, Double)? in
            guard line.contains("frames between were"),
                  let at = line.range(of: #"at \d+–\d+ fps"#, options: .regularExpression),
                  let pct = line.range(of: #"were [+−-]?\d+%"#, options: .regularExpression) else { return nil }
            let value = Double(line[pct].dropFirst(5).dropLast().replacingOccurrences(of: "−", with: "-")) ?? 0
            return (String(line[at].dropFirst(3)), value)
        }
        if !checks.isEmpty {
            let byBand = Dictionary(grouping: checks, by: \.0)
            let words = byBand.keys.sorted().map { band -> String in
                let v = byBand[band]!.map(\.1)
                return String(format: "%@ %+.0f%%", band, v.reduce(0, +) / Double(v.count))
            }
            parts.append("It compared Smooth Motion against the game's own frames alone \(checks.count) time\(checks.count == 1 ? "" : "s"), the same scene seconds apart: " + words.joined(separator: ", ") + ".")
        }
        // What it has learned on this Mac, from its newest line saying so.
        if let learned = lines.last(where: { $0.contains("| on this Mac") }),
           let text = after("| on this Mac:", in: learned) ?? after("| on this Mac so far:", in: learned),
           !text.hasPrefix("nothing yet") {
            parts.append("Learned on this Mac: \(text).")
        }
        return parts.joined(separator: " ")
    }
}
