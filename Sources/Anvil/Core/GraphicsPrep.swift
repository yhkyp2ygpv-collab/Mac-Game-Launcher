import Foundation
import CryptoKit
import Metal

/// Graphics Prep: Anvil's FSR and frame generation compiled for this Mac, checked on its GPU
/// at the game's own sizes and in its own colour format, and the quicker FSR kept — before a
/// game's first start, and again only when something it depends on changes (Anvil's shaders,
/// macOS, the GPU, or the game's colour format).
///
/// What it does, and what it doesn't. Every game's own shaders are compiled by D3DMetal as the
/// game meets them, and D3DMetal keeps them (ShaderCacheManager keeps a copy macOS can't sweep
/// away); nothing outside the game can compile those ahead of it, because what they are is
/// only known when the game asks for them. FSR 3 itself needs the motion vectors and depth a
/// game hands its own upscaler (see GraphicsScan). What Graphics Prep prepares is Anvil's own
/// part of the picture:
///
/// - **Compiled before the game starts.** Anvil's 18 compute pipelines (FSR 1, FSR 3 and frame generation) go into a Metal binary
///   archive for this GPU, so the game takes them ready-made instead of compiling them at its
///   first frame — measured on an M4 under Rosetta, 690 ms for the library and 116 ms for the
///   pipelines cold, after every Anvil update or whenever macOS clears its shader cache.
///   (libanvil also starts the library compiling in the background the moment the game opens
///   Metal, so the first frame no longer waits for what is left either.) The archive is then
///   opened by the game's own architecture, under Rosetta, to show every pipeline is found.
/// - **Checked on the GPU.** FSR runs at the game's sizes in its format: a flat colour must come
///   out the colour it went in, and the one-pass version must give the two-pass picture.
/// - **The quicker FSR for the game.** Both ways are timed and the quicker kept — one pass for
///   a 16-bit float picture (1.57 ms a frame against 1.88 on an M4, 17% less), two for an 8- or
///   10-bit one (1.44 against 1.52). Less time on the GPU per frame is less latency per frame:
///   FSR runs on every frame shown, generated ones included.
/// - **FSR 3 for every game, tested at the game's sizes.** Anvil's temporal FSR 3 (motion
///   measured from the game's frames, then EASU, RCAS and a blend with the frames before) runs
///   on a moving test scene beside FSR 1 alone, both against a supersampled picture of the
///   same scene: it is used for the game only where it comes out closer in motion, no further
///   standing still, with no trail behind a moving object and nothing broken. Upscaling, it
///   won at every size tried on an M4; at the display's own size, where there is nothing to
///   upscale, it didn't — and the game's frames are then left as they are.
///
/// The work runs in anvil-prep, a process of its own: nothing it does can take Anvil or a game
/// down with it, and a hang is cut off at 90 seconds. Whatever goes wrong, the game starts as it
/// did before — pipelines compiled in the game, FSR in two passes.
struct GraphicsPrep: Codable, Hashable {
    /// What a prep was made for. A different `shaders`, `os` or `gpu` makes the archive useless
    /// (Metal would only miss in it); a different `pixelFormat` makes the timing someone else's.
    struct Key: Codable, Hashable {
        var shaders: String
        var os: String
        var gpu: String
        var pixelFormat: Int
    }

    enum Status: String, Codable { case ready, failed }

    struct GameCache: Codable, Hashable {
        var executable: String
        var bytes: Int64
        var restored: Bool
    }

    /// What the next session showed of it, from game.log.
    struct Seen: Codable, Hashable {
        var at: Date
        var readyMade: Int?
        var of: Int?
        var firstFrameWaitMs: Int?
        var onePass: Bool
        /// Frames that went through FSR 3, and why it stopped if it did.
        var fsr3Frames: Int?
        var fsr3Stopped: String?
    }

