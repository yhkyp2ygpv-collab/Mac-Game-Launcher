import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Offline Test: whether a game really plays with no connection, found out while there is one.
///
/// Anvil starts the game exactly as it starts it with no connection — Epic's offline start, its
/// own connections held back (anvil_net.mm) — while the Mac stays online, watches it for a little
/// over a minute, closes it the way Quit does, and judges from the pictures Anvil keeps of its
/// screen: compared with the same moments of its online starts, and read for words. A game that
/// gets as far as its online starts do plays offline; one that stays on the screen its online
/// starts leave within seconds needs internet to start. On 10 October LEGO Star Wars' Epic
/// edition, started offline, still showed its key-art loading screen at 15 s, where its online
/// start was already at its Seizure Warning.
///
/// One start per test, the way the game's record has got to (EpicOfflineWay); a test that doesn't
/// get going moves an Epic game on to its next way for the next test or offline start. The test
/// fakes nothing and gets around no store's sign-in: it is the start a player gets on a plane.
@MainActor
final class OfflineTest: ObservableObject {
    static let shared = OfflineTest()

    /// In the session's launch lines: a test, not a session to learn from as play.
    nonisolated static let logMark = "offline test:"
    /// How long a test watches before closing the game: past the 60 s picture.
    nonisolated static let watchSeconds = 66

    enum Verdict: String, Codable {
        case plays, needsInternet, crashed, unclear

        var title: String {
            switch self {
            case .plays: "Plays offline"
            case .needsInternet: "Needs internet to start"
            case .crashed: "Closed by itself"
            case .unclear: "Couldn't tell"
            }
        }
        var symbol: String {
            switch self {
            case .plays: "checkmark.circle.fill"
            case .needsInternet: "wifi.exclamationmark"
            case .crashed: "xmark.octagon.fill"
            case .unclear: "questionmark.circle"
            }
        }
    }

    /// The last Offline Test of a game, kept in its OfflineRecord.
    struct Result: Codable, Hashable {
        var date: Date
        var verdict: Verdict
        /// How an Epic game was started for it.
        var way: EpicOfflineWay?
        /// Why, in a sentence.
        var detail: String
        /// The test's pictures, and the online session it was compared with: folder names
        /// under Screens/<game id>.
        var folder: String?
        var comparedWith: String?
        /// The picture from the test to show beside the online one, by file name ("045s.jpg").
        var picture: String?
        var referencePicture: String?
        /// Set by the player for a test Anvil couldn't judge.
        var confirmedByPlayer = false

        init(date: Date, verdict: Verdict, way: EpicOfflineWay? = nil, detail: String, folder: String? = nil,
             comparedWith: String? = nil, picture: String? = nil, referencePicture: String? = nil) {
            self.date = date; self.verdict = verdict; self.way = way; self.detail = detail; self.folder = folder
            self.comparedWith = comparedWith; self.picture = picture; self.referencePicture = referencePicture
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            date = c.value("date", Date.distantPast)
            verdict = c.value("verdict", .unclear)
            way = c.optional("way")
            detail = c.value("detail", "")
            folder = c.optional("folder")
            comparedWith = c.optional("comparedWith")
            picture = c.optional("picture")
            referencePicture = c.optional("referencePicture")
            confirmedByPlayer = c.value("confirmedByPlayer", false)
        }
    }

    struct Run: Equatable {
        enum Phase: Equatable { case starting, watching, closing, judging }
        let gameID: UUID
        let title: String
        var phase: Phase
        var since = Date()
        /// Games still to test after this one, for Test All.
        var queued: Int = 0
    }

    @Published private(set) var run: Run?
    private var queue: [UUID] = []
    /// Tests finished since the queue last ran dry, for the one notice at the end.
    private var finished: [(String, Verdict)] = []
    private var stopRequested = false

    // MARK: What can be tested

    /// Why a game can't be given an Offline Test, or nil when it can.
    nonisolated static func whyNot(_ game: Game) -> String? {
        if AutoStart.isStoreApp(game) { return "It's a store's own app; the games in it are tested one by one." }
        if game.steamAppID != nil {
            return "A Steam game starts offline only in Steam's own Offline Mode, which Steam turns on itself; Anvil checks that Steam is ready for it instead."
        }
        if !game.exists { return "Its program can't be found." }
        return nil
    }

