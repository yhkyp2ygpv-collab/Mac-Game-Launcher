import SwiftUI

/// The wait before a game starts while Graphics Prep runs, and the result of a Prepare Now:
/// each step as it goes, with a way out.
struct GraphicsPrepPanel: View {
    let activity: GraphicsPrepRunner.Activity
    @ObservedObject private var runner = GraphicsPrepRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preparing \(activity.title)'s graphics")
                        .font(.headline)
                    Text(activity.beforeLaunch
                         ? "Before it starts, because \(activity.reason). Once — and again only when Anvil, macOS or the game's picture changes."
                         : "\(activity.reason).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 11) {
                ForEach(activity.steps) { step in row(step) }
            }
            if let outcome = activity.outcome {
                Text(outcome)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if !activity.finished {
                    Button(activity.beforeLaunch ? "Skip and Start" : "Stop") { runner.skip() }
                        .keyboardShortcut(.cancelAction)
                } else if !activity.beforeLaunch {
                    Button("Done") { runner.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 4)
    }

    private func row(_ step: GraphicsPrepRunner.Step) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon(step.state)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .foregroundStyle(step.state == .waiting ? .secondary : .primary)
                if let result = step.result {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: GraphicsPrepRunner.Step.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// The panel over a window, the window dimmed behind it: the main window's, or a game's page
/// (a sheet, which would otherwise cover the main window's copy).
private struct GraphicsPrepOverlay: ViewModifier {
    let sheetGameID: UUID?
    @ObservedObject private var runner = GraphicsPrepRunner.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if let activity = runner.active, shows(activity) {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        GraphicsPrepPanel(activity: activity)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: runner.active?.gameID)
            .onAppear { if let id = sheetGameID { runner.sheetGameID = id } }
            .onDisappear { if let id = sheetGameID, runner.sheetGameID == id { runner.sheetGameID = nil } }
    }

    private func shows(_ activity: GraphicsPrepRunner.Activity) -> Bool {
        if let id = sheetGameID { return activity.gameID == id }
        return runner.sheetGameID != activity.gameID
    }
}

extension View {
    /// Graphics Prep's panel over this view while it runs. `sheetFor`: the game whose page this is.
    func graphicsPrepOverlay(sheetFor gameID: UUID? = nil) -> some View {
        modifier(GraphicsPrepOverlay(sheetGameID: gameID))
    }
}

/// A game's Graphics Prep, on its Performance tab: whether it runs before a start, what the
/// last one found, and Prepare Now.
struct GraphicsPrepSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var runner = GraphicsPrepRunner.shared
    @State private var prep: GraphicsPrep?
    @State private var pending: String?

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        SwiftUI.Section {
            if let game {
                Toggle("Prepare graphics before starting", isOn: Binding(
                    get: { game.prepareGraphics },
                    set: { var g = game; g.prepareGraphics = $0; library.update(g) }))
                Toggle("Memory warm-up", isOn: Binding(
                    get: { game.warmMemory },
                    set: { var g = game; g.warmMemory = $0; library.update(g) }))
                Text("As the game starts, the parts of its data you play most are read into your Mac's spare memory, so places you've been before load from memory instead of the disk — fewer stutters as you reach them. Anvil notes which parts those are while you play. It uses at most half of the memory that's free beyond 4 GB (no more than 8 GB, half that on battery), only reads, and never gets in the way of the game's own reading.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let container = library.container(id: game.containerID), let plan = GraphicsPrepRunner.rayTracingPlan(for: game, container: container) {
                    Toggle("Ray tracing", isOn: Binding(
                        get: { rayTracingOn(game, container: container) },
                        set: { var g = game; g.rayTracing = $0; library.update(g) }))
                    Text(plan + " Set as the game starts; off makes the heaviest places a little quicker.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let prep {
                rows(prep)
            } else {
                Text("Not prepared yet — Anvil prepares it before its next start\(game?.prepareGraphics == false ? " if you switch that on, or now" : ""), in a few seconds.")
                    .foregroundStyle(.secondary)
            }
            if prep != nil, let pending, game?.prepareGraphics == true {
                LabeledContent("Next start", value: "Prepares again: \(pending)")
            }
            Button(runner.active?.gameID == gameID && runner.active?.finished == false ? "Preparing…" : "Prepare Now") { prepareNow() }
                .disabled(busy)
            note("Before the game starts, Anvil compiles its own FSR 1, FSR 3 and frame generation for this Mac's GPU, tests FSR on it at the game's size and in its colour format, and keeps the quicker way for this game — so nothing of Anvil's compiles while you play, and FSR takes as little of each frame as it can here. FSR 3 is tested on a moving scene against FSR 1 and a supersampled picture, and used for the game where it came out better. The game's own shaders are D3DMetal's: compiled the first time the game uses each one and kept from then on, which nothing can do before the game asks for them.")
        } header: {
            Text("Graphics Prep")
        }
        .task(id: gameID) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .graphicsPrepChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .graphicsScanChanged)) { _ in reload() }
    }

