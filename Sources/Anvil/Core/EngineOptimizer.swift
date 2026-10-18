import Foundation

/// Every engine Anvil keeps, made ready for this Mac by itself — when it is installed or
/// updated, and at a start for any engine that isn't ready yet. Nothing here needs a
/// connection, so it happens offline too.
///
/// For each engine:
/// 1. its profile is read (EngineProfile): what kind of engine it is and how Anvil runs
///    games on it;
/// 2. it is sealed (EngineSeal), so a changed file is caught before a game runs on it;
/// 3. Anvil's Game Mode copy of it is built;
/// 4. it is run once, through that copy, into a throwaway Windows setup that is deleted
///    straight after. Apple's Rosetta translates an Intel program the first time it runs and
///    keeps the translation, so this moves that work — seconds of a game's first launch —
///    to a moment nobody is waiting. It also shows the engine actually starts on this Mac
///    before any game is trusted to it: an engine that doesn't is not offered by Autopilot.
///
/// It runs in the background at low priority, one engine at a time, and never while a
/// game is running: a game started meanwhile stops it, and it carries on at the next start.
@MainActor
final class EngineOptimizer: ObservableObject {
    static let shared = EngineOptimizer()

    struct Record: Codable, Hashable {
        var runtimeID: String
        /// The engine as it was prepared: a new version or a repaired copy is prepared again.
        var fingerprint: String
        var preparedAt: Date
        var profile: EngineProfile
        /// How long the first run took — Rosetta's translation, done ahead of time.
        var warmUpSeconds: Double?
        /// The engine ran here: it made its Windows setup, or finished its first run cleanly.
        var starts: Bool
        var steps: [String]
        /// How the verdict was reached. 2 (0.21.1): after Wine has finished writing, and only
        /// a certain failure counts. Records without it came from 0.20–0.21's check, which
        /// looked before Wine had written anything and read every engine — Engine 3.0, which
        /// had just run LEGO at 120 fps, included — as not starting. They are done again.
        var check: Int?
        /// Why the engine can't be used here, when that is certain: it couldn't be run at
        /// all, or it failed straight away without making a Windows setup.
        var failure: String?
    }

    static let checkVersion = 2

    @Published private(set) var working: String?
    @Published private(set) var records: [String: Record] = [:]
    private var warmUp: Process?
    /// The running warm-up was ended for a game.
    private var yielded = false

    private init() { load() }

