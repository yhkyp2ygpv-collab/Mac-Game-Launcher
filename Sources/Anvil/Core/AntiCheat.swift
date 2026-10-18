import Foundation

/// The anti-cheat a game ships with, found from the files in its folder, so Anvil can say
/// up front whether its online play can work on a Mac — rather than leaving a game that
/// closes at the menu to look like Anvil's fault.
///
/// Anvil never tries to get around anti-cheat. Doing that is what gets accounts banned,
/// and the games' makers decide where their multiplayer runs. What can work is what a
/// game's maker has allowed: Easy Anti-Cheat and BattlEye have a mode for Wine (the one
/// the Steam Deck uses) that a game's maker can switch on; the kernel-level systems need
/// Windows itself and never run under Wine.
enum AntiCheat: String, Codable, CaseIterable, Identifiable {
    case easyAntiCheat, battlEye, vanguard, eaJavelin, xigncode, gameGuard, punkBuster, ace

    var id: String { rawValue }

    var name: String {
        switch self {
        case .easyAntiCheat: "Easy Anti-Cheat"
        case .battlEye: "BattlEye"
        case .vanguard: "Riot Vanguard"
        case .eaJavelin: "EA Javelin"
        case .xigncode: "XIGNCODE3"
        case .gameGuard: "nProtect GameGuard"
        case .punkBuster: "PunkBuster"
        case .ace: "Anti-Cheat Expert"
        }
    }

    /// Whether the game's maker can allow it under Wine at all.
    var canBeAllowedUnderWine: Bool { self == .easyAntiCheat || self == .battlEye }

    /// File and folder names that give each one away, lowercased.
    private var markers: [String] {
        switch self {
        case .easyAntiCheat: ["easyanticheat", "easyanticheat_eos", "start_protected_game.exe", "easyanticheat_x64.dll", "easyanticheat_eos_setup.exe"]
        case .battlEye: ["battleye", "beservice.exe", "beservice_x64.exe", "beclient_x64.dll"]
        case .vanguard: ["vgc.exe", "vgk.sys", "riot vanguard"]
        case .eaJavelin: ["eaanticheat", "eaanticheat.gameservicelauncher.exe", "eaanticheat.installer.exe"]
        case .xigncode: ["xigncode", "x3.xem"]
        case .gameGuard: ["gameguard", "gamemon.des", "gamemon64.des"]
        case .punkBuster: ["pnkbstra.exe", "pnkbstrb.exe"]
        case .ace: ["anticheatexpert", "ace-base64.sys"]
        }
    }

    /// What a game folder holds, looking two levels down — where these always are.
    static func detect(in folder: URL) -> [AntiCheat] {
        let fm = FileManager.default
        var names: Set<String> = []
        func look(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for entry in entries.prefix(400) {
                names.insert(entry.lastPathComponent.lowercased())
                if depth > 0, (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    look(entry, depth: depth - 1)
                }
            }
        }
        look(folder, depth: 2)
        return allCases.filter { kind in kind.markers.contains(where: names.contains) }
    }

    /// Where to look for a game: its install folder, the one above the executable's own
    /// when that is a bin or Binaries folder.
    static func detect(for game: Game) -> [AntiCheat] {
        detect(forExecutable: game.executableURL)
    }

    static func detect(forExecutable executable: URL) -> [AntiCheat] {
        detect(in: installFolder(of: executable))
    }

    /// A game's install folder: above a bin or Binaries folder its executable sits in, and for
    /// an Unreal game one further up, where Engine/ and the anti-cheat sit beside the
    /// project's own folder (<install>/<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe).
    static func installFolder(of executable: URL) -> URL {
        var folder = executable.deletingLastPathComponent()
        var climbed = false
        for _ in 0..<3 where ["bin", "binaries", "win64", "x64", "win32"].contains(folder.lastPathComponent.lowercased()) {
            folder.deleteLastPathComponent()
            climbed = true
        }
        let parent = folder.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if climbed, FileManager.default.fileExists(atPath: parent.appendingPathComponent("Engine").path, isDirectory: &isDir), isDir.boolValue {
            return parent
        }
        return folder
    }

    /// The sentence the game's page and Health show.
    static func note(for kinds: [AntiCheat]) -> String? {
        guard let first = kinds.first else { return nil }
        let names = kinds.map(\.name).joined(separator: " and ")
        if let kernel = kinds.first(where: { !$0.canBeAllowedUnderWine }) {
            return "Uses \(kernel.name), which only runs on Windows itself, so its online play can't work on a Mac. Offline parts may still run. Anvil doesn't get around anti-cheat — that gets accounts banned."
        }
        _ = first
        return "Uses \(names). Online play works only if the game's maker has switched on its Wine support (as many have for the Steam Deck), and not always on a Mac even then. Offline and single-player parts usually work. Anvil doesn't get around anti-cheat — that gets accounts banned."
    }
}
