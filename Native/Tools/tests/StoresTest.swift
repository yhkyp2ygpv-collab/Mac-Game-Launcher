import Foundation
import AppKit
import Metal

/// Steam, Epic, anti-cheat, the device profile and the public edition's self-check, in a
/// throwaway home (CFFIXED_USER_HOME). Build with Sources/Anvil/Core/*.swift.
@main struct StoresHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/stores/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default
        func write(_ text: String, _ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: url)
        }
        func exe(_ url: URL, bytes: Int) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(repeating: 0x4D, count: bytes).write(to: url)
        }

        // MARK: Steam
        let lib = Library.shared
        var c = Container(name: "Steam", runtimeID: "none")
        c.storefront = "steam"
        lib.containers.append(c)
        let steam = SteamSupport.steamDir(in: c)
        exe(SteamSupport.steamExe(in: c), bytes: 1000)
        let apps = steam.appendingPathComponent("steamapps")
        // A second library on D:, as Steam writes it: escaped backslashes.
        let dDrive = RuntimeManager.support.appendingPathComponent("ExternalDrive")
        try? fm.createDirectory(at: c.prefixURL.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: c.prefixURL.appendingPathComponent("dosdevices/d:"), withDestinationURL: dDrive)
        write("""
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t\t"apps" { "620" "12000" }
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"D:\\\\SteamLibrary"
        \t}
        }
        """, apps.appendingPathComponent("libraryfolders.vdf"))
        write("""
        "AppState"
        {
        \t"appid"\t\t"620"
        \t"name"\t\t"Portal 2"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"Portal 2"
        \t"SizeOnDisk"\t\t"12884901888"
        }
        """, apps.appendingPathComponent("appmanifest_620.acf"))
        exe(apps.appendingPathComponent("common/Portal 2/portal2.exe"), bytes: 400_000)
        exe(apps.appendingPathComponent("common/Portal 2/bin/vcredist_x64.exe"), bytes: 900_000)
        write("""
        "AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "StateFlags" "4" "installdir" "Steamworks Shared" }
        """, apps.appendingPathComponent("appmanifest_228980.acf"))
        let dApps = dDrive.appendingPathComponent("SteamLibrary/steamapps")
        write("""
        "AppState" { "appid" "1172470" "name" "Apex Legends" "StateFlags" "4" "installdir" "Apex Legends" }
        """, dApps.appendingPathComponent("appmanifest_1172470.acf"))
        exe(dApps.appendingPathComponent("common/Apex Legends/r5apex.exe"), bytes: 500_000)
        exe(dApps.appendingPathComponent("common/Apex Legends/EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe"), bytes: 100)
        write("""
        "AppState" { "appid" "570" "name" "Dota 2" "StateFlags" "1026" "installdir" "dota 2 beta" }
        """, dApps.appendingPathComponent("appmanifest_570.acf"))
        exe(dApps.appendingPathComponent("common/dota 2 beta/game/bin/win64/dota2.exe"), bytes: 300_000)
        exe(steam.appendingPathComponent("appcache/librarycache/620/abc123/library_600x900.jpg"), bytes: 10)

        let folders = SteamSupport.libraryFolders(in: c)
        print("library folders:", folders.map { $0.path.replacingOccurrences(of: RuntimeManager.support.path, with: "…") })
        check(folders.count == 2, "both Steam libraries found, C: and D:")
        let installed = SteamSupport.installedGames(in: c)
        print("installed:", installed.map { "\($0.name) [\($0.appID)] ready=\($0.ready)" })
        check(installed.map(\.appID) == ["1172470", "570", "620"], "games found, Steam's redistributables left out")
        check(installed.first { $0.appID == "570" }?.ready == false, "a game mid-update is not ready")
        check(installed.first { $0.appID == "620" }?.sizeOnDisk == 12_884_901_888, "size read")
        check(SteamSupport.cachedArtwork(appID: "620", in: c) != nil, "Steam's own cover found in its library cache")

        let added = SteamSupport.shared.importGames()
        print("added:", added, "—", SteamSupport.shared.lastFound ?? "")
        check(Set(added) == ["Portal 2", "Apex Legends"], "ready games added to the library")
        let portal = lib.games.first { $0.steamAppID == "620" }
        check(portal?.executableURL.lastPathComponent == "portal2.exe", "the game's own exe, not the redistributable")
        check(portal?.containerID == c.id, "in Steam's container")
        check(SteamSupport.shared.lastFound?.contains("Dota 2") == true, "the one still updating is named")
        check(SteamSupport.shared.importGames().isEmpty, "a second search adds nothing twice")

        // reg query output, as Wine prints it.
        check(SteamSupport.activeUser(in: "\nHKEY_CURRENT_USER\\Software\\Valve\\Steam\\ActiveProcess\n    ActiveUser    REG_DWORD    0x1a2b3c4d\n") == 0x1a2b3c4d, "signed-in user read from the registry")
        check(SteamSupport.activeUser(in: "    ActiveUser    REG_DWORD    0x0\n") == 0, "signed out reads as 0")
        check(SteamSupport.activeUser(in: "ERROR: The system was unable to find the specified registry key or value.") == 0, "missing key reads as 0")
        check(SteamSupport.isWebHelperCrash("[0930/111034.241:ERROR:crashpad_client_win.cc(144)] crash server failed to launch, self-terminating"), "the web helper crash from 30 Sep is recognised")

        // The installer check.
        let fake = RuntimeManager.support.appendingPathComponent("SteamSetup.exe")
        try! Data("<html>captive portal</html>".utf8).write(to: fake)
        check(!SteamSupport.looksLikeInstaller(fake), "a web page saved as the installer is refused")
        var pe = Data("MZ".utf8); pe.append(Data(count: 2_000_000))
        try! pe.write(to: fake)
        check(SteamSupport.looksLikeInstaller(fake), "a Windows program of the right size is accepted")

        // The safer web view, switched on once.
        check(SteamSupport.shared.useSafeWebView(in: c), "safe web view switched on")
        let client = SteamSupport.shared.clientGame(in: c)
        print("Steam starts with:", SteamSupport.shared.clientArguments(in: c))
        check(client?.arguments.contains("-no-cef-sandbox") == true && client?.arguments.contains("-cef-disable-gpu") == true, "Steam's arguments carry both")
        check(!SteamSupport.shared.useSafeWebView(in: c), "and not twice")

        // MARK: Anti-cheat
        let apex = lib.games.first { $0.steamAppID == "1172470" }!
        let ac = AntiCheat.detect(for: apex)
        check(ac == [.easyAntiCheat], "Easy Anti-Cheat found in Apex's folder")
        let val = RuntimeManager.support.appendingPathComponent("Valorant/live")
        exe(val.appendingPathComponent("ShooterGame/Binaries/Win64/VALORANT-Win64-Shipping.exe"), bytes: 10)
        exe(RuntimeManager.support.appendingPathComponent("Valorant/Riot Vanguard/vgc.exe"), bytes: 10)
        let v = AntiCheat.detect(in: RuntimeManager.support.appendingPathComponent("Valorant"))
        check(v == [.vanguard], "Vanguard found")
        print("note:", AntiCheat.note(for: v) ?? "-")
        check(AntiCheat.note(for: v)?.contains("can't work on a Mac") == true, "kernel anti-cheat is called out as impossible")
        check(AntiCheat.detect(for: portal!).isEmpty, "a game without anti-cheat has none")

        // MARK: Epic
        let list = """
        [info] something legendary logs first
        [{"app_name": "Fortnite", "app_title": "Fortnite", "metadata": {"keyImages": [{"type": "Thumbnail", "url": "https://x/t.jpg"}, {"type": "DieselGameBoxTall", "url": "https://x/tall.jpg"}]}},
         {"app_name": "9d2d0eb64d5c44529cece33fe2a46482", "app_title": "Grand Theft Auto V", "metadata": {}}]
        """
        let owned = EpicLibrary.parseOwned(EpicLibrary.jsonPart(of: list)!)
        print("owned:", owned.map { "\($0.title) cover=\($0.cover?.lastPathComponent ?? "-")" })
        check(owned.count == 2 && owned[0].title == "Fortnite" && owned[0].cover?.lastPathComponent == "tall.jpg", "Epic's game list parsed, tall cover chosen")
        check(EpicLibrary.progressFraction(in: "[DLManager] INFO: = Progress: 42.17% (1022/2424), Running for 00:01:10, ETA: 00:01:36") == 0.4217, "install progress read")
        check(EpicLibrary.progressFraction(in: "[cli] INFO: Install size: 12.3 GiB") == nil, "other lines ignored")
        let gamesDir = RuntimeManager.support.appendingPathComponent("EpicGames/Celeste")
        exe(gamesDir.appendingPathComponent("Celeste.exe"), bytes: 2000)
        write(#"{"Salt": {"title": "Celeste", "install_path": "\#(gamesDir.path)", "executable": "Celeste.exe", "app_name": "Salt"}}"#,
              EpicAccount.configDir.appendingPathComponent("installed.json"))
        check(EpicLibrary.installed().first?.executable.lastPathComponent == "Celeste.exe", "Anvil's own Epic installs read")
        var epicC = Container(name: "Epic Games", runtimeID: "none")
        epicC.storefront = "epic"
        lib.containers.append(epicC)
        let epicAdded = await EpicLibrary.shared.importInstalled()
        check(epicAdded == ["Celeste"] && lib.games.first { $0.epicAppName == "Salt" }?.containerID == epicC.id, "installed Epic game added to the Epic container")
        check(await EpicLibrary.shared.importInstalled().isEmpty, "and only once")

        // MARK: Device
        let device = await DeviceProfile.measure()
        print("device:", device.summary, String(format: "— %.0f GFLOPS, %@, start at %@", device.gpuGFLOPS, device.tier.title, device.startingLevel.title))
        if MTLCreateSystemDefaultDevice() == nil {
            print("skipped: no Metal device in this sandbox — the GPU test runs in the app; the tier came from the core count")
            check(device.tier == .base && device.gpuGFLOPS == 0, "without a measurement the 10-core GPU still reads as standard graphics")
        } else {
            check(device.gpuGFLOPS > 500, "the GPU test ran and measured something believable")
        }
        check(DeviceProfile.tier(gpuCores: 10, gflops: 0) == .base && DeviceProfile.tier(gpuCores: 40, gflops: 0) == .max
              && DeviceProfile.tier(gpuCores: 8, gflops: 0) == .entry && DeviceProfile.tier(gpuCores: 80, gflops: 0) == .ultra, "tiers by core count")
        device.save()
        check(DeviceProfile.current == device, "kept")
        let reread = DeviceProfile.load()
        check(reread?.chip == device.chip && reread?.tier == device.tier && reread?.gpuCores == device.gpuCores, "and read back from disk after a restart")
        check(Tuner.shared.graphicsLevel(for: portal!) == device.startingLevel, "an unmeasured game starts where the Mac's profile says")

        // MARK: Self-check
        let bundle = RuntimeManager.support.appendingPathComponent("Test.app")
        try? fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try? fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bundle.appendingPathComponent("Contents/MacOS/Test"))
        write("""
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>dev.anvil.launcher</string><key>CFBundleExecutable</key><string>Test</string>
        <key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """, bundle.appendingPathComponent("Contents/Info.plist"))
        write("shader", bundle.appendingPathComponent("Contents/Resources/AnvilShaders.metallib"))
        func sign() {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--force", "--sign", "-", "--identifier", "dev.anvil.launcher", bundle.path]
            p.standardError = FileHandle.nullDevice; try! p.run(); p.waitUntilExit()
        }
        sign()
        check(AppProtection.verify(bundle: bundle) == nil, "an untouched copy passes")
        write("changed", bundle.appendingPathComponent("Contents/Resources/AnvilShaders.metallib"))
        check(AppProtection.verify(bundle: bundle) != nil, "an edited file is caught")
        sign()
        write("extra", bundle.appendingPathComponent("Contents/Resources/added.dylib"))
        check(AppProtection.verify(bundle: bundle) != nil, "an added file is caught")
        try? fm.removeItem(at: bundle.appendingPathComponent("Contents/Resources/added.dylib"))
        sign()
        try? fm.removeItem(at: bundle.appendingPathComponent("Contents/Resources/AnvilShaders.metallib"))
        check(AppProtection.verify(bundle: bundle) != nil, "a removed file is caught")
        write("shader", bundle.appendingPathComponent("Contents/Resources/AnvilShaders.metallib"))
        sign()
        check(AppProtection.verify(bundle: bundle) == nil, "a fresh copy passes again — nothing was broken for good")

        // 0.34.2: ⌘ is Ctrl where a store's app is installed, so ⌘V pastes into its sign-in.
        let plainGame = Container(name: "Plain", runtimeID: "none")
        try? fm.createDirectory(at: plainGame.driveC, withIntermediateDirectories: true)
        check(!plainGame.holdsStoreApp && !plainGame.commandKeysAreCtrl, "a game's container: ⌘ stays ⌘")
        var steamBox = Container(name: "Steam Keys", runtimeID: "none")
        write("exe", steamBox.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe"))
        check(steamBox.holdsStoreApp && steamBox.commandKeysAreCtrl, "Steam's container: ⌘ is Ctrl")
        check(Prefix.inputSettings(steamBox).contains { $0.name == "LeftCommandIsCtrl" && $0.value == "y" }, "…and that's what Wine is given")
        steamBox.commandIsCtrl = false
        check(!steamBox.commandKeysAreCtrl, "turned off by hand, it stays off")
        let epicBox = Container(name: "Epic Keys", runtimeID: "none")
        write("exe", epicBox.driveC.appendingPathComponent("Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"))
        check(epicBox.commandKeysAreCtrl, "Epic's launcher's container: ⌘ is Ctrl")

        print(failures == 0 ? "stores: all checks passed" : "\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
