import Foundation

/// A Windows executable Anvil knows how to launch, plus per-title overrides that
/// take precedence over its container's settings.
struct Game: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var executablePath: String
    var containerID: UUID
    var arguments: [String] = []
    var workingDirectory: String?
    var artworkPath: String?
    var lastPlayed: Date?
    var totalPlaySeconds: Double = 0

    // Per-title overrides. nil means "inherit from the container".
    var backendOverride: GraphicsBackend?
    var syncOverride: SyncPrimitive?
    var hudOverride: HUDConfig?
    var videoMemoryOverrideMB: Int?
    var extraArgumentsRaw: String = ""
    var preset: PresetKind = .balanced
    var controllerProfileOverride: ControllerProfile?
    var upscalerOverride: UpscalerConfig?
    /// For a game installed through Mythic or Heroic: sign it in to Epic at launch, as
    /// those launchers do, so it can see the DLC, cloud saves and achievements its
    /// owner has. See EpicLink.
    var epicSignIn: Bool = true
    /// Launch without Anvil's library: no frame pacing, overlay or controller fixes.
    /// Set by the user, or by Anvil when the game failed to start with them and started
    /// without — see Launcher.finish.
    var anvilEnhancementsOff: Bool = false
    /// How Nintendo-style pads are presented to this game. See PadIdentity.
    var padIdentity: PadIdentity = .automatic
    /// Whether a Nintendo-layout pad's face buttons follow their letters or their
    /// positions in this game. See FaceButtonLayout.
    var faceButtons: FaceButtonLayout = .automatic
    /// Whether Anvil sets this game's own heavy graphics options for a steady frame
    /// rate on this Mac. See GameTuning; only games it knows are touched.
    var graphicsTuning: GraphicsTuning = .automatic
    /// How the last session ran, read from game.log when it ended.
    var lastSession: SessionStats?
    /// Frame pacing for this game alone, when it shares its container with others and
    /// Auto-Tune chose differently for it. Nil follows the container.
    var targetFPSOverride: Int?
    /// What "best" means for this game, for Auto-Tune and the container advice. Nil is
    /// Smooth 80+.
    var tuneGoal: TuneGoal?
    /// Anvil checks every session, fixes what is safe to fix, and starts Auto-Tune by
    /// itself. See GameDoctor.
    var autopilot: Bool = true
    /// For a game whose own engine can carry on while another app is in front (see
    /// KeepRunning): start it that way, so its loading doesn't wait for it to be in front.
    /// Anvil holds it to 30 fps meanwhile.
    var keepRunningBehind: Bool = true
    /// A game from Steam: its app id. It is started with the Steam client running and
    /// signed in, in the same container, so its multiplayer, DRM and achievements work.
    var steamAppID: String?
    /// A game installed through Anvil's own Epic connection: legendary's name for it.
    var epicAppName: String?
    /// The display mode that fills the screen, by kind of engine ("wine7", "wine9"),
    /// learned from the window the game actually got. See GameTuning.DisplayMode.
    var displayModes: [String: String]?
    /// For a game whose screen shape Anvil sets (TT Games' AspectRatio): the screen's own shape,
    /// true to its proportions, or a 16:9 layout. See GameTuning.PictureShape.
    var pictureShape: GameTuning.PictureShape = .fill
    /// For a game the graphics scan found DLSS in, on an engine that can: its DLSS runs as
    /// Apple's MetalFX. See DLSSThroughMetalFX. Switched off by Autopilot if the game
    /// crashes with it on.
    var dlssThroughMetalFX: Bool = true
    /// For a game whose settings file Anvil knows (GameUpscaler): which of its own upscalers it starts with, and at what
    /// quality — nil for Automatic, chosen from how it runs here.
    var gameUpscaler: GameUpscaler.Choice = .automatic
    var gameUpscalerQuality: UpscaleQuality?
    /// Its film grain and colour fringing off while Anvil upscales (GameUpscaler).
    var cleanPicture: Bool = true
    /// Which frame generation it runs with, for a game whose settings Anvil knows: Automatic is the game's own where
    /// it has one (GameUpscaler.FrameGen).
    var gameFrameGen: GameUpscaler.FrameGen = .automatic
    /// Its own quality settings, for a game whose settings Anvil knows: for an even 80 (Automatic), or exactly as set
    /// in its menu (GameUpscaler.Graphics).
    var gameGraphics: GameUpscaler.Graphics = .automatic
    /// Graphics Prep before a start that needs it: Anvil's FSR and frame generation compiled
    /// for this Mac and tested on its GPU at the game's size. See GraphicsPrep.
    var prepareGraphics: Bool = true
    /// The memory warm-up before a start: the parts of the game's data played most read into memory as it
    /// starts. See MemoryWarmup.
    var warmMemory: Bool = true
    /// Ray tracing for a DirectX 12 game that offers it: nil leaves it to Anvil — on where this Mac traces rays
    /// in hardware (M3 and later); true or false as chosen. See Launcher's D3DM_SUPPORT_DXR.
    var rayTracing: Bool?
    /// How its starts with no connection have gone here. See OfflineStarts.
    var offlineRecord: OfflineRecord?

    var executableURL: URL { URL(fileURLWithPath: executablePath) }
    var exists: Bool { FileManager.default.fileExists(atPath: executablePath) }

    var playtimeDescription: String {
        if totalPlaySeconds < 60 { return lastPlayed == nil ? "Not played yet" : "Under a minute" }
        let hours = totalPlaySeconds / 3600
        if hours < 1 { return "\(Int(totalPlaySeconds / 60)) min" }
        return String(format: "%.1f hours", hours)
    }
}