    /// FSR 3 for every game on the moving test scene, at the game's sizes and in its format,
    /// against FSR 1 alone. Differences are from a supersampled picture of the scene, in 255ths
    /// a pixel; trail is FSR 3's difference around the moving disc over FSR 1's (1 = the same).
    struct FSR3: Codable, Hashable {
        var better: Bool
        var why: String?
        var native: Bool
        var ms: Double
        var fsr1Ms: Double
        var error: Double
        var fsr1Error: Double
        var flicker: Double
        var fsr1Flicker: Double
        var stillError: Double
        var fsr1StillError: Double
        var trail: Double
        /// Smooth Motion's check (0.51): its frame made halfway between two, against the scene at that moment
        /// and against the older frame it stands in for.
        var smoothMadeError: Double?
        var smoothOlderError: Double?
        var smoothMs: Double?

        /// What the test found, and what it costs a frame.
        func text(off: Bool) -> String {
            if off { return "Off for this game — it closed unexpectedly with FSR 3 on; FSR 1, as before" }
            let cost = native ? "\(GraphicsPrep.ms(ms)) a frame" : "\(GraphicsPrep.ms(ms)) a frame against FSR 1's \(GraphicsPrep.ms(fsr1Ms))"
            guard better else {
                return "Not used for this game: \(why ?? "it wasn't better here")"
                    + (native ? " — the game's frames are shown as it draws them" : " — FSR 1, as before")
            }
            let base = native ? "the game's own frame" : "FSR 1"
            return "In motion \(GraphicsPrep.percent(error, against: fsr1Error))% closer to a supersampled picture than \(base), "
                + "\(GraphicsPrep.percent(flicker, against: fsr1Flicker))% less flicker, "
                + "\(GraphicsPrep.percent(stillError, against: fsr1StillError))% closer standing still · \(cost)"
        }
    }

    var key: Key
    var at: Date
    var status: Status
    var failure: String?
    var gameSize: String
    var shownSize: String
    /// The sizes came from the display, before any session showed the game's own.
    var estimated: Bool
    var gpu: String
    var compileMs: Int
    var pipelines: Int
    var pipelinesOf: Int
    /// Pipelines the game's architecture found ready-made in the archive; nil if not checked.
    var verifiedReady: Int?
    var archiveKept: Bool
    var pass: String
    var tile: String?
    var splitMs: Double?
    var fusedMs: Double?
    var tested: Bool
    var untestedWhy: String?
    var frameGeneration: Int
    var frameGenerationOf: Int
    var gameCache: GameCache?
    var seconds: Double
    /// One pass was switched off for this game after it closed unexpectedly with it on.
    var onePassOff: Bool = false
    var seen: Seen?
    /// FSR 3's test; nil from a prep before 0.29.
    var fsr3: FSR3?
    /// FSR 3 was switched off for this game after it closed unexpectedly with it on.
    var fsr3Off: Bool?

    var onePass: Bool { pass == "fused" && !onePassOff }
}

// MARK: - The key

