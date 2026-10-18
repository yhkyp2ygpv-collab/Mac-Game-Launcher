import Foundation

/// After every session, Anvil reads what the game left in the logs, puts right what is
/// safe to put right, starts Auto-Tune where there is something to measure, and keeps
/// what it found on the game's page — so a game is looked after without anyone opening
/// a log. What it does by itself is only ever what Anvil itself caused or a setting
/// already measured to be better; anything that changes how a game looks or which
/// engine runs it stays a button.
@MainActor
final class Autopilot: ObservableObject {
    static let shared = Autopilot()

    @Published private(set) var reports: [UUID: HealthReport] = [:]
    /// The last check worth mentioning, for the banner.
    @Published var banner: Banner?
    /// Games being checked right now.
    @Published private(set) var checking: Set<UUID> = []
    /// What Autopilot is doing about a game's engine, while it does it.
    @Published private(set) var engineWork: [UUID: String] = [:]

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var gameID: UUID
        var title: String
        var message: String
    }

    /// Where reports live. Tests point this somewhere else.
    nonisolated(unsafe) static var directory: URL = RuntimeManager.support.appendingPathComponent("Health", isDirectory: true)

    private init() { load() }

    func report(for game: Game) -> HealthReport? { reports[game.id] }

    // MARK: Persistence

    private func url(for id: UUID) -> URL { Self.directory.appendingPathComponent("\(id.uuidString).json") }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let report = try? decoder.decode(HealthReport.self, from: data) else { continue }
            reports[id] = report
        }
    }

    private func save(_ id: UUID) {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let report = reports[id] else {
            try? FileManager.default.removeItem(at: url(for: id))
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(report) { DiskCache.writeReplacing(data, to: url(for: id)) }
    }

    // MARK: Checking

    /// Called by the launcher when a session ends.
    func sessionEnded(game: Game, outcome: SessionEvidence.Outcome) {
        let id = game.id
        Task {
            // The game's last lines, the session's summary and Auto-Tune's record of it
            // land first.
            try? await Task.sleep(for: .seconds(3))
            await self.check(gameID: id, outcome: outcome, announce: true)
            // And everything else, now the game is closed.
            await CheckUp.shared.run()
        }
    }

    /// When Anvil starts: every game whose last session hasn't been checked yet, then
    /// the engine each game on Autopilot could use.
    func atLaunch() async {
        undoUnmeasuredEngineSwitchesOnce()
        rejudgeKeptTrialsOnce()
        for game in Library.shared.games {
            let title = game.title, log = Launcher.gameLogURL
            let started = await Task.detached(priority: .utility) { FrameLog.lastSession(of: title, in: log)?.startedAt }.value
            guard let started else { continue }
            if let done = reports[game.id]?.sessionStartedAt, abs(done.timeIntervalSince(started)) < 1 { continue }
            await check(gameID: game.id, outcome: nil, announce: false, considerEngine: false)
        }
        for game in Library.shared.games { await considerEngineUpgrade(gameID: game.id) }
        CheckUp.shared.watchWhileOpen()
    }

    /// Read the game's last session and act on it.
    func check(gameID: UUID, outcome: SessionEvidence.Outcome?, announce: Bool, considerEngine: Bool = true) async {
        guard !checking.contains(gameID), let game = Library.shared.games.first(where: { $0.id == gameID }) else { return }
        checking.insert(gameID)
        defer { checking.remove(gameID) }
        let title = game.title, exe = game.executableURL
        let gameLog = Launcher.gameLogURL, launchLog = AnvilLog.url
        let (evidence, analysis) = await Task.detached(priority: .utility) {
            (SessionEvidence.read(title: title, gameLog: gameLog, launchLog: launchLog, outcome: outcome),
             GameAnalysis.cached(for: exe))
        }.value
        guard var evidence,
              var current = Library.shared.games.first(where: { $0.id == gameID }),
              Library.shared.container(id: current.containerID) != nil else { return }
        // An Offline Test judges its own session (OfflineTest); it isn't play to learn from.
        if evidence.launchLines.contains(where: { $0.contains(OfflineTest.logMark) }) { return }
        // The words on its screen, from the pictures Anvil kept of the session.
        if let started = evidence.startedAt {
            let folder = ScreenReader.folder(gameID: gameID, startedAt: started)
            let firstRead = !FileManager.default.fileExists(atPath: folder.appendingPathComponent("text.json").path)
            evidence.screens = await Task.detached(priority: .utility) { ScreenReader.read(folder: folder) }.value
            if firstRead, let line = ScreenReader.logLine(title: title, shots: evidence.screens) { AnvilLog.write(line) }
        }
        // How a start with no connection went, kept with the game.
        if let outcome = OfflineStarts.outcome(of: evidence) {
            var record = current.offlineRecord ?? OfflineRecord()
            if OfflineStarts.isEpic(evidence.launchLines) { record.viaEpic = true }
            let way = OfflineStarts.epicWay(evidence.launchLines)
            let next = record.add(outcome, session: evidence.startedAt, way: way)
            if outcome == .stuck, let shot = ScreenReader.atClose(evidence.screens) { record.lastScreen = ScreenReader.quote(shot.lines) }
            if record != current.offlineRecord {
                current.offlineRecord = record
                Library.shared.update(current)
                var line = "offline: \(title) — this start with no connection \(outcome == .played ? "was played" : "was closed within minutes")"
                if let way { line += " (started as \(way.title))" }
                if let next { line += "; that way didn't get it going, so its next offline start is as \(next.title)" }
                if record.doesntGetGoing {
                    line += record.viaEpic
                        ? "; every way an Epic game starts offline has been tried and none got it going — from now on it starts online when Offline Mode is on and there is a connection"
                        : "; its last \(record.stuckCount) offline starts didn't get going — from now on it starts online when Offline Mode is on and there is a connection"
                }
                AnvilLog.write(line)
            }
        }
        // What the session showed of the game's graphics, kept with its scan.
        GraphicsScan.confirm(gameID: gameID, evidence: evidence)
        GraphicsScan.changed()
        GraphicsPrep.confirm(gameID: gameID, evidence: evidence)
        NotificationCenter.default.post(name: .graphicsPrepChanged, object: nil)

        var actions: [HealthFinding] = []
        if current.autopilot && !Launcher.shared.isBusy(current) {
            // Installed in another app's Wine setup: into a copy of that setup first, so
            // everything after applies to the container it will really run in.
            if let foreign = Library.shared.foreignPrefix(of: current.executableURL) {
                await giveOwnContainer(gameID: gameID)
                if let moved = Library.shared.games.first(where: { $0.id == gameID }),
                   Library.shared.foreignPrefix(of: moved.executableURL) == nil,
                   let now = Library.shared.container(id: moved.containerID) {
                    current = moved
                    actions.append(HealthFinding(
                        id: "foreign-setup", kind: .fixed, title: "Moved into a copy of \(foreign.displayName)",
                        detail: "\(moved.title) was installed there but ran in another container, without its settings, sign-in or updates. It now has “\(now.name)”, made from a copy of that setup on the matching engine; the original is untouched.",
                        fix: nil))
                }
            }
            actions += act(on: &current, evidence: evidence, analysis: analysis)
        }
        guard let fresh = Library.shared.games.first(where: { $0.id == gameID }),
              let container = Library.shared.container(id: fresh.containerID) else { return }
        var report = GameDoctor.diagnose(evidence, context(for: fresh, container: container, analysis: analysis, actions: actions))
        if let old = reports[gameID] {
            if let then = old.sessionStartedAt, let now = evidence.startedAt, abs(then.timeIntervalSince(now)) < 1 {
                // Checking the same session again keeps what was already put right in it.
                let kept = old.findings.filter { f in f.kind == .fixed && !report.findings.contains { $0.id == f.id } }
                report.findings = (kept + report.findings).sorted { $0.kind.order < $1.kind.order }
            } else if report.playMinutes < 0.75 {
                // A session too short to say how the game runs — a look at the menu —
                // leaves what the last real session said about it in place.
                let performance: Set<String> = ["smooth", "gpu-limit", "cpu-limit", "turns-limit", "mixed-limit",
                                                "game-cap", "hitches", "pacing-flaps"]
                let when = (old.sessionStartedAt ?? old.checkedAt).formatted(date: .abbreviated, time: .shortened)
                let kept = old.findings
                    .filter { f in performance.contains(f.id) && !report.findings.contains { $0.id == f.id } }
                    .map { f -> HealthFinding in
                        var f = f
                        if !f.detail.hasPrefix("From ") { f.detail = "From the session of \(when): " + f.detail }
                        return f
                    }
                report.findings = (report.findings + kept).sorted { $0.kind.order < $1.kind.order }
            }
        }
        reports[gameID] = report
        save(gameID)
        AnvilLog.write("doctor: \(title) — \(report.headline)"
                       + (report.findings.isEmpty ? "" : " [" + report.findings.map { "\($0.kind.rawValue):\($0.id)" }.joined(separator: ", ") + "]"))
        if announce, report.problems > 0 || report.fixed > 0 {
            banner = Banner(gameID: gameID, title: "Anvil checked \(title)", message: report.headline.prefix(1).uppercased() + report.headline.dropFirst() + ".")
        }
        if considerEngine { await considerEngineUpgrade(gameID: gameID) }
    }

    // MARK: What Autopilot does by itself

    /// Settings the container advice has measured to be better for every game, which
    /// Autopilot applies without asking. Pacing, resolution, the graphics backend and the
    /// engine are left to Auto-Tune and to the player.
    private static let safeSettings: [(title: String, copy: (inout Container, Container) -> Void)] = [
        ("Synchronisation", { $0.sync = $1.sync }),
        ("Keep Rosetta's translations", { $0.rosettaAOT = $1.rosettaAOT }),
        ("Keep compiled shaders", { $0.persistentShaderCache = $1.persistentShaderCache }),
        ("Protect the shader cache", { $0.protectShaderCache = $1.protectShaderCache }),
        ("Game Mode", { $0.gameMode = $1.gameMode }),
        ("Game threads at interactive priority", { $0.highPriority = $1.highPriority }),
        ("Unity's own log", { $0.keepGameLog = $1.keepGameLog }),
        ("One frame in flight", { $0.lowLatencyQueue = $1.lowLatencyQueue }),
        ("Lock to the display's refresh", { $0.lockToRefresh = $1.lockToRefresh }),
    ]

    private func act(on game: inout Game, evidence: SessionEvidence, analysis: GameAnalysis?) -> [HealthFinding] {
        var done: [HealthFinding] = []
        guard var container = Library.shared.container(id: game.containerID) else { return done }

        // An engine on trial, judged once enough has been played on it.
        if let verdict = judgeEngineTrial(game: game, container: &container, evidence: evidence) { done.append(verdict) }

        // Closed unexpectedly with frame generation or FSR to the display on: both off for this
        // game, so the next start is as it was before them. Said, with where to switch them back.
        if let o = evidence.outcome, !o.userClosed, o.status != 0 {
            let generated = evidence.launchLines.contains { $0.contains("env ANVIL_FRAME_GEN=1") }
            let upscaled = evidence.gameLines.contains { $0.contains("[anvil] FSR to the display: the game draws ") }
            let metalFX = evidence.launchLines.contains { $0.contains("env D3DM_ENABLE_METALFX=1") }
            let onePass = evidence.launchLines.contains { $0.contains("env ANVIL_FSR_PASS=fused") }
            let fsr3 = evidence.launchLines.contains { $0.contains("env ANVIL_FSR3=1") }
            let config0 = game.upscalerOverride ?? container.upscaler
            let vcNeed = VCRuntime.need(for: game)
            if !evidence.drewFrames {
                // Closed before its first frame: nothing of Anvil's that works on pictures had started, so
                // nothing graphical is switched off for it. Until 0.58.2 Hogwarts Legacy lost FSR's one pass
                // for its launcher's "Microsoft Visual C++ Runtime" message.
                if let vcNeed, !VCRuntime.missing(vcNeed, in: container).isEmpty {
                    AnvilLog.write("autopilot: \(game.title) closed before its first frame (code \(o.status)) — it needs Microsoft's Visual C++ Runtime, which “\(container.name)” doesn't have yet: installing it")
                    Task { _ = await VCRuntimeSetup.shared.ensureAll() }
                    done.append(HealthFinding(
                        id: "vc-runtime", kind: .fixed, title: "Microsoft's Visual C++ Runtime put in for this game",
                        detail: "\(game.title) closed before it showed anything (code \(o.status))" + (o.status == 41 ? ", the code Unreal Engine's launcher ends with when a component it needs is missing" : "")
                            + ": " + vcNeed.reasons.joined(separator: "; ") + ". Anvil installs Microsoft's own Visual C++ Redistributable into “\(container.name)” once, checked as signed by Microsoft, before the next start. FSR and frame generation weren't the cause and stay as they were.",
                        fix: nil))
                } else if VCRuntime.loadsMicrosofts(container), o.seconds < 120,
                          evidence.launchLines.contains(where: { $0.contains("env WINEDLLOVERRIDES=") && $0.contains("vcruntime140") }),
                          let at = VCRuntime.installedAt(container), VCRuntime.drewBefore(title: game.title, installedAt: at) {
                    // It ran before Microsoft's runtime was put in, and doesn't start with it: Wine's own again.
                    VCRuntime.useWinesOwn(container, why: "\(game.title) closed before its first frame after the install")
                    AnvilLog.write("autopilot: \(game.title) closed before its first frame (code \(o.status)) with Microsoft's Visual C++ Runtime loaded — it ran on Wine's own before, so “\(container.name)” goes back to Wine's from the next start")
                    done.append(HealthFinding(
                        id: "vc-runtime-wine", kind: .fixed, title: "Back to Wine's own Visual C++ files",
                        detail: "\(game.title) closed before it showed anything (code \(o.status)) with Microsoft's Visual C++ Runtime, which it ran without before. Its next start uses Wine's own, as before; Microsoft's stays installed for the games whose launchers look for it.",
                        fix: nil))
                } else {
                    AnvilLog.write("autopilot: \(game.title) closed before its first frame (code \(o.status)) — before FSR or frame generation start, so they stay as they were")
                    done.append(HealthFinding(
                        id: "closed-before-frame", kind: .advice, title: "Closed before it showed anything",
                        detail: "\(game.title) closed \(Int(o.seconds)) s after it started (code \(o.status)), before its first frame. FSR, frame generation and Anvil's other picture work start with that frame, so they weren't the cause and stay as they were. A message from the game itself, if it showed one, says what it wanted.",
                        fix: nil))
                }
            } else if (generated || upscaled || metalFX || fsr3),
               let cause = GameDoctor.crashCause(launchLines: evidence.launchLines, gameLines: evidence.gameLines) {
                AnvilLog.write("autopilot: \(game.title) closed unexpectedly — \(cause); FSR and frame generation stay on")
                done.append(HealthFinding(
                    id: "crash-cause", kind: .advice, title: "Not FSR or frame generation",
                    detail: "\(game.title) closed unexpectedly (code \(o.status)): \(cause). They stay on."
                        + (cause.contains("depth-stencil") ? " Anvil now puts a depth-stencil state like that right before Metal sees it, so it doesn't stop the game again." : ""),
                    fix: nil))
            } else if fsr3 && config0.mode == .fsr3Every {
                // The newest part first: FSR 1 for this game from its next start, as every game
                // ran before 0.29. FSR to the display and frame generation stay on.
                var config = config0
                config.mode = .fsr1
                game.upscalerOverride = config
                Library.shared.update(game)
                GraphicsPrep.fsr3OffAfterCrash(gameID: game.id)
                AnvilLog.write("autopilot: \(game.title) closed unexpectedly with FSR 3 on — FSR 1 for it from the next start")
                done.append(HealthFinding(
                    id: "fsr3-off", kind: .fixed, title: "FSR 3 back to FSR 1 for this game",
                    detail: "\(game.title) closed unexpectedly (code \(o.status)) with FSR 3 on, so its next start uses FSR 1, as every game ran before. FSR to the display and frame generation stay on. If it closes the same way without FSR 3, FSR 3 wasn't the cause: choose “FSR 3 — every game” again on its Performance tab.",
                    fix: nil))
            } else if onePass && GraphicsPrep.stored(gameID: game.id)?.onePassOff == false {
                // The newest part first, as with DLSS below: FSR goes back to the two passes every
                // game ran before, and FSR and frame generation themselves stay on.
                GraphicsPrep.onePassOffAfterCrash(gameID: game.id)
                AnvilLog.write("autopilot: \(game.title) closed unexpectedly with FSR in one pass — two passes from the next start")
                done.append(HealthFinding(
                    id: "fsr-one-pass-off", kind: .fixed, title: "FSR back to two passes for this game",
                    detail: "\(game.title) closed unexpectedly (code \(o.status)) with FSR in the one pass Graphics Prep chose for it, so its next start uses the two passes every game ran before. FSR and frame generation stay on.",
                    fix: nil))
            } else if metalFX && game.dlssThroughMetalFX {
                game.dlssThroughMetalFX = false
                Library.shared.update(game)
                AnvilLog.write("autopilot: \(game.title) closed unexpectedly with DLSS through MetalFX on — off for it from the next start")
                done.append(HealthFinding(
                    id: "metalfx-dlss-off", kind: .fixed, title: "DLSS through MetalFX switched off for this game",
                    detail: "\(game.title) closed unexpectedly with it on (code \(o.status)), so its next start is without it. If it closes the same way without it, it wasn't the cause: switch it back on in the Graphics Scan section of its Performance tab.",
                    fix: nil))
            } else if generated || upscaled {
                var config = game.upscalerOverride ?? container.upscaler
                config.frameGenChoice = .off
                config.fsrToDisplay = false
                game.upscalerOverride = config
                Library.shared.update(game)
                AnvilLog.write("autopilot: \(game.title) closed unexpectedly with \(generated ? "frame generation" : "")\(generated && upscaled ? " and " : "")\(upscaled ? "FSR to the display" : "") on — off for it from the next start")
                done.append(HealthFinding(
                    id: "fsr-off", kind: .fixed, title: "Frame generation and FSR switched off for this game",
                    detail: "\(game.title) closed unexpectedly with them on (code \(o.status)), so its next start is without them. If it closes the same way without them, they weren't the cause: switch them back on under Upscaling in its settings.",
                    fix: nil))
            }
        }

        // The game's window against the screen: the next display mode for this kind of
        // engine when it didn't fill it.
        if let fitted = learnDisplayMode(game: &game, container: container, evidence: evidence) { done.append(fitted) }

        // Anvil's own leftovers in the game's folder.
        if let fixed = removeLeftovers(from: &game, container: &container) { done.append(fixed) }

        // The container settings measured to be better for any game.
        let goal = game.tuneGoal ?? Tuner.shared.state(for: game)?.goal ?? .smooth
        let others = Library.shared.games(in: container).filter { $0.id != game.id }.map(\.title)
        let advice = ContainerAdvisor.advise(game: game, container: container, goal: goal, analysis: analysis,
                                             engines: ContainerAdvisor.engines(RuntimeManager.shared.runtimes), otherGames: others,
                                             displayIsProMotion: DisplayProfile.steadyModeApplies)
        let safe = advice.changes.filter { change in Self.safeSettings.contains { $0.title == change.title } }
        if !safe.isEmpty {
            var updated = container
            for change in safe { Self.safeSettings.first { $0.title == change.title }?.copy(&updated, advice.recommended) }
            Library.shared.update(updated)
            container = updated
            AnvilLog.write("autopilot: “\(container.name)” — " + safe.map { "\($0.title) \($0.from) → \($0.to)" }.joined(separator: ", "))
            done.append(HealthFinding(
                id: "container-settings", kind: .fixed,
                title: "Set \(safe.count) container setting\(safe.count == 1 ? "" : "s") the better way",
                detail: safe.map { "\($0.title): \($0.to) — \($0.reason)" }.joined(separator: " ")
                    + (others.isEmpty ? "" : " “\(container.name)” is shared with \(others.joined(separator: ", ")), which gets them too."),
                fix: nil))
        }

        // Auto-Tune, already decided: it learns from this session too, and measures again
        // when the game has come to run clearly worse than its choice measured.
        let recentSession = evidence.startedAt.map { Date().timeIntervalSince($0) < 12 * 3600 } ?? false
        if recentSession, let said = Tuner.shared.learn(from: Gameplay.split(evidence.windows, loadsIntoHeavy: evidence.loadsIntoHeavy),
                                                         game: game, container: container) {
            done.append(HealthFinding(id: "autotune-relearn", kind: .fixed, title: "Auto-Tune is measuring again", detail: said, fix: nil))
        }

        // Auto-Tune, for a game with something to measure. The session counts as its
        // first measurement only if it is recent: an older one may have run with
        // settings that have changed since.
        let recent = evidence.startedAt.map { Date().timeIntervalSince($0) < 12 * 3600 } ?? false
        if Tuner.shared.autoStart(game, container: container, played: recent ? Gameplay.split(evidence.windows, loadsIntoHeavy: evidence.loadsIntoHeavy) : nil) {
            let state = Tuner.shared.state(for: game)
            let counted = state?.current.flatMap { state?.trial($0)?.minutes } ?? 0
            done.append(HealthFinding(
                id: "autotune-started", kind: .fixed, title: "Auto-Tune started",
                detail: "It measures \(state?.current?.shortTitle ?? "each setup") and the setups beside it over your next sessions — "
                    + String(format: "about %.0f minutes of play each — ", Tuner.playingMinutes)
                    + "and keeps the one that best meets “\(goal.title)”."
                    + (counted > 0 ? String(format: " The %@ just played count toward the first.", GameDoctor.minutesText(counted)) : "")
                    + " Nothing to do; the Performance tab shows the results.",
                fix: nil))
        }
        return done
    }

    /// After a session of a game whose display mode Anvil sets: keep the mode that filled the
    /// screen, try the next one where it didn't. Remembered per kind of engine, so going
    /// back to an engine finds the mode that worked on it.
    private func learnDisplayMode(game: inout Game, container: Container, evidence: SessionEvidence) -> HealthFinding? {
        guard GameTuning.profile(for: game)?.fitsDisplay == true, game.graphicsTuning != .gameDefault,
              let fit = GameTuning.windowFit(in: evidence.gameLines),
              let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) else { return nil }
        let major = EngineProfile.of(runtime).wineMajor
        let key = GameTuning.engineKey(wineMajor: major)
        let current = GameTuning.displayMode(for: game, wineMajor: major)
        var modes = game.displayModes ?? [:]
        if fit.fills {
            guard modes[key] != current.rawValue else { return nil }
            modes[key] = current.rawValue
            game.displayModes = modes
            Library.shared.update(game)
            AnvilLog.write("display: \(game.title) fills the screen in \(current.title) on Wine \(major) — kept")
            return nil
        }
        if let next = current.next {
            modes[key] = next.rawValue
            game.displayModes = modes
            Library.shared.update(game)
            AnvilLog.write("display: \(game.title)'s window \(fit.detail) in \(current.title) on Wine \(major) — \(next.title) next time")
            return HealthFinding(id: "display-fit", kind: .fixed, title: "The picture didn't fill the screen",
                                 detail: "In \(current.title) the game's window was \(fit.detail). Next time it starts in \(next.title); Anvil keeps whichever fills the screen on this engine.",
                                 fix: nil)
        }
        modes[key] = GameTuning.DisplayMode.fullscreen.rawValue
        game.displayModes = modes
        Library.shared.update(game)
        AnvilLog.write("display: \(game.title) — no display mode filled the screen on Wine \(major); back to fullscreen")
        return HealthFinding(id: "display-fit", kind: .advice, title: "No display mode fills the screen on this engine",
                             detail: "Fullscreen, a borderless window and the game's own fullscreen window were each tried on Wine \(major), and none filled the screen. It's back in fullscreen. An engine where the picture fits — Anvil remembers which — is the way round it.",
                             fix: nil)
    }

    /// Remove an upscaler Anvil injected but nothing uses, and put back what it replaced.
    private func removeLeftovers(from game: inout Game, container: inout Container) -> HealthFinding? {
        let config = game.upscalerOverride ?? container.upscaler
        guard let left = UpscalerManager.unusedInjection(for: game, config: config) else { return nil }
        do {
            try UpscalerManager.shared.removeInjection(fromGameAt: game.executablePath)
        } catch {
            AnvilLog.write("autopilot: \(game.title) — couldn't remove unused upscaler files: \(error.localizedDescription)")
            return nil
        }
        if game.upscalerOverride != nil {
            game.upscalerOverride?.forceInjection = false
            game.upscalerOverride?.injectedPayloadID = nil
            Library.shared.update(game)
        } else if container.upscaler.forceInjection {
            container.upscaler.forceInjection = false
            container.upscaler.injectedPayloadID = nil
            Library.shared.update(container)
        }
        AnvilLog.write("autopilot: \(game.title) — removed \(left.files) unused upscaler file(s) from its folder"
                       + (left.replacedOwn.isEmpty ? "" : "; restored its own \(left.replacedOwn.joined(separator: ", "))"))
        return HealthFinding(
            id: "leftovers", kind: .fixed, title: "Removed unused upscaler files from the game's folder",
            detail: "\(left.files) file\(left.files == 1 ? "" : "s") an earlier Anvil injected — an AMD SDK the game never calls."
                + (left.replacedOwn.isEmpty ? "" : " The game's own \(left.replacedOwn.joined(separator: ", ")), which the SDK's had replaced, is back.")
                + " Nothing else in the folder was touched.",
            fix: nil)
    }

    // MARK: Context

    private func context(for game: Game, container: Container, analysis: GameAnalysis?, actions: [HealthFinding]) -> DoctorContext {
        let runtimes = RuntimeManager.shared
        let current = runtimes.runtime(id: container.runtimeID)
        func engine(_ r: Runtime) -> DoctorContext.Engine { .init(id: r.id, name: r.displayName, d3dMetal: r.d3dMetalVersion) }
        let currentRank = current?.hasD3DMetal == true ? (current?.d3dMetalRank ?? []) : []
        // Not one already tried here and switched back from: LEGO Star Wars' Doctor kept
        // offering Engine 3.0 after its trial found it slower and without the Switch Pro mode.
        let newerAll = runtimes.runtimes
            .filter { $0.isUsable && $0.hasD3DMetal && $0.id != container.runtimeID && currentRank.lexicographicallyPrecedes($0.d3dMetalRank) }
        let newer = newerAll.filter { container.mayTry($0) }
            .max { $0.d3dMetalRank.lexicographicallyPrecedes($1.d3dMetalRank) }
        let triedNewer = newerAll.filter { !container.mayTry($0) }
            .max { $0.d3dMetalRank.lexicographicallyPrecedes($1.d3dMetalRank) }
        let available = EngineCatalog.shared.releases
            .filter { release in
                guard let gptk = release.gptkVersion, runtimes.runtime(id: release.runtimeID) == nil,
                      !container.rejectedEngines.contains(release.runtimeID) else { return false }
                let rank = gptk.split(separator: ".").map { Int($0) ?? 0 }
                return currentRank.lexicographicallyPrecedes(rank) && newer.map { $0.d3dMetalRank.lexicographicallyPrecedes(rank) } ?? true
            }
            .max { ($0.gptkVersion ?? "").compare($1.gptkVersion ?? "", options: .numeric) == .orderedAscending }
        let tune = Tuner.shared.state(for: game)
        let config = game.upscalerOverride ?? container.upscaler
        let api = analysis?.primary
        return DoctorContext(
            title: game.title,
            executableName: game.executableURL.lastPathComponent,
            enhancementsOff: game.anvilEnhancementsOff,
            autopilot: game.autopilot,
            graphicsLevels: GameTuning.profile(for: game) != nil,
            graphicsLevel: GameTuning.profile(for: game) != nil ? Tuner.shared.graphicsLevel(for: game) : nil,
            autoTuneMeasuring: tune?.isActive ?? false,
            autoTuneChoice: tune?.mode == .finished ? tune?.winner?.title : nil,
            directX: api == .d3d11 || api == .d3d12,
            engine: current.map(engine),
            newerEngineInstalled: newer.map(engine),
            triedEngineName: triedNewer?.displayName,
            newerEngineAvailable: available.map { $0.headline + ($0.channel == "preview" ? " (a preview release)" : "") },
            engineTrial: container.engineTrial,
            previousEngineName: container.engineTrial.map { Self.engineName($0.fromRuntimeID) },
            leftovers: UpscalerManager.unusedInjection(for: game, config: config),
            actions: actions,
            foreignSetup: Library.shared.foreignPrefix(of: game.executableURL)?.displayName,
            containerName: container.name,
            steamUpdate: SteamSupport.isSteamClient(game) ? SteamSupport.updateState(in: container) : nil,
            steamConnection: SteamSupport.isSteamClient(game) ? SteamSupport.connectionReport(in: container) : nil,
            vpn: SteamSupport.isSteamClient(game) ? Connectivity.activeVPN() : nil,
            steamTestedEngine: SteamSupport.isSteamClient(game) ? Self.steamTestedEngine(for: container)?.displayName : nil,
            offline: game.offlineRecord)
    }

    // MARK: Buttons

    /// Carry out a finding's fix. Engine switches go through `switchEngine`, after the
    /// player has confirmed.
    func apply(_ fix: HealthFinding.Fix, findingID: String, gameID: UUID) {
        guard var game = Library.shared.games.first(where: { $0.id == gameID }),
              var container = Library.shared.container(id: game.containerID) else { return }
        var note: String?
        switch fix {
        case .enhancementsOn:
            game.anvilEnhancementsOff = false
            Library.shared.update(game)
            note = "Back on from the next launch."
        case .removeLeftovers:
            if let fixed = removeLeftovers(from: &game, container: &container) { note = fixed.detail }
        case .switchBack:
            if let trial = container.engineTrial {
                container.runtimeID = trial.fromRuntimeID
                container.engineTrial = nil
                container.reject(trial.toRuntimeID, byPlayer: true)
                Library.shared.update(container)
                AnvilLog.write("engine: “\(container.name)” switched back to \(trial.fromRuntimeID) by the player")
                note = "Back on \(RuntimeManager.shared.runtime(id: trial.fromRuntimeID)?.displayName ?? trial.fromRuntimeID) from the next launch."
            }
        case .controllerAsConnected:
            game.padIdentity = .asConnected
            Library.shared.update(game)
            note = "The pad is shown to the game as it is from the next launch."
        case .bestContainer:
            let goal = game.tuneGoal ?? .smooth
            let others = Library.shared.games(in: container).filter { $0.id != game.id }.map(\.title)
            let advice = ContainerAdvisor.advise(game: game, container: container, goal: goal,
                                                 analysis: GameAnalysis.cached(for: game.executableURL),
                                                 engines: ContainerAdvisor.engines(RuntimeManager.shared.runtimes), otherGames: others)
            Library.shared.update(advice.recommended)
            note = "Applied from the next launch."
        case .showEngines:
            NotificationCenter.default.post(name: .anvilShowRuntimes, object: nil)
            return
        case .switchEngine, .epicSignIn:
            return
        case .ownContainer:
            Task { await self.giveOwnContainer(gameID: gameID) }
            return
        case .steamTestedEngine:
            guard let engine = Self.steamTestedEngine(for: container) else { return }
            let from = container.runtimeID
            container.runtimeID = engine.id
            container.reject(from, byPlayer: true)
            Library.shared.update(container)
            AnvilLog.write("engine: “\(container.name)” moved from \(from) to \(engine.id) for Steam by the player")
            note = "Steam runs on \(engine.displayName) from its next start. Wine updates its Windows setup once, which takes a few seconds."
        }
        if let note { resolve(findingID, gameID: gameID, note: note) }
    }

    /// Switch a game's container to a newer engine: snapshot first, then on trial, so a
    /// game that won't start on it goes back by itself — and, after a few minutes of play,
    /// one that runs clearly slower on it too.
    func switchEngine(for game: Game, to runtimeID: String, byAutopilot: Bool = false) async throws {
        guard var container = Library.shared.container(id: game.containerID),
              let runtime = RuntimeManager.shared.runtime(id: runtimeID) else { return }
        let from = container.runtimeID
        let before = baseline(for: game, container: container)
        _ = try await SnapshotManager.shared.snapshot(container, label: "Before switching to \(runtime.displayName)")
        container.engineTrial = EngineTrial(fromRuntimeID: from, toRuntimeID: runtimeID, before: before, byAutopilot: byAutopilot)
        container.runtimeID = runtimeID
        container.rejectedEngines.removeAll { $0 == runtimeID }
        container.rejectedAtSupport?[runtimeID] = nil
        Library.shared.update(container)
        // What Auto-Tune measured was measured on the old engine; it starts again on this one.
        for g in Library.shared.games(in: container) where Tuner.shared.state(for: g) != nil { Tuner.shared.reset(g) }
        AnvilLog.write("engine: “\(container.name)” switched from \(from) to \(runtimeID) for \(game.title)"
                       + (byAutopilot ? " by Autopilot" : "") + ", on trial (snapshot taken)"
                       + (before.map { String(format: "; before: %.0f fps typical, 80+ %.0f%% over %.1f min", $0.fps, $0.shareAt80 * 100, $0.minutes) } ?? ""))
        let note = "Now on \(runtime.displayName), from the next launch. If the game doesn't start, crashes or runs clearly slower on it, Anvil switches back by itself."
        for id in ["gpu-limit", "cpu-limit", "turns-limit", "mixed-limit"] { resolve(id, gameID: game.id, note: note) }
    }

    /// How the game runs now, for the comparison: Auto-Tune's measurement of the setup it
    /// runs with, or else its last session of a minute and a half or more.
    private func baseline(for game: Game, container: Container) -> EngineTrial.Baseline? {
        if let state = Tuner.shared.state(for: game) {
            let level = Tuner.shared.graphicsLevel(for: game)
            let pacing = game.targetFPSOverride ?? container.targetFPS
            let same = state.trials
                .filter { ($0.setup.graphics == nil || $0.setup.graphics == level) && $0.setup.pacing == pacing && $0.minutes >= 1.5 }
                .max { $0.minutes < $1.minutes }
            if let s = same?.stats { return .init(fps: s.typicalFPS, shareAt80: s.shareAt80, minutes: s.minutes) }
        }
        if let s = game.lastSession, s.minutes >= 1.5 { return .init(fps: s.averageFPS, shareAt80: s.shareAt80, minutes: s.minutes) }
        return nil
    }

    static func engineName(_ id: String) -> String {
        RuntimeManager.shared.runtime(id: id)?.displayName ?? RuntimeManager.displayName(forManaged: id)
    }

    /// An engine on trial, once a session has had enough play on it: kept when the game
    /// runs at least about as well, the old engine back when it runs clearly slower.
    private func judgeEngineTrial(game: Game, container: inout Container, evidence: SessionEvidence) -> HealthFinding? {
        guard var trial = container.engineTrial, container.runtimeID == trial.toRuntimeID, !trial.judged,
              let before = trial.before else { return nil }
        let split = Gameplay.split(evidence.windows, loadsIntoHeavy: evidence.loadsIntoHeavy)
        // Generated frames hold the game's own to every second refresh: no measure of an engine.
        guard !split.play.contains(where: { ($0.generatedShare ?? 0) > 0.02 }) else { return nil }
        guard let now = TrialStats.from(play: split.play, hitches: split.hitches),
              now.minutes >= EngineTrial.minutesToJudge else { return nil }
        let newName = Self.engineName(trial.toRuntimeID), oldName = Self.engineName(trial.fromRuntimeID)
        let numbers = String(format: "On %@: typically %.0f fps, \(DisplayProfile.targetText) or more %.0f%% of the time. On %@: %.0f fps, \(DisplayProfile.targetText) or more %.0f%%.",
                             newName, now.typicalFPS, now.shareAt80 * 100, oldName, before.fps, before.shareAt80 * 100)
        if EngineTrial.isClearlySlower(fps: now.typicalFPS, shareAt80: now.shareAt80, than: before) {
            return revertTrial(game: game, container: &container, trial: trial, title: "Back on \(oldName): \(newName) was slower",
                               logReason: "ran slower", detail: numbers)
        }
        let lost = lostFeatures(game: game, trial: trial)
        if let lost, !EngineTrial.keeps(fps: now.typicalFPS, shareAt80: now.shareAt80, than: before, losesFeatures: true) {
            return revertTrial(game: game, container: &container, trial: trial, title: "Back on \(oldName): \(newName) was no faster, and loses \(lost)",
                               logReason: "was no faster and loses \(lost)", detail: numbers + " On \(newName) the game loses \(lost), so it would have to be clearly faster to be worth it.")
        }
        trial.judged = true
        container.engineTrial = trial
        Library.shared.update(container)
        // Said as it is: on 1 October Engine 3.0 held 80 as often as 2.6.1 but typically
        // ran at 83 fps against 95, and the log called that "at least as well".
        let lowerRate = now.typicalFPS < before.fps * 0.97
        let verdict = lowerRate
            ? "is as smooth — \(DisplayProfile.targetText) or more as often — at a lower typical frame rate"
            : "runs at least as well"
        AnvilLog.write("engine trial: \(game.title) \(verdict) on \(trial.toRuntimeID) — kept. " + numbers)
        return HealthFinding(id: "engine-trial", kind: .good,
                             title: lowerRate ? "\(newName) is as smooth for this game" : "\(newName) runs this game at least as well",
                             detail: numbers + " It stays.", fix: nil)
    }

    /// The container back on the engine the trial came from, the new one not offered here
    /// again until Anvil supports its kind better.
    private func revertTrial(game: Game, container: inout Container, trial: EngineTrial,
                             title: String, logReason: String, detail: String) -> HealthFinding {
        container.runtimeID = trial.fromRuntimeID
        container.engineTrial = nil
        container.reject(trial.toRuntimeID)
        Library.shared.update(container)
        for g in Library.shared.games(in: container) where Tuner.shared.state(for: g) != nil { Tuner.shared.reset(g) }
        AnvilLog.write("engine trial: \(game.title) \(logReason) on \(trial.toRuntimeID) — “\(container.name)” is back on \(trial.fromRuntimeID). " + detail)
        return HealthFinding(id: "engine-trial", kind: .fixed, title: title,
                             detail: detail + " Your saves and settings are as they were. Autopilot won't try \(Self.engineName(trial.toRuntimeID)) here again until Anvil supports it better; it can still be chosen by hand.",
                             fix: nil)
    }

    /// What the game was using on the trial's old engine that the new one can't give it,
    /// in words — nil when nothing. Today: the Switch Pro mode, for a game played with a
    /// Nintendo-style pad, which only Wine 7.7's controller driver has.
    func lostFeatures(game: Game, trial: EngineTrial) -> String? {
        guard let old = RuntimeManager.shared.runtime(id: trial.fromRuntimeID),
              let new = RuntimeManager.shared.runtime(id: trial.toRuntimeID) else { return nil }
        guard EngineProfile.of(old).proController, !EngineProfile.of(new).proController,
              Self.playedWithSwitchPad(title: game.title, log: AnvilLog.url) else { return nil }
        return "the Switch Pro mode your Nintendo-style pad uses"
    }

    /// For Steam on a preview engine (Wine 9): Engine 2.6.1 — Wine 7.7, the base Mac
    /// launchers like Whisky have run Steam on — when it is installed. Nil otherwise.
    static func steamTestedEngine(for container: Container) -> Runtime? {
        guard let current = RuntimeManager.shared.runtime(id: container.runtimeID),
              EngineProfile.of(current).wineMajor >= 9,
              let tested = RuntimeManager.shared.runtime(id: "mythic-engine-2.6.1"), tested.isUsable else { return nil }
        return tested
    }

    /// Whether launches of this game have shown a Nintendo-style pad as a Switch Pro
    /// Controller, from the launch log.
    nonisolated static func playedWithSwitchPad(title: String, log: URL) -> Bool {
        guard let data = try? Data(contentsOf: log, options: .alwaysMapped) else { return false }
        let text = String(decoding: data.suffix(6 * 1024 * 1024), as: UTF8.self)
        var current: Substring?
        for line in text.split(separator: "\n") {
            if let r = line.range(of: "prepareAndLaunch: ") {
                current = line[r.upperBound...]
            } else if line.contains("controller identity: Nintendo Switch Pro Controller"),
                      let current, current.hasPrefix(title + " container=") {
                return true
            }
        }
        return false
    }

    /// Once, in 0.23.0: engine trials kept under the old rule are judged again under the
    /// new one, from what Auto-Tune has measured on the new engine since. LEGO Star Wars
    /// was kept on Engine 3.0 at 84 fps typical against 95 on 2.6.1, losing the Switch Pro mode.
    func rejudgeKeptTrialsOnce() {
        let key = "rejudgeKeptTrials-0.23.0"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for var container in Library.shared.containers {
            guard let trial = container.engineTrial, trial.judged, trial.byAutopilot,
                  container.runtimeID == trial.toRuntimeID, let before = trial.before,
                  RuntimeManager.shared.runtime(id: trial.fromRuntimeID)?.isUsable == true else { continue }
            for game in Library.shared.games(in: container) {
                guard let lost = lostFeatures(game: game, trial: trial),
                      let now = Tuner.shared.state(for: game)?.trials
                        .filter({ $0.minutes >= EngineTrial.minutesToJudge }).compactMap(\.stats)
                        .max(by: { $0.minutes < $1.minutes }),
                      !EngineTrial.keeps(fps: now.typicalFPS, shareAt80: now.shareAt80, than: before, losesFeatures: true)
                else { continue }
                let newName = Self.engineName(trial.toRuntimeID), oldName = Self.engineName(trial.fromRuntimeID)
                let numbers = String(format: "On %@: typically %.0f fps, \(DisplayProfile.targetText) or more %.0f%% of the time (Auto-Tune, %.1f min). On %@: %.0f fps, \(DisplayProfile.targetText) or more %.0f%%.",
                                     newName, now.typicalFPS, now.shareAt80 * 100, now.minutes, oldName, before.fps, before.shareAt80 * 100)
                let finding = revertTrial(game: game, container: &container, trial: trial,
                                          title: "Back on \(oldName): \(newName) was no faster, and loses \(lost)",
                                          logReason: "was no faster and loses \(lost)",
                                          detail: numbers + " On \(newName) the game loses \(lost), so it would have to be clearly faster to be worth it.")
                var report = reports[game.id] ?? HealthReport(checkedAt: Date(), sessionStartedAt: nil, playMinutes: 0, findings: [])
                report.findings.removeAll { $0.id == "engine-trial" }
                report.findings.insert(finding, at: 0)
                reports[game.id] = report
                save(game.id)
                break
            }
        }
    }

    /// Once, in 0.19.3: an engine that was kept without ever being measured against the
    /// old one goes back to the engine its container had before (the one its snapshot was
    /// taken on), and Autopilot doesn't offer it there again.
    ///
    /// Engine 3.0 was kept for LEGO Star Wars after three sessions that didn't crash — all
    /// in menus or under a minute and a half — then measured 58 fps in play against 81 on
    /// Engine 2.6.1, with no Switch Pro mode, no Game Mode and a picture that didn't fit.
    /// Only the engine changes: the game's saves and settings stay as they are.
    func undoUnmeasuredEngineSwitchesOnce() {
        let key = "unmeasuredEngineSwitch-0.19.3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let library = Library.shared
        for var container in library.containers where container.engineTrial == nil {
            guard let snap = SnapshotManager.shared.snapshots(for: container)
                    .first(where: { $0.label.hasPrefix("Before switching to ") }),
                  snap.runtimeID != container.runtimeID,
                  RuntimeManager.shared.runtime(id: snap.runtimeID)?.isUsable == true,
                  !container.rejectedEngines.contains(container.runtimeID) else { continue }
            let unmeasured = container.runtimeID
            container.runtimeID = snap.runtimeID
            // It lost under 0.19's support for Wine 9 (level 1), before Anvil started its games
            // as the Game Mode app and fitted its picture: one more measured trial later.
            container.reject(unmeasured, atSupport: 1)
            library.update(container)
            for g in library.games(in: container) where Tuner.shared.state(for: g) != nil { Tuner.shared.reset(g) }
            // What was seen of its picture there, on 1 October: fullscreen cut off, a borderless
            // window under the menu bar. A retry starts at the mode not yet tried.
            if let engine = RuntimeManager.shared.runtime(id: unmeasured) {
                let key = GameTuning.engineKey(wineMajor: EngineProfile.of(engine).wineMajor)
                for var g in library.games(in: container) where GameTuning.profile(for: g)?.fitsDisplay == true && g.displayModes?[key] == nil {
                    var modes = g.displayModes ?? [:]
                    modes[key] = GameTuning.DisplayMode.fullscreenWindow.rawValue
                    g.displayModes = modes
                    library.update(g)
                }
            }
            let oldName = Self.engineName(snap.runtimeID), newName = Self.engineName(unmeasured)
            AnvilLog.write("engine: “\(container.name)” back on \(snap.runtimeID) — \(unmeasured) was kept without being measured, and ran slower in play")
            for g in library.games(in: container) {
                var report = reports[g.id] ?? HealthReport(checkedAt: Date(), sessionStartedAt: nil, playMinutes: 0, findings: [])
                report.findings.removeAll { $0.id == "engine-trial" }
                report.findings.insert(HealthFinding(
                    id: "engine-trial", kind: .fixed, title: "Back on \(oldName)",
                    detail: "\(newName) was kept after three sessions that only showed it starts; measured in play it was slower (58 fps typical against 81), and the picture didn't fit. Your saves and settings are as they were. Anvil now supports engines like it fully — Game Mode, its pacing and the picture's fit — so once this game has a measured session on \(oldName), Autopilot gives \(newName) one more measured trial and keeps whichever is faster.",
                    fix: nil), at: 0)
                reports[g.id] = report
                save(g.id)
            }
        }
    }

    // MARK: Newer engines

    /// Whether what has been measured of a game falls short of 80: any setup Auto-Tune
    /// measured for a minute or more, or the last session of a minute or more.
    func needsSpeed(_ game: Game) -> Bool {
        if let state = Tuner.shared.state(for: game) {
            let measured = state.trials.filter { $0.minutes >= 1 }.compactMap(\.stats)
            if !measured.isEmpty { return measured.contains { $0.shareAt80 < 0.95 } }
        }
        if let s = game.lastSession, s.minutes >= 1 { return s.shareAt80 < 0.95 }
        return reports[game.id]?.findings.contains { ["gpu-limit", "cpu-limit", "turns-limit", "mixed-limit"].contains($0.id) } ?? false
    }

    /// For a DirectX 11 or 12 game on Autopilot that doesn't hold 80: the newest D3DMetal
    /// there is, installed from the engine list if it isn't here yet, switched to on trial.
    func considerEngineUpgrade(gameID: UUID) async {
        guard let game = Library.shared.games.first(where: { $0.id == gameID }), game.autopilot,
              engineWork[gameID] == nil, !Launcher.shared.isBusy(game),
              let container = Library.shared.container(id: game.containerID), container.engineTrial == nil,
              needsSpeed(game) else { return }
        let exe = game.executableURL
        let analysis = await Task.detached(priority: .utility) { GameAnalysis.cached(for: exe) }.value
        guard analysis?.primary == .d3d11 || analysis?.primary == .d3d12 else { return }

        let runtimes = RuntimeManager.shared
        let current = runtimes.runtime(id: container.runtimeID)
        let rank = current?.hasD3DMetal == true ? (current?.d3dMetalRank ?? []) : []
        let rejected = Set(container.rejectedEngines)
        // Only with something to compare against: a trial without how the game ran before
        // can never be judged.
        guard baseline(for: game, container: container) != nil else { return }
        // Engines that started on this Mac when Anvil prepared them; one rejected earlier
        // only if Anvil now supports its kind better than when it lost.
        var target = runtimes.runtimes
            .filter { $0.isUsable && $0.hasD3DMetal && $0.id != container.runtimeID && container.mayTry($0)
                      && EngineOptimizer.shared.mayOffer($0)
                      && rank.lexicographicallyPrecedes($0.d3dMetalRank) }
            .max { $0.d3dMetalRank.lexicographicallyPrecedes($1.d3dMetalRank) }
        let best = target?.d3dMetalRank ?? rank
        let release = EngineCatalog.shared.releases
            .filter { release in
                guard let gptk = release.gptkVersion, !rejected.contains(release.runtimeID),
                      runtimes.runtime(id: release.runtimeID) == nil else { return false }
                return best.lexicographicallyPrecedes(gptk.split(separator: ".").map { Int($0) ?? 0 })
            }
            .max { ($0.gptkVersion ?? "").compare($1.gptkVersion ?? "", options: .numeric) == .orderedAscending }

        if let release {
            guard Connectivity.isOnlineNow else { return }
            engineWork[gameID] = "Installing \(release.headline) for \(game.title)…"
            banner = Banner(gameID: gameID, title: "Installing a faster engine for \(game.title)",
                            message: "\(release.headline)\(release.channel == "preview" ? " (preview)" : "") — Apple's newer D3DMetal. It downloads once; the game then switches to it on trial.")
            AnvilLog.write("engine: installing \(release.headline) for \(game.title) by Autopilot")
            do {
                target = try await EngineCatalog.shared.install(release)
            } catch {
                AnvilLog.write("engine: \(release.headline) couldn't be installed: \(error.localizedDescription)")
                engineWork[gameID] = nil
                return
            }
        }
        guard let target else { engineWork[gameID] = nil; return }
        // The game may have been started while the engine downloaded.
        guard let fresh = Library.shared.games.first(where: { $0.id == gameID }), !Launcher.shared.isBusy(fresh) else {
            engineWork[gameID] = nil
            return
        }
        engineWork[gameID] = "Switching \(game.title) to \(target.displayName)…"
        do {
            try await switchEngine(for: fresh, to: target.id, byAutopilot: true)
            banner = Banner(gameID: gameID, title: "\(game.title) now runs on \(target.displayName)",
                            message: "D3DMetal \(target.d3dMetalVersion ?? "newer"), on trial with a snapshot: if the game doesn't start, crashes or runs slower, Anvil switches back by itself.")
            var report = reports[gameID] ?? HealthReport(checkedAt: Date(), sessionStartedAt: nil, playMinutes: 0, findings: [])
            report.findings.removeAll { $0.id == "engine-switched" }
            report.findings.insert(HealthFinding(
                id: "engine-switched", kind: .fixed, title: "Switched to \(target.displayName)",
                detail: "Its D3DMetal \(target.d3dMetalVersion ?? "") replaces \(current?.d3dMetalVersion ?? "the older one") in \(current?.displayName ?? "the old engine"). A snapshot of the container was taken first. Once you've played a few minutes on it, the game is compared with how it ran before; if it doesn't start, crashes or runs clearly slower, Anvil switches back by itself.",
                fix: nil), at: 0)
            reports[gameID] = report
            save(gameID)
        } catch {
            AnvilLog.write("engine: switching \(game.title) to \(target.displayName) failed: \(error.localizedDescription)")
        }
        engineWork[gameID] = nil
    }

    /// Move a game installed in another app's Wine setup into a container made from a copy
    /// of that setup.
    func giveOwnContainer(gameID: UUID) async {
        guard var game = Library.shared.games.first(where: { $0.id == gameID }), !Launcher.shared.isBusy(game),
              let foreign = Library.shared.foreignPrefix(of: game.executableURL) else { return }
        let library = Library.shared
        let target: (Container, URL)?
        if let existing = library.containers.first(where: { $0.sourceSetup == foreign.driveC.path }) {
            target = (existing, Library.inside(existing, executable: game.executableURL, from: foreign))
        } else {
            target = try? await library.containerFromSetup(foreign, executable: game.executableURL, title: game.title)
        }
        guard let (container, exe) = target else { return }
        game.containerID = container.id
        game.executablePath = exe.path
        library.update(game)
        resolve("foreign-setup", gameID: gameID, note: "Now in “\(container.name)”, a copy of \(foreign.displayName) — from the next launch.")
    }

    /// Mark a finding as dealt with.
    private func resolve(_ findingID: String, gameID: UUID, note: String) {
        guard var report = reports[gameID], let i = report.findings.firstIndex(where: { $0.id == findingID }) else { return }
        report.findings[i].kind = .fixed
        report.findings[i].detail = note
        report.findings[i].fix = nil
        reports[gameID] = report
        save(gameID)
    }
}

extension Notification.Name {
    /// Show the engine list.
    static let anvilShowRuntimes = Notification.Name("anvil.showRuntimes")
    /// Open a game's page; the object is its UUID.
    static let anvilShowGame = Notification.Name("anvil.showGame")
}
