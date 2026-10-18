import SwiftUI
import AppKit

/// One game: how it ran, how to start it, and its own settings. Anything left on
/// "Inherit" follows the container, so a container stays the single place to tune an
/// engine while one awkward title can still get its own treatment.
struct GameDetailView: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var artwork: ArtworkStore
    @EnvironmentObject private var shortcuts: ShortcutStore
    /// Auto-Tune's choice shows in the Graphics picker, so the page follows it.
    @ObservedObject private var tuner = Tuner.shared
    @ObservedObject private var connectivity = Connectivity.shared
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", performance = "Performance", controller = "Controller", advanced = "Advanced"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: "info.circle"
            case .performance: "speedometer"
            case .controller: "gamecontroller"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    @AppStorage("gameDetailTab") private var tab: Tab = .overview
    @State private var error: String?
    @State private var epic: EpicLink?
    @State private var antiCheat: [AntiCheat] = []
    @State private var keepRunningSwitch: String?
    @State private var nativeSwitchPro = false
    @State private var showDataImport = false
    @State private var showEpicSignIn = false

    private var game: Binding<Game> {
        Binding(
            get: { library.games.first { $0.id == gameID } ?? Game(title: "—", executablePath: "", containerID: UUID()) },
            set: { library.update($0) }
        )
    }

    private var container: Binding<Container> {
        Binding(
            get: { library.container(id: game.wrappedValue.containerID) ?? Container(name: "—", runtimeID: "") },
            set: { library.update($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            Divider()
            Form {
                switch tab {
                case .overview: overview
                case .performance: performance
                case .controller: controller
                case .advanced: advanced
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 720, height: 760)
        // Graphics Prep's wait, when a start from this page needs it, or a Prepare Now.
        .graphicsPrepOverlay(sheetFor: gameID)
        .autoStartOverlay(sheetFor: gameID)
        // A rename typed above reaches the shortcut once, when the sheet closes.
        .onDisappear {
            if let stored = library.games.first(where: { $0.id == gameID }) { shortcuts.refresh(for: stored) }
        }
        // Read fresh each time the sheet opens, so DLC installed elsewhere shows up.
        .task(id: game.wrappedValue.executablePath) {
            epic = EpicLink.find(for: game.wrappedValue)
            let g = game.wrappedValue
            nativeSwitchPro = await Task.detached { NativeControllerSupport.supportsSwitchPro(g) }.value
            antiCheat = await Task.detached { AntiCheat.detect(for: g) }.value
            let exe = g.executableURL
            keepRunningSwitch = await Task.detached { KeepRunning.supportedSwitch(for: exe) }.value
        }
        .sheet(isPresented: $showEpicSignIn, onDismiss: { epic = EpicLink.find(for: game.wrappedValue) }) {
            EpicSignInView()
        }
        .sheet(isPresented: $showDataImport) {
            if let container = library.container(id: game.wrappedValue.containerID) {
                SaveTransferView(container: container, game: game.wrappedValue)
            }
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    // MARK: Header

    private var header: some View {
        let g = game.wrappedValue
        let running = launcher.isRunning(g)
        return ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    if let image = artwork.banner(for: g) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ArtworkPlaceholder(title: g.title)
                    }
                }
                .clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0),
                                   .init(color: .black.opacity(0.35), location: 0.6),
                                   .init(color: .black.opacity(0.1), location: 1)],
                           startPoint: .bottom, endPoint: .top)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: game.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text(running ? "Playing now"
                     : g.playtimeDescription + (g.lastPlayed.map { " · last played \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                if let stats = g.lastSession { SessionBadge(stats: stats) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .padding(.trailing, 190)
        }
        .frame(height: 210)
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(HeroButtonStyle(prominent: false, tint: .white))
                .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if running {
                    Button {
                        if launcher.isClosing(g) { launcher.forceQuit(g) } else { launcher.quit(g) }
                    } label: {
                        Label(launcher.isClosing(g) ? "Force Quit" : "Quit Game", systemImage: "stop.fill")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: true, tint: .red))
                } else {
                    Button { play() } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: true, tint: .accentColor))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!g.exists || launcher.launching != nil)
                }
            }
            .padding(22)
        }
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        HealthSection(gameID: gameID)

        SwiftUI.Section("Launch") {
            Picker("Container", selection: game.containerID) {
                ForEach(library.containers) { Text($0.name).tag($0.id) }
            }
            TextField("Arguments", text: game.extraArgumentsRaw, prompt: Text("-dx12 -windowed"))
                .onChange(of: game.wrappedValue.extraArgumentsRaw) { _, new in
                    game.wrappedValue.arguments = new.split(separator: " ").map(String.init)
                }
            Toggle("Anvil enhancements", isOn: Binding(
                get: { !game.wrappedValue.anvilEnhancementsOff },
                set: { game.wrappedValue.anvilEnhancementsOff = !$0 }
            ))
            note(game.wrappedValue.anvilEnhancementsOff
                 ? "Off: the game starts exactly as the engine would start it — no frame pacing, overlay or controller fixes. Anvil switches this off by itself if a game only starts without them."
                 : "Frame pacing, the overlay and the controller fixes. If a game ever closes straight away with them, Anvil tries it once without and keeps them off for it if that works.")
        }

        SwiftUI.Section("Quick Launch") {
            if let shortcut = shortcuts.shortcuts[gameID] {
                LabeledContent("Shortcut in Applications") {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shortcut]) }
                        Button("Remove") { shortcuts.remove(for: game.wrappedValue) }
                    }
                }
            } else {
                Button {
                    do {
                        let app = try shortcuts.create(for: game.wrappedValue)
                        NSWorkspace.shared.activateFileViewerSelecting([app])
                    } catch {
                        self.error = "Couldn't make the shortcut: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Add Shortcut to Applications", systemImage: "square.and.arrow.down.on.square")
                }
            }
            note("A small app in Applications › Anvil Games with this game's artwork as its icon. It starts the game from Spotlight, Launchpad or the Dock with every setting here, exactly as Play does.")
        }

        SwiftUI.Section("Game Data") {
            Button {
                showDataImport = true
            } label: {
                Label("Import Saves & Game Data…", systemImage: "arrow.down.doc")
            }
            note("Brings this game's progress and settings over from Mythic, Heroic, Whisky or CrossOver. Its own saves are picked out for you; anything already here is moved aside, never overwritten.")
            GameSavesSection(gameID: gameID) { dismiss() }
        }

        AddToSteamSection(game: game.wrappedValue)

        if let note = AntiCheat.note(for: antiCheat) {
            SwiftUI.Section("Online Play") {
                Label(note, systemImage: antiCheat.allSatisfy(\.canBeAllowedUnderWine) ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(antiCheat.allSatisfy(\.canBeAllowedUnderWine) ? .orange : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        SwiftUI.Section("Offline") {
            let offline = OfflineStarts.summary(for: game.wrappedValue)
            if OfflineStarts.needsConnection(game.wrappedValue) {
                Label("Needs internet to start", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(offline.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let auto = AutoStart.summary(for: game.wrappedValue, in: library.games, networkUp: connectivity.networkUp) {
                    Label {
                        Text("Auto start: ").bold() + Text(auto)
                    } icon: {
                        Image(systemName: connectivity.networkUp ? "play.circle" : "clock.arrow.circlepath")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label(offline.text, systemImage: offline.warn ? "wifi.exclamationmark" : "wifi.slash")
                    .foregroundStyle(offline.warn ? .orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OfflineTestRows(game: game.wrappedValue)
            note("How this game's starts with no connection have gone on this Mac. Started with Offline Mode on or no connection, the game's own connections are held back. An Epic game starts with Epic's offline arguments; if that doesn't get it going, Anvil tries Epic Offline Mode's own start next, then the game's program on its own, and keeps whichever gets it playing. A game that waits with every one needs internet to start, and plays on without it once started: Auto start then starts it online whenever there's a connection, and with none waits and starts it as soon as there is — or starts another copy of it in the library that plays offline, such as its Steam edition.")
        }

        if game.wrappedValue.steamAppID != nil {
            SwiftUI.Section("Steam") {
                LabeledContent("App", value: game.wrappedValue.steamAppID ?? "")
                note("Started with Steam running and signed in beside it, in the same Windows setup, so its online play, cloud saves and achievements work. Steam closes properly after the game, finishing its cloud saves.")
            }
        }

        if let keep = keepRunningSwitch {
            SwiftUI.Section("Behind Other Apps") {
                Toggle("Keep running when another app is in front", isOn: game.keepRunningBehind)
                note("This game pauses — its loading too — whenever another app is in front. Its own \(keep) switch keeps it going, so a load finishes while you're elsewhere; Anvil holds it to 30 fps until it's back in front, so it costs little.")
            }
        }

        if let epic {
            SwiftUI.Section("Epic Games") {
                Toggle("Sign in to Epic when launching", isOn: game.epicSignIn)
                if epic.launcher == "Anvil" {
                    note("Anvil signs the game in itself, with its own copy of legendary — the open-source Epic client — so the game sees the DLC you own and uses cloud saves and achievements. No other launcher is needed. Anvil never sees your password.")
                } else {
                    note("Signed in through \(epic.launcher)'s sign-in until Anvil has its own; it takes it over at its next start. Anvil never sees your password.")
                }
                Button("Sign In to Epic Again…") { showEpicSignIn = true }
                    .controlSize(.small)
                if epic.dlc.isEmpty {
                    LabeledContent("DLC", value: "None for this game")
                } else {
                    ForEach(epic.dlc) { item in
                        LabeledContent(item.title) {
                            if item.installed {
                                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("Not installed").foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                    if epic.dlc.contains(where: { !$0.installed }) {
                        note("DLC that isn't installed here is either not owned or not downloaded yet. Anvil picks up DLC installed by any launcher the next time you open this.")
                    }
                }
            }
        }
    }

    // MARK: Performance

    @ViewBuilder
    private var performance: some View {
        AutoTuneSection(gameID: gameID)

        LearnSection(gameID: gameID)

        if let stats = game.wrappedValue.lastSession {
            SwiftUI.Section("Last Session") {
                LabeledContent("Average", value: String(format: "%.0f fps", stats.averageFPS))
                LabeledContent("At 80 fps or more", value: String(format: "%.0f%% of the time", stats.shareAt80 * 100))
                LabeledContent("At the full 120", value: String(format: "%.0f%% of the time", stats.shareAt120 * 100))
                LabeledContent("Lowest 1% low", value: String(format: "%.0f fps", stats.lowestOnePercent))
                note(String(format: "Over %.0f minutes of play, %@. Measured inside the game on every frame the display showed.",
                            stats.minutes, stats.endedAt.formatted(.relative(presentation: .named))))
            }
        }

        SwiftUI.Section("Frame Rate") {
            Picker("Pacing", selection: Binding(
                get: {
                    let fps = game.wrappedValue.targetFPSOverride ?? container.wrappedValue.targetFPS
                    return [0, 80, 60, 30].contains(fps) ? fps : 0
                },
                set: {
                    // A game with pacing of its own keeps it on the game; otherwise the
                    // container's is the game's.
                    if game.wrappedValue.targetFPSOverride != nil { game.wrappedValue.targetFPSOverride = $0 }
                    else { container.wrappedValue.targetFPS = $0 }
                }
            )) {
                Text("Up to 120 — each frame as soon as it's ready").tag(0)
                Text("Steady — 120, or an even 80 when it can't").tag(80)
                Text("Hold to 60").tag(60)
                Text("Hold to 30").tag(30)
            }
            note(pacingNote)
        }

        if let profile = GameTuning.profile(for: game.wrappedValue) {
            SwiftUI.Section("Graphics") {
                let chosen = Tuner.shared.graphicsLevel(for: game.wrappedValue)
                Picker("The game's own graphics options", selection: game.graphicsTuning) {
                    Text("Automatic — \(chosen.title) now").tag(GraphicsTuning.automatic)
                    Text("Light").tag(GraphicsTuning.light)
                    Text("Medium").tag(GraphicsTuning.medium)
                    Text("Full — exactly as the game has them").tag(GraphicsTuning.gameDefault)
                }
                let level = game.wrappedValue.graphicsTuning.level ?? chosen
                if level != .full {
                    LabeledContent("Changes") {
                        Text(profile.settings(for: level).map(\.label).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                }
                note(game.wrappedValue.graphicsTuning == .automatic
                     ? "Auto-Tune's choice for this game once it has measured it, and Medium until then. " + level.detail + ". Set before the next launch; the game's own values are kept. Anything you change afterwards in the game's own menu stays as you set it."
                     : level.detail + ". Set before the next launch; the game's own values are kept and come back at Full. Anything you change afterwards in the game's own menu stays as you set it.")
                if profile.fitsDisplay {
                    Picker("Picture", selection: game.pictureShape) {
                        ForEach(GameTuning.PictureShape.allCases) { Text($0.title).tag($0) }
                    }
                    note(game.wrappedValue.pictureShape == .whole
                         ? "Tells the game its screen is 16:9, so its menus and HUD show whole. The game takes that as the monitor's shape, so on a MacBook's taller screen the picture can come out squeezed. Set at the next launch, unless the graphics options above are at Full — exactly as the game has them."
                         : "The picture in its true proportions, filling the screen. The game lays its menus out for 16:9, so on a MacBook's taller screen it trims their left and right edges. Set at the next launch.")
                }
            }
        }

        SwiftUI.Section("Preset") {
            PresetsView(container: container, game: game.wrappedValue)
        }

        GraphicsScanSection(gameID: gameID)

        GraphicsPrepSection(gameID: gameID)

        LookCheckSection(gameID: gameID)

        SwiftUI.Section("Upscaling") {
            UpscalerEditor(config: Binding(
                get: {
                    game.wrappedValue.upscalerOverride
                        ?? library.container(id: game.wrappedValue.containerID)?.upscaler
                        ?? UpscalerConfig()
                },
                set: { game.wrappedValue.upscalerOverride = $0 }
            ), game: game.wrappedValue)
        }

        SwiftUI.Section("Overlay") {
            Toggle("Override the container's overlay", isOn: Binding(
                get: { game.wrappedValue.hudOverride != nil },
                set: { game.wrappedValue.hudOverride = $0 ? .fpsOnly : nil }
            ))
            if game.wrappedValue.hudOverride != nil {
                HUDEditor(config: Binding(
                    get: { game.wrappedValue.hudOverride ?? .fpsOnly },
                    set: { game.wrappedValue.hudOverride = $0 }
                ))
            }
        }
    }

    private var pacingNote: String {
        switch container.wrappedValue.targetFPS {
        case 80:
            return "When the game can't hold 120, frames are held to an even 80 — every one 12.5 ms apart — instead of changing between 80 and 120 with it. The hold works before each frame starts, so it adds almost no delay, and the game goes back to 120 as soon as it can. On a display without ProMotion this behaves like Up to 120."
        case 60, 30:
            return "Every frame held to this rate, evenly. For a game that cannot keep anything higher."
        default:
            return "The lowest delay: every frame reaches the screen as soon as it's ready, up to 120. On ProMotion that shows the game's own rate, so the count moves with the scene. Choose Steady for an even 80 whenever the game can't reach 120."
        }
    }

    // MARK: Controller

    /// Whether a Nintendo-style pad becomes a Pro Controller for this game.
    private var virtualPro: Bool {
        switch game.wrappedValue.padIdentity {
        case .switchPro: true
        case .automatic: nativeSwitchPro
        case .asConnected: false
        }
    }

    @ViewBuilder
    private var controller: some View {
        SwiftUI.Section("Nintendo-style Pads") {
            Picker("Show to the game as", selection: game.padIdentity) {
                ForEach(PadIdentity.allCases) { Text($0.title).tag($0) }
            }
            note(padIdentityNote)
            if !virtualPro {
                Picker("Face buttons", selection: game.faceButtons) {
                    ForEach(FaceButtonLayout.allCases) { Text($0.title).tag($0) }
                }
                note(faceButtonsNote)
            }
        }

        SwiftUI.Section("Profile") {
            Toggle("Use a controller profile just for this game", isOn: Binding(
                get: { game.wrappedValue.controllerProfileOverride != nil },
                set: { game.wrappedValue.controllerProfileOverride = $0 ? ControllerProfile() : nil }
            ))
            if game.wrappedValue.controllerProfileOverride != nil {
                ControllerEditor(profile: Binding(
                    get: { game.wrappedValue.controllerProfileOverride ?? ControllerProfile() },
                    set: { game.wrappedValue.controllerProfileOverride = $0 }
                ))
            }
        }
    }

    /// What the identity setting will do for this game, in its own terms.
    private var padIdentityNote: String {
        switch game.wrappedValue.padIdentity {
        case .automatic:
            return nativeSwitchPro
                ? "This game has its own Nintendo Switch Pro Controller support. Anvil shows your Nintendo-style pad to it as a real Pro Controller, speaking Nintendo's own protocol, and hides the Xbox-style copy — so the game uses its own Nintendo button prompts, and every button is the one printed on your pad: A is A, confirm and cancel included."
                : "This game reads controllers as Xbox pads and shows Xbox button prompts, so pads are shown to it as they are."
        case .switchPro:
            return "Nintendo-style pads are shown to this game as a Switch Pro Controller that speaks Nintendo's protocol, with no Xbox-style copy. Only a game with its own Switch Pro support can use it; any other game will see no controller."
        case .asConnected:
            return "Pads are shown to the game as Xbox-style pads, with Xbox button prompts."
        }
    }

    /// What the face-button setting will do for a game reading the pad as an Xbox pad.
    private var faceButtonsNote: String {
        switch game.wrappedValue.faceButtons {
        case .automatic, .letters:
            return "Where the game shows A, press the A on your pad: each letter on screen is the letter printed on the button."
        case .positions:
            return "The bottom button is the game's A, as on an Xbox pad, whatever letter is printed on it. The letters on screen will not match your pad."
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        BestContainerSection(gameID: gameID)

        SwiftUI.Section("Overrides") {
            Picker("Graphics backend", selection: Binding(
                get: { game.wrappedValue.backendOverride },
                set: { game.wrappedValue.backendOverride = $0 }
            )) {
                Text("Inherit from container").tag(GraphicsBackend?.none)
                ForEach(GraphicsBackend.allCases) { Text($0.title).tag(GraphicsBackend?.some($0)) }
            }
            Picker("Synchronisation", selection: Binding(
                get: { game.wrappedValue.syncOverride },
                set: { game.wrappedValue.syncOverride = $0 }
            )) {
                Text("Inherit from container").tag(SyncPrimitive?.none)
                ForEach(SyncPrimitive.allCases) { Text($0.title).tag(SyncPrimitive?.some($0)) }
            }
        }

        SwiftUI.Section("File Integrity") {
            IntegrityView(game: game.wrappedValue)
        }

        SwiftUI.Section("Executable") {
            LabeledContent("Path") {
                Text(game.wrappedValue.executablePath)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([game.wrappedValue.executableURL])
            }
        }
    }

    // MARK: Helpers

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func play() {
        let g = game.wrappedValue
        guard QuickLaunch.engine(for: g) != nil else {
            error = "This game's container or runtime is missing."
            return
        }
        // Online, offline, or once the connection is back — or another copy of it (AutoStart).
        AutoStart.shared.play(g) { chosen in
            guard let engine = QuickLaunch.engine(for: chosen) else {
                error = "\(chosen.title)'s container or runtime is missing."
                return
            }
            Task {
                do {
                    try await launcher.prepareAndLaunch(game: chosen, container: engine.container, runtime: engine.runtime)
                    dismiss()
                } catch Launcher.LaunchError.alreadyStarting {
                } catch {
                    // Surfaced rather than swallowed: a Play button that silently does
                    // nothing is indistinguishable from one that is broken.
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
