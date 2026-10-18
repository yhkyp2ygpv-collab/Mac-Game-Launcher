// 0.35.0, in a throwaway home: Steam's shortcuts.vdf read and written (Valve's binary
// key-values), a game of Anvil's added beside a shortcut Steam made, added again without a
// second entry, its grid art cut to Steam's three sizes — and the store-window resolution.
//
//   swiftc -Onone -parse-as-library -module-name Anvil $(find Sources/Anvil/Core -name '*.swift') \
//     Native/Tools/tests/SteamShortcutsTest.swift -o $T/SteamShortcutsTest
//   CFFIXED_USER_HOME=<dir>/shortcuts/home $T/SteamShortcutsTest
import AppKit
import Foundation

@main struct SteamShortcutsHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard RuntimeManager.support.path.contains("/shortcuts/home/") else { print("refusing: not in the throwaway home"); exit(2) }
        var failures = 0
        func check(_ c: Bool, _ m: String) { if !c { failures += 1; print("FAIL: \(m)") } else { print("ok: \(m)") } }
        typealias V = SteamShortcuts.Value

        // 1. A file as Steam writes it, with one shortcut of the player's own.
        let theirs: [(String, V)] = [("appid", .int(-1_234_567)), ("AppName", .string("Their Game")),
                                     ("Exe", .string(#""C:\Games\their.exe""#)), ("StartDir", .string(#""C:\Games\""#)),
                                     ("LastPlayTime", .int(1_700_000_000)), ("tags", .map([]))]
        let original = SteamShortcuts.encode([("shortcuts", .map([("0", .map(theirs))]))])
        check(original.last == 0x08 && original.dropLast().last == 0x08, "the file ends as Steam's do (08 08)")
        let parsed = try? SteamShortcuts.parse(original)
        check(parsed.map { SteamShortcuts.encode($0) } == original, "read and written back byte for byte")

        // 2. LEGO added beside it.
        let lego = Game(title: "LEGO® Star Wars™: The Skywalker Saga", executablePath: "/Applications/Games/Mythic/LEGOStarWarsTSS/LEGOSTARWARSSKYWALKERSAGA_DX11.exe", containerID: UUID())
        guard let result = try? SteamShortcuts.adding(lego, to: original),
              let top = try? SteamShortcuts.parse(result.data), case .map(let list)? = top.first?.1 else {
            print("FAIL: couldn't add"); exit(1)
        }
        let (added, id) = result
        check(list.count == 2 && list[0].1["AppName"]?.text == "Their Game", "the player's own shortcut is kept, first")
        let mine = list[1].1
        check(mine["Exe"]?.text == #""C:\windows\system32\winebrowser.exe""# && mine["LaunchOptions"]?.text == "anvil://play/\(lego.id.uuidString)",
              "LEGO's shortcut opens its anvil:// link through winebrowser")
        check(mine["AppName"]?.text == lego.title && mine["AllowOverlay"] == .int(0), "named as the game, no Steam overlay in winebrowser")
        check(id & 0x8000_0000 != 0 && mine["appid"] == .int(Int32(bitPattern: id)), "its id has Steam's shortcut bit, and is the one written (\(id))")
        check(SteamShortcuts.gameID(appID: id) == (UInt64(id) << 32 | 0x0200_0000), "steam://rungameid/ id")

        // 3. Added again: replaced, not doubled.
        let again = try? SteamShortcuts.adding(lego, to: added)
        if let again, let t = try? SteamShortcuts.parse(again.data), case .map(let l)? = t.first?.1 {
            check(l.count == 2 && again.appID == id, "added twice, still one entry for it (\(l.count) in all)")
            check(l.map(\.0) == ["0", "1"], "entries numbered from 0 again")
        } else { check(false, "added twice") }

        // 4. Into an empty or missing file, and a file that isn't Steam's.
        check((try? SteamShortcuts.adding(lego, to: nil)) != nil, "no file yet: one is made")
        check((try? SteamShortcuts.adding(lego, to: Data("not vdf".utf8))) == nil, "a file Anvil can't read is left alone")

        // 5. Grid art from a cover, at Steam's sizes.
        let cover = NSImage(size: NSSize(width: 1280, height: 720), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        let dir = RuntimeManager.support.appendingPathComponent("config")
        SteamShortcuts.writeGrid(cover, appID: id, in: dir)
        for (suffix, w, h) in [("p", 600, 900), ("", 920, 430), ("_hero", 1920, 620)] {
            let url = dir.appendingPathComponent("grid/\(id)\(suffix).png")
            let rep = (try? Data(contentsOf: url)).flatMap(NSBitmapImageRep.init(data:))
            check(rep?.pixelsWide == w && rep?.pixelsHigh == h, "grid \(suffix.isEmpty ? "header" : suffix) \(w)×\(h)")
        }

        // 6. A container with Steam: the store window's resolution.
        var box = Container(name: "Steam Scale", runtimeID: "none")
        try? FileManager.default.createDirectory(at: box.prefixURL, withIntermediateDirectories: true)
        check(box.storeWindowSmooth, "Steam's window at point size unless chosen otherwise")
        check(Prefix.writtenScale(box) == "retina-192", "a container's own Retina 192 is what the registry holds at first (\(Prefix.writtenScale(box)))")
        box.storeWindowSharp = true
        check(!box.storeWindowSmooth, "turned on: Retina")
        box.scaling = .native
        check(Prefix.containerScale(box).retina == false && Prefix.containerScale(box).dpi == 96, "a native container is points at 96")

        print(failures == 0 ? "steam shortcuts: all passed" : "steam shortcuts: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
