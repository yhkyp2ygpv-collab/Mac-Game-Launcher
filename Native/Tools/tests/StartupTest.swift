import Foundation

/// Anvil's first start after an update, step by step as RootView runs it, in a throwaway
/// home seeded with copies of the real library, logs, Auto-Tune results and engines.
/// Prints how long each step takes and what it logged.
@main struct StartupHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/startup/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        let logStart = (try? Data(contentsOf: AnvilLog.url))?.count ?? 0
        func step(_ name: String, _ work: () async -> Void) async {
            let t = Date()
            await work()
            print(String(format: "%-34@ %6.0f ms", name as NSString, Date().timeIntervalSince(t) * 1000))
        }
        print("library:", Library.shared.games.map(\.title), "containers:", Library.shared.containers.map { "\($0.name) [\($0.runtimeID)]" })
        print("engines:", RuntimeManager.shared.runtimes.map { "\($0.id) managed=\($0.isManaged)" })
        await step("tidy empty store containers") { Library.shared.tidyEmptyStoreContainers() }
        print("containers now:", Library.shared.containers.map(\.name))
        await step("protection key") { _ = ProtectionKey.current }
        await step("display") { DisplayProfile.start() }
        await step("own engines in use") { await RuntimeManager.shared.ownEnginesInUse(by: Library.shared.containers) }
        await step("engine seals (first: seal all)") { await RuntimeManager.shared.checkSeals() }
        await step("engine seals (again)") { await RuntimeManager.shared.checkSeals() }
        await step("Epic sign-in leftover") { EpicVault.sealLeftover() }
        await step("Epic prepare (offline here)") { await EpicAccount.shared.prepare() }
        await step("Steam games") { SteamSupport.shared.importGames() }
        // The startup, the setup and the Epic page all at once, as on 1 October.
        await step("Epic games (three callers at once)") {
            async let a = EpicLibrary.shared.importInstalled()
            async let b = EpicLibrary.shared.importInstalled()
            async let c = EpicLibrary.shared.importInstalled()
            _ = await (a, b, c)
        }
        print("Epic containers after:", Library.shared.containers.filter { $0.storefront == "epic" }.count)
        await step("Autopilot at launch") { await Autopilot.shared.atLaunch() }
        // What a launch checks before Wine runs.
        if let lego = Library.shared.games.first(where: { $0.title.contains("LEGO") }),
           let c = Library.shared.container(id: lego.containerID),
           let r = RuntimeManager.shared.runtime(id: c.runtimeID) {
            await step("seal check before LEGO launch") {
                _ = await Task.detached { EngineSeal.check(root: r.root, id: r.id, full: false) }.value
            }
            print("LEGO: engine \(r.id), Auto-Tune level \(Tuner.shared.graphicsLevel(for: lego).title), autopilot \(lego.autopilot)")
        }
        print("seal problems:", RuntimeManager.shared.sealProblems)
        print("banner:", Autopilot.shared.banner.map { "\($0)" } ?? "none")
        let log = (try? Data(contentsOf: AnvilLog.url)) ?? Data()
        print("--- logged during startup ---")
        print(String(decoding: log.dropFirst(logStart), as: UTF8.self))
        exit(0)
    }
}