extension GraphicsPrep {
    /// The shader files Anvil ships, hashed: what the game's libanvil compiles is these.
    nonisolated static let shaderHash: String = {
        guard let resources = Bundle.main.resourceURL else { return "none" }
        var hasher = SHA256()
        // How they are compiled counts as much as what they say: an archive from before the
        // language version was named (anvil_shaderset.mm) holds nothing the game can use.
        hasher.update(data: Data("msl-3.1".utf8))
        // And what the prep checks: Smooth Motion's made frame, since 0.51 (halfway only since 0.52), so every game
        // is prepared once more, before its next start, to check it.
        hasher.update(data: Data("smooth-check-2".utf8))
        for name in ["AnvilShaders.metallib", "AnvilShaders.metal", "AnvilShaders.pack"] {
            if let data = try? Data(contentsOf: resources.appendingPathComponent(name)) {
                hasher.update(data: Data(name.utf8))
                hasher.update(data: data)
            }
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    nonisolated static let osBuild: String = ProcessInfo.processInfo.operatingSystemVersionString

    nonisolated static let gpuName: String = MTLCreateSystemDefaultDevice()?.name ?? "no GPU"

    /// The game's sizes and colour format: as its last session showed them, else the display's
    /// pixels, the game at half of them (a Retina screen in points), and BGRA8 — D3DMetal's usual.
    nonisolated static func picture(gameID: UUID) -> (game: String, shown: String, format: Int, estimated: Bool) {
        if let live = GraphicsScan.stored(gameID: gameID)?.live,
           let game = live.gameSize, let shown = live.shownSize {
            return (game, shown, live.pixelFormat ?? 80, false)
        }
        let (pixels, _) = GraphicsScan.display()
        let w = pixels.count == 2 ? pixels[0] : 3024, h = pixels.count == 2 ? pixels[1] : 1964
        return ("\(w / 2)x\(h / 2)", "\(w)x\(h)", GraphicsScan.stored(gameID: gameID)?.live?.pixelFormat ?? 80, true)
    }

    nonisolated static func key(gameID: UUID) -> Key {
        Key(shaders: shaderHash, os: osBuild, gpu: gpuName, pixelFormat: picture(gameID: gameID).format)
    }

    /// Why a game needs preparing before this start, or nil if what it has still holds.
    nonisolated static func reason(gameID: UUID) -> String? {
        guard let kept = stored(gameID: gameID) else { return "it hasn't been prepared yet" }
        let now = key(gameID: gameID)
        if kept.key.shaders != now.shaders { return "Anvil's shaders changed" }
        if kept.key.os != now.os { return "macOS changed" }
        if kept.key.gpu != now.gpu { return "the GPU changed" }
        if kept.key.pixelFormat != now.pixelFormat { return "the game's colour format turned out different" }
        if kept.status == .failed { return nil }   // tried for this key; Prepare Now tries again
        if kept.archiveKept && !FileManager.default.fileExists(atPath: archiveURL(gameID: gameID).path) {
            return "its compiled shaders were removed"
        }
        return nil
    }

    /// What a launch gets from the prep: the archive, if it is for these shaders on this Mac;
    /// one pass, if that was measured quicker in this colour format and hasn't been switched off.
    nonisolated static func usable(gameID: UUID) -> (archive: URL?, onePass: Bool, tile: String)? {
        guard let kept = stored(gameID: gameID), kept.status == .ready else { return nil }
        let now = key(gameID: gameID)
        guard kept.key.shaders == now.shaders, kept.key.os == now.os, kept.key.gpu == now.gpu else { return nil }
        let archive = archiveURL(gameID: gameID)
        let hasArchive = kept.archiveKept && FileManager.default.fileExists(atPath: archive.path)
        let onePass = kept.onePass && kept.key.pixelFormat == now.pixelFormat
        guard hasArchive || onePass else { return nil }
        return (hasArchive ? archive : nil, onePass, kept.tile ?? "32x32")
    }

    /// FSR 3 for a launch: `use` — whether Graphics Prep's test found it better than FSR 1 at
    /// the game's sizes (nil: not tested on these shaders, this macOS and this GPU) — and
    /// whether those sizes were the display's own, with nothing to upscale.
    nonisolated static func fsr3Verdict(gameID: UUID) -> (use: Bool?, native: Bool) {
        guard let kept = stored(gameID: gameID), kept.status == .ready, let test = kept.fsr3 else { return (nil, false) }
        let now = key(gameID: gameID)
        guard kept.key.shaders == now.shaders, kept.key.os == now.os, kept.key.gpu == now.gpu else { return (nil, false) }
        if kept.fsr3Off == true { return (false, test.native) }
        return (test.better, test.native)
    }

    /// How much smaller the game draws than the display shows it, from the sizes Graphics Prep
    /// last saw in a session ("1512x982" → "3024x1964": 0.5). Nil before a session has shown them.
    nonisolated static func drawnRatio(gameID: UUID) -> Double? {
        guard let kept = stored(gameID: gameID) else { return nil }
        func width(_ size: String) -> Double? { size.split(separator: "x").first.flatMap { Double($0) } }
        guard let drawn = width(kept.gameSize), let shown = width(kept.shownSize), drawn > 0, shown > 0 else { return nil }
        return drawn / shown
    }

    /// FSR 3's cost over FSR 1 at the game's sizes, as Graphics Prep measured it on this Mac:
    /// where libanvil's budget for it starts (ANVIL_FSR3_EXTRA_MS), before it learns the cost
    /// in the game itself. Nil when not measured on these shaders, this macOS and this GPU.
    nonisolated static func fsr3ExtraMs(gameID: UUID) -> Double? {
        guard let kept = stored(gameID: gameID), kept.status == .ready, let test = kept.fsr3, !test.native,
              test.ms > 0, test.fsr1Ms > 0 else { return nil }
        let now = key(gameID: gameID)
        guard kept.key.shaders == now.shaders, kept.key.os == now.os, kept.key.gpu == now.gpu else { return nil }
        return min(max(test.ms - test.fsr1Ms, 0.3), 8.0)
    }
}

// MARK: - Keeping it

extension GraphicsPrep {
    nonisolated static var folder: URL { DiskCache.directory.appendingPathComponent("GraphicsPrep", isDirectory: true) }
    nonisolated private static var url: URL { DiskCache.directory.appendingPathComponent("GraphicsPrep.json") }
    nonisolated static func archiveURL(gameID: UUID) -> URL { folder.appendingPathComponent("\(gameID.uuidString).metalar") }
    nonisolated static func newArchiveURL(gameID: UUID) -> URL { folder.appendingPathComponent("\(gameID.uuidString).new.metalar") }

    nonisolated(unsafe) private static var memory: [String: GraphicsPrep]?
    private static let lock = NSLock()

    private nonisolated static func load() {
        if memory != nil { return }
        memory = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: GraphicsPrep].self, from: $0) } ?? [:]
    }

    private nonisolated static func save() {
        guard let memory, let data = try? JSONEncoder().encode(memory) else { return }
        try? FileManager.default.createDirectory(at: DiskCache.directory, withIntermediateDirectories: true)
        DiskCache.writeReplacing(data, to: url)
    }

    nonisolated static func stored(gameID: UUID) -> GraphicsPrep? {
        lock.lock(); defer { lock.unlock() }
        load()
        return memory?[gameID.uuidString]
    }

    nonisolated static func keep(_ prep: GraphicsPrep, gameID: UUID) {
        lock.lock(); defer { lock.unlock() }
        load()
        memory?[gameID.uuidString] = prep
        save()
    }

    nonisolated static func update(gameID: UUID, _ change: (inout GraphicsPrep) -> Void) {
        lock.lock(); defer { lock.unlock() }
        load()
        guard var prep = memory?[gameID.uuidString] else { return }
        change(&prep)
        memory?[gameID.uuidString] = prep
        save()
    }

    /// Preps and archives of games no longer in the library. Anvil's own cache, nothing of the
    /// player's: removed outright.
    @MainActor static func tidy() {
        let ids = Set(Library.shared.games.map(\.id.uuidString))
        Task.detached(priority: .background) {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let id = name.split(separator: ".").first.map(String.init), !ids.contains(id) else { continue }
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
            forgetAll(except: ids)
        }
    }

    private nonisolated static func forgetAll(except ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        load()
        guard let keys = memory?.keys.filter({ !ids.contains($0) }), !keys.isEmpty else { return }
        for k in keys { memory?[k] = nil }
        save()
    }
}