    /// Games a Test All would start: testable, and not yet known to play offline or to need
    /// internet — or with an Epic way left to try since their last test.
    nonisolated static func untested(_ games: [Game]) -> [Game] {
        games.filter { g in
            guard whyNot(g) == nil else { return false }
            let r = g.offlineRecord
            if r?.playedOffline == true || r?.doesntGetGoing == true { return false }
            guard let test = r?.test else { return true }
            if test.verdict == .unclear && !test.confirmedByPlayer { return false }
            // An Epic game whose last test didn't get going and has another way to try.
            return test.verdict != .plays && r?.viaEpic == true && test.way != r?.currentWay
        }
    }

    // MARK: Running

    /// Test one game, or carry on with the queue.
    func test(_ game: Game) {
        guard run == nil else {
            if !queue.contains(game.id) { queue.append(game.id) }
            run?.queued = queue.count
            return
        }
        Task { await perform(game) }
    }

    /// Every game that hasn't been tested yet, one after another.
    func testAll() {
        let games = Self.untested(Library.shared.games)
        guard !games.isEmpty else { return }
        AnvilLog.write("offline test: testing \(games.count) game\(games.count == 1 ? "" : "s") one after another — \(games.map(\.title).joined(separator: ", "))")
        queue.append(contentsOf: games.map(\.id).filter { !queue.contains($0) })
        if run == nil, let first = queue.first {
            queue.removeFirst()
            if let g = Library.shared.games.first(where: { $0.id == first }) { Task { await perform(g) } }
        } else {
            run?.queued = queue.count
        }
    }

    /// Stop: the game being tested is closed, nothing is recorded, and the queue is dropped.
    func stop() {
        guard let run else { return }
        stopRequested = true
        queue.removeAll()
        if let game = Library.shared.games.first(where: { $0.id == run.gameID }) { Launcher.shared.quit(game) }
    }

    private func next() {
        while let id = queue.first {
            queue.removeFirst()
            if let g = Library.shared.games.first(where: { $0.id == id }) {
                Task { await perform(g) }
                return
            }
        }
    }

    private func perform(_ stored: Game) async {
        let launcher = Launcher.shared
        guard let game = Library.shared.games.first(where: { $0.id == stored.id }) else { next(); return }
        if let why = Self.whyNot(game) {
            AnvilLog.write("offline test: \(game.title) — not tested: \(why)")
            next(); return
        }
        guard launcher.sessions.isEmpty, launcher.launching == nil else {
            AnvilLog.write("offline test: \(game.title) — not started: another game is running or starting")
            GameReady.shared.say("Offline Test didn't start", "Close the game that's running, then test \(game.title) again.", id: "offline-test-\(game.id.uuidString)")
            queue.removeAll()
            return
        }
        guard let engine = QuickLaunch.engine(for: game) else { next(); return }
        stopRequested = false
        let way = game.offlineRecord?.viaEpic == true || game.epicAppName != nil ? (game.offlineRecord?.currentWay ?? .keptArguments) : nil
        run = Run(gameID: game.id, title: game.title, phase: .starting, queued: queue.count)
        AnvilLog.write("offline test: \(game.title) — starting it as with no connection, its own connections held back; the Mac stays online")

        let session: Launcher.Session
        do {
            session = try await launcher.prepareAndLaunch(game: game, container: engine.container, runtime: engine.runtime, offlineTest: true)
        } catch {
            AnvilLog.write("offline test: \(game.title) — didn't start: \(error.localizedDescription)")
            finishRun(game, Result(date: Date(), verdict: .crashed, way: way, detail: "It didn't start: \(error.localizedDescription)"))
            return
        }

        // Watching: how long it ran in front, and whether it closed by itself.
        run?.phase = .watching
        run?.since = session.startedAt
        var inFront = 0, watched = 0, behindFor = 0, broughtBack = 0
        var lastBroughtBack = -100
        var endedAlone: Int?
        while watched < Self.watchSeconds {
            try? await Task.sleep(for: .seconds(1))
            watched += 1
            guard let live = launcher.sessions.first(where: { $0.id == session.id }) else { endedAlone = watched; break }
            if GameReady.inFront(live) || launcher.runsBehind.contains(game.id) {
                inFront += 1
                behindFor = 0
            } else {
                // Many games stop drawing behind other windows (Unity's do), and then there's
                // nothing to judge: on 10 October macOS's notification prompt came up in front of
                // Cat Quest II 6 s into its test. Put back in front, now and then, not fought over.
                behindFor += 1
                if behindFor >= 3, watched - lastBroughtBack >= 10, watched > 3 {
                    GameFocus.handOff(to: game, startedAt: live.startedAt)
                    lastBroughtBack = watched
                    broughtBack += 1
                }
            }
            if stopRequested { break }
        }
        if broughtBack > 0 {
            AnvilLog.write("offline test: \(game.title) — brought back in front \(broughtBack) time\(broughtBack == 1 ? "" : "s") during the test")
        }
        if stopRequested {
            AnvilLog.write("offline test: \(game.title) — stopped; nothing recorded")
            await waitForEnd(session)
            run = nil
            stopRequested = false
            return
        }
        if endedAlone == nil {
            run?.phase = .closing
            launcher.quit(game)
            await waitForEnd(session)
        }

        // Judging, from its pictures and those of its online starts.
        run?.phase = .judging
        try? await Task.sleep(for: .seconds(1))
        let folder = session.screens
        let gameID = game.id, title = game.title, launchLog = AnvilLog.url
        let shareInFront = Double(inFront) / Double(max(watched, 1))
        let judgement = await Task.detached(priority: .userInitiated) { () -> OfflineJudge.Judgement in
            var test = folder.map { OfflineJudge.pictures(in: $0) } ?? []
            // Closed early: its last picture, at the moment it closed, counts as one more.
            if let s = endedAlone, let folder, let last = OfflineJudge.lastPicture(in: folder, at: s),
               last.seconds > (test.last?.seconds ?? 0) { test.append(last) }
            let text = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
            let references = Self.onlineFolders(gameID: gameID, launchLog: text)
                .filter { $0.standardizedFileURL != folder?.standardizedFileURL }
                .prefix(4).map { (name: $0.lastPathComponent, pictures: OfflineJudge.pictures(in: $0)) }
            return OfflineJudge.judge(test: test, references: Array(references), endedAloneAt: endedAlone,
                                      shareInFront: shareInFront, title: title)
        }.value
        var result = Result(date: Date(), verdict: judgement.verdict, way: way, detail: judgement.detail,
                            folder: folder?.lastPathComponent, comparedWith: judgement.comparedWith,
                            picture: judgement.picture, referencePicture: judgement.referencePicture)
        if way != nil, result.verdict == .needsInternet || result.verdict == .plays {
            result.detail += " Started as \(way!.title)."
        }
        finishRun(game, result)
    }

