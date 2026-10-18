import SwiftUI

/// What Anvil found about a game's last session, at the top of its Overview tab.
struct HealthSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var autopilot = Autopilot.shared
    @ObservedObject private var catalog = EngineCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEngine = false
    @State private var showEpicSignIn = false
    @State private var switching: String?

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        if let game {
            SwiftUI.Section {
                if let work = autopilot.engineWork[gameID] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(work).font(.callout)
                        }
                        if case .downloading(let fraction) = catalog.state, fraction > 0 {
                            ProgressView(value: fraction)
                            Text(String(format: "%.0f%% downloaded", fraction * 100)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let report = autopilot.report(for: game) {
                    summary(report)
                    ForEach(report.findings) { finding in
                        row(finding, game: game)
                    }
                    if report.findings.isEmpty {
                        Label("Nothing to report from the last session.", systemImage: "checkmark.seal")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else if autopilot.checking.contains(gameID) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the last session…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Anvil checks every session when it ends: what held the frame rate back, anything that went wrong, and what it fixed.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let switching {
                    Text(switching).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Autopilot", isOn: Binding(
                    get: { game.autopilot },
                    set: { value in
                        guard var g = library.games.first(where: { $0.id == gameID }) else { return }
                        g.autopilot = value
                        library.update(g)
                    }))
                Text(game.autopilot
                     ? "On: after each session Anvil fixes what it safely can, starts Auto-Tune when there's something to measure, and moves a game that can't hold 80 to the newest D3DMetal — with a snapshot first, and back by itself if the game doesn't start, crashes or runs slower."
                     : "Off: Anvil still checks each session and shows what it finds, but changes nothing by itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                HStack {
                    Text("Health")
                    Spacer()
                    Button {
                        Task { await autopilot.check(gameID: gameID, outcome: nil, announce: false) }
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(autopilot.checking.contains(gameID) || launcher.isRunning(game))
                }
            }
            .sheet(isPresented: $showEpicSignIn) { EpicSignInView() }
            .confirmationDialog(engineTitle(game), isPresented: $confirmEngine) {
                Button("Switch Engine") { switchEngine(game) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Anvil takes a snapshot of the container first. If the game doesn't start or crashes on the new engine, the container goes back to the one it has now by itself. The first start takes a little longer while Wine updates the container.")
            }
        }
    }

    private func summary(_ report: HealthReport) -> some View {
        let when = report.checkedAt.formatted(.relative(presentation: .named))
        let played = report.playMinutes > 0 ? " · \(GameDoctor.minutesText(report.playMinutes)) of play" : ""
        return Text("Last session checked \(when)\(played): \(report.headline).")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func row(_ f: HealthFinding, game: Game) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(f.kind))
                .foregroundStyle(color(f.kind))
                .font(.body)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).font(.callout).bold()
                Text(f.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = f.fix {
                    Button(fix.label) { run(fix, finding: f, game: game) }
                        .controlSize(.small)
                        .disabled(launcher.isRunning(game) && fix != .showEngines)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func run(_ fix: HealthFinding.Fix, finding: HealthFinding, game: Game) {
        switch fix {
        case .switchEngine:
            confirmEngine = true
        case .epicSignIn:
            showEpicSignIn = true
        case .showEngines:
            dismiss()
            autopilot.apply(fix, findingID: finding.id, gameID: game.id)
        default:
            autopilot.apply(fix, findingID: finding.id, gameID: game.id)
        }
    }

    /// The newest D3DMetal installed that the game's container isn't using.
    private func newerEngine(for game: Game) -> Runtime? {
        guard let container = library.container(id: game.containerID) else { return nil }
        let current = runtimes.runtime(id: container.runtimeID)
        let rank = current?.hasD3DMetal == true ? (current?.d3dMetalRank ?? []) : []
        return runtimes.runtimes
            .filter { $0.isUsable && $0.hasD3DMetal && $0.id != container.runtimeID && rank.lexicographicallyPrecedes($0.d3dMetalRank) }
            .max { $0.d3dMetalRank.lexicographicallyPrecedes($1.d3dMetalRank) }
    }

    private func engineTitle(_ game: Game) -> String {
        guard let engine = newerEngine(for: game), let container = library.container(id: game.containerID) else { return "Switch engine?" }
        return "Switch “\(container.name)” to \(engine.displayName)?"
    }

    private func switchEngine(_ game: Game) {
        guard let engine = newerEngine(for: game) else { return }
        switching = "Taking a snapshot first…"
        Task {
            do {
                try await autopilot.switchEngine(for: game, to: engine.id)
                switching = nil
            } catch {
                switching = "Not switched: the snapshot couldn't be taken (\(error.localizedDescription))."
            }
        }
    }

    private func icon(_ kind: HealthFinding.Kind) -> String {
        switch kind {
        case .problem: "exclamationmark.triangle.fill"
        case .fixed: "wand.and.stars"
        case .advice: "lightbulb.fill"
        case .good: "checkmark.seal.fill"
        }
    }

    private func color(_ kind: HealthFinding.Kind) -> Color {
        switch kind {
        case .problem: .orange
        case .fixed: .blue
        case .advice: .yellow
        case .good: .green
        }
    }
}

/// Said once after a session, wherever Anvil is: what the check found, with the way to it.
struct HealthBanner: View {
    let banner: Autopilot.Banner
    var open: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout).bold()
                Text(banner.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Details", action: open)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