// MARK: - anvil-prep's report

extension GraphicsPrep {
    /// One line of anvil-prep's output.
    struct Event: Decodable, Hashable {
        var event: String
        var gpu: String?
        var arch: String?
        var ms: Double?
        var pipelines: Int?
        var of: Int?
        var missing: [String]?
        var splitMs: Double?
        var fusedMs: Double?
        var fusedOk: Bool?
        var maxDiff: Double?
        var meanDiff: Double?
        var pixelsApart: Int?
        var pass: String?
        var tested: Bool?
        var why: String?
        var tile: String?
        var frameGeneration: Int?
        var frameGenerationOf: Int?
        var ready: Int?
        var made: Int?
        var compileMs: Double?
        var pipelinesMs: Double?
        var fsr3: Bool?
        var fsr3Why: String?
        var fsr3Native: Bool?
        var fsr3Ms: Double?
        var fsr1Ms: Double?
        var fsr3Error: Double?
        var fsr1Error: Double?
        var fsr3Flicker: Double?
        var fsr1Flicker: Double?
        var fsr3StillError: Double?
        var fsr1StillError: Double?
        var fsr3Trail: Double?
        var smoothMadeError: Double?
        var smoothOlderError: Double?
        var smoothMs: Double?

        /// FSR 3's test, from the event that carries it.
        var fsr3Test: FSR3? {
            guard let better = fsr3 else { return nil }
            return FSR3(better: better, why: fsr3Why, native: fsr3Native ?? false, ms: fsr3Ms ?? 0, fsr1Ms: fsr1Ms ?? 0,
                        error: fsr3Error ?? 0, fsr1Error: fsr1Error ?? 0, flicker: fsr3Flicker ?? 0,
                        fsr1Flicker: fsr1Flicker ?? 0, stillError: fsr3StillError ?? 0,
                        fsr1StillError: fsr1StillError ?? 0, trail: fsr3Trail ?? 1,
                        smoothMadeError: smoothMadeError, smoothOlderError: smoothOlderError, smoothMs: smoothMs)
        }

