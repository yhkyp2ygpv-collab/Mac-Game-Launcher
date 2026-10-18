import CoreAudio
import Foundation

/// One of the Mac's sound outputs, and what 3D sound makes of it.
///
/// The rules are libanvil's (anvil_audio.mm), which decides at each game's start: `listenerFor`
/// says who is listening, and `plan` takes outputs of 2 to 8 channels. They are kept the same here
/// by hand, and Native/Tools/tests/sound_output_cases.txt holds both to one table — the audio test
/// runs it through libanvil's code, SoundOutputTest through this.
struct SoundOutput: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    /// Output channels: 2 for stereo, 6 for 5.1, 1 for a single speaker or a headset in call mode.
    let channels: Int
    /// A built-in output's data source — the headphone jack ('hdpn') or the speakers ('ispk') — else 0.
    let dataSource: UInt32
    var isDefault = false

    enum Listener: String, Sendable { case headphones, builtInSpeakers, externalSpeakers, surround }

    /// How a game's sound plays here with 3D sound on.
    enum Fit: String, Sendable {
        case threeD             // binaural, on headphones and earbuds
        case virtualSurround    // Apple's virtual surround, on two speakers
        case surround           // each channel to its own speaker
        case mono               // one channel: nothing to place a sound with
        case tooWide            // more than 8 channels: left as the game mixes
        case unreadable         // macOS doesn't say how many channels

        var compatible: Bool { self == .threeD || self == .virtualSurround || self == .surround }
    }

    static let headphoneJack = fourCC("hdpn")

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// anvil_audio.mm's `listenerFor`: the player's choice, else what the device says — the
    /// headphone jack or the speakers of a built-in output (on Apple silicon the jack can be a
    /// device of its own, "External Headphones"), a Bluetooth device worn unless its name says
    /// speaker, a USB one across the room unless its name says headset. More than two channels is
    /// a surround system whatever was chosen.
    func listener(_ choice: SpatialSound.Output) -> Listener {
        if channels > 2 { return .surround }
        switch choice {
        case .headphones: return .headphones
        case .speakers: return isBuiltIn ? .builtInSpeakers : .externalSpeakers
        case .automatic: break
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == Self.headphoneJack || nameHas(["headphone"]) ? .headphones : .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return nameHas(["speaker", "soundlink", "boom", "jbl flip", "jbl charge", "homepod", "echo", "sonos", "soundbar"])
                ? .externalSpeakers : .headphones
        case kAudioDeviceTransportTypeUSB:
            return nameHas(["headset", "headphone", "earphone", "buds", "airpods", "arctis", "hyperx", "cloud", "blackshark",
                            "kraken", "g pro", "astro", "virtuoso", "void"])
                ? .headphones : .externalSpeakers
        default:
            return .externalSpeakers
        }
    }

    /// anvil_audio.mm's `plan`: 3D sound takes outputs of 2 to 8 channels.
    func fit(_ choice: SpatialSound.Output) -> Fit {
        switch channels {
        case ..<1: return .unreadable
        case 1: return .mono
        case 9...: return .tooWide
        default:
            switch listener(choice) {
            case .headphones: return .threeD
            case .surround: return .surround
            case .builtInSpeakers, .externalSpeakers: return .virtualSurround
            }
        }
    }

    private func nameHas(_ words: [String]) -> Bool {
        let lower = name.lowercased()
        return words.contains { lower.contains($0) }
    }

    // MARK: Said to the player

    var layout: String {
        switch channels {
        case 1: "mono"
        case 2: "stereo"
        case 3: "2.1"
        case 4: "quadraphonic"
        case 5: "4.1"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
    }

    var connection: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: listener(.automatic) == .headphones ? "Headphone jack" : "Built in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Combined"
        default: "Output"
        }
    }

    /// "Bluetooth · stereo".
    var subtitle: String { channels > 0 ? "\(connection) · \(layout)" : connection }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return channels > 2 ? "hifispeaker.2" : "tv"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: break
        }
        switch listener(.automatic) {
        case .headphones: return "headphones"
        case .builtInSpeakers: return "laptopcomputer"
        case .externalSpeakers, .surround: return "hifispeaker.2"
        }
    }

    /// What it sounds like here, in a few words.
    func headline(_ choice: SpatialSound.Output) -> String {
        switch fit(choice) {
        case .threeD: "3D sound on headphones"
        case .virtualSurround: listener(choice) == .builtInSpeakers ? "Virtual surround on the Mac's speakers" : "Virtual surround on two speakers"
        case .surround: transport == kAudioDeviceTransportTypeVirtual ? "\(layout) surround, passed on" : "Real \(layout) surround"
        case .mono: isBluetooth ? "In headset mode — one channel" : "One speaker — no surround"
        case .tooWide: "\(channels) channels — not used"
        case .unreadable: "Its channels can't be read"
        }
    }

    func detail(_ choice: SpatialSound.Output) -> String {
        let chosen = choice == .automatic ? "" : " (\(choice.title.lowercased()), as you chose)"
        switch fit(choice) {
        case .threeD:
            return "Each sound comes from where it is — ahead, beside you, behind — in 3D for headphones and earbuds\(chosen), with your personalized spatial audio if you've set it up."
        case .virtualSurround:
            return listener(choice) == .builtInSpeakers
                ? "Apple's virtual surround for the Mac's own speakers\(chosen): sound spreads wider than the Mac. Best sitting centred in front of the screen."
                : "Apple's virtual surround across two speakers\(chosen). Best sitting centred between them."
        case .surround:
            return transport == kAudioDeviceTransportTypeVirtual
                ? "Games mix in \(layout) and each channel is passed on as its own channel."
                : "Games mix for this \(layout) system and each channel goes to its own speaker."
        case .mono:
            return isBluetooth
                ? "An app is using its microphone, which leaves one channel and call quality. Choose another microphone in System Settings › Sound › Input to get stereo — and 3D sound — back."
                : "One speaker can't place a sound around you, so games play in mono here. Headphones or two speakers get 3D sound."
        case .tooWide:
            return "3D sound is made for outputs of 2 to 8 channels, like headphones, speakers and 5.1 or 7.1 systems. On this \(channels)-channel output games play as they mix."
        case .unreadable:
            return "macOS doesn't say how many channels this output has, so games play as they mix."
        }
    }

    /// Something the player can do about it, where there is something.
    func hint(_ choice: SpatialSound.Output) -> Hint? {
        if transport == kAudioDeviceTransportTypeAirPlay {
            return .init(text: "AirPlay plays sound a moment late, which you'll notice in a game. Wired, Bluetooth or the Mac's own speakers are quicker.")
        }
        if (transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort), channels == 2 {
            return .init(text: "TV or receiver with surround speakers? Set it to 5.1 or 7.1 in Audio MIDI Setup (Configure Speakers) and each channel goes to its own speaker.",
                         opensAudioMIDISetup: true)
        }
        if transport == kAudioDeviceTransportTypeVirtual, channels == 2, choice == .automatic {
            return .init(text: "A virtual device passes sound on to another app, so 3D sound mixes it for speakers. Listening to it on headphones? Choose Headphones under Listening on.")
        }
        if fit(choice) == .threeD, tracksHead {
            return .init(text: "These can follow your head: turn on Follow head movement and the sound stays anchored to the screen as you turn.")
        }
        return nil
    }

    struct Hint: Equatable, Sendable {
        let text: String
        var opensAudioMIDISetup = false
    }

    /// AirPods and Beats, which may track the head (AirPods Pro, Max, 3rd generation and later;
    /// some Beats). Others ignore the setting.
    var tracksHead: Bool {
        let lower = name.lowercased()
        return isBluetooth && (lower.contains("airpods") || lower.contains("beats"))
    }

    /// For the launch log.
    func launchLine(_ choice: SpatialSound.Output) -> String {
        "\(name) (\(subtitle.lowercased())) — \(fit(choice).compatible ? "compatible" : "not compatible"): \(headline(choice).lowercasedFirst)"
    }
}

