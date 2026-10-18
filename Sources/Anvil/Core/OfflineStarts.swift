import AppKit
import Foundation

/// How a game's starts with no connection have gone on this Mac, from its sessions: played,
/// or closed again within minutes without getting going.
///
/// Most single-player games start offline as they do online: DRM-free ones, Epic games made to
/// run offline (Anvil starts them with Epic's own offline start), and Steam games once Steam is
/// in its Offline Mode. Some don't: their store's online sign-in is part of their start, and
/// with no connection they wait on a screen. On 1–8 October LEGO Star Wars' Epic edition was
/// started offline seven times here and each time stayed on its loading screen until it was
/// closed, while every online start got past it in about 35 seconds. Anvil can't sign a game
/// in without its store, and won't get around a store's sign-in; what it can do is try each
/// way an Epic game starts offline (EpicOfflineWay) until one gets it going, keep that one,
/// and once none has, wait for a connection before starting it (AutoStart) and show what the
/// game was showing.
struct OfflineRecord: Codable, Hashable {
    enum Outcome: String, Codable {
        /// Ran 5 minutes or more in front.
        case played
        /// Closed by the player within 3 minutes in front.
        case stuck
    }

    /// The last offline starts, oldest first (at most 6).
    var recent: [Outcome] = []
    /// The session last counted, so a session checked twice counts once.
    var lastSession: Date?
    /// What the game showed when it was last closed offline, from its screen (ScreenReader).
    var lastScreen: String?
    /// Its offline starts were Epic's offline start.
    var viaEpic = false
    /// The way an Epic game is started offline now; nil for the first, Epic's kept arguments.
    var epicWay: EpicOfflineWay?
    /// The ways that didn't get it going, in the order they were tried.
    var epicWaysFailed: [EpicOfflineWay] = []
    /// Starts in a row with the way in use that didn't get going.
    var epicWayStuck = 0
    /// The way in use got it playing offline.
    var epicWayPlayed = false
    /// Its last Offline Test (OfflineTest): started offline while the Mac was online, judged
    /// from its screen.
    var test: OfflineTest.Result?

    var currentWay: EpicOfflineWay { epicWay ?? .keptArguments }
    /// Every way an Epic game starts offline has been tried, and none got it going.
    var allEpicWaysTried: Bool { EpicOfflineWay.allCases.allSatisfy(epicWaysFailed.contains) }

    /// Started offline at least twice running and closed each time within minutes, with no
    /// offline start among the recent ones played — for an Epic game, once every way of starting
    /// it offline has been tried.
    var doesntGetGoing: Bool {
        let starts = recent.count >= 2 && recent.suffix(2).allSatisfy { $0 == .stuck }
        // An Offline Test that saw it stay on the screen its online starts leave counts on its own.
        let tested = test?.verdict == .needsInternet && recent.last == .stuck
        return (starts || tested) && !recent.contains(.played) && (!viaEpic || allEpicWaysTried)
    }
    var stuckCount: Int { recent.filter { $0 == .stuck }.count }
    var playedOffline: Bool { recent.contains(.played) }

    init() {}

    /// Key by key (see Tolerant.swift): a record from another build stays readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        recent = c.value("recent", [])
        lastSession = c.optional("lastSession")
        lastScreen = c.optional("lastScreen")
        viaEpic = c.value("viaEpic", false)
        epicWay = c.optional("epicWay")
        epicWaysFailed = c.value("epicWaysFailed", [])
        epicWayStuck = c.value("epicWayStuck", 0)
        epicWayPlayed = c.value("epicWayPlayed", false)
        test = c.optional("test")
        // Kept before the ways (0.33.0 and earlier): every one of those starts was Epic's kept
        // arguments, so a record that hadn't got going with them goes on to the next way.
        if viaEpic, epicWay == nil, epicWaysFailed.isEmpty, recent.count >= 2,
           recent.suffix(2).allSatisfy({ $0 == .stuck }), !recent.contains(.played) {
            epicWaysFailed = [.keptArguments]
            epicWay = EpicOfflineWay.keptArguments.next
        }
    }

    /// One offline start's outcome; `way` is how an Epic game was started (nil for other games).
    /// `decisive`: an Offline Test's, which settles a way in one start. Returns the way that's
    /// next when this one is given up on.
    @discardableResult
    mutating func add(_ outcome: Outcome, session: Date?, way: EpicOfflineWay? = nil, decisive: Bool = false) -> EpicOfflineWay? {
        if let session, let last = lastSession, abs(session.timeIntervalSince(last)) < 1 { return nil }
        recent = Array((recent + [outcome]).suffix(6))
        lastSession = session
        guard let way, way == currentWay else { return nil }
        if outcome == .played {
            epicWayPlayed = true
            epicWayStuck = 0
            epicWaysFailed.removeAll { $0 == way }
            return nil
        }
        epicWayStuck += 1
        // The first way gets two starts, as before; the ones after it, tried because the game
        // has already waited on a screen offline, get one each. A way that has played gets two.
        let given = decisive ? 1 : (way == .keptArguments || epicWayPlayed) ? 2 : 1
        guard epicWayStuck >= given else { return nil }
        if !epicWaysFailed.contains(way) { epicWaysFailed.append(way) }
        epicWayStuck = 0
        epicWayPlayed = false
        guard let next = EpicOfflineWay.allCases.first(where: { !epicWaysFailed.contains($0) }) else { return nil }
        epicWay = next
        return next
    }
}