        nonisolated static func parse(_ line: Substring) -> Event? {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(Event.self, from: Data(line.utf8))
        }
    }

    /// A prep from what anvil-prep said: its "prepare" run, then its "verify" one under the
    /// game's architecture. nil when prepare never reached "done".
    nonisolated static func from(prepare: [Event], verify: [Event], key: Key, gameSize: String, shownSize: String,
                                 estimated: Bool, gameCache: GameCache?, seconds: Double) -> GraphicsPrep? {
        func last(_ name: String, _ events: [Event]) -> Event? { events.last { $0.event == name } }
        let failed = last("failed", prepare)
        guard let done = last("done", prepare) ?? (failed == nil ? nil : Event(event: "done")) else { return nil }
        let archived = last("archived", prepare)
        let timed = last("timed", prepare)
        let verified = last("verified", verify)
        let verifiedAll = verified.map { ($0.ready ?? 0) == ($0.of ?? -1) && ($0.of ?? 0) > 0 } ?? false
        return GraphicsPrep(
            key: key, at: Date(), status: failed == nil ? .ready : .failed, failure: failed?.why,
            gameSize: gameSize, shownSize: shownSize, estimated: estimated,
            gpu: last("device", prepare)?.gpu ?? key.gpu,
            compileMs: Int(last("compiled", prepare)?.ms ?? 0),
            pipelines: archived?.pipelines ?? 0, pipelinesOf: archived?.of ?? 0,
            verifiedReady: verified?.ready, archiveKept: failed == nil && verifiedAll,
            pass: failed == nil ? (done.pass ?? "split") : "split", tile: done.tile,
            splitMs: timed?.splitMs, fusedMs: (timed?.fusedOk ?? false) ? timed?.fusedMs : nil,
            tested: done.tested ?? false, untestedWhy: done.why,
            frameGeneration: done.frameGeneration ?? 0, frameGenerationOf: done.frameGenerationOf ?? 0,
            gameCache: gameCache, seconds: seconds,
            fsr3: failed == nil ? (done.fsr3Test ?? last("fsr3", prepare)?.fsr3Test) : nil)
    }
}

