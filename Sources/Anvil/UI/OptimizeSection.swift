import SwiftUI

/// Optimize for This Mac, at the top of a game's Performance tab (OptimizePass): every step Anvil takes for the game,
/// done now with its progress and the time left, then what the game needs.
struct OptimizeSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @ObservedObject private var runner = OptimizeRunner.shared
    @ObservedObject private var launcher = Launcher.shared

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        if let game {
            SwiftUI.Section {
                let mine = runner.activity?.gameID == gameID ? runner.activity : nil
                HStack {
                    Button(mine != nil && mine?.finished == nil ? "Optimizing…" : "Optimize for This Mac") {
                        Task { await runner.run(game) }
                    }
                    .disabled(runner.running || launcher.isRunning(game))
                    if launcher.isRunning(game) {
                        Text("After the game is closed").font(.caption).foregroundStyle(.secondary)
                    } else if runner.running && mine == nil {
                        Text("Another game is being optimized").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if mine?.finished != nil {
                        Button("Done") { runner.close() }.controlSize(.small)
                    }
                }
                if let a = mine {
                    let p = OptimizePass.progress(a.steps, within: a.within)
                    let at = (a.steps.firstIndex { $0.state == .running } ?? a.steps.count - 1) + 1
                    ProgressView(value: a.finished != nil ? 1 : p.fraction) {
                        Text(a.finished != nil
                             ? String(format: "Done in %.0f s", a.finished!.timeIntervalSince(a.started))
                             : "Step \(at) of \(a.steps.count): \(a.steps[at - 1].title)")
                            .font(.callout)
                    } currentValueLabel: {
                        Text(a.finished != nil ? "" : "\(Int((p.fraction * 100).rounded()))% · \(OptimizePass.remainingText(p.remaining))")
                            .font(.caption)
                    }
                    ForEach(a.steps) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            icon(s.state).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.title).font(.callout)
                                if let r = s.result {
                                    Text(r).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if a.finished != nil {
                        Text("What it needs").font(.headline).padding(.top, 4)
                        if a.needs.allSatisfy({ $0.kind == .fine }) {
                            Text("Nothing: everything Anvil can do for it here is done.").font(.callout)
                        }
                        ForEach(a.needs, id: \.rowID) { n in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: n.kind == .act ? "exclamationmark.circle.fill" : "checkmark.circle")
                                    .foregroundStyle(n.kind == .act ? Color.orange : Color.green).frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.title).font(.callout)
                                    Text(n.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Text("Does now what Anvil would otherwise do at the game's next start: reads its program, scans its graphics, compiles and tests Anvil's shaders on this Mac's GPU, puts in what it needs to run, keeps its translated code and shaders, and checks its Unreal Engine tuning, memory, power and heat. Then it lists what the game still needs. No connection needed. The game's own files are never changed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Optimize for This Mac")
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: OptimizePass.Step.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