enum OfflineStarts {
    static let playedFront: Double = 300
    static let stuckFront: Double = 180

    /// Whether a session's launch lines (anvil.log) show it started with no connection: Offline
    /// Mode, or a Mac with none — as Anvil writes it at every start since 0.32, and Epic's
    /// offline start before that.
    static func startedOffline<S: StringProtocol>(_ lines: [S]) -> Bool {
        lines.contains { line in
            line.contains("network: offline at the start") || line.contains("network: held back for the game")
                || line.contains("started offline as the signed-in account")
        }
    }

    /// The start went through Epic, online or with its offline start.
    static func isEpic<S: StringProtocol>(_ lines: [S]) -> Bool {
        lines.contains { $0.contains("  Epic: ") || $0.contains("  Epic sign-in") }
    }

    /// How an Epic game was started offline, from its launch lines: the way they name, or Epic's
    /// kept arguments for a start from before the ways were written down. Nil when it wasn't an
    /// Epic offline start.
    static func epicWay<S: StringProtocol>(_ lines: [S]) -> EpicOfflineWay? {
        guard isEpic(lines), startedOffline(lines) else { return nil }
        for line in lines where line.contains("  Epic: ") {
            if let way = EpicOfflineWay.allCases.first(where: { line.contains($0.logMark) }) { return way }
        }
        return lines.contains { $0.contains("started offline as the signed-in account") } ? .keptArguments : nil
    }

    /// How an offline start went, or nil when it says nothing either way: not started offline,
    /// crashed, or closed after a few minutes of play.
    static func outcome(of e: SessionEvidence) -> OfflineRecord.Outcome? {
        // An Offline Test records its own verdict, from its screen (OfflineTest).
        guard startedOffline(e.launchLines), !e.launchLines.contains(where: { $0.contains(OfflineTest.logMark) }),
              let o = e.outcome else { return nil }
        let front = GameDoctor.timeInFront(e, seconds: o.seconds) ?? o.seconds
        if front >= playedFront { return .played }
        if o.userClosed, o.status == 0, front < stuckFront { return .stuck }
        return nil
    }

    /// A game's record from what anvil.log still holds: for the games played before Anvil kept one.
    static func history(title: String, launchLog text: String) -> OfflineRecord {
        var record = OfflineRecord()
        let lines = text.split(separator: "\n")
        let iso = ISO8601DateFormatter()
        var i = 0
        while i < lines.count {
            guard lines[i].contains("prepareAndLaunch: \(title) ") else { i += 1; continue }
            var session: [Substring] = [lines[i]]
            var j = i + 1
            while j < lines.count, !lines[j].contains("prepareAndLaunch: ") { session.append(lines[j]); j += 1 }
            let started = lines[i].split(separator: " ").first.flatMap { iso.date(from: String($0)) }
            var e = SessionEvidence(startedAt: started, gameLines: [], launchLines: session, windows: [], outcome: nil)
            e.outcome = e.outcomeFromLog(title: title)
            if let outcome = outcome(of: e) {
                if isEpic(session) { record.viaEpic = true }
                record.add(outcome, session: started, way: epicWay(session))
            }
            i = j
        }
        return record
    }

    /// A game whose starts with no connection don't get going here, however Anvil starts it:
    /// it needs internet to start, and plays on without it once it has.
    static func needsConnection(_ game: Game) -> Bool { game.offlineRecord?.doesntGetGoing ?? false }

    /// What a player can do about it — the one way such a game is played offline.
    static let howToPlayOffline = "To play it offline: connect to the internet and start it. Once it's past its loading screen you can turn Wi-Fi off — it keeps playing for the rest of the session. Press Play with no internet and Anvil’s Auto start waits, then starts it by itself as soon as the connection is back; with Offline Mode on and a connection, it starts online."

    /// Why, in a sentence or two, from the game's record.
    static func why(_ record: OfflineRecord) -> String {
        let screen = record.lastScreen.map { " (“\($0)”)" } ?? ""
        if record.viaEpic {
            return "Its Epic edition signs in to Epic every time it starts, and waits on its loading screen until it can. Its last \(record.stuckCount) starts with no connection stayed on that screen\(screen), whichever way Anvil started it — including the start Epic's own Offline Mode uses, which gives a game only your account name and id."
        }
        return "Its last \(record.stuckCount) starts with no connection stayed on one screen\(screen) until they were closed, while online it plays normally."
    }

    /// The game's offline line for its page.
    static func summary(for game: Game) -> (text: String, warn: Bool) {
        let steam = game.steamAppID != nil
        let steamNote = " Steam games start offline once Steam itself is offline: sign in once with “Remember me”, then Steam › Go Offline."
        guard let record = game.offlineRecord, !record.recent.isEmpty else {
            return ("Not started offline here yet." + (steam ? steamNote : ""), false)
        }
        if record.doesntGetGoing {
            return (why(record) + " " + howToPlayOffline + (steam ? steamNote : ""), true)
        }
        if record.playedOffline {
            return ("Played offline here" + (record.viaEpic ? ", started as \(record.currentWay.title)." : "."), false)
        }
        var text = "Started offline here \(record.recent.count) time\(record.recent.count == 1 ? "" : "s")."
        if record.viaEpic, !record.epicWaysFailed.isEmpty {
            text += " Its offline starts with \(record.epicWaysFailed.map(\.title).joined(separator: ", then ")) didn't get going, so the next one starts as \(record.currentWay.title)."
        }
        return (text, !record.epicWaysFailed.isEmpty)
    }
}