    /// What the switch shows: as set, or what Anvil does by itself — the game's own reflections on unless its graphics
    /// are at Light; D3DMetal's hardware ray tracing as Launcher decides.
    private func rayTracingOn(_ game: Game, container: Container) -> Bool {
        if let chosen = game.rayTracing { return chosen }
        if GameTuning.profile(for: game)?.rayTraced != nil { return Tuner.shared.graphicsLevel(for: game) != .light }
        return Launcher.rayTracing(for: game, container: container).on
    }

    private var busy: Bool {
        guard let game else { return true }
        return (runner.active != nil && runner.active?.finished == false) || launcher.launching != nil || launcher.isRunning(game)
    }

    @ViewBuilder
    private func rows(_ p: GraphicsPrep) -> some View {
        LabeledContent("Prepared") {
            Text(p.status == .ready
                 ? "\(p.at.formatted(date: .abbreviated, time: .shortened)), in \(String(format: "%.1f", p.seconds)) s, for the \(p.gpu)"
                 : "Didn't finish: \(p.failure ?? "no reason given") — the game starts as before")
                .multilineTextAlignment(.trailing)
        }
        if p.status == .ready {
            LabeledContent("Anvil's shaders") { Text(p.pipelinesText).multilineTextAlignment(.trailing) }
            LabeledContent("FSR") { Text(p.fsrText).multilineTextAlignment(.trailing) }
            if let fsr3 = p.fsr3Text {
                LabeledContent("FSR 3") { Text(fsr3).multilineTextAlignment(.trailing) }
            }
            if p.frameGenerationOf > 0 {
                LabeledContent("Frame generation", value: "\(p.frameGeneration) of \(p.frameGenerationOf) pipelines compiled")
            }
            LabeledContent("Tested at") {
                Text("\(GraphicsPrepRunner.pretty(p.gameSize)) → \(GraphicsPrepRunner.pretty(p.shownSize)), \(GraphicsPrep.formatName(p.key.pixelFormat))"
                     + (p.estimated ? " — from the display until a session" : ""))
                    .multilineTextAlignment(.trailing)
            }
        }
        if let cache = p.gameCacheText {
            LabeledContent("The game's own shaders") { Text(cache).multilineTextAlignment(.trailing) }
        }
        LabeledContent("Seen in play") {
            Text(p.seenText ?? "After its next session").multilineTextAlignment(.trailing)
        }
    }

    private func reload() {
        prep = GraphicsPrep.stored(gameID: gameID)
        pending = GraphicsPrep.reason(gameID: gameID)
    }

    private func prepareNow() {
        guard let game, let container = library.container(id: game.containerID),
              let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) ?? RuntimeManager.shared.defaultRuntime else { return }
        Task {
            _ = await runner.run(game: game, container: container, runtime: runtime, beforeLaunch: false,
                                 reason: "On request — the game's next start uses what this finds")
            reload()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
