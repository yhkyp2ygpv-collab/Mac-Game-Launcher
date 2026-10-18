import SwiftUI

/// Auto-Tune on a game's Performance tab: pick what "best" means, and Anvil measures the
/// game with each setup and keeps the one that meets it.
struct AutoTuneSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var tuner = Tuner.shared
    @State private var confirmTest = false
    @State private var message: String?

    private var game: Game? { library.games.first { $0.id == gameID } }
    private var container: Container? { game.flatMap { library.container(id: $0.containerID) } }
    private var state: TuneState? { game.flatMap { tuner.state(for: $0) } }

    private var goal: Binding<TuneGoal> {
        Binding(
            get: { state?.isActive == true ? state!.goal : (game?.tuneGoal ?? state?.goal ?? .smooth) },
            set: { new in
                guard var g = game else { return }
                g.tuneGoal = new
                library.update(g)
            })
    }

    var body: some View {
        if let game, let container {
            SwiftUI.Section {
                Picker("Goal", selection: goal) {
                    ForEach(TuneGoal.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .disabled(state?.isActive == true)
                note(goal.wrappedValue.summary)

                if let why = tuner.unavailableReason(for: game) {
                    Label(why, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                } else {
                    status(game, container)
                }

                if let state, state.trials.contains(where: { TunePlanner.ladder(state.space).contains($0.setup) }) {
                    results(state)
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Auto-Tune")
            } footer: {
                note(explanation(game, container))
            }
            .confirmationDialog("Test \(game.title) now?", isPresented: $confirmTest) {
                // Testing again for the same goal measures afresh; a new goal reuses
                // whatever was already measured.
                Button("Start Test") { start(game, quick: true, fresh: state?.mode == .finished && state?.goal == goal.wrappedValue) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(testMessage(game, container))
            }
        }
    }

    // MARK: Status and actions

    @ViewBuilder
    private func status(_ game: Game, _ container: Container) -> some View {
        let running = launcher.isRunning(game)
        switch state?.mode {
        case .quickTest?:
            progress(game, testing: true)
            HStack {
                Button("Stop Test", role: .destructive) { tuner.stop(game) }
                if (state?.trials.contains { $0.minutes >= Tuner.quickMinutes } ?? false) {
                    Button("Decide Now") { tuner.finishNow(game) }
                }
            }
        case .whilePlaying?:
            progress(game, testing: false)
            HStack {
                Button("Test Now Instead") { switchToQuickTest(game) }.disabled(running)
                if (state?.trials.contains { $0.minutes >= 1 } ?? false) {
                    Button("Decide Now") { tuner.finishNow(game) }
                }
                Button("Stop", role: .destructive) { tuner.stop(game) }
            }
        case .paused?:
            Label(state?.pausedReason ?? "The test is paused.", systemImage: "pause.circle")
                .font(.callout)
            HStack {
                Button("Continue Test") { tuner.resume(game) }.disabled(running)
                if (state?.trials.contains { $0.minutes >= 1 } ?? false) {
                    Button("Decide Now") { tuner.finishNow(game) }
                }
                Button("Stop", role: .destructive) { tuner.stop(game) }
            }
        case .finished?:
            if let winner = state?.winner {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tuned for \(state?.goal.title ?? ""): \(winner.title)").font(.callout).bold()
                        if let reason = state?.winnerReason {
                            Text(reason.prefix(1).uppercased() + reason.dropFirst() + ".")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let date = state?.finishedAt {
                            Text("Decided \(date.formatted(.relative(presentation: .named))); in use from the next launch.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            if let stale = tuner.staleness(for: game, container: container) {
                Label(stale + " Testing again would confirm it still holds.", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            if goal.wrappedValue != state?.goal {
                Text("The goal has changed since this was decided. Test again to tune for \(goal.wrappedValue.title) — setups already measured are reused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            startButtons(game, again: true, running: running)
        default:
            if state?.mode == .stopped {
                Text(state?.winner.map { "Stopped. The game keeps what Auto-Tune chose before: \($0.title)." }
                     ?? "Stopped. The game runs with its own settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            startButtons(game, again: false, running: running)
        }
    }

    private func startButtons(_ game: Game, again: Bool, running: Bool) -> some View {
        HStack {
            Button {
                confirmTest = true
            } label: {
                Label(again ? "Test Again" : "Test Now", systemImage: "gauge.with.dots.needle.67percent")
            }
            .disabled(running)
            .help(running ? "Close the game first — each test starts it with different settings." : "")
            Button("Tune While I Play") {
                start(game, quick: false, fresh: again && state?.goal == goal.wrappedValue)
            }
            if again {
                Button("Clear Results", role: .destructive) { tuner.reset(game); message = nil }
            }
        }
    }

    private func progress(_ game: Game, testing: Bool) -> some View {
        let state = self.state
        let current = state?.current
        let needed = testing ? Tuner.quickMinutes : Tuner.playingMinutes
        let measured = (current.flatMap { state?.trial($0)?.minutes } ?? 0)
        let liveMinutes = tuner.live[game.id]
        let shown = min(liveMinutes ?? measured, needed)
        let done = state?.trials.filter { $0.minutes >= needed }.count ?? 0
        let total = max(state.map { TunePlanner.expectedCount($0.space) } ?? 1, done + 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(testing ? "Testing" : "Tuning while you play").font(.callout).bold()
                Spacer()
                Text("Setup \(min(done + 1, total)) of about \(total)").font(.caption).foregroundStyle(.secondary)
            }
            if let current {
                Text(current.title).font(.callout)
            }
            ProgressView(value: shown, total: needed)
            Text(testing
                 ? (launcher.isRunning(game)
                    ? String(format: "%.1f of %.1f minutes of play measured. Load in and play or stand somewhere busy; Anvil closes the game and starts the next setup by itself.", shown, needed)
                    : "Starting the game with this setup…")
                 : String(format: "%.1f of %.0f minutes measured with this setup. Just play as usual — each session measures the next setup until there is enough to decide.", shown, needed))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Results

    private func results(_ state: TuneState) -> some View {
        let ladder = Set(TunePlanner.ladder(state.space))
        let rows = state.trials.filter { ladder.contains($0.setup) }.sorted { $0.setup.qualityRank < $1.setup.qualityRank }
        return VStack(alignment: .leading, spacing: 6) {
            Text("MEASURED").font(.system(size: 9)).bold().foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Setup")
                    Text("80+").gridColumnAlignment(.trailing)
                    Text("Typical").gridColumnAlignment(.trailing)
                    Text("Could make").gridColumnAlignment(.trailing)
                    Text("1% low").gridColumnAlignment(.trailing)
                    Text("Hitches").gridColumnAlignment(.trailing)
                    Text("Played").gridColumnAlignment(.trailing)
                }
                .font(.caption2.bold()).foregroundStyle(.secondary)
                ForEach(rows, id: \.setup) { trial in
                    let s = trial.stats
                    let isWinner = state.mode == .finished && state.winner == trial.setup
                    let isCurrent = state.isActive && state.current == trial.setup
                    GridRow {
                        HStack(spacing: 5) {
                            if isWinner { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if isCurrent { Image(systemName: "record.circle").foregroundStyle(Color.accentColor) }
                            Text(trial.setup.shortTitle)
                        }
                        Text(s.map { String(format: "%.0f%%", $0.shareAt80 * 100) } ?? "—")
                        Text(s.map { String(format: "%.0f fps", $0.typicalFPS) } ?? "—")
                        Text(s.map { String(format: "%.0f fps", $0.capacity) } ?? "—")
                        Text(s.map { String(format: "%.0f fps", $0.onePercentLow) } ?? "—")
                        Text(s.map { String(format: "%.1f/min", $0.hitchesPerMinute) } ?? "—")
                        Text(String(format: "%.1f min", trial.minutes))
                    }
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(isWinner ? .bold : .regular)
                }
            }
            note("80+ is the share of play at 80 fps or more. Typical is what the display showed half the time; Could make is what the game managed on its own, before any pacing — the fairest comparison of how heavy a setup is. Scenes differ between sessions, so small differences are within noise.")
        }
        .padding(.vertical, 4)
    }

    // MARK: Words

    private func explanation(_ game: Game, _ container: Container) -> String {
        let space = tuner.space(for: game, container: container, goal: goal.wrappedValue)
        let ladder = TunePlanner.ladder(space)
        var text: String
        if !space.levels.isEmpty {
            text = "Anvil tries \(game.title)'s own graphics at " + ladder.map { $0.graphics?.title ?? "" }.joined(separator: ", ")
                + " — Light turns off the heaviest effects, Medium the ones that cost most for what they show, Full is the game's own."
        } else if space.canHalveResolution {
            text = "Anvil tries this game at full resolution and at half, upscaled."
        } else {
            text = "Nothing Anvil can change makes this game faster or better-looking beyond its pacing, which the goal sets."
        }
        text += " Frame pacing follows the goal. Only real play is measured — not the menus or the load — and everything happens on this Mac, online or offline. Results are kept and reused until the game, its engine or macOS changes."
        return text
    }

    private func testMessage(_ game: Game, _ container: Container) -> String {
        let space = tuner.space(for: game, container: container, goal: goal.wrappedValue)
        let n = TunePlanner.expectedCount(space)
        return "Anvil starts \(game.title) \(n == 1 ? "once" : "up to \(n + 1) times"), each time with a different setup. Each time, load into your game and play or stand somewhere busy — the same place each time is best. After about 90 seconds of play Anvil closes the game and starts the next setup. Nothing you do during a test needs saving. At the end the best setup for \(goal.wrappedValue.title) becomes the game's settings."
    }

    private func start(_ game: Game, quick: Bool, fresh: Bool = false) {
        var g = game
        g.tuneGoal = goal.wrappedValue
        library.update(g)
        do {
            let started = try tuner.start(g, goal: goal.wrappedValue, quickTest: quick, fresh: fresh)
            message = started ? nil : "Nothing Anvil can change makes this game faster or better-looking, so there is nothing to test — its frame pacing has been set for \(goal.wrappedValue.title)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func switchToQuickTest(_ game: Game) {
        tuner.stop(game)
        start(game, quick: true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The best container settings for a game, on its Advanced tab.
struct BestContainerSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var launcher: Launcher
    @State private var analysis: GameAnalysis?
    @State private var confirmEngine: ContainerAdvisor.EngineChoice?
    @State private var applied: String?

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        if let game, let container = library.container(id: game.containerID) {
            SwiftUI.Section {
                if let analysis {
                    content(game, container, analysis)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the game…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Best Container for This Game")
            } footer: {
                Text("Worked out on this Mac from the game's own files and the engines installed here — no connection needed. Auto-Tune on the Performance tab then measures what only the game itself can show.")
                    .font(.caption)
            }
            .task(id: game.executablePath) {
                let url = game.executableURL
                analysis = await Task.detached(priority: .userInitiated) { GameAnalysis.cached(for: url) }.value
                    ?? GameAnalysis(apis: [], primary: nil, engine: .other, is64Bit: true, rendersAtWindowSize: false)
            }
            .confirmationDialog("Switch \(container.name) to \(confirmEngine?.name ?? "")?",
                                isPresented: .constant(confirmEngine != nil), presenting: confirmEngine) { choice in
                Button("Switch Engine") { switchEngine(choice, game: game) }
                Button("Cancel", role: .cancel) { confirmEngine = nil }
            } message: { choice in
                Text("\(choice.reason) Anvil takes a snapshot of the container first, and switches back by itself if the game doesn't start or crashes on the new engine. The container keeps its saves and settings; the first start takes a little longer while Wine updates it. Every game in “\(container.name)” uses the engine.")
            }
        }
    }

    @ViewBuilder
    private func content(_ game: Game, _ container: Container, _ analysis: GameAnalysis) -> some View {
        let goal = game.tuneGoal ?? Tuner.shared.state(for: game)?.goal ?? .smooth
        let others = library.games(in: container).filter { $0.id != game.id }.map(\.title)
        let advice = ContainerAdvisor.advise(game: game, container: container, goal: goal, analysis: analysis,
                                             engines: ContainerAdvisor.engines(runtimes.runtimes), otherGames: others,
                                             displayIsProMotion: DisplayProfile.steadyModeApplies)
        LabeledContent("This game", value: analysis.summary)
        LabeledContent("Goal", value: goal.title)
        if advice.isOptimal {
            Label("“\(container.name)” is already set up the best way for this game.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
        ForEach(advice.changes) { change in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(change.title).font(.callout)
                    Spacer()
                    Text(change.from).foregroundStyle(.secondary).strikethrough()
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(change.to).bold()
                }
                Text(change.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 1)
        }
        if let engine = advice.engine {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Engine").font(.callout)
                    Spacer()
                    Button("Switch to \(engine.name)…") { confirmEngine = engine }
                        .disabled(launcher.isRunning(game))
                }
                Text(engine.reason + " Never switched without asking.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(advice.notes, id: \.self) { note in
            Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        if !others.isEmpty && !advice.changes.isEmpty {
            Label("“\(container.name)” is shared with \(others.joined(separator: ", ")); these settings apply to \(others.count == 1 ? "it" : "them") too.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if !advice.changes.isEmpty {
            Button {
                library.update(advice.recommended)
                AnvilLog.write("best container: “\(container.name)” set up for \(game.title) (\(goal.title)) — "
                               + advice.changes.map { "\($0.title) \($0.from) → \($0.to)" }.joined(separator: ", "))
                applied = "Applied \(advice.changes.count) change\(advice.changes.count == 1 ? "" : "s"); in use from the next launch."
            } label: {
                Label("Apply Best Settings", systemImage: "wand.and.stars")
            }
            .disabled(launcher.isRunning(game))
        }
        if let applied {
            Text(applied).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func switchEngine(_ choice: ContainerAdvisor.EngineChoice, game: Game) {
        confirmEngine = nil
        guard let container = library.container(id: game.containerID) else { return }
        applied = "Taking a snapshot of “\(container.name)” first…"
        Task {
            do {
                try await Autopilot.shared.switchEngine(for: game, to: choice.runtimeID)
                applied = "“\(container.name)” now uses \(choice.name), with a snapshot of how it was. If the game doesn't start on it, Anvil switches back by itself; Auto-Tune measures it afresh."
            } catch {
                applied = "Not switched: the snapshot couldn't be taken (\(error.localizedDescription))."
            }
        }
    }
}