extension GraphicsPrep {
    /// A prep that didn't finish: kept, so the page can say why, and the game starts as before.
    nonisolated static func failed(key: Key, gameSize: String, shownSize: String, estimated: Bool, why: String,
                                   gameCache: GameCache?, seconds: Double) -> GraphicsPrep {
        GraphicsPrep(key: key, at: Date(), status: .failed, failure: why, gameSize: gameSize, shownSize: shownSize,
                     estimated: estimated, gpu: key.gpu, compileMs: 0, pipelines: 0, pipelinesOf: 0, verifiedReady: nil,
                     archiveKept: false, pass: "split", tile: nil, splitMs: nil, fusedMs: nil, tested: false,
                     untestedWhy: nil, frameGeneration: 0, frameGenerationOf: 0, gameCache: gameCache, seconds: seconds)
    }
}

// MARK: - In words

extension GraphicsPrep {
    nonisolated static func ms(_ value: Double) -> String { String(format: "%.2f ms", value) }

    /// A Metal pixel format as a player would say it.
    nonisolated static func formatName(_ format: Int) -> String {
        switch format {
        case 70: return "8-bit RGBA"
        case 71: return "8-bit RGBA (sRGB)"
        case 80: return "8-bit BGRA"
        case 81: return "8-bit BGRA (sRGB)"
        case 90: return "10-bit RGB"
        case 94: return "10-bit BGR"
        case 115: return "16-bit float"
        default: return "pixel format \(format)"
        }
    }

    /// FSR's part: which way, and what it costs a frame.
    var fsrText: String {
        guard status == .ready else { return "Two passes, as before" }
        guard tested, let split = splitMs else { return "Two passes" + (untestedWhy.map { " — not timed: \($0)" } ?? "") }
        if onePass, let fused = fusedMs {
            return "One pass, \(Self.ms(fused)) a frame — \(Int(((1 - fused / split) * 100).rounded()))% less than two (\(Self.ms(split)))"
        }
        if onePassOff, let fused = fusedMs {
            return "Two passes, \(Self.ms(split)) a frame — one pass (\(Self.ms(fused))) off after the game closed unexpectedly with it"
        }
        if let fused = fusedMs { return "Two passes, \(Self.ms(split)) a frame — quicker here than one (\(Self.ms(fused)))" }
        return "Two passes, \(Self.ms(split)) a frame"
    }

    /// How much closer, as a percentage of FSR 1's figure: "16% closer".
    nonisolated static func percent(_ value: Double, against base: Double) -> Int {
        base > 0 ? Int(((1 - value / base) * 100).rounded()) : 0
    }

    /// FSR 3's part: what its test found, and what it costs a frame.
    var fsr3Text: String? {
        guard status == .ready, let t = fsr3 else { return nil }
        return t.text(off: fsr3Off == true)
    }

    var pipelinesText: String {
        guard status == .ready else { return "Compiled in the game, as before" }
        if archiveKept, let ready = verifiedReady {
            return "\(ready) of \(pipelinesOf) ready-made for the \(gpu)"
        }
        return "\(pipelines) of \(pipelinesOf) compiled, but the game's side couldn't use them — compiled in the game, as before"
    }

    var gameCacheText: String? { gameCache.map(GameCache.text) }

