import Foundation
import GameController
import IOKit.hid

/// Canonical action space. Every physical pad is normalised into these, and every
/// game binds these — so a remap made on a DualSense is the same remap on a Switch
/// Pro, and the on-screen prompts stay honest either way.
enum CanonicalInput: String, Codable, CaseIterable, Identifiable {
    case faceDown, faceRight, faceLeft, faceUp        // A/B/X/Y in Xbox terms
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftStick, rightStick                        // stick clicks
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case start, select, home
    case paddle1, paddle2, paddle3, paddle4
    case touchpad

    var id: String { rawValue }

    /// SDL's name for this element, used when generating a mapping string.
    var sdlName: String {
        switch self {
        case .faceDown: "a"
        case .faceRight: "b"
        case .faceLeft: "x"
        case .faceUp: "y"
        case .leftShoulder: "leftshoulder"
        case .rightShoulder: "rightshoulder"
        case .leftTrigger: "lefttrigger"
        case .rightTrigger: "righttrigger"
        case .leftStick: "leftstick"
        case .rightStick: "rightstick"
        case .dpadUp: "dpup"
        case .dpadDown: "dpdown"
        case .dpadLeft: "dpleft"
        case .dpadRight: "dpright"
        case .start: "start"
        case .select: "back"
        case .home: "guide"
        case .paddle1: "paddle1"
        case .paddle2: "paddle2"
        case .paddle3: "paddle3"
        case .paddle4: "paddle4"
        case .touchpad: "touchpad"
        }
    }
}

/// Controller families Anvil recognises. The distinction matters for two things:
/// which glyphs to draw, and which quirks to apply.
enum ControllerFamily: String, Codable, CaseIterable {
    case xbox, dualsense, dualshock4, switchPro, joyConPair, mfi, steam, generic

    var displayName: String {
        switch self {
        case .xbox: "Xbox"
        case .dualsense: "DualSense"
        case .dualshock4: "DualShock 4"
        case .switchPro: "Switch Pro"
        case .joyConPair: "Joy-Con Pair"
        case .mfi: "MFi"
        case .steam: "Steam Controller"
        case .generic: "Generic"
        }
    }

    /// Label the player actually sees on this pad for a canonical input.
    func glyph(for input: CanonicalInput) -> String {
        switch (self, input) {
        case (.dualsense, .faceDown), (.dualshock4, .faceDown): "✕"
        case (.dualsense, .faceRight), (.dualshock4, .faceRight): "○"
        case (.dualsense, .faceLeft), (.dualshock4, .faceLeft): "□"
        case (.dualsense, .faceUp), (.dualshock4, .faceUp): "△"
        case (.dualsense, .select), (.dualshock4, .select): "Create"
        case (.dualsense, .start), (.dualshock4, .start): "Options"

        // Nintendo's physical layout puts B where Xbox puts A. Anvil maps by
        // *position*, so "the bottom button" stays the bottom button and prompts
        // don't lie — this is the single most common cross-pad confusion.
        case (.switchPro, .faceDown), (.joyConPair, .faceDown): "B"
        case (.switchPro, .faceRight), (.joyConPair, .faceRight): "A"
        case (.switchPro, .faceLeft), (.joyConPair, .faceLeft): "Y"
        case (.switchPro, .faceUp), (.joyConPair, .faceUp): "X"
        case (.switchPro, .select), (.joyConPair, .select): "−"
        case (.switchPro, .start), (.joyConPair, .start): "+"

        case (_, .faceDown): "A"
        case (_, .faceRight): "B"
        case (_, .faceLeft): "X"
        case (_, .faceUp): "Y"
        case (_, .leftShoulder): "LB"
        case (_, .rightShoulder): "RB"
        case (_, .leftTrigger): "LT"
        case (_, .rightTrigger): "RT"
        case (_, .leftStick): "LS"
        case (_, .rightStick): "RS"
        case (_, .dpadUp): "D-Up"
        case (_, .dpadDown): "D-Down"
        case (_, .dpadLeft): "D-Left"
        case (_, .dpadRight): "D-Right"
        case (_, .start): "Menu"
        case (_, .select): "View"
        case (_, .home): "Guide"
        case (_, .paddle1): "P1"
        case (_, .paddle2): "P2"
        case (_, .paddle3): "P3"
        case (_, .paddle4): "P4"
        case (_, .touchpad): "Touchpad"
        }
    }

