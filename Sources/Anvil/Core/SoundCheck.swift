import Foundation

/// What a sound output can do for surround, found by running Anvil's own game audio against it
/// (anvil-soundcheck, built from the same anvil_audio.mm libanvil runs in every game): the
/// device's own answers — channels now and possible, its speaker layout, how late its sound is —
/// and a dry run of 3D sound for a 7.1 game and a stereo one, set up for this output exactly as a
/// game would get it and rendered into memory. Nothing is heard unless a test is played.
struct SoundScan: Equatable, Sendable {
    let values: [String: String]

    init(lines: [String]) {
        var v: [String: String] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            v[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        values = v
    }

    func int(_ key: String) -> Int? { values[key].flatMap { Int($0) } }
    func double(_ key: String) -> Double? { values[key].flatMap { Double($0) } }
    func flag(_ key: String) -> Bool { values[key] == "1" }

    var deviceID: UInt32? { values["device.id"].flatMap { UInt32($0) } }
    var name: String { values["device.name"] ?? "This output" }
    var channels: Int { int("device.channels") ?? 0 }
    var mostChannels: Int { max(int("device.mostChannels") ?? 0, channels) }
    var toldChannels: Int { int("engine.toldChannels") ?? channels }
    var latencyMs: Double? { double("device.latencyMs") }
    var failure: String? { values["failed"] }
    var complete: Bool { values["done"] == "1" }

    /// 3D sound for a 7.1 game ran on this output, start to finish.
    var surroundWorks: Bool { flag("game71.spatial") && flag("game71.rendered") }
    var stereoMadeSurround: Bool { flag("gameStereo.spatial") && values["gameStereo.upmix"] == "stereo" }

    var listener: SoundOutput.Listener? { values["game71.listener"].flatMap(SoundOutput.Listener.init(rawValue:)) }

    struct Finding: Identifiable, Equatable, Sendable {
        enum Level: Sendable { case good, info, warning, bad }
        let id: String
        let level: Level
        let title: String
        let detail: String
        var opensAudioMIDISetup = false
    }

    private static func layoutName(_ n: Int) -> String {
        switch n { case 1: "mono"; case 2: "stereo"; case 6: "5.1"; case 8: "7.1"; default: "\(n)-channel" }
    }

    private var listenerWords: String {
        switch listener {
        case .headphones?: "for headphones — 3D, binaural"
        case .builtInSpeakers?: "for the Mac's own speakers — virtual surround"
        case .externalSpeakers?: "for two speakers — virtual surround"
        case .surround?: "each channel to its own speaker"
        case nil: ""
        }
    }

    /// Can this output be used for surround sound, in a sentence.
    var verdict: (yes: Bool, text: String) {
        if let failure { return (false, "Couldn't check: \(failure)") }
        if channels == 1 { return (false, "No — it plays one channel, so no sound can come from around you") }
        if !surroundWorks { return (false, "No — Anvil's 3D sound couldn't run on it") }
        if channels >= 3 { return (true, "Yes — real \(Self.layoutName(channels)) surround, each channel to its own speaker") }
        if mostChannels >= 6 { return (true, "Yes — virtual surround now, and real \(Self.layoutName(mostChannels)) if it's set to \(mostChannels) channels") }
        return (true, listener == .headphones ? "Yes — 3D surround on headphones" : "Yes — virtual surround \(listenerWords.replacingOccurrences(of: " — virtual surround", with: ""))")
    }

    var findings: [Finding] {
        var list: [Finding] = []
        if let failure {
            list.append(.init(id: "failed", level: .bad, title: "The check couldn't run", detail: failure))
            return list
        }
        if values["device.alive"] == "0" {
            list.append(.init(id: "alive", level: .bad, title: "The output isn't there", detail: "macOS says this device isn't connected any more."))
        }
        // What the 3D sound engine did with it.
        if surroundWorks {
            let cpu = double("game71.cpuMsPerSecond").map { String(format: " — %.1f ms of one core a second (%.1f%%)", $0, $0 / 10) } ?? ""
            list.append(.init(id: "engine", level: .good, title: "Anvil's 3D sound runs on it",
                              detail: "A 7.1 game's mix was set up through Apple's spatial mixer \(listenerWords), and a second of it played through without fault\(cpu)."))
        } else {
            let why = values["game71.failed"] ?? "Apple's spatial mixer wouldn't start for it"
            list.append(.init(id: "engine", level: .bad, title: "Anvil's 3D sound can't run on it", detail: why.prefix(1).uppercased() + why.dropFirst() + "."))
        }
        // Channels: now, and what it could be set to.
        switch channels {
        case 1:
            list.append(.init(id: "channels", level: .bad, title: "One channel",
                              detail: "A single speaker — or a headset in call mode while an app uses its microphone. Games play in mono here."))
        case 2 where mostChannels >= 6:
            list.append(.init(id: "channels", level: .warning, title: "Set to stereo, can play \(Self.layoutName(mostChannels))",
                              detail: "It takes up to \(mostChannels) channels. Set it to \(mostChannels) in Audio MIDI Setup (Configure Speakers) and games get real surround, each channel to its own speaker. Until then, games are told it plays 7.1 and Apple's spatial audio makes virtual surround from its two speakers.",
                              opensAudioMIDISetup: true))
        case 2:
            list.append(.init(id: "channels", level: .good, title: "Stereo — games mix in 7.1 for it",
                              detail: "Games are told it plays \(Self.layoutName(toldChannels)), so they mix in surround, and Apple's spatial audio places that mix around you \(listenerWords)."))
        case 3...8:
            list.append(.init(id: "channels", level: .good, title: "Real \(Self.layoutName(channels)) surround",
                              detail: "Games are told its own \(Self.layoutName(channels)) layout and each channel goes to its own speaker\(values["device.layout"].map { $0.isEmpty ? "" : " (\($0))" } ?? "")."))
        default:
            list.append(.init(id: "channels", level: .info, title: "\(channels) channels",
                              detail: "3D sound is made for 2 to 8 channels; on this many, games play as they mix."))
        }
        // Stereo games.
        if stereoMadeSurround {
            let bed = int("gameStereo.bed") ?? 8
            list.append(.init(id: "stereo", level: .good, title: "Stereo games made \(Self.layoutName(bed)) by Anvil Surround",
                              detail: "A game that only mixes in stereo is split before 3D sound places it: voices in the middle to the centre, the room beside and behind you, sounds panned to one side left at the front."))
        } else if flag("gameStereo.spatial") {
            list.append(.init(id: "stereo", level: .info, title: "Stereo games placed as stereo",
                              detail: "Anvil Surround is off, so a stereo game's two sides are placed ahead of you as two speakers."))
        }
        // How late it is.
        if let ms = latencyMs, ms > 0 {
            let late = ms > 100
            list.append(.init(id: "latency", level: late ? .warning : ms > 45 ? .info : .good,
                              title: String(format: "Sound reaches you %.0f ms after the game plays it", ms),
                              detail: late ? "That's late enough to notice in a game — usual for Bluetooth and AirPlay. Wired headphones or the Mac's own speakers are quicker."
                                           : ms > 45 ? "A little more than wired outputs, still fine to play with."
                                                     : "Quick: as wired outputs are."))
        }
        if flag("game71.personalized") {
            list.append(.init(id: "personal", level: .good, title: "Your personalized spatial audio",
                              detail: "Set up for your ears in System Settings, and used for every game."))
        }
        if let hog = int("device.hogPid"), hog > 0 {
            list.append(.init(id: "hog", level: .warning, title: "Another app has it to itself",
                              detail: "An app (process \(hog)) holds this output exclusively, so games may not be heard until it lets go."))
        }
        return list
    }
}

/// Runs anvil-soundcheck: a silent scan of an output, or a test that plays through it.
@MainActor
final class SoundCheck: ObservableObject {
    static let shared = SoundCheck()