    var seenText: String? {
        guard let seen else { return nil }
        var parts: [String] = []
        if let r = seen.readyMade, let of = seen.of { parts.append("\(r) of \(of) pipelines came ready-made") }
        if let w = seen.firstFrameWaitMs { parts.append(w == 0 ? "the first frame didn't wait for Anvil's shaders" : "the first frame waited \(w) ms for Anvil's shaders") }
        if seen.onePass { parts.append("FSR ran in one pass") }
        if let n = seen.fsr3Frames, n > 0 { parts.append("FSR 3 on \(n.formatted()) frames") }
        if let why = seen.fsr3Stopped { parts.append("FSR 3 stopped: \(why)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// For the launch log.
    var summary: String {
        if status == .failed { return "didn't finish — \(failure ?? "no reason given"); the game starts as before" }
        var parts = ["\(pipelinesText.prefix(1).lowercased())\(pipelinesText.dropFirst())", "FSR: \(fsrText.prefix(1).lowercased())\(fsrText.dropFirst())"]
        if frameGenerationOf > 0 { parts.append("frame generation's \(frameGeneration) of \(frameGenerationOf) compiled") }
        if let f3 = fsr3Text { parts.append("FSR 3: \(f3.prefix(1).lowercased())\(f3.dropFirst())") }
        parts.append("at \(gameSize) → \(shownSize) in \(Self.formatName(key.pixelFormat))\(estimated ? " (the display's, until a session shows the game's own)" : "")")
        return parts.joined(separator: "; ")
    }
}

// MARK: - What a session showed

extension GraphicsPrep {
    /// libanvil's lines about its shaders, from a session's game.log.
    nonisolated static func seen(in lines: [Substring], at date: Date) -> Seen? {
        var seen = Seen(at: date, readyMade: nil, of: nil, firstFrameWaitMs: nil, onePass: false)
        var fsr3Frames = 0
        var any = false
        for line in lines {
            guard let at = line.range(of: "[anvil] ") else { continue }
            let text = line[at.upperBound...]
            if text.hasPrefix("shaders: "), let r = text.range(of: " pipelines ready-made from Graphics Prep") {
                let counts = text[text.index(text.startIndex, offsetBy: 9)..<r.lowerBound].components(separatedBy: " of ")
                if counts.count == 2, let a = Int(counts[0]), let b = Int(counts[1]) { seen.readyMade = a; seen.of = b; any = true }
            } else if text.hasPrefix("shaders: compiled in the background"), let w = text.range(of: "the first frame waited ") {
                seen.firstFrameWaitMs = Int(text[w.upperBound...].prefix { $0.isNumber })
                any = true
            } else if text.hasPrefix("FSR: one pass") {
                seen.onePass = true
                any = true
            } else if text.hasPrefix("FSR 3: off for this session — ") {
                let why = text.dropFirst("FSR 3: off for this session — ".count)
                seen.fsr3Stopped = String(why.split(separator: ";").first ?? why)
                any = true
            }
            // "| FSR 3 on N" — frames through FSR 3 since the stats line before.
            if let r = line.range(of: "| FSR 3 on "), let n = Int(line[r.upperBound...].prefix { $0.isNumber }) {
                fsr3Frames += n
                any = true
            }
        }
        if fsr3Frames > 0 { seen.fsr3Frames = fsr3Frames }
        return any ? seen : nil
    }

    /// After a session: what it showed, kept with the game's prep.
    nonisolated static func confirm(gameID: UUID, evidence: SessionEvidence) {
        guard let seen = seen(in: evidence.gameLines, at: evidence.startedAt ?? Date()) else { return }
        update(gameID: gameID) { $0.seen = seen }
    }

    /// The game closed unexpectedly with FSR in one pass: two from its next start.
    /// Undone, for a game it was turned off for by mistake.
    nonisolated static func onePassBackOn(gameID: UUID) {
        update(gameID: gameID) { $0.onePassOff = false }
    }

    nonisolated static func onePassOffAfterCrash(gameID: UUID) {
        update(gameID: gameID) { $0.onePassOff = true }
    }

    /// The game closed unexpectedly with FSR 3 on: FSR 1 from its next start, until a prep for
    /// different shaders, macOS or GPU tests it again.
    nonisolated static func fsr3OffAfterCrash(gameID: UUID) {
        update(gameID: gameID) { $0.fsr3Off = true }
    }

    /// FSR 3 back for the game: the crash it was switched off for turned out not to be its (Housekeeping, 0.58).
    nonisolated static func fsr3BackOn(gameID: UUID) {
        update(gameID: gameID) { $0.fsr3Off = nil }
    }
}

extension Notification.Name {
    static let graphicsPrepChanged = Notification.Name("AnvilGraphicsPrepChanged")
}
