import Foundation

/// Small upkeep done once per start, and the leftovers Anvil can point out.
@MainActor
enum Housekeeping {

    static func atLaunch() {
        AnvilLog.rotateIfNeeded()
        // First, so the first launch already knows whether Epic can be reached.
        Connectivity.shared.start()
        PlaytimeHistory.recoverIfNeeded()
        repairFaceButtonsOnce()
        steadyPacingOnce()
        generatedFramesOffOnce()
        automaticUpscalingOnce()
        remeasureSteadyOnce()
        frameGenerationEverywhereOnce()
        restoreMisjudgedOnce()
        fsr3EverywhereOnce()
        restoreMisjudgedFsr3Once()
        restoreOnePassBeforeFirstFrameOnce()
        // Sessions Learn missed — Anvil closed while a game ran — learned from game.log.
        Task { await LearnStore.shared.catchUp() }
        realFramesOnce()
        trueShapeOnce()
        offlineHistoryOnce()
        // Cover art: a store's own app gets Anvil's tile now; games without art look for it once
        // there is a connection (Steam's cover, or the Epic catalogue's, from the stores' caches).
        StoreArt.ensureAll()
        Connectivity.shared.whenOnline {
            Task { @MainActor in
                let missing = Library.shared.games.filter { ArtworkStore.shared.image(for: $0) == nil }
                guard !missing.isEmpty else { return }
                let added = await ArtworkFetcher.shared.fetchMissing(in: missing)
                if added > 0 { AnvilLog.write("artwork: found cover art for \(added) game\(added == 1 ? "" : "s")") }
            }
        }
        // Shortcuts made before a rename or an artwork change catch up with their game.
        ShortcutStore.shared.refreshAll(Library.shared.games)
    }

    // MARK: Face buttons