    enum Test: String, Sendable { case surround, stereo }

    @Published private(set) var scanning = false
    @Published private(set) var scan: SoundScan?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var testing: Test?
    @Published private(set) var part: String?
    @Published private(set) var problem: String?

    private var scanProcess: Process?
    private var testProcess: Process?

    nonisolated static var helper: URL? {
        if let path = ProcessInfo.processInfo.environment["ANVIL_SOUNDCHECK"] { return URL(fileURLWithPath: path) }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("anvil-soundcheck"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The game's own settings, with 3D sound on: the check says what a game gets with it.
    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.merge(SpatialSound.environment(forcingOn: true)) { _, new in new }
        env["ANVIL_LOG"] = nil
        return env
    }

    func scan(_ output: SoundOutput) {
        guard !scanning else { return }
        guard let helper = Self.helper else { problem = "The sound check is missing from this copy of Anvil."; return }
        problem = nil
        scanning = true
        let p = Process()
        p.executableURL = helper
        p.arguments = ["scan", String(output.id)]
        p.environment = Self.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            let status = process.terminationStatus
            Task { @MainActor in SoundCheck.shared.finishScan(lines: lines, status: status, output: output) }
        }
        scanProcess = p
        do { try p.run() } catch {
            scanning = false
            problem = "The sound check couldn't start: \(error.localizedDescription)"
        }
    }

    private func finishScan(lines: [String], status: Int32, output: SoundOutput) {
        scanning = false
        scanProcess = nil
        let result = SoundScan(lines: lines)
        guard result.complete || result.failure != nil else {
            problem = "The sound check stopped before it finished (code \(status))."
            return
        }
        scan = result
        scannedAt = Date()
        let verdict = result.verdict
        AnvilLog.write("sound check: \(output.name) — \(verdict.text)"
                       + (result.latencyMs.map { String(format: ", %.0f ms late", $0) } ?? ""))
    }

    /// Plays a test through `output`: a burst from each speaker of a 7.1 mix in turn, or a stereo
    /// game's sound through Anvil Surround. `part` follows what is playing.
    func play(_ test: Test, through output: SoundOutput) {
        guard testing == nil else { return }
        guard let helper = Self.helper else { problem = "The sound check is missing from this copy of Anvil."; return }
        problem = nil
        testing = test
        part = nil
        let p = Process()
        p.executableURL = helper
        p.arguments = ["play", test.rawValue, String(output.id)]
        p.environment = Self.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            Task { @MainActor in
                for line in lines {
                    if line.hasPrefix("playing=") { SoundCheck.shared.part = String(line.dropFirst(8)) }
                    if line.hasPrefix("failed=") { SoundCheck.shared.problem = "The test couldn't play: " + line.dropFirst(7) }
                }
            }
        }
        p.terminationHandler = { _ in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                SoundCheck.shared.testing = nil
                SoundCheck.shared.part = nil
                SoundCheck.shared.testProcess = nil
            }
        }
        testProcess = p
        do {
            try p.run()
            AnvilLog.write("sound check: playing the \(test == .surround ? "surround" : "stereo game") test through \(output.name)")
        } catch {
            testing = nil
            problem = "The test couldn't start: \(error.localizedDescription)"
        }
    }

    func stop() { testProcess?.terminate() }

    /// Forget a scan that was for another output.
    func forget(unless output: SoundOutput?) {
        if let scan, scan.deviceID != output?.id { self.scan = nil; scannedAt = nil }
    }
}