    static func detect(vendor: String?, productCategory: String?) -> ControllerFamily {
        let s = ((vendor ?? "") + " " + (productCategory ?? "")).lowercased()
        if s.contains("dualsense") { return .dualsense }
        if s.contains("dualshock") || s.contains("ds4") { return .dualshock4 }
        if s.contains("switch pro") || s.contains("pro controller") { return .switchPro }
        if s.contains("joy-con") || s.contains("joycon") { return .joyConPair }
        if s.contains("xbox") { return .xbox }
        if s.contains("steam") { return .steam }
        if s.contains("mfi") { return .mfi }
        return .generic
    }
}

/// A pad currently plugged in or paired.
struct ConnectedController: Identifiable, Hashable {
    var id: String
    var displayName: String
    var family: ControllerFamily
    var transport: HIDControllerScanner.Device.Transport
    var batteryLevel: Float?
    var hasHaptics: Bool
    var hasMotion: Bool
    var vendorID: Int
    var productID: Int
    /// SDL's identifier for this exact device. A mapping keyed to any other GUID is
    /// silently ignored, so this must come from the device itself.
    var sdlGUID: String
    /// True when GameController has a profile for it, meaning haptics, battery and
    /// motion are available. False means Anvil saw it over raw HID only — it still
    /// works in games, but macOS exposes less about it.
    var hasNativeProfile: Bool
    var elements: Set<CanonicalInput>

    var isWireless: Bool { transport == .bluetooth }

    var subtitle: String {
        var parts = [family.displayName, transport.rawValue]
        if let b = batteryLevel { parts.append("\(Int(b * 100))%") }
        if hasHaptics { parts.append("Haptics") }
        if hasMotion { parts.append("Gyro") }
        if !hasNativeProfile { parts.append("HID only") }
        return parts.joined(separator: " · ")
    }
}

/// Per-game remapping: canonical input → canonical input.
/// Empty means identity, which is what almost every game should stay on.
struct ControllerProfile: Codable, Hashable {
    var name: String = "Default"
    var remap: [CanonicalInput: CanonicalInput] = [:]
    var swapFaceButtons: Bool = false          // Nintendo-style confirm/cancel
    var swapTriggersAndShoulders: Bool = false
    var leftStickDeadzone: Double = 0.08
    var rightStickDeadzone: Double = 0.08
    var triggerThreshold: Double = 0.06
    var invertLookY: Bool = false
    var rumbleEnabled: Bool = true
    var rumbleIntensity: Double = 1.0
    var motionAsRightStick: Bool = false       // gyro aim for pads that have it

    /// True when the profile changes nothing, so SDL's own mappings can be left alone.
    var isIdentity: Bool {
        remap.allSatisfy { $0.key == $0.value } && !swapFaceButtons
            && !swapTriggersAndShoulders && !invertLookY
    }

    func resolved(_ input: CanonicalInput) -> CanonicalInput {
        var out = remap[input] ?? input
        if swapFaceButtons {
            switch out {
            case .faceDown: out = .faceRight
            case .faceRight: out = .faceDown
            default: break
            }
        }
        if swapTriggersAndShoulders {
            switch out {
            case .leftTrigger: out = .leftShoulder
            case .leftShoulder: out = .leftTrigger
            case .rightTrigger: out = .rightShoulder
            case .rightShoulder: out = .rightTrigger
            default: break
            }
        }
        return out
    }
}

@MainActor
final class ControllerManager: ObservableObject {
    @Published private(set) var controllers: [ConnectedController] = []

    static let shared = ControllerManager()

