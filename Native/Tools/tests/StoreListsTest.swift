// 0.40.0, in a throwaway home: the Steam account's games read from Steam's own cache files
// (appinfo.vdf v27–v29, packageinfo.vdf, librarycache), Epic's list kept on disk so the page opens
// at once, legendary's download progress, its expired sign-in and account name, and covers kept small.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil -name '*.swift' ! -name AnvilApp.swift) \
//     Native/Tools/tests/StoreListsTest.swift -o $T/StoreListsTest
//   CFFIXED_USER_HOME=<dir>/storelists/home $T/StoreListsTest [real Steam folder in a container]
import AppKit
import Foundation

@main struct StoreListsHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/storelists/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        let fm = FileManager.default

        // 1. Valve's binary files, written as Steam writes them.
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func cstr(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        /// A KV map: keys as text, or as indexes into `table`.
        func kv(_ entries: [(String, Any)], table: inout [String], indexed: Bool) -> Data {
            var d = Data()
            func key(_ k: String) -> Data {
                guard indexed else { return cstr(k) }
                if let i = table.firstIndex(of: k) { return le32(UInt32(i)) }
                table.append(k); return le32(UInt32(table.count - 1))
            }
            for (k, v) in entries {
                if let m = v as? [(String, Any)] { d += Data([0]) + key(k) + kv(m, table: &table, indexed: indexed) }
                else if let s = v as? String { d += Data([1]) + key(k) + cstr(s) }
                else if let i = v as? Int { d += Data([2]) + key(k) + le32(UInt32(bitPattern: Int32(i))) }
            }
            return d + Data([8])
        }
        func appinfo(version: UInt8, apps: [(UInt32, String, String)]) -> Data {
            var table: [String] = []
            var body = Data()
            for (id, name, type) in apps {
                let tree = kv([("appinfo", [("appid", Int(id)), ("common", [("name", name), ("type", type)] as [(String, Any)])] as [(String, Any)])],
                              table: &table, indexed: version >= 0x29)
                let fixed = Data(count: 4 + 4 + 8 + 20 + 4 + (version >= 0x28 ? 20 : 0))
                body += le32(id) + le32(UInt32(fixed.count + tree.count)) + fixed + tree
            }
            body += le32(0)
            var header = le32(0x0756_4400 | UInt32(version)) + le32(1)
            if version >= 0x29 {
                let tableAt = UInt64(header.count + 8 + body.count)
                header += le64(tableAt)
                var strings = le32(UInt32(table.count))
                for s in table { strings += cstr(s) }
                return header + body + strings
            }
            return header + body
        }
        let apps: [(UInt32, String, String)] = [(440, "Team Fortress 2", "Game"), (228980, "Steamworks Common Redistributables", "Tool"),
                                                (620, "Portal 2", "game"), (999, "A Demo", "Demo"), (480, "Spacewar", "Game")]
        for v: UInt8 in [0x27, 0x28, 0x29] {
            let kinds = SteamLibrary.appKinds(appinfo(version: v, apps: apps), only: [440, 228980, 620])
            check(kinds[440]?.name == "Team Fortress 2" && kinds[620]?.type == "game" && kinds[228980]?.type == "Tool" && kinds[999] == nil,
                  String(format: "appinfo.vdf v%x: names and kinds read, apps not asked for skipped", v))
        }
        // packageinfo.vdf v28: package 0 (everyone's) and one bought.
        var none: [String] = []
        var packages = le32(0x0656_5528) + le32(1)
        for (pid, ids) in [(UInt32(0), [440, 480]), (UInt32(12345), [620])] {
            let tree = kv([(String(pid), [("packageid", Int(pid)), ("appids", ids.enumerated().map { (String($0.offset), $0.element as Any) })] as [(String, Any)])],
                          table: &none, indexed: false)
            packages += le32(pid) + Data(count: 20 + 4 + 8) + tree
        }
        packages += le32(0xFFFF_FFFF)
        let pk = SteamLibrary.packageApps(packages)
        check(pk[0] == [440, 480] && pk[12345] == [620], "packageinfo.vdf: each package's apps")

        // 2. A Steam folder laid out as one is: TF2 shown in the library, Portal 2 bought.
        let steam = RuntimeManager.support.appendingPathComponent("Steam", isDirectory: true)
        let cache = steam.appendingPathComponent("appcache", isDirectory: true)
        try? fm.createDirectory(at: cache.appendingPathComponent("librarycache/440/abc123"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: cache.appendingPathComponent("librarycache/228980"), withIntermediateDirectories: true)
        try? Data("jpg".utf8).write(to: cache.appendingPathComponent("librarycache/440/abc123/library_capsule.jpg"))
        try? appinfo(version: 0x29, apps: apps).write(to: cache.appendingPathComponent("appinfo.vdf"))
        try? packages.write(to: cache.appendingPathComponent("packageinfo.vdf"))
        let owned = SteamLibrary.owned(in: steam)
        check(owned.map(\.name) == ["Portal 2", "Team Fortress 2"],
              "the account's games: the one bought and the one its library shows — not Steam's tools, not Spacewar from everyone's package (\(owned.map(\.name)))")
        check(owned.first { $0.appID == "440" }?.localCover?.lastPathComponent == "library_capsule.jpg", "Steam's own cover found one folder down")
        check(owned.first { $0.appID == "620" }?.remoteCover.absoluteString.contains("/620/library_600x900.jpg") == true, "and from Steam's image server otherwise")
        check(SteamLibrary.owned(in: RuntimeManager.support.appendingPathComponent("NoSteam")).isEmpty, "no Steam there: nothing, no fault")

        // 3. The real one, read only.
        if CommandLine.arguments.count > 1 {
            let real = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let began = Date()
            let games = SteamLibrary.owned(in: real)
            print(String(format: "info: this Mac's Steam account — %@ (%.0f ms)", games.map(\.name).joined(separator: ", "), Date().timeIntervalSince(began) * 1000))
            check(games.contains { $0.appID == "440" } && !games.contains { $0.appID == "228980" }, "this Mac's Steam: its games, not its tools")
        }

        // 4. Epic's list from the disk at once.
        let saved = #"{"at":781999200,"titles":[{"appName":"c390e58246ea4a778acd26473a489b48","title":"LEGO® Star Wars™: The Skywalker Saga"},{"appName":"6a2cc8b03e684bbd9096a338f96a7ba2","title":"Cat Quest II","cover":"https:\/\/cdn1.epicgames.com\/x.jpg"}]}"#
        try? fm.createDirectory(at: DiskCache.directory, withIntermediateDirectories: true)
        try? Data(saved.utf8).write(to: EpicLibrary.listCache)
        let epic = EpicLibrary.shared
        check(epic.owned.count == 2 && epic.updatedAt != nil, "Epic's list kept on disk is there the moment the page opens (\(epic.owned.count) games)")
        epic.forgetList()
        check(epic.owned.isEmpty && !fm.fileExists(atPath: EpicLibrary.listCache.path), "another account: the list kept is forgotten")

        // 5. legendary's words.
        let lines = """
        [DLManager] INFO: = Progress: 12.34% (770/6234), Running for 00:00:42, ETA: 00:09:23
        [DLManager] INFO:  - Downloaded: 412.29 MiB, Written: 412.31 MiB
        [DLManager] INFO:  + Download\t- 13.76 MiB/s (raw) / 13.80 MiB/s (decompressed)
        """
        let p = EpicLibrary.progress(in: lines)
        check(abs((p.fraction ?? 0) - 0.1234) < 0.0001 && p.secondsLeft == 563 && abs((p.speed ?? 0) - 13.76) < 0.001,
              "download progress: 12.34%, 9 min 23 s left, 13.76 MiB/s")
        check(EpicStoreView.downloadText(0.1234, .init(fraction: 0.1234, speed: 13.76, secondsLeft: 563)) == "Downloading — 12% · 14.4 MB/s · about 9 min left",
              "said as \(EpicStoreView.downloadText(0.1234, .init(fraction: 0.1234, speed: 13.76, secondsLeft: 563)))")
        check(EpicStoreView.downloadText(0, nil).hasPrefix("Getting ready"), "before the first byte: getting ready, not 0%")
        check(EpicLibrary.signInExpired(#"[cli] ERROR: Login failed, please run "legendary auth""#)
              && EpicLibrary.signInExpired("[Core] ERROR: Invalid refresh token")
              && !EpicLibrary.signInExpired("[cli] ERROR: Connection reset by peer"), "an expired sign-in told from a network fault")
        check(EpicAccount.accountName(fromStatus: #"[cli] INFO: x"# + "\n" + #"{"account": "SomePlayer", "games_available": 209}"#) == "SomePlayer"
              && EpicAccount.accountName(fromStatus: #"{"account": "<not logged in>"}"#) == nil, "the account's name from legendary's status")

        // 6. Covers kept small.
        let big = NSImage(size: NSSize(width: 1200, height: 1600), flipped: false) { r in NSColor.systemOrange.setFill(); r.fill(); return true }
        let jpeg = NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
        let small = CoverCache.thumbnail(jpeg)
        let rep = small.flatMap(NSBitmapImageRep.init(data:))
        check(rep?.pixelsWide == 120 && rep?.pixelsHigh == 160 && (small?.count ?? .max) < jpeg.count / 4,
              "a 1200 × 1600 cover kept as 120 × 160 (\(small?.count ?? 0) bytes, from \(jpeg.count))")
        let asked = CoverCache.sized(URL(string: "https://cdn1.epicgames.com/offer/abc/box.jpg")!)
        check(asked.query?.contains("resize=1") == true && asked.query?.contains("w=240") == true, "Epic's image server asked for the small one")
        check(CoverCache.sized(URL(string: "https://example.com/a.jpg")!).query == nil, "anyone else's left as it is")
        let loaded = await CoverCache.load("epic-test", local: nil, remote: nil)
        check(loaded == nil, "nothing to load from: nothing, no fault")
        let tmp = RuntimeManager.support.appendingPathComponent("cover.jpg")
        try? jpeg.write(to: tmp)
        let fromDisk = await CoverCache.load("steam-440", local: tmp, remote: nil)
        check(fromDisk != nil && fm.fileExists(atPath: CoverCache.file(for: "steam-440").path), "Steam's own cover read once and kept")

        if let net = ProcessInfo.processInfo.environment["STORE_COVER_URL"], let url = URL(string: net) {
            let began = Date()
            let remote = await CoverCache.load("epic-net", local: nil, remote: url)
            let kept = (try? Data(contentsOf: CoverCache.file(for: "epic-net")))?.count ?? 0
            check(remote != nil && kept > 0, String(format: "an Epic cover fetched small and kept (%d bytes, %.1f s)", kept, Date().timeIntervalSince(began)))
        }

        print(failures == 0 ? "store lists: all passed" : "store lists: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