    private func waitForEnd(_ session: Launcher.Session) async {
        for _ in 0..<60 where Launcher.shared.sessions.contains(where: { $0.id == session.id }) {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func finishRun(_ game: Game, _ result: Result) {
        record(result, for: game.id)
        AnvilLog.write("offline test: \(game.title) — \(result.verdict.title.lowercased()): \(result.detail)")
        finished.append((game.title, result.verdict))
        // Said once the last test is over: a notice — or macOS asking whether Anvil may show
        // them — coming up in front of the next game would be in its test's way.
        if queue.isEmpty {
            let done = finished
            finished.removeAll()
            let body = done.count == 1 ? "\(done[0].1.title). \(result.detail)"
                : done.map { "\($0.0): \($0.1.title.lowercased())" }.joined(separator: "; ") + "."
            GameReady.shared.say(done.count == 1 ? "Offline Test: \(game.title)" : "Offline Tests done", body,
                                 id: "offline-test-\(game.id.uuidString)", gameID: nil)
        }
        run = nil
        Task { await CheckUp.shared.run() }
        next()
    }

    /// The test's result into the game's record: a test that played counts as an offline start
    /// that played, one that didn't get going as one that didn't — given at once for the way it
    /// used, being a test.
    func record(_ result: Result, for gameID: UUID) {
        guard var game = Library.shared.games.first(where: { $0.id == gameID }) else { return }
        var record = game.offlineRecord ?? OfflineRecord()
        if result.way != nil { record.viaEpic = true }
        record.test = result
        switch result.verdict {
        case .plays: record.add(.played, session: result.date, way: result.way, decisive: true)
        case .needsInternet: record.add(.stuck, session: result.date, way: result.way, decisive: true)
        case .crashed, .unclear: break
        }
        game.offlineRecord = record
        Library.shared.update(game)
    }

    /// The player's answer for a test Anvil couldn't judge, from its picture.
    func confirm(gameID: UUID, plays: Bool) {
        guard let game = Library.shared.games.first(where: { $0.id == gameID }), var result = game.offlineRecord?.test else { return }
        result.verdict = plays ? .plays : .needsInternet
        result.confirmedByPlayer = true
        result.detail = plays ? "You saw it playable in its offline test." : "You saw it stuck in its offline test."
        record(result, for: gameID)
        AnvilLog.write("offline test: \(game.title) — the player says it \(plays ? "plays" : "doesn't get going") offline")
    }

    // MARK: Its online starts

    /// The picture folders of the game's sessions that started online, newest first — from the
    /// launch log, where each session names its folder (ANVIL_SCREENS) and says if it was offline.
    nonisolated static func onlineFolders(gameID: UUID, launchLog text: String) -> [URL] {
        let marker = "env ANVIL_SCREENS="
        let root = ScreenReader.root.appendingPathComponent(gameID.uuidString, isDirectory: true).path
        var online: [URL] = []
        var offline = false
        for line in text.split(separator: "\n") {
            if line.contains("prepareAndLaunch: ") { offline = false; continue }
            if line.contains(logMark) || OfflineStarts.startedOffline([line]) { offline = true; continue }
            guard let r = line.range(of: marker) else { continue }
            let path = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix(root), !offline else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { online.append(url) }
        }
        return online.reversed()
    }
}

// MARK: - Judging

/// Comparing a test's pictures with the game's online ones. Each picture is cut to a 32 × 18 grey
/// thumbnail; two pictures are the same screen when their thumbnails differ by little on average —
/// a loading screen's moving bar or a menu's sparkle stays well under it, a new screen goes far over.
enum OfflineJudge {
    struct Picture {
        var name: String
        var seconds: Int
        var thumb: [Float]
        var lines: [String]
    }

    struct Judgement: Equatable {
        var verdict: OfflineTest.Verdict
        var detail: String
        var comparedWith: String?
        var picture: String?
        var referencePicture: String?
    }

    /// Thumbnails differing by less than this, on a 0–1 grey scale, are the same screen. Measured
    /// on LEGO Star Wars' pictures of 9–10 October: one screen differs from itself by 0.000–0.037
    /// (its loading bar moving, its Seizure Warning fading in), a new screen by 0.06–0.47.
    static let same: Float = 0.05
    static let side = (w: 32, h: 18)

    /// A session's timed pictures (not last.jpg), oldest first, with their words.
    static func pictures(in folder: URL) -> [Picture] {
        let words = Dictionary(ScreenReader.read(folder: folder).map { ($0.name, $0.lines) }, uniquingKeysWith: { a, _ in a })
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { ScreenReader.seconds(of: $0) != nil }
        return names.compactMap { name -> Picture? in
            guard let s = ScreenReader.seconds(of: name), let t = thumbnail(folder.appendingPathComponent(name)) else { return nil }
            return Picture(name: name, seconds: s, thumb: t, lines: words[name] ?? [])
        }.sorted { $0.seconds < $1.seconds }
    }

    /// last.jpg — the newest picture, taken every few seconds — as a picture at `seconds`.
    static func lastPicture(in folder: URL, at seconds: Int) -> Picture? {
        let url = folder.appendingPathComponent("last.jpg")
        guard let t = thumbnail(url) else { return nil }
        let lines = ScreenReader.read(folder: folder).first(where: \.isLast)?.lines ?? []
        return Picture(name: "last.jpg", seconds: seconds, thumb: t, lines: lines)
    }

    static func thumbnail(_ url: URL) -> [Float]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let (w, h) = side
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes.map { Float($0) / 255 } : nil
    }

    static func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum: Float = 0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return sum / Float(a.count)
    }

    /// Nearly one shade all over: black between scenes, a fade. Says nothing about where a game is.
    static func isBlank(_ t: [Float]) -> Bool {
        guard !t.isEmpty else { return true }
        let mean = t.reduce(0, +) / Float(t.count)
        let spread = t.reduce(0) { $0 + abs($1 - mean) } / Float(t.count)
        return spread < 0.02
    }

    static func judge(test: [Picture], references: [(name: String, pictures: [Picture])], endedAloneAt: Int?,
                      shareInFront: Double, title: String) -> Judgement {
        let shown = test.filter { !isBlank($0.thumb) }
        if let s = endedAloneAt {
            // Closed before the test was over, by itself or from outside Anvil — which Anvil can't
            // tell. What it had shown by then still says whether it had got going: on 10 October
            // Cat Quest II, started offline, was telling its opening story when it closed at 21 s.
            guard let last = shown.last else {
                return Judgement(verdict: .crashed, detail: "It closed \(s) s after it started, before it showed anything. Its next start shows whether that happens online too.")
            }
            let words = last.lines.isEmpty ? "" : " (“\(ScreenReader.quote(last.lines))”)"
            switch ScreenReader.kind(of: last.lines) {
            case .connection:
                return Judgement(verdict: .needsInternet, detail: "It was showing\(words) when it closed, \(s) s after it started.", picture: last.name)
            case .pressToStart, .menu:
                return Judgement(verdict: .plays, detail: "It had got as far as \(ScreenReader.kind(of: last.lines) == .menu ? "its menu" : "waiting for a button")\(words) when it closed, \(s) s after it started.", picture: last.name)
            default:
                return Judgement(verdict: .unclear, detail: "It closed \(s) s after it started — by itself, or from outside Anvil — while showing the picture below\(words). Say whether it had got going, or test it again with nothing else running.", picture: last.name)
            }
        }

        // A screen waiting for a button is a game that's going.
        if let p = shown.first(where: { $0.seconds >= 10 && [.pressToStart, .menu].contains(ScreenReader.kind(of: $0.lines)) }) {
            let what = ScreenReader.kind(of: p.lines) == .menu ? "at its menu" : "waiting for a button press"
            return Judgement(verdict: .plays, detail: "At \(p.seconds) s it was \(what) (“\(ScreenReader.quote(p.lines))”), as a game is once it's going.", picture: p.name)
        }

        let late = shown.filter { $0.seconds >= 20 }
        guard !late.isEmpty else {
            if shareInFront < 0.6 {
                return Judgement(verdict: .unclear, detail: "Another window was in front of it for most of the test (\(100 - Int(shareInFront * 100))% of it), and games like it stop drawing there, so Anvil had nothing to judge by. Test it again with nothing else coming up.")
            }
            return Judgement(verdict: .unclear, detail: shown.isEmpty
                             ? "Anvil had no pictures of its screen to judge by — this engine doesn't give Anvil the game's frames. Say whether it got to its menu."
                             : "It showed too little to judge by in the time it ran.")
        }
        if shareInFront < 0.6 {
            return Judgement(verdict: .unclear, detail: "It was in front for only \(Int(shareInFront * 100))% of the test, and many games pause behind other apps.", picture: late.last?.name)
        }

        // Against its online starts: as far as they get, or stuck where they move on from.
        for ref in references {
            let pics = ref.pictures.filter { !isBlank($0.thumb) }
            guard let first = pics.first else { continue }
            // Screens an online start reaches after its first one.
            let later = pics.filter { $0.seconds > first.seconds && difference($0.thumb, first.thumb) >= same }
            for t in late {
                if let match = later.first(where: { difference($0.thumb, t.thumb) < same }) {
                    return Judgement(verdict: .plays,
                                     detail: "It got as far as its online starts: at \(t.seconds) s it showed the screen an online start shows at \(match.seconds) s.",
                                     comparedWith: ref.name, picture: t.name, referencePicture: match.name)
                }
            }
            if let movedOn = later.first, late.allSatisfy({ difference($0.thumb, first.thumb) < same }),
               let lastLate = late.last, lastLate.seconds > movedOn.seconds {
                let counterpart = pics.min { abs($0.seconds - lastLate.seconds) < abs($1.seconds - lastLate.seconds) } ?? movedOn
                return Judgement(verdict: .needsInternet,
                                 detail: "It stayed on its first screen for \(lastLate.seconds) s, where started online it moves on from that screen by \(movedOn.seconds) s: with no connection it waits for something only a connection gives it — usually its store's sign-in.",
                                 comparedWith: ref.name, picture: lastLate.name, referencePicture: counterpart.name)
            }
        }

        // Still showing a message about its connection or sign-in at the end. (One shown on the
        // way, then left behind — "playing offline" — is a game carrying on.)
        if let p = late.last, ScreenReader.kind(of: p.lines) == .connection {
            return Judgement(verdict: .needsInternet, detail: "At \(p.seconds) s it was still showing “\(ScreenReader.quote(p.lines))”.", picture: p.name)
        }

        // No online start to compare with, or none that settles it: whether it kept moving.
        let changes = zip(late, late.dropFirst()).filter { difference($0.thumb, $1.thumb) >= same }.count
        if changes >= 2 || (late.count >= 2 && changes >= 1 && late.count <= 3) {
            return Judgement(verdict: .plays, detail: "Its screen kept changing through the test — intros, menus or play — rather than waiting on one screen.", picture: late.last?.name)
        }
        return Judgement(verdict: .unclear,
                         detail: "It stayed on one screen from \(late.first!.seconds) s to \(late.last!.seconds) s: a menu waiting for you, or a screen it's stuck on. Its picture is below — say which.",
                         picture: late.last?.name)
    }
}