func fourCC(_ code: String) -> UInt32 {
    code.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}

extension String {
    /// "Real 5.1 surround" → "real 5.1 surround", leaving names like "AirPods" and "3D" as they are.
    var lowercasedFirst: String {
        let word = prefix { $0 != " " }
        guard let first, first.isUppercase, !word.dropFirst().contains(where: \.isUppercase) else { return self }
        return first.lowercased() + dropFirst()
    }
}

// MARK: - Reading the Mac's outputs

extension SoundOutput {
    /// Every device that plays sound, the one macOS plays through first.
    nonisolated static func all() -> [SoundOutput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let current: AudioDeviceID = value(system, kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let outputs = ids.compactMap { id -> SoundOutput? in
            let output = read(id, isDefault: id == current)
            return output.channels > 0 || output.isDefault ? output : nil
        }
        return outputs.sorted { a, b in
            a.isDefault != b.isDefault ? a.isDefault : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The output macOS plays through now.
    nonisolated static func current() -> SoundOutput? {
        let id: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        return id == 0 ? nil : read(id, isDefault: true)
    }

    nonisolated static func read(_ id: AudioDeviceID, isDefault: Bool) -> SoundOutput {
        SoundOutput(id: id, name: name(of: id) ?? "Sound output",
                    transport: value(id, kAudioDevicePropertyTransportType) ?? 0,
                    channels: outputChannels(of: id),
                    dataSource: value(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) ?? 0,
                    isDefault: isDefault)
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    private nonisolated static func name(of id: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private nonisolated static func outputChannels(of id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The Mac's outputs, kept current as headphones go in, AirPods connect or the output is switched.
@MainActor
final class SoundOutputs: ObservableObject {
    static let shared = SoundOutputs()

    @Published private(set) var outputs: [SoundOutput] = []
    var current: SoundOutput? { outputs.first(where: \.isDefault) }
    var others: [SoundOutput] { outputs.filter { !$0.isDefault } }

    private struct Watch {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var watching: [AudioDeviceID: [Watch]] = [:]

    private init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = SoundOutput.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                Task { @MainActor in SoundOutputs.shared.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        let now = SoundOutput.all()
        if now != outputs { outputs = now }
        watch(Set(now.map(\.id)))
    }

    /// Each output's own changes: the headphone jack or the speakers, a headset dropping to one
    /// channel for a call, a system set to 5.1, a rename.
    private func watch(_ ids: Set<AudioDeviceID>) {
        for (id, watches) in watching where !ids.contains(id) {
            for var w in watches { AudioObjectRemovePropertyListenerBlock(id, &w.address, .main, w.block) }
            watching[id] = nil
        }
        for id in ids where watching[id] == nil {
            watching[id] = [
                SoundOutput.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
                SoundOutput.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput),
                SoundOutput.address(kAudioObjectPropertyName),
            ].map { address in
                var address = address
                let block: AudioObjectPropertyListenerBlock = { _, _ in
                    Task { @MainActor in SoundOutputs.shared.refresh() }
                }
                AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
                return Watch(address: address, block: block)
            }
        }
    }
}