    private init() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        GCController.startWirelessControllerDiscovery()
        refresh()
    }

    /// Merge both sources. HID sees every pad; GameController adds battery, haptics
    /// and motion for the ones it recognises. Neither alone is sufficient.
    func refresh() {
        HIDControllerScanner.shared.refresh()
        let hidDevices = HIDControllerScanner.shared.devices

        var result: [ConnectedController] = []
        var claimedHID = Set<String>()

        for gc in GCController.controllers() {
            let family = ControllerFamily.detect(vendor: gc.vendorName, productCategory: gc.productCategory)
            // Pair it with its HID entry so the SDL GUID and transport are real.
            let match = hidDevices.first { device in
                device.family == family && !claimedHID.contains(device.id)
            }
            if let match { claimedHID.insert(match.id) }

            var elements: Set<CanonicalInput> = []
            if let pad = gc.extendedGamepad {
                elements.formUnion([.faceDown, .faceRight, .faceLeft, .faceUp,
                                    .leftShoulder, .rightShoulder,
                                    .leftTrigger, .rightTrigger,
                                    .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .start])
                if pad.leftThumbstickButton != nil { elements.insert(.leftStick) }
                if pad.rightThumbstickButton != nil { elements.insert(.rightStick) }
                if pad.buttonOptions != nil { elements.insert(.select) }
                if pad.buttonHome != nil { elements.insert(.home) }
            }
            if gc.physicalInputProfile is GCDualSenseGamepad { elements.insert(.touchpad) }

            result.append(ConnectedController(
                id: match?.id ?? "gc-\(gc.vendorName ?? "pad")",
                displayName: gc.vendorName ?? match?.name ?? "Controller",
                family: match?.family ?? family,
                transport: match?.transport ?? (gc.isAttachedToDevice ? .usb : .bluetooth),
                batteryLevel: gc.battery?.batteryLevel,
                hasHaptics: gc.haptics != nil,
                hasMotion: gc.motion != nil,
                vendorID: match?.vendorID ?? 0,
                productID: match?.productID ?? 0,
                sdlGUID: match?.sdlGUID ?? "",
                hasNativeProfile: true,
                elements: elements))
        }

        // Everything HID found that GameController didn't. These still work — Wine
        // and SDL read them directly — they simply have no Apple profile.
        for device in hidDevices where !claimedHID.contains(device.id) {
            result.append(ConnectedController(
                id: device.id,
                displayName: device.name,
                family: device.family,
                transport: device.transport,
                batteryLevel: nil,
                hasHaptics: false,
                hasMotion: false,
                vendorID: device.vendorID,
                productID: device.productID,
                sdlGUID: device.sdlGUID,
                hasNativeProfile: false,
                // No profile to query, so assume a standard modern layout.
                elements: Set(CanonicalInput.allCases).subtracting([.paddle1, .paddle2,
                                                                    .paddle3, .paddle4,
                                                                    .touchpad])))
        }

        controllers = result
        remember(hidDevices)
    }

    // MARK: SDL configuration

    /// Makers whose pads SDL's own drivers handle properly — correct buttons, analog
    /// triggers, rumble, and input read as it arrives rather than polled.
    static let firstPartyVendors: Set<Int> = [0x054C, 0x057E, 0x045E, 0x28DE]  // Sony, Nintendo, Microsoft, Valve

    /// A pad seen at any time. SDL reads its configuration once, when the game starts,
    /// so a controller plugged in mid-game only gets the right treatment if Anvil
    /// already knew about it.
    struct RememberedController: Codable, Hashable {
        var name: String
        var vendorID: Int
        var productID: Int
        var version: Int
        var bluetooth: Bool
        var layout: HIDLayout

        var device: HIDControllerScanner.Device {
            HIDControllerScanner.Device(name: name, vendorID: vendorID, productID: productID,
                                        version: version, transport: bluetooth ? .bluetooth : .usb,
                                        locationID: 0,
                                        family: ControllerFamily.detect(vendorID: vendorID,
                                                                        productID: productID, name: name),
                                        layout: layout)
        }
    }

    private static let rememberedKey = "anvil.rememberedControllers"
    private(set) lazy var remembered: [RememberedController] = {
        guard let data = UserDefaults.standard.data(forKey: Self.rememberedKey),
              let list = try? JSONDecoder().decode([RememberedController].self, from: data)
        else { return [] }
        return list
    }()

    private func remember(_ devices: [HIDControllerScanner.Device]) {
        var list = remembered
        for d in devices where d.vendorID != 0 {
            let entry = RememberedController(name: d.name, vendorID: d.vendorID, productID: d.productID,
                                             version: d.version, bluetooth: d.transport == .bluetooth,
                                             layout: d.layout)
            if let i = list.firstIndex(where: { $0.vendorID == d.vendorID && $0.productID == d.productID
                                                && $0.bluetooth == entry.bluetooth }) {
                // Keep the richer record: a layout read now beats an empty one.
                if d.layout.buttonCount > 0 || list[i].layout.buttonCount == 0 { list[i] = entry }
            } else {
                list.append(entry)
            }
        }
        if list.count > 32 { list = Array(list.suffix(32)) }
        guard list != remembered else { return }
        remembered = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.rememberedKey)
        }
    }

    /// Environment additions for a launch.
    ///
    /// Anvil used to switch SDL's dedicated drivers off entirely (SDL_JOYSTICK_HIDAPI=0)
    /// and send one guessed mapping for every connected pad. The guess was verified on
    /// the PowerA pad it was written for and was wrong elsewhere — a DualSense on that
    /// path has its right stick on Z/Rz and its triggers on Rx/Ry, so L2 moved the
    /// camera — and switching the drivers off took analog triggers, rumble and
    /// event-driven input away from every PlayStation, Xbox, Switch and Steam pad.
    ///
    /// Now each pad goes to whatever handles it best:
    ///  * Sony, Nintendo, Microsoft and Valve pads: SDL's own drivers, untouched.
    ///  * Other pads SDL's built-in database covers: SDL's mapping, kept off the
    ///    dedicated drivers so they stay on the path already proven with third-party
    ///    pads.
    ///  * Pads only the community database (bundled) covers: its mapping.
    ///  * Pads nothing covers: a mapping built from the pad's own HID descriptor.
    ///
    /// `faceButtons` is the resolved layout (letters or positions) for Nintendo-layout
    /// pads; see FaceButtonLayout. Every third-party Nintendo-layout pad gets a mapping
    /// of its own, so the choice is in the mapping and nowhere else.
    func environment(profile: ControllerProfile, controllers: [ConnectedController],
                     sdlLibrary: URL?, faceButtons: FaceButtonLayout = .positions) -> [String: String] {
        var env: [String: String] = [:]
        var mappings: [String] = []
        var ignore: [String] = []
        var handled = Set<String>()

        // Connected pads first, then everything seen before.
        var pads: [HIDControllerScanner.Device] = controllers.compactMap { c in
            HIDControllerScanner.shared.devices.first { $0.id == c.id }
        }
        pads += remembered.map(\.device)

        for pad in pads where pad.vendorID != 0 {
            let key = String(format: "0x%04x/0x%04x", pad.vendorID, pad.productID)
            guard handled.insert(key + (pad.transport == .bluetooth ? "-bt" : "-usb")).inserted else { continue }
            if Self.firstPartyVendors.contains(pad.vendorID) { continue }

            if !ignore.contains(key) { ignore.append(key) }
            let bus = pad.transport == .bluetooth ? 0x05 : 0x03
            let nintendo = pad.family == .switchPro || pad.family == .joyConPair
            // On a Nintendo-layout pad A and B are decided by the face-button layout
            // alone. The profile's "Swap confirm and cancel" stacked on top of it
            // unseen: LEGO Star Wars had both, the two A/B swaps cancelled, and only X
            // and Y moved — so the buttons stayed wrong whichever layout was picked.
            var profile = profile
            if nintendo && profile.swapFaceButtons {
                profile.swapFaceButtons = false
                AnvilLog.write("  \(pad.name): “Swap confirm and cancel” ignored — the face-button layout decides A and B on Switch pads")
            }
            var mapping: String
            if let lib = sdlLibrary,
               let builtIn = SDLControllerDB.mapping(vendor: pad.vendorID, product: pad.productID,
                                                    version: pad.version, bus: bus, in: lib) {
                // SDL already maps it correctly. Only restate it when something changes,
                // and then key it to this exact device.
                if profile.isIdentity && !nintendo { continue }
                mapping = Self.remapped(builtIn, guid: pad.sdlGUID, name: pad.name, profile: profile)
            } else if let listed = SDLControllerDB.communityMapping(vendor: pad.vendorID, product: pad.productID,
                                                                    version: pad.version, layout: pad.layout) {
                mapping = Self.remapped(listed, guid: pad.sdlGUID, name: pad.name, profile: profile)
            } else {
                mapping = Self.descriptorMapping(for: pad, profile: profile)
            }
            if nintendo && faceButtons == .letters { mapping = Self.swappingLetters(mapping) }
            // A mapping must end with a comma. SDL appends its own "crc:" field to the
            // string it stores, directly after the last character; without the comma
            // that field fuses with the last element — "righty:a3crc:578a" — and the
            // element is thrown away. Checked against the engine's SDL 2.32.8: every
            // mapping Anvil sent before this lost its last element, which was the right
            // stick's vertical axis.
            if !mapping.hasSuffix(",") { mapping += "," }
            mappings.append(mapping)
        }

        if !mappings.isEmpty { env["SDL_GAMECONTROLLERCONFIG"] = mappings.joined(separator: "\n") }
        env["SDL_JOYSTICK_HIDAPI"] = "1"
        if !ignore.isEmpty { env["SDL_HIDAPI_IGNORE_DEVICES"] = ignore.joined(separator: ",") }
        // XInput rumble reaches PlayStation pads only with these on.
        env["SDL_JOYSTICK_HIDAPI_PS4_RUMBLE"] = "1"
        env["SDL_JOYSTICK_HIDAPI_PS5_RUMBLE"] = "1"

        env["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"

        // Off — this is why controllers stopped working after the macOS 27 update.
        //
        // Since macOS 11, SDL asks Apple's GameController framework whether it
        // supports a device, and if it says yes, SDL's own IOKit backend steps aside
        // and leaves the pad to its GameController-based backend. macOS 27 began
        // saying yes for the PowerA Switch 2 pad. That backend never delivers input
        // where Wine runs SDL — on a thread of its own, not the main one — so the pad
        // simply vanished: SDL reported zero controllers under every other setting.
        //
        // Measured with the engine's own libSDL2 on the real pad: with this left on,
        // joysticks=0; with it off, joysticks=1, gamepad=1, and a ten-second test read
        // 163 inputs — every face button, the d-pad, shoulders, ZL/ZR, stick clicks,
        // −, + and Home, and both sticks. First-party pads lose nothing by it: with
        // this off they go to SDL's dedicated HIDAPI drivers, which are enabled above.
        env["SDL_JOYSTICK_MFI"] = "0"

        // Nintendo's own pads go through SDL's Switch driver, which takes the face-button
        // layout from this: 0 puts Xbox's A on the bottom button, 1 on the button
        // labelled A. Wine passes SDL's A to the game as XInput's A either way. Pads
        // Anvil maps itself carry the layout in their mapping, which this leaves alone.
        env["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] = faceButtons == .letters ? "1" : "0"

        // SDL's input thread at real-time priority, so it is not scheduled behind a
        // game that saturates every core. Verified present in this SDL build.
        env["SDL_THREAD_FORCE_REALTIME_TIME_CRITICAL"] = "1"
        return env
    }

    /// Kept for callers that have no engine to hand; behaves as if SDL knew no pads.
    func environment(profile: ControllerProfile, controllers: [ConnectedController]) -> [String: String] {
        environment(profile: profile, controllers: controllers, sdlLibrary: nil)
    }

    /// A mapping built from what the pad's descriptor declares.
    static func descriptorMapping(for pad: HIDControllerScanner.Device, profile: ControllerProfile) -> String {
        var layout = pad.layout
        // No descriptor read (an older record, or the read failed): use the layout
        // verified on real hardware rather than emitting a mapping with nothing in it.
        if layout.buttonCount == 0 && layout.axisUsages.isEmpty {
            layout = HIDLayout(); layout.axisUsages = [0x30, 0x31, 0x32, 0x35]
            layout.buttonCount = 13; layout.hatCount = 1
        }

        var fields = [pad.sdlGUID, pad.name.replacingOccurrences(of: ",", with: " "), "platform:Mac OS X"]

        // Axes. A pad with Rx/Ry puts its right stick there and its triggers on Z/Rz
        // (the PlayStation arrangement); one without puts the right stick on Z/Rz and
        // has digital triggers (the arrangement of the PowerA pad this was verified on).
        let leftX = layout.axisIndex(0x30), leftY = layout.axisIndex(0x31)
        var rightX: Int?, rightY: Int?, triggerL: Int?, triggerR: Int?
        if let rx = layout.axisIndex(0x33), let ry = layout.axisIndex(0x34) {
            rightX = rx; rightY = ry
            triggerL = layout.axisIndex(0x32); triggerR = layout.axisIndex(0x35)
        } else {
            rightX = layout.axisIndex(0x32); rightY = layout.axisIndex(0x35)
        }

        // A Switch-style pad from another maker reports its face buttons as Y, B, A, X —
        // the HORI layout the Switch itself reads over USB, which SDL's database and
        // the community one record for every PowerA and Hori Switch pad. Anything else
        // is assumed to lead with the bottom button.
        let nintendo = pad.family == .switchPro && pad.vendorID != 0x057E
        let face: [(CanonicalInput, Int)] = nintendo
            ? [(.faceLeft, 0), (.faceDown, 1), (.faceRight, 2), (.faceUp, 3)]
            : [(.faceDown, 0), (.faceRight, 1), (.faceLeft, 2), (.faceUp, 3)]
        let buttons: [(CanonicalInput, Int)] = face + [
            (.leftShoulder, 4), (.rightShoulder, 5), (.leftTrigger, 6), (.rightTrigger, 7),
            (.select, 8), (.start, 9), (.leftStick, 10), (.rightStick, 11), (.home, 12),
        ]
        for (input, index) in buttons where index < layout.buttonCount {
            if input == .leftTrigger && triggerL != nil { continue }
            if input == .rightTrigger && triggerR != nil { continue }
            fields.append("\(profile.resolved(input).sdlName):b\(index)")
        }
        if let t = triggerL { fields.append("\(profile.resolved(.leftTrigger).sdlName):a\(t)") }
        if let t = triggerR { fields.append("\(profile.resolved(.rightTrigger).sdlName):a\(t)") }
        if nintendo && layout.buttonCount > 13 { fields.append("misc1:b13") }      // Capture

        if layout.hatCount > 0 {
            fields += ["\(profile.resolved(.dpadUp).sdlName):h0.1",
                       "\(profile.resolved(.dpadRight).sdlName):h0.2",
                       "\(profile.resolved(.dpadDown).sdlName):h0.4",
                       "\(profile.resolved(.dpadLeft).sdlName):h0.8"]
        }
        if let a = leftX { fields.append("leftx:a\(a)") }
        if let a = leftY { fields.append("lefty:a\(a)") }
        if let a = rightX { fields.append("rightx:a\(a)") }
        // Invert only the camera stick. This used to invert both.
        if let a = rightY { fields.append("righty:a\(a)\(profile.invertLookY ? "~" : "")") }
        return fields.joined(separator: ",") + ","
    }

    /// The same mapping with each face button bound to the one whose letter it has:
    /// Xbox's A to the pad's A, on the right, and so on. Nintendo's letters are the
    /// mirror of Xbox's, so this swaps A with B and X with Y.
    static func swappingLetters(_ mapping: String) -> String {
        let mirror = ["a": "b", "b": "a", "x": "y", "y": "x"]
        var fields = mapping.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for i in fields.indices.dropFirst(2) {
            let parts = fields[i].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let other = mirror[parts[0]] else { continue }
            fields[i] = other + ":" + parts[1]
        }
        return fields.joined(separator: ",")
    }

    /// Every element name SDL 2 understands in a mapping (the engines ship 2.30 and 2.32).
    static let sdl2Elements: Set<String> = [
        "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick",
        "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright", "misc1",
        "paddle1", "paddle2", "paddle3", "paddle4", "touchpad",
        "leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger",
    ]

    /// SDL's own mapping for a pad, with the profile's remaps applied and keyed to
    /// this exact device.
    static func remapped(_ builtIn: String, guid: String, name: String,
                         profile: ControllerProfile) -> String {
        let byName = Dictionary(uniqueKeysWithValues: CanonicalInput.allCases.map { ($0.sdlName, $0) })
        var fields = [guid, name.replacingOccurrences(of: ",", with: " "), "platform:Mac OS X"]
        for field in builtIn.split(separator: ",").dropFirst(2) {
            let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (target, source) = (parts[0], parts[1])
            switch target {
            case "platform", "hint", "crc", "sdk>=", "sdk<=": continue
            case "righty":
                var src = source
                if profile.invertLookY { src = src.hasSuffix("~") ? String(src.dropLast()) : src + "~" }
                fields.append("righty:\(src)")
            default:
                if let input = byName[target] {
                    fields.append("\(profile.resolved(input).sdlName):\(source)")
                } else if Self.sdl2Elements.contains(target) {
                    fields.append("\(target):\(source)")
                }
                // Anything else is an SDL 3 name (misc2, the Switch 2's C button, and
                // the like) that SDL 2 does not have.
            }
        }
        return fields.joined(separator: ",") + ","
    }
}
