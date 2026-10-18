import Foundation

/// 3D sound for every game: Apple's spatial audio between the game and whatever the Mac plays
/// through (libanvil's anvil_audio.mm). A game is told a stereo output plays 7.1, so it mixes its
/// sound in surround; each channel of that mix is then placed around the listener — binaural on
/// headphones, earbuds and AirPods (with the player's personalized spatial audio where it is set
/// up), Apple's virtualization on a Mac's built-in speakers and on external speakers, and on a
/// real surround system each channel to its own speaker.
enum SpatialSound {
    nonisolated static let enabledKey = "spatialSound"
    nonisolated static let outputKey = "spatialSoundOutput"
    nonisolated static let headTrackingKey = "spatialSoundHeadTracking"
    /// Anvil Surround: a stereo game's sound split into surround before 3D sound places it
    /// (libanvil's anvil_upmix.h), and a 7.1 mix with sound only in its front pair the same.
    nonisolated static let upmixKey = "spatialSoundUpmix"

    /// What the player listens on, when the device can't say for sure (a Bluetooth or USB device
    /// is taken as worn unless its name says speaker, and the other way round).
    enum Output: String, CaseIterable, Identifiable {
        case automatic, headphones, speakers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .headphones: "Headphones or earbuds"
            case .speakers: "Speakers"
            }
        }
        var environmentValue: String {
            switch self {
            case .automatic: "auto"
            case .headphones: "headphones"
            case .speakers: "speakers"
            }
        }
    }

    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    nonisolated static var output: Output {
        UserDefaults.standard.string(forKey: outputKey).flatMap(Output.init(rawValue:)) ?? .automatic
    }
    nonisolated static var headTracking: Bool { UserDefaults.standard.bool(forKey: headTrackingKey) }
    nonisolated static var upmix: Bool { UserDefaults.standard.object(forKey: upmixKey) as? Bool ?? true }

    /// The switch for every game, wherever it is flipped (the Library, the menu bar, Settings).
    /// A running game keeps the sound it started with: libanvil sets it up as the game opens its
    /// output, and the game was told then how many channels to mix.
    nonisolated static func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        UserDefaults.standard.set(on, forKey: enabledKey)
        let output = SoundOutput.current().map { " — playing through \($0.launchLine(Self.output))" } ?? ""
        AnvilLog.write("settings: 3D surround sound \(on ? "on" : "off") for every game, from its next start\(output)")
    }

    /// For a game's process — or, `forcingOn`, for the sound check, which says what a game gets
    /// with 3D sound on.
    nonisolated static func environment(forcingOn: Bool = false) -> [String: String] {
        guard enabled || forcingOn else { return ["ANVIL_SPATIAL": "0", "ANVIL_SURROUND_MIX": "0", "ANVIL_UPMIX": "0"] }
        return ["ANVIL_SPATIAL": "1", "ANVIL_SURROUND_MIX": "1",
                "ANVIL_SPATIAL_OUTPUT": output.environmentValue,
                "ANVIL_SPATIAL_HEAD": headTracking ? "1" : "0",
                "ANVIL_UPMIX": upmix ? "1" : "0"]
    }

    /// For the launch log.
    nonisolated static var launchLine: String {
        guard enabled else { return "off — each game's own mix, folded into stereo where it is wider" }
        return "on — the game mixes in surround and Apple's spatial audio places it around you"
            + (output == .automatic ? "" : " (\(output.title.lowercased()), as chosen)")
            + (headTracking ? ", following your head with AirPods" : "")
            + (upmix ? "; Anvil Surround makes a stereo game's sound surround (voices to the centre, the room around you)"
                     : "; Anvil Surround off — stereo games placed as stereo")
    }

    /// For the launch log: what the game will play through, and what 3D sound makes of it.
    nonisolated static var outputLine: String {
        SoundOutput.current().map { $0.launchLine(output) } ?? "no sound output found"
    }
}