    nonisolated static var dir: URL { RuntimeManager.support.appendingPathComponent("EngineOptimizer", isDirectory: true) }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let r = try? decoder.decode(Record.self, from: data) else { continue }
            // A verdict from the old check isn't kept: the engine is prepared again.
            guard (r.check ?? 0) >= Self.checkVersion else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            records[r.runtimeID] = r
        }
    }

    private func save(_ record: Record) {
        records[record.runtimeID] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(record) else { return }
        let url = Self.dir.appendingPathComponent(record.runtimeID + ".json")
        if (try? data.write(to: url, options: .atomic)) == nil { try? data.write(to: url) }
    }

    /// What identifies this build of an engine: its loader and ntdll, by size and date.
    nonisolated static func fingerprint(_ runtime: Runtime) -> String {
        ["bin/wine", "bin/wine64", "lib/wine/x86_64-unix/ntdll.so"].map { rel -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: runtime.root.appendingPathComponent(rel).path)
            let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
            let date = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(rel):\(size):\(Int(date))"
        }.joined(separator: "|") + "|\(runtime.d3dMetalVersion ?? "-")"
    }

    func isPrepared(_ runtime: Runtime) -> Bool {
        records[runtime.id]?.fingerprint == Self.fingerprint(runtime)
    }

    /// Whether Autopilot may put a game on this engine: not when its first run failed for
    /// certain. Anything less certain is left to the game itself, whose engine trial goes
    /// back by itself if it doesn't start.
    func mayOffer(_ runtime: Runtime) -> Bool {
        guard let r = records[runtime.id], r.fingerprint == Self.fingerprint(runtime) else { return true }
        return r.failure == nil
    }

    /// Engines of Anvil's own that aren't prepared yet, newest D3DMetal first.
    private var pending: [Runtime] {
        RuntimeManager.shared.runtimes
            .filter { $0.isManaged && $0.isUsable && !isPrepared($0) }
            .sorted { $1.d3dMetalRank.lexicographicallyPrecedes($0.d3dMetalRank) }
    }

    private var scheduled: Task<Void, Never>?

    /// Prepare what isn't ready once Anvil is idle — nothing running, nothing starting,
    /// no engine being switched: a little after a start, and after the last game closes.
    /// While anything is busy it looks again later, so a warm-up stopped for a game always
    /// carries on. On 1 October the warm-up at a start was stopped by LEGO two seconds in
    /// and never carried on, so no engine was prepared.
    func prepareWhenIdle(after delay: Duration = .seconds(45)) {
        guard !pending.isEmpty else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard Launcher.shared.isIdle, Autopilot.shared.engineWork.isEmpty, self.working == nil else {
                self.scheduled = nil
                self.prepareWhenIdle(after: .seconds(120))
                return
            }
            self.scheduled = nil
            await self.prepareAll()
        }
    }

    /// Every engine of Anvil's own that isn't prepared yet, newest D3DMetal first.
    func prepareAll() async {
        for runtime in pending {
            guard Launcher.shared.isIdle else {
                AnvilLog.write("engines: preparing \(runtime.displayName) waits — a game is running or starting")
                prepareWhenIdle(after: .seconds(120))
                return
            }
            await prepare(runtime)
        }
    }

    func prepare(_ runtime: Runtime) async {
        guard working == nil else { return }
        working = "Preparing \(runtime.displayName) for this Mac…"
        defer { working = nil }
        let clock = ContinuousClock()
        let began = clock.now
        var steps: [String] = []
        let profile = EngineProfile.read(runtime)
        steps.append("read: \(profile.title)")

        // Sealed before anything runs from it.
        let root = runtime.root, id = runtime.id
        if !EngineSeal.isSealed(id) {
            let n = await Task.detached(priority: .utility) { (try? EngineSeal.seal(root: root, id: id)) ?? 0 }.value
            steps.append("sealed \(n) files")
        } else {
            steps.append("seal checked")
        }

        // Anvil's Game Mode copy, which is what games run through.
        let copy = await Task.detached(priority: .utility) { try? GameModeEngine.prepared(for: runtime) }.value
        steps.append(copy != nil ? "Game Mode copy built" : "no Game Mode copy (the engine runs as it is)")

        // One run into a throwaway Windows setup: Rosetta's translations made now, and proof
        // that the engine starts here.
        let engine = copy ?? runtime
        guard let run = await warmUp(engine, profile: EngineProfile.of(engine)) else {
            // Stopped for a game: not recorded, so done again once nothing is running.
            AnvilLog.write("engines: preparing \(runtime.displayName) paused — a game started; it carries on once nothing is running")
            prepareWhenIdle(after: .seconds(120))
            return
        }
        if let failure = run.failure {
            steps.append("didn't start: \(failure)")
        } else if run.starts {
            steps.append(String(format: "first run %.0f s — Rosetta's translations ready", run.seconds))
        } else {
            steps.append(String(format: "first run %.0f s, not confirmed — games on it decide", run.seconds))
        }

        save(Record(runtimeID: runtime.id, fingerprint: Self.fingerprint(runtime), preparedAt: Date(),
                    profile: profile, warmUpSeconds: run.seconds, starts: run.starts, steps: steps,
                    check: Self.checkVersion, failure: run.failure))
        AnvilLog.write("engines: \(runtime.displayName) prepared in \(Launcher.format(clock.now - began)) — " + steps.joined(separator: "; "))
    }

    struct WarmUp {
        var starts: Bool
        var seconds: Double
        var failure: String?
    }

    /// `wineboot --init` into a setup of its own, then that setup removed. Nil when it was
    /// stopped for a game.
    private func warmUp(_ engine: Runtime, profile: EngineProfile) async -> WarmUp? {
        // A game got there first: nothing started, so nothing to clean up.
        guard Launcher.shared.isIdle else { return nil }
        let prefix = RuntimeManager.support.appendingPathComponent("Cache/EngineWarmUp/\(engine.id.replacingOccurrences(of: "/", with: "_"))", isDirectory: true)
        try? FileManager.default.removeItem(at: prefix)
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let loader = engine.wine64.resolvingSymlinksInPath()
        let server = engine.wineserver.resolvingSymlinksInPath()
        let p = Process()
        p.executableURL = loader
        p.arguments = ["wineboot", "--init"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        // Unseen: no Mac display driver (so no window, no Dock icon, no "updating" dialog),
        // no Mono or Gecko prompts, no menu entries.
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml,winemac.drv,winemenubuilder.exe=d"
        if profile.needsLoaderPath { env["WINELOADER"] = loader.path }
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .background
        let started = Date()
        yielded = false
        do { try p.run() } catch {
            try? FileManager.default.removeItem(at: prefix)
            return WarmUp(starts: false, seconds: 0, failure: "couldn't be run (\(error.localizedDescription))")
        }
        warmUp = p
        defer { warmUp = nil }
        var interrupted = false, timedOut = false
        while p.isRunning {
            try? await Task.sleep(for: .milliseconds(500))
            if !Launcher.shared.isIdle {
                p.terminate()
                interrupted = true
            }
            if Date().timeIntervalSince(started) > 240 { p.terminate(); timedOut = true }
        }
        // Ended by a game starting — stopped here, or by the launch itself through
        // yieldToGame, which can end it between two looks. Either way it says nothing about
        // the engine: counted as a failed start, Autopilot would never have offered it.
        if yielded || !Launcher.shared.isIdle { interrupted = true }
        let seconds = Date().timeIntervalSince(started)
        let status = p.terminationStatus, cleanExit = p.terminationReason == .exit && status == 0
        // Wine writes the registry only when its server finishes, a few seconds after the
        // run itself: looked for straight away, it was never there, and every engine read as
        // not starting. So the server is waited for first, and the Windows folder Wine makes
        // during the run counts as well.
        let stopped = interrupted
        let madeSetup = await Task.detached(priority: .background) { () -> Bool in
            if !stopped { Self.waitForServer(server, prefix: prefix, timeout: 20) }
            let fm = FileManager.default
            let made = fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
                || fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32").path)
            // Its wineserver stopped and the setup gone: nothing of it is kept.
            Launcher.killPrefix(wineserver: server, prefix: prefix)
            try? fm.removeItem(at: prefix)
            return made
        }.value
        if interrupted { return nil }
        // Certain only when it made nothing and ended in failure at once.
        let failure: String? = !madeSetup && !cleanExit && !timedOut && seconds < 10
            ? String(format: "Wine ended with %@ %d after %.1f s, before making a Windows setup",
                     p.terminationReason == .exit ? "status" : "signal", status, seconds)
            : nil
        return WarmUp(starts: madeSetup || cleanExit, seconds: seconds, failure: failure)
    }

    /// `wineserver -w`: returns once the server has finished — and written the registry.
    nonisolated private static func waitForServer(_ server: URL, prefix: URL, timeout: TimeInterval) {
        let p = Process()
        p.executableURL = server
        p.arguments = ["-w"]
        p.environment = ["WINEPREFIX": prefix.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate() }
    }

    /// A game is starting: the first run gives way at once.
    func yieldToGame() {
        guard let p = warmUp else { return }
        yielded = true
        p.terminate()
    }
}
