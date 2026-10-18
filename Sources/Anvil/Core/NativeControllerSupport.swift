import Foundation

/// How a Nintendo-style pad is presented to a game: as itself, or as the Switch Pro
/// Controller the game has built-in support for.
///
/// A game with its own Switch Pro support recognises the controller by USB vendor and
/// product id, then talks to it in Nintendo's protocol and shows Nintendo's prompts. A
/// pad made for the Switch by another company — PowerA, Hori, PDP — carries its maker's
/// id, and a pad Wine exposes speaks none of that protocol anyway. So for such a game
/// Anvil hides the pad and puts a Pro Controller of its own in its place, one that does
/// speak it (anvil_switchpro.mm). The game then handles the pad exactly as it would a
/// real Pro Controller: its prompts, its A and B, its confirm and cancel.
enum PadIdentity: String, Codable, CaseIterable, Identifiable {
    /// A Switch Pro Controller when the game supports one natively.
    case automatic
    case switchPro
    case asConnected

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .switchPro: "Nintendo Switch Pro Controller"
        case .asConnected: "As connected (Xbox-style)"
        }
    }
}

/// Which button on a Nintendo-layout pad plays Xbox's A, B, X and Y, for a game that
/// reads the pad as an Xbox pad.
///
/// Nintendo prints its letters the other way round from Xbox: A is the right button and
/// B the bottom one. So a Switch pad read as an Xbox pad can agree with the game's Xbox
/// prompts by letter or by position, never both. A game reading it as a Switch Pro
/// Controller has no such problem, and this setting does not apply to it.
enum FaceButtonLayout: String, Codable, CaseIterable, Identifiable {
    /// By letter: the letter on screen is the letter to press.
    case automatic
    /// The button labelled A is Xbox's A.
    case letters
    /// The bottom button is Xbox's A, whatever is printed on it.
    case positions

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic — match the letters on the pad"
        case .letters: "The pad's A is the game's A"
        case .positions: "The bottom button is the game's A"
        }
    }
}

enum NativeControllerSupport {
    /// Text in a game's executable showing it drives the Switch Pro Controller itself,
    /// in Nintendo's protocol: TT Games' input device and prompt set (LEGO Star Wars:
    /// The Skywalker Saga reads it through SwitchProControllerInputDevicePC and draws
    /// NNXPRO= prompts). This is the support the virtual Pro Controller was checked
    /// against, instruction by instruction.
    private static let protocolMarkers = ["SwitchProControllerInputDevicePC", "NNXPRO="]

    /// Whether the game's own executable drives a Switch Pro Controller itself. Only the
    /// executable is read, not the libraries beside it. Cached by path, size and date,
    /// since executables are large.
    ///
    /// Until 0.14 any mention of "Switch Pro Controller" counted — which is also in
    /// every game that bundles SDL's controller list, and such a game reads pads its own
    /// way. Only the markers above count now.
    static func supportsSwitchPro(_ game: Game) -> Bool {
        let path = game.executablePath
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(Int(date))"
        let cacheKey = "anvil.nativeSwitchPro.v2"
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Bool] ?? [:]
        if let known = cache[key] { return known }

        var found = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
            found = protocolMarkers.contains { data.range(of: Data($0.utf8)) != nil }
        }
        cache = cache.filter { !$0.key.hasPrefix(path + "|") }
        cache[key] = found
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return found
    }

    /// A pad laid out and labelled for the Switch but not made by Nintendo.
    static func isNintendoStyleThirdParty(_ pad: ConnectedController) -> Bool {
        guard pad.vendorID != 0x057E else { return false }
        let name = pad.displayName.lowercased()
        return pad.family == .switchPro || name.contains("nintendo") || name.contains("switch")
    }

    static func isNintendoLayout(_ pad: ConnectedController) -> Bool {
        pad.family == .switchPro || pad.family == .joyConPair || isNintendoStyleThirdParty(pad)
    }

    /// What this launch presents, and the rule for anvil_switchpro.mm: the vendor and
    /// product ids, as SDL reports them, of every pad to turn into a Pro Controller.
    static func resolve(_ game: Game, pads: [ConnectedController]) -> (identity: PadIdentity, rule: String?, reason: String) {
        let candidates = pads.filter(isNintendoLayout)
        var reason: String
        switch game.padIdentity {
        case .asConnected:
            return (.asConnected, nil, "set to show pads as they are")
        case .switchPro:
            reason = "set to show Nintendo-style pads as a Switch Pro Controller"
        case .automatic:
            guard !candidates.isEmpty else { return (.asConnected, nil, "no Nintendo-style pad connected") }
            guard supportsSwitchPro(game) else {
                return (.asConnected, nil, "the game has no Switch Pro support of its own, so it reads pads as Xbox pads")
            }
            reason = "the game drives the Switch Pro Controller itself"
        }
        guard !candidates.isEmpty else { return (.asConnected, nil, "no Nintendo-style pad connected") }
        var ids: [String] = []
        for pad in candidates {
            ids.append(String(format: "%04x:%04x", pad.vendorID & 0xFFFF, pad.productID & 0xFFFF))
            // SDL reports two Joy-Cons used together as one pad with an id of its own.
            if pad.family == .joyConPair { ids.append("057e:2008") }
        }
        reason += " (" + candidates.map(\.displayName).joined(separator: ", ") + ")"
        return (.switchPro, Array(Set(ids)).sorted().joined(separator: ","), reason)
    }

    /// Which face-button layout this launch uses, given the identity already decided.
    ///
    /// A pad shown as a Switch Pro Controller carries Nintendo's own buttons: A is A,
    /// wherever the game puts it. Its SDL mapping therefore goes by label, so that SDL's
    /// A is the pad's A, and the game's own Switch support does the rest — prompts,
    /// confirm and cancel included. A pad read as an Xbox pad goes by letter too, unless
    /// the player chose positions: then the A on screen is the A under the player's thumb.
    static func resolveFaceButtons(_ game: Game, pads: [ConnectedController],
                                   identity: PadIdentity) -> (layout: FaceButtonLayout, reason: String) {
        if identity == .switchPro {
            return (.letters, "the game reads the pad as a Switch Pro Controller — every button is the one printed on it")
        }
        switch game.faceButtons {
        case .letters: return (.letters, "set to match the letters on the pad")
        case .positions: return (.positions, "set to match the Xbox positions")
        case .automatic: break
        }
        guard pads.contains(where: isNintendoLayout) else { return (.letters, "no Nintendo-layout pad connected") }
        return (.letters, "the game shows Xbox prompts, so each letter on the pad is the same letter in the game")
    }
}
