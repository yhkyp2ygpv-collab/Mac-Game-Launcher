import SwiftUI

/// Upscaler controls, with the game's actual capability stated up front so the
/// available modes are never a mystery.
struct UpscalerEditor: View {
    @Binding var config: UpscalerConfig
    var game: Game?

    @EnvironmentObject private var upscalers: UpscalerManager
    @State private var installError: String?
    @State private var installNote: String?
    /// Anti-cheat in the game's folder: nothing of Anvil's may go in there.
    @State private var antiCheat: [AntiCheat] = []

    var body: some View {
        everyGameSection
        modeSection
        if config.mode != .off { qualitySection }
        // Scanning the game and managing downloaded payloads only matters for the
        // FSR 3 modes. Showing that machinery unconditionally made every mode look
        // like it needed files, when the defaults need none.
        if !config.mode.isBuiltIn {
            capabilitySection
            runtimeSection
        }
    }

    // MARK: FSR and frame generation, in any game

    private var everyGameSection: some View {
        Group {
            Toggle("FSR to the display", isOn: config.mode == .fsr3Every ? .constant(true) : $config.fsrToDisplay)
                .disabled(config.mode == .fsr3Every)
            if config.mode == .fsr3Every {
                Text("On with FSR 3, which runs as part of it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("AMD FSR 1 — EASU, then RCAS sharpening — draws the final picture at your display's own resolution, in any game: a game under Wine draws at its window's size, half the display's pixels each way on a Retina Mac, and macOS otherwise stretches it with a plain bilinear filter. Edges come out about twice as sharp. It holds no frame back, so it adds no latency; it costs about 1.5 ms of GPU time a frame on an M4 at 3024×1964 (measured), less on Pro and Max chips.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if config.frameGenChoice != .off {
                Toggle("Smooth Motion in heavy scenes", isOn: $config.smoothMotion)
                if config.smoothMotion {
                    Picker("Smooth Motion", selection: $config.smoothMotionStyle) {
                        ForEach(UpscalerConfig.SmoothMotionStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
                Text("Where the game can only make 15 fps up to half your display's rate — a heavy area — Anvil makes a frame for each of the game's, so 40 fps of the game's is shown as 80. It starts within three of the game's frames of it slowing down, so a heavy scene coming into view isn't a sudden drop to half. With FSR 3 to the display. On a MacBook Pro's ProMotion display from 15 to 60 fps; on a 60 Hz display, such as a MacBook Air's, from 15 to 30. On battery too.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Lowest latency, the default: each of the game's frames is shown the moment it's ready, exactly as without Smooth Motion, and a frame made ahead of it — the picture carried on along its motion — is shown halfway to the next. Nothing real waits for anything made, so controller, keyboard and mouse answer as fast as the game itself allows. Where the motion suddenly turns, the made frame is a little off and the next real frame puts it right. Smoothest picture: the frame is made between two of the game's, from both, so it's right even where the motion turns — but each of the game's frames reaches the screen half a frame later for it: 20 ms at 25 fps, more the lower it goes. Either way, where the two frames disagree over much of the picture (reflections, heat, flames, motion too fast to follow) the real frame is shown instead of a made one that would warp.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Lower latency at low frame rates", isOn: $config.lowLatencyAtLowFPS)
            Text("When the game can't keep up — under 55 fps with your Mac's GPU working flat out — it normally starts its next frame at once, and that frame then waits behind the last on the GPU: what you do reaches the screen about two of its frames later. With this on, Anvil starts each frame only as the GPU is about to finish the last, so it's made from your controls a moment later. Measured on Anvil's test game at 18–19 fps: 15–25% less delay from a frame's start to the screen (10–12% with Smooth Motion), for 7–12% fewer frames of the game's own. A trade, so it's yours to make. Off by default.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Guardian", isOn: $config.guardian)
            Text("A small part of Anvil inside the game that wakes every few seconds while you play and makes sure what Anvil does is working: that frames keep reaching the screen, that Smooth Motion isn't costing the game its own frames, and that nothing switches back and forth. It also learns what runs best on your Mac: now and then, for a few seconds, it shows the game's own frames without Smooth Motion and compares — the same scene, seconds apart — and where Smooth Motion costs more than it gives, it leaves it off there, looking again now and then. What it learns is kept for each game on this Mac. It never restarts a game or changes its settings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Sharper textures with FSR", isOn: $config.sharpTextures)
            Text("While FSR upscales, the game's textures are sampled as sharp as the display's own size would make them — a mip level sharper for each halving, as AMD's FSR guidance asks — with 8× anisotropic filtering for surfaces seen at an angle. Shadow maps, the interface and lookup textures are left alone. Takes effect at the game's next start.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Frame generation", selection: $config.frameGenChoice) {
                ForEach(UpscalerConfig.FrameGenChoice.allCases) { Text($0.title).tag($0) }
            }
            Text("When the game is below the display's rate, Anvil makes the frames in between from the motion it measures between the game's own — no support from the game needed. At 60 fps that's 60 of the game's frames and 60 generated: 120 on the display. It stays out of the way when the game fills the display itself. On a ProMotion display, which shows the game's own frames evenly at any rate, it's used only where it looks clean: a game holding about 66–76 fps, short of an even 80 — never in a game's first 30 seconds, below 60, or in a long session (on battery, by default), where an even 80 of the game's own frames is kept.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if config.frameGenChoice != .off {
                Label(config.frameGenChoice == .lowLatency
                      ? "Lowest latency predicts each frame forward from the last two, so nothing waits for a later frame: about 6 ms more from drawing to the display at 60 fps (measured), from keeping the frames evenly spaced."
                      : "Smoothest builds each frame between two of the game's with Apple's MetalFX: a better frame, but the newer one waits for it — a whole frame more latency than lowest latency.",
                      systemImage: "timer")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Generated frames come from the picture alone, not the game's own motion data, so fast motion and on-screen text can show a little smearing. The game's own frames are never changed, and the frame rate Anvil measures for Auto-Tune and its checks is the game's own.",
                      systemImage: "eye")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Capability

    @ViewBuilder
    private var capabilitySection: some View {
        if let game {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: config.capability.scanned ? "doc.text.magnifyingglass" : "questionmark.circle")
                    .foregroundStyle(config.capability.scanned ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(config.capability.scanned ? "What this game supports" : "Not scanned yet")
                        .font(.callout).bold()
                    Text(config.capability.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(config.capability.scanned ? "Rescan" : "Scan") {
                    config.capability = upscalers.scan(gameAt: game.executablePath)
                    // A forced injection keeps its mode whatever the game has: the scan no longer
                    // counts Anvil's injected FidelityFX as the game's, and switching away would
                    // hide the injection's own Remove button.
                    if !config.forceInjection && !config.capability.supports(config.mode) {
                        config.mode = config.capability.bestAvailableMode
                    }
                }
            }
        } else {
            Text("Set a default here for the whole container. Each game can scan its own files and pick the best mode it actually supports.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Group {
            Picker("Upscaler", selection: $config.mode) {
                ForEach(UpscalerMode.choices) { mode in
                    Text(mode.title).tag(mode)
                }
                // A retired mode still set shows as itself until another is chosen; it runs as FSR 3 for every game.
                if !UpscalerMode.choices.contains(config.mode) {
                    Text(config.mode.title + " — retired, runs as FSR 3").tag(config.mode)
                }
            }
            .task(id: game?.executablePath) {
                guard let exe = game?.executableURL else { antiCheat = []; return }
                antiCheat = await Task.detached { AntiCheat.detect(forExecutable: exe) }.value
            }

            Text(config.mode.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if config.mode == .fsr3Every {
                fsr3Status
            } else if config.mode.isBuiltIn {
                Label("AMD's FSR shaders are already compiled into Anvil. Nothing to download, nothing to point at.",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("This mode only does something in a game that already ships FSR, DLSS or XeSS — it needs motion vectors and depth from the engine. “FSR 3 — every game” measures the motion itself and needs no files.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let game, !antiCheat.isEmpty {
                Label("\(game.title) uses \(antiCheat.map(\.name).joined(separator: " and ")), so Anvil never puts files into its folder — a library that isn't the game's own is what anti-cheat flags, and that can get an account banned. “FSR 3 — every game” changes no files and works here.",
                      systemImage: "shield.lefthalf.filled")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let game, let manifest = upscalers.injectionManifest(forGameAt: game.executablePath) {
                // Left by the retired modes' Force injection: libraries of AMD's in the game's folder. Anvil takes them
                // out once at 0.62's first start; this is for any that couldn't be.
                HStack {
                    Label("\(manifest.copied.count) upscaler librar\(manifest.copied.count == 1 ? "y" : "ies") Anvil injected are still in \(game.title)'s folder",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Remove") {
                        do {
                            try upscalers.removeInjection(fromGameAt: game.executablePath)
                            installNote = "Removed. Original files restored."
                            installError = nil
                        } catch {
                            installError = error.localizedDescription
                        }
                    }
                    .controlSize(.small)
                }
            }

            if config.mode.requiresGameSupport {
                Label("This mode needed a library of AMD's in the game's folder and did nothing without one, so it runs as FSR 3 for every game. A game's own DLSS, XeSS or FSR is chosen under “The Game's Own Upscaler” on its Performance tab.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    /// FSR 3 for this game, as Graphics Prep's test at its sizes found it.
    @ViewBuilder
    private var fsr3Status: some View {
        Label("Anvil's FSR 3 and AMD's FSR 1 shaders are compiled into Anvil; nothing to download. It runs in any game whose frames D3DMetal draws.",
              systemImage: "checkmark.seal.fill")
            .font(.caption).foregroundStyle(.green)
            .fixedSize(horizontal: false, vertical: true)
        if let game {
            let prep = GraphicsPrep.stored(gameID: game.id)
            if let text = prep?.fsr3Text, let test = prep?.fsr3 {
                Label("\(game.title), tested by Graphics Prep at \(GraphicsPrepRunner.pretty(prep?.gameSize ?? "")) → \(GraphicsPrepRunner.pretty(prep?.shownSize ?? "")): \(text)",
                      systemImage: test.better && prep?.fsr3Off != true ? "checkmark.circle" : "minus.circle")
                    .font(.caption).foregroundStyle(test.better && prep?.fsr3Off != true ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Graphics Prep tests it at \(game.title)'s sizes before its next start. Until then it runs wherever the game is upscaled.",
                      systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Label("For more frames, choose a lower resolution in the game's own settings: FSR 3 takes whatever it draws to the display, and frame generation fills in between. Games with FSR, DLSS or XeSS of their own can also turn that on in their menus.",
              systemImage: "speedometer")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Quality

    private var qualitySection: some View {
        Group {
            // FSR 3 takes whatever size the game draws at: there is no render scale to choose.
            if config.mode != .fsr3Every {
                Picker("Quality mode", selection: $config.quality) {
                    ForEach(UpscaleQuality.allCases) { q in
                        Text(q.title).tag(q)
                    }
                }
                HStack {
                    Text(config.quality.summary)
                    Spacer()
                    Text("renders \(Int(config.quality.pixelFraction * 100))% of the pixels")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Sharpening")
                    Spacer()
                    Text("\(Int(config.sharpness * 100))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $config.sharpness, in: 0...1)
                Text(config.mode == .fsr3Every
                     ? "RCAS, as the game's frames are upscaled. Where FSR 3 runs at the display's own size, at half this strength — there it only offsets the blend's softening."
                     : "Applied only while the game renders below native resolution, to offset the stretch. At native the game's own image is left exactly as it drew it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Runtimes

    private var runtimeSection: some View {
        Group {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FSR runtime").font(.callout).bold()
                    if let latest = upscalers.latest {
                        Text("\(latest.kind.title) \(latest.version) · \(latest.libraryNames.count) libraries"
                         + (latest.vector.proxyFilename.map { " · proxies \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("None installed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Add…") { addRuntime() }
            }

            ForEach(upscalers.runtimes) { rt in
                HStack {
                    Text("\(rt.kind.title) \(rt.version)").font(.caption)
                    if rt.id == upscalers.latest?.id {
                        Text("NEWEST").font(.system(size: 9)).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if let game, config.capability.hasFSR {
                        Button("Install into game") { install(rt, game: game) }
                            .controlSize(.small)
                    }
                    Button(role: .destructive) { upscalers.remove(rt) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Text("Anvil ships no upscaler binaries — they're AMD's, under AMD's licence. Download the FidelityFX SDK from AMD (GPUOpen) and point Anvil at the folder of DLLs; it reads the version from the files themselves, so a newer release than 3.1.5 works the day it lands with no update to Anvil. Installing into a game backs up every file it replaces, and uninstalling puts the originals back byte for byte.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = installNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let err = installError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addRuntime() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder containing the FidelityFX DLLs."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rt = try upscalers.installRuntime(from: url)
            installError = nil
            installNote = "Added FidelityFX \(rt.version)."
        } catch {
            installNote = nil
            installError = error.localizedDescription
        }
    }

    private func install(_ rt: FSRRuntime, game: Game) {
        do {
            try upscalers.install(rt, intoGameAt: game.executablePath)
            installError = nil
            installNote = "Installed FidelityFX \(rt.version) into \(game.title). Originals backed up."
        } catch {
            installNote = nil
            installError = error.localizedDescription
        }
    }
}