    /// Once, in 0.13.1: undo a pair of settings that cancelled each other.
    ///
    /// LEGO Star Wars was set to "Match the letters on the pad" and given its own
    /// controller profile with "Swap confirm and cancel" — both chosen by hand while
    /// the buttons were wrong. Each swaps A and B, so together they left A and B where
    /// they were and moved only X and Y: wrong under either layout. The swap no longer
    /// applies to Switch pads, and the layout goes back to Automatic, which maps by
    /// position for a game with Nintendo prompts — the one layout that matches them.
    static func repairFaceButtonsOnce() {
        let key = "faceButtonRepair-0.13.1"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        for var game in Library.shared.games
        where game.faceButtons == .letters && game.controllerProfileOverride?.swapFaceButtons == true {
            game.faceButtons = .automatic
            game.controllerProfileOverride?.swapFaceButtons = false
            // Nothing else was changed in it, so it goes and the container's applies again.
            if game.controllerProfileOverride == ControllerProfile() { game.controllerProfileOverride = nil }
            Library.shared.update(game)
            AnvilLog.write("face buttons: \(game.title) had “letters” and “swap confirm and cancel” together, which cancelled on A and B — set back to Automatic")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: Frame rate

    /// Once, in 0.14.0: containers that followed the display get Steady pacing — 120
    /// when the game can hold it, an even 80 when it can't (see anvil_inject.mm). Asked
    /// for as "stable 80 fps or more"; a container set to anything else is left alone,
    /// and Up to 120 is one choice away under Performance.
    static func steadyPacingOnce() {
        let key = "steadyPacing-0.14.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.containers.isEmpty else { return }
        for var container in Library.shared.containers where container.targetFPS == 0 {
            container.targetFPS = 80
            Library.shared.update(container)
            AnvilLog.write("frame rate: “\(container.name)” set to Steady — 120, or an even 80 when a game can't hold 120")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once, in 0.15.0: generated frames off wherever they were still switched on.
    ///
    /// Every session with them drew a report of distorted motion, and no preset has turned
    /// them on since 0.12 — but a container set up before that kept the switch. LEGO Star
    /// Wars' did: ANVIL_FRAME_GEN=1 in every launch, though its frames all came from the
    /// game (gen=0), because generation only runs when the game leaves refreshes empty. It
    /// is one switch away in Upscaling for anyone who wants it back.
    static func generatedFramesOffOnce() {
        let key = "generatedFramesOff-0.15.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.containers.isEmpty else { return }
        for var container in Library.shared.containers where container.upscaler.frameGeneration {
            container.upscaler.frameGeneration = false
            Library.shared.update(container)
            AnvilLog.write("frame generation: off in “\(container.name)” — real frames only")
        }
        for var game in Library.shared.games where game.upscalerOverride?.frameGeneration == true {
            game.upscalerOverride?.frameGeneration = false
            Library.shared.update(game)
            AnvilLog.write("frame generation: off for \(game.title) — real frames only")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once, in 0.19.2: games Autopilot looks after go back to their container's upscaling.
    ///
    /// On 1 October, between two LEGO Star Wars sessions on Engine 3.0, the game's own
    /// upscaling was set by hand to FSR 1 at Ultra Performance — a third of the screen's
    /// resolution — with generated frames on and the upscaler forced into its folder: the
    /// settings to reach for when frames are low, and the reason the picture got worse.
    /// Frames were low because Anvil's pacing never reached the game on Wine 9, fixed in
    /// this version. With Autopilot on, those choices are Auto-Tune's and Autopilot's, so
    /// they go back to automatic once; anything set from now on is kept.
    static func automaticUpscalingOnce() {
        let key = "automaticUpscaling-0.19.2"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        for var game in Library.shared.games where game.autopilot {
            guard let o = game.upscalerOverride,
                  o.frameGeneration || o.forceInjection || o.quality == .ultraPerformance else { continue }
            game.upscalerOverride = nil
            Library.shared.update(game)
            AnvilLog.write("upscaling: \(game.title) back to automatic — generated frames off, its own resolution, nothing forced into its folder")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once, in 0.24.0: Auto-Tune measures again what it measured under Steady.
    ///
    /// Until 0.24 a game held at an even 80 stayed held for the rest of its session once
    /// the display was judged not to follow it, and on a fixed refresh a held frame waits
    /// for the 16.7 ms refresh: LEGO Star Wars' last three sessions of 1–2 October were
    /// shown at 60–74 fps while the game could make 85 and more. Auto-Tune measured its
    /// graphics levels in those sessions, and the hold itself now lets a game able to make
    /// about 98 run at its own rate. Every result measured under Steady describes pacing
    /// that no longer exists, so it is measured again while the game is played.
    static func remeasureSteadyOnce() {
        let key = "remeasureSteady-0.24.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        for game in Library.shared.games {
            guard let state = Tuner.shared.state(for: game), state.trials.contains(where: { $0.setup.pacing == 80 }) else { continue }
            Tuner.shared.reset(game)
            AnvilLog.write("auto-tune: \(game.title) — measured under Steady pacing before 0.24, which held frames it shouldn't have; measured again as it's played")
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once, in 0.26.0: frame generation for every game, as the player asked on 3 October —
    /// "FSR 3 on all games … force it". Every container and every game with settings of its
    /// own gets it, lowest latency first; FSR to the display is on by default anyway. A game
    /// that closes unexpectedly with either on has both switched off for it again (Autopilot).
    static func frameGenerationEverywhereOnce() {
        let key = "frameGenerationEverywhere-0.26.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.containers.isEmpty else { return }
        for var container in Library.shared.containers where !container.upscaler.frameGeneration {
            container.upscaler.frameGenChoice = .lowLatency
            Library.shared.update(container)
        }
        for var game in Library.shared.games {
            guard var o = game.upscalerOverride, !o.frameGeneration else { continue }
            o.frameGenChoice = .lowLatency
            game.upscalerOverride = o
            Library.shared.update(game)
        }
        AnvilLog.write("upscaling: frame generation on for every game (lowest latency), with FSR to the display")
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once, in 0.31.0: frame generation off for every game, as it was before 0.26.
    ///
    /// On 7 October the player saw distortion in the picture. Generated frames are made up from
    /// motion Anvil measures between the game's own frames, with no motion vectors or depth from
    /// the game, and they bend edges, text and the HUD where that guess is wrong. LEGO Star Wars's
    /// last long session (5 October) was half generated for minutes at a time: it made 82 fps of
    /// its own, was taken for short of the display's 120, and was held to 60 real frames with 60
    /// made up between them — where Steady had it at an even 80, every one real. Each game's
    /// Upscaling section still has it, for anyone who wants it.
    static func realFramesOnce() {
        let key = "realFrames-0.31.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.containers.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        var changed = 0
        for var container in Library.shared.containers where container.upscaler.frameGeneration {
            container.upscaler.frameGenChoice = .off
            Library.shared.update(container)
            changed += 1
        }
        for var game in Library.shared.games {
            guard var o = game.upscalerOverride, o.frameGeneration else { continue }
            o.frameGenChoice = .off
            game.upscalerOverride = o
            Library.shared.update(game)
            changed += 1
        }
        if changed > 0 {
            AnvilLog.write("upscaling: frame generation off for every game (\(changed) settings) — only the game's own frames are shown, so nothing made up bends the picture; it can be switched on again in each game's Upscaling section")
        }
    }

    /// Once, in 0.31.0: every game back on its screen's own shape (see GameTuning.PictureShape).
    static func trueShapeOnce() {
        let key = "trueShape-0.31.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        for var game in Library.shared.games where game.pictureShape == .whole {
            game.pictureShape = .fill
            Library.shared.update(game)
            guard GameTuning.profile(for: game)?.fitsDisplay == true else { continue }
            AnvilLog.write("display: \(game.title) back to the screen's own shape — told 16:9 on this screen, its picture could be squeezed")
        }
    }

    /// Once, in 0.32.0: each game's offline record (OfflineStarts) from the starts anvil.log
    /// still holds, so a game that hasn't got going offline is known before its next offline
    /// start — LEGO Star Wars' seven, 1–8 October, among them.
    static func offlineHistoryOnce() {
        let key = "offlineHistory-0.32.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        let titles = Library.shared.games.filter { $0.offlineRecord == nil }.map { ($0.id, $0.title) }
        let logs = [AnvilLog.url.deletingPathExtension().appendingPathExtension("old.log"), AnvilLog.url]
        Task.detached(priority: .utility) {
            let text = logs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            let found = titles.compactMap { id, title -> (UUID, OfflineRecord)? in
                let record = OfflineStarts.history(title: title, launchLog: text)
                return record.recent.isEmpty ? nil : (id, record)
            }
            await MainActor.run {
                for (id, record) in found {
                    guard var game = Library.shared.games.first(where: { $0.id == id }), game.offlineRecord == nil else { continue }
                    game.offlineRecord = record
                    Library.shared.update(game)
                    AnvilLog.write("offline: \(game.title) — \(record.recent.count) earlier start\(record.recent.count == 1 ? "" : "s") with no connection found in the log"
                                   + (record.doesntGetGoing ? "; the last \(record.stuckCount) didn't get going — from now on it starts online when Offline Mode is on and there is a connection" : ""))
                }
            }
        }
    }

    /// Once, in 0.29.0: FSR 3 for every game, as the player asked on 3 October — "make FSR 3
    /// work on all games no matter the game". Every container and every game with settings of
    /// its own that used Anvil's FSR 1, MetalFX or no upscaler mode moves to it; one set to a
    /// game's own FSR or DLSS keeps that. Graphics Prep tests it at each game's sizes before
    /// its next start (Anvil's shaders changed, so every game is prepared again once), FSR 1
    /// runs where the test found it better, and a game that closes unexpectedly with FSR 3 on
    /// goes back to FSR 1 (Autopilot).
    static func fsr3EverywhereOnce() {
        let key = "fsr3Everywhere-0.29.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.containers.isEmpty else { return }
        let moves: Set<UpscalerMode> = [.off, .fsr1, .metalFX]
        var changed = 0
        for var container in Library.shared.containers where moves.contains(container.upscaler.mode) {
            container.upscaler.mode = .fsr3Every
            Library.shared.update(container)
            changed += 1
        }
        for var game in Library.shared.games {
            guard var o = game.upscalerOverride, moves.contains(o.mode) else { continue }
            o.mode = .fsr3Every
            game.upscalerOverride = o
            Library.shared.update(game)
            changed += 1
        }
        AnvilLog.write("upscaling: FSR 3 for every game — \(changed) container\(changed == 1 ? "" : "s") and game settings moved to it; Graphics Prep tests it for each game before its next start")
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once, in 0.27.0: back on what was switched off for the wrong reason.
    ///
    /// On 3 October LEGO Star Wars froze on Metal's own assertion over a depth-stencil state
    /// its graphics asked for, and was force quit. Autopilot took that for FSR or frame
    /// generation and switched both off for it — and the container advice, which set generated
    /// frames off after every session, switched them off for its container. Neither had to do
    /// with it (see GameDoctor.crashCause); the state is now put right before Metal sees it.
    /// Read from the launch log, so only a switch-off with a cause on record is undone.
    static func restoreMisjudgedOnce() {
        let key = "restoreMisjudged-0.27.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard let text = AnvilLog.tail(bytes: 4_000_000) else { return }
        let lines = text.split(separator: "\n")
        for var game in Library.shared.games {
            guard var o = game.upscalerOverride, !o.fsrToDisplay || !o.frameGeneration,
                  let off = lines.lastIndex(where: { $0.contains("autopilot: \(game.title) closed unexpectedly with ") && $0.contains("off for it from the next start") }),
                  let start = lines[..<off].lastIndex(where: { $0.contains("prepareAndLaunch: \(game.title) ") }),
                  let cause = GameDoctor.crashCause(launchLines: Array(lines[start..<off]), gameLines: []) else { continue }
            o.fsrToDisplay = true
            o.frameGenChoice = .lowLatency
            game.upscalerOverride = o
            Library.shared.update(game)
            AnvilLog.write("upscaling: \(game.title) — FSR to the display and frame generation back on: its crash was \(cause.prefix(1).lowercased() + cause.dropFirst()), not them")
        }
        guard let since = lines.lastIndex(where: { $0.contains("upscaling: frame generation on for every game") }) else { return }
        for var container in Library.shared.containers where !container.upscaler.frameGeneration {
            guard lines[since...].contains(where: { $0.contains("autopilot: “\(container.name)” — ") && $0.contains("Generated frames On → Off") })
            else { continue }
            container.upscaler.frameGenChoice = .lowLatency
            Library.shared.update(container)
            AnvilLog.write("upscaling: “\(container.name)” — frame generation back on; the container advice that switched it off is gone")
        }
    }

    /// Once, in 0.58.0: FSR 3 back where Autopilot switched it off for a crash that the game's own crash record puts
    /// somewhere else (GameDoctor.crashCause, CrashDump).
    ///
    /// On 17 October LEGO Star Wars crashed 2 seconds after the Mac woke from 27 minutes asleep, in its own code with
    /// Epic Online Services on its stack; FSR 3 was switched off for it, and Smooth Motion — made from FSR 3's pictures
    /// — went with it for the next two hours. Read from the launch log, so only a switch-off with a cause on record
    /// is undone.
    /// Once, in 0.58.2: FSR's one pass back for a game Autopilot took it from when it closed before
    /// drawing anything. Hogwarts Legacy's launcher stopped at "Microsoft Visual C++ Runtime" on 17
    /// October (code 41), and Autopilot put FSR back to two passes for it — FSR hadn't started yet.
    static func restoreOnePassBeforeFirstFrameOnce() {
        let key = "restoreOnePassBeforeFirstFrame-0.58.2"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        for game in Library.shared.games where GraphicsPrep.stored(gameID: game.id)?.onePassOff == true {
            // Only a game that has never drawn a frame through Anvil: no session of it says FSR ran.
            guard !VCRuntime.drewBefore(title: game.title, installedAt: .distantFuture) else { continue }
            GraphicsPrep.onePassBackOn(gameID: game.id)
            AnvilLog.write("graphics prep: \(game.title) — FSR's one pass back: it was turned off when the game closed before its first frame, before FSR starts")
        }
    }

    static func restoreMisjudgedFsr3Once() {
        let key = "restoreMisjudgedFsr3-0.58.0"
        guard !UserDefaults.standard.bool(forKey: key), !Library.shared.games.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard let text = AnvilLog.tail(bytes: 4_000_000) else { return }
        let lines = text.split(separator: "\n")
        for var game in Library.shared.games {
            guard var o = game.upscalerOverride, o.mode == .fsr1,
                  let off = lines.lastIndex(where: { $0.contains("autopilot: \(game.title) closed unexpectedly with FSR 3 on") }),
                  let start = lines[..<off].lastIndex(where: { $0.contains("prepareAndLaunch: \(game.title) ") }),
                  let cause = GameDoctor.crashCause(launchLines: Array(lines[start..<off]), gameLines: []) else { continue }
            o.mode = .fsr3Every
            game.upscalerOverride = o
            Library.shared.update(game)
            GraphicsPrep.fsr3BackOn(gameID: game.id)
            AnvilLog.write("upscaling: \(game.title) — FSR 3 back on, and Smooth Motion with it: \(cause), not FSR 3")
        }
    }

    // MARK: Leftover containers

    struct Leftover: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let bytes: Int64
        let modified: Date?
        /// Save-like folders found under its Windows user profile, if any.
        let hasUserData: Bool
    }

    /// Prefixes in Anvil's Containers folder that no container in the library uses —
    /// left by containers deleted in earlier versions, or by a library that could not
    /// be read and was rebuilt. Nothing here is deleted without being asked.
    nonisolated static func leftoverContainers(known: Set<UUID>) -> [Leftover] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: RuntimeManager.containersDir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { url -> Leftover? in
            guard url.hasDirectoryPath, let id = UUID(uuidString: url.lastPathComponent),
                  !known.contains(id) else { return nil }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return Leftover(url: url, bytes: ShaderCacheManager.size(of: url), modified: modified,
                            hasUserData: userDataPresent(in: url))
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Whether the prefix's Windows user profile holds anything a game may have saved.
    private nonisolated static func userDataPresent(in prefix: URL) -> Bool {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        guard let people = try? fm.contentsOfDirectory(atPath: users.path) else { return false }
        for person in people where person != "Public" {
            let profile = users.appendingPathComponent(person)
            for place in ["Saved Games", "Documents", "AppData/Roaming", "AppData/LocalLow", "AppData/Local"] {
                let dir = profile.appendingPathComponent(place)
                let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                // A fresh prefix has a Microsoft folder and little else.
                if items.contains(where: { !$0.hasPrefix(".") && $0 != "Microsoft" && $0 != "desktop.ini"
                                           && $0 != "Temp" && $0 != "Wine" && $0 != "openal" }) { return true }
            }
        }
        return false
    }
}

/// Play time from before Anvil recorded it.
///
/// Game.totalPlaySeconds and lastPlayed were never written until 0.13.0, but every
/// session's length has always been in the launch log: "exited: <title> code=0 after
/// 5548.6s". Read once, for games that have no play time of their own yet.
@MainActor
enum PlaytimeHistory {
    private static let doneKey = "playtimeRecoveredFromLog"

    static func recoverIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let logs = [AnvilLog.url.deletingPathExtension().appendingPathExtension("old.log"), AnvilLog.url]
        Task.detached(priority: .utility) {
            let sessions = logs.flatMap { parse((try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
            await MainActor.run { apply(sessions) }
        }
    }

    struct Played { let title: String; let seconds: Double; let ended: Date }

    nonisolated static func parse(_ text: String) -> [Played] {
        let stamp = ISO8601DateFormatter()
        var out: [Played] = []
        for line in text.split(separator: "\n") where line.contains("  exited: ") {
            // 2026-09-29T00:56:38Z  exited: LEGO® Star Wars™: The Skywalker Saga code=0 after 5548.6s
            guard let exited = line.range(of: "  exited: "),
                  let code = line.range(of: " code=", options: .backwards),
                  let after = line.range(of: " after ", options: .backwards),
                  code.lowerBound > exited.upperBound, after.lowerBound > code.upperBound,
                  let date = stamp.date(from: String(line[..<exited.lowerBound])) else { continue }
            let title = String(line[exited.upperBound..<code.lowerBound])
            let tail = line[after.upperBound...]
            guard let s = tail.firstIndex(of: "s"), let seconds = Double(tail[..<s]) else { continue }
            out.append(Played(title: title, seconds: seconds, ended: date))
        }
        return out
    }

    private static func apply(_ sessions: [Played]) {
        let library = Library.shared
        // Only once the library has loaded; otherwise try again next start.
        guard !library.games.isEmpty else { return }
        var recovered: [String] = []
        for var game in library.games where game.totalPlaySeconds == 0 && game.lastPlayed == nil {
            let mine = sessions.filter { $0.title == game.title && $0.seconds >= 10 }
            guard !mine.isEmpty else { continue }
            game.totalPlaySeconds = mine.reduce(0) { $0 + $1.seconds }
            game.lastPlayed = mine.map(\.ended).max()
            library.update(game)
            recovered.append("\(game.title) \(String(format: "%.1f", game.totalPlaySeconds / 3600)) h over \(mine.count) sessions")
        }
        if !recovered.isEmpty { AnvilLog.write("play time recovered from the launch log: " + recovered.joined(separator: "; ")) }
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
