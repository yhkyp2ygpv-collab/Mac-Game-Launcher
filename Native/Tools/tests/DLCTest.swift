// DLC the account owns, found and downloadable (0.61): on copies of Anvil's real Epic records — no sign-in among them,
// an empty stand-in where Anvil keeps it sealed — LEGO Star Wars' fourteen DLC on the store, one of them (Classic
// Obi-Wan) the account's; and Steam's own files for a Steam setup, read where they are.
//
//   CFFIXED_USER_HOME=$T/home HOME=$T/home DLCTest <Anvil's Epic folder> <LEGO's .exe> <Steam container folder>
import Foundation

@main
struct DLCTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    @MainActor
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 4 else { print("usage: see header"); exit(2) }
        let fm = FileManager.default
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "/"
        guard !EpicAccount.configDir.path.hasPrefix(realHome + "/Library") else { print("refusing: not in a throwaway home"); exit(2) }
        let real = URL(fileURLWithPath: a[1], isDirectory: true), lego = a[2]
        let epicDir = EpicAccount.configDir
        try? fm.createDirectory(at: epicDir, withIntermediateDirectories: true)
        for name in ["installed.json", "assets.json", "entitlements.json", "metadata"] {
            try? fm.copyItem(at: real.appendingPathComponent(name), to: epicDir.appendingPathComponent(name))
        }
        // As before the download of 21 October (11:04): Classic Obi-Wan not installed yet.
        let installedCopy = epicDir.appendingPathComponent("installed.json")
        if var records = (try? JSONSerialization.jsonObject(with: Data(contentsOf: installedCopy))) as? [String: Any] {
            records["7b40d89dd2cb4f439e00d4ab81188f3b"] = nil
            try? JSONSerialization.data(withJSONObject: records).write(to: installedCopy)
        }
        try? Data().write(to: epicDir.appendingPathComponent("user.json.sealed"))
        check(EpicAccount.isSignedIn, "an empty stand-in where Anvil keeps the sealed sign-in")
        let game = Game(title: "LEGO® Star Wars™: The Skywalker Saga", executablePath: lego, containerID: UUID())

        print("— LEGO Star Wars' DLC on Epic")
        guard let link = EpicLink.find(for: game) else { check(false, "LEGO found in Anvil's Epic records"); exit(1) }
        check(link.launcher == "Anvil", "installed through Anvil's own Epic connection")
        check(link.dlc.count == 14, "the store's \(link.dlc.count) DLC listed")
        check(link.ownedDLC.map(\.title) == ["LEGO® Star Wars™: Classic Obi-Wan"], "yours: \(link.ownedDLC.map(\.title))")
        check(link.dlcToDownload.first?.appName == "7b40d89dd2cb4f439e00d4ab81188f3b" && link.dlcToDownload.count == 1,
              "and not downloaded: Classic Obi-Wan, app \(link.dlcToDownload.first?.appName ?? "-")")
        check(link.dlc.first?.title == "LEGO® Star Wars™: Classic Obi-Wan", "listed first, before what isn't yours")
        check(link.dlc.filter { !$0.owned }.count == 13 && link.dlc.allSatisfy { $0.appName != nil }, "the other 13 not on the account, each with an app of its own")

        print("— how it's downloaded")
        let dir = URL(fileURLWithPath: "/tmp/Games")
        check(EpicLibrary.installArguments(appName: "c390e58246ea4a778acd26473a489b48", into: dir, withDLC: true).contains("--with-dlcs"),
              "a game's install brings its DLC (--with-dlcs)")
        let dlcArgs = EpicLibrary.installArguments(appName: "7b40d89dd2cb4f439e00d4ab81188f3b", into: dir, withDLC: false)
        check(dlcArgs.prefix(2) == ["install", "7b40d89dd2cb4f439e00d4ab81188f3b"] && dlcArgs.contains("--yes") && !dlcArgs.contains("--with-dlcs"),
              "a DLC's: legendary install <its app> — \(dlcArgs.joined(separator: " "))")

        print("— once installed")
        let installedURL = epicDir.appendingPathComponent("installed.json")
        var installed = (try? JSONSerialization.jsonObject(with: Data(contentsOf: installedURL))) as? [String: Any] ?? [:]
        let base = installed["c390e58246ea4a778acd26473a489b48"] as? [String: Any] ?? [:]
        installed["7b40d89dd2cb4f439e00d4ab81188f3b"] = ["app_name": "7b40d89dd2cb4f439e00d4ab81188f3b", "title": "LEGO® Star Wars™: Classic Obi-Wan",
                                                       "is_dlc": true, "install_path": base["install_path"] ?? "", "executable": "", "version": "1.0.0.3"]
        try? JSONSerialization.data(withJSONObject: installed).write(to: installedURL)
        let after = EpicLink.find(for: game)
        check(after?.dlc.first { $0.appName == "7b40d89dd2cb4f439e00d4ab81188f3b" }?.installed == true && after?.dlcToDownload.isEmpty == true,
              "Classic Obi-Wan installed, nothing left to download")
        check(EpicLibrary.installedApps().contains("7b40d89dd2cb4f439e00d4ab81188f3b") && !EpicLibrary.installed().contains { $0.appName == "7b40d89dd2cb4f439e00d4ab81188f3b" },
              "recorded beside the game, and not taken for a game of its own")

        print("— owned with nothing to download")
        let entsURL = epicDir.appendingPathComponent("entitlements.json")
        var ents = (try? JSONSerialization.jsonObject(with: Data(contentsOf: entsURL))) as? [[String: Any]] ?? []
        ents.append(["catalogItemId": "03104423f03b4cdca1899ae890ae1559", "namespace": "9c59efaabb6a48f19b3485d5d9416032", "entitlementType": "EXECUTABLE"])
        try? JSONSerialization.data(withJSONObject: ents).write(to: entsURL)
        let trooper = EpicLink.find(for: game)?.dlc.first { $0.id == "03104423f03b4cdca1899ae890ae1559" }
        check(trooper?.owned == true && trooper?.downloadable == false && trooper?.toDownload == false,
              "an entitlement without a download (stand-in for the Trooper Pack): yours, unlocked in the game, nothing to download")

        print("— Steam")
        let steamC = URL(fileURLWithPath: a[3], isDirectory: true)
        var c = Container(name: "Steam", runtimeID: "none")
        c.id = UUID(uuidString: steamC.lastPathComponent) ?? UUID()
        try? fm.createDirectory(at: RuntimeManager.containersDir, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: c.prefixURL, withDestinationURL: steamC)
        let steamDir = SteamSupport.steamDir(in: c)
        let owned = SteamLibrary.owned(in: steamDir)
        check(!owned.isEmpty, "the account's Steam games read (\(owned.count))")
        var withDLC = 0, total = 0
        let started = Date()
        for t in owned {
            let list = SteamLibrary.dlc(of: t.appID, in: c)
            if !list.isEmpty { withDLC += 1; total += list.count; print("     \(t.name): " + list.map { "\($0.name)\($0.hasFiles ? "" : " (unlock only)")" }.joined(separator: ", ")) }
        }
        check(Date().timeIntervalSince(started) < 30, String(format: "DLC of yours for %d of them (%d in all), read in %.1f s", withDLC, total, Date().timeIntervalSince(started)))
        check(SteamLibrary.dlc(of: "not-an-app", in: c).isEmpty, "a bad app id: none")

        print(failures == 0 ? "dlc: all checks passed" : "dlc: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
