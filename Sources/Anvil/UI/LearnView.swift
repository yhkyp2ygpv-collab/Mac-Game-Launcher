import SwiftUI

/// Learn on a game's Performance tab: what Anvil has learned of how the game runs on this Mac, what each of
/// its settings costs here, and what each setup would do over the play seen (LearnStore).
struct LearnSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @ObservedObject private var store = LearnStore.shared
    @State private var report: Report?

    struct Row: Identifiable { let id: String; let title: String; let detail: String; let chosen: Bool }
    struct Report {
        var minutes: Double
        var sessions: Int
        var costs: [Row]
        var setups: [Row]
        var advice: String?
        var timed: Bool
    }

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        if let game {
            SwiftUI.Section {
                if let report {
                    if report.sessions == 0 {
                        Text("Nothing yet. Anvil learns from every session of \(game.title) played from Anvil 0.59 on.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Learned from", value: String(format: "%.0f min of play, %d session%@", report.minutes, report.sessions, report.sessions == 1 ? "" : "s"))
                        if !report.timed {
                            Text("The game's GPU work wasn't timed in these sessions, so what its settings cost can't be told from where you were in it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(report.costs) { row in
                            LabeledContent(row.title) { Text(row.detail).foregroundStyle(.secondary) }
                        }
                        if !report.setups.isEmpty {
                            ForEach(report.setups) { row in
                                LabeledContent {
                                    Text(row.detail).foregroundStyle(row.chosen ? .primary : .secondary)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(row.title)
                                        if row.chosen { Image(systemName: "checkmark").foregroundStyle(.green) }
                                    }
                                }
                            }
                        }
                        if let advice = report.advice {
                            Label(advice, systemImage: "lightbulb").font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text("Learned on This Mac")
            } footer: {
                Text(footer(game))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .task(id: store.models[LearnStore.key(for: game)]?.updated) { await refresh(game) }
        }
    }

    private func footer(_ game: Game) -> String {
        if GameTuning.profile(for: game) != nil {
            return "Each stretch of play is kept with how heavy the scene was, so a setting's cost is measured where you actually play, not in whichever scene a test happened to run. With graphics on Automatic, Anvil picks the level from this after each session, and with the Ray Tracing switch on Automatic, the reflections. It stays on this Mac."
        }
        return "Each stretch of play is kept with how heavy the scene was, so what the game's own settings cost is measured where you actually play — learned from the changes you make in its menu. It stays on this Mac."
    }

    private func refresh(_ game: Game) async {
        guard let model = store.model(for: game) else {
            report = Report(minutes: 0, sessions: 0, costs: [], setups: [], advice: nil, timed: false)
            return
        }
        let target = DisplayProfile.steadyTarget
        let profiled = GameTuning.profile(for: game) != nil
        let chosenLevel = Tuner.shared.graphicsLevel(for: game)
        let container = library.container(id: game.containerID)
        let current = container.map { LearnStore.parts(for: game, in: $0, level: chosenLevel) } ?? []
        let rtChosen = game.rayTracing
        report = await Task.detached(priority: .userInitiated) {
            Self.build(model: model, target: target, profiled: profiled, current: current, reflectionsChosen: rtChosen)
        }.value
    }

    nonisolated static func build(model: LearnModel, target: Double, profiled: Bool, current: [String], reflectionsChosen: Bool?) -> Report {
        let fit = model.fit()
        var costs: [Row] = []
        for (name, ms) in fit.costs.sorted(by: { abs($0.value) > abs($1.value) }) {
            let perStep = name.hasPrefix("sg.") ? " a step" : ""
            if fit.known(name) {
                costs.append(Row(id: "cost:" + name, title: Learn.describe(name).prefix(1).uppercased() + Learn.describe(name).dropFirst(),
                                 detail: String(format: "%@%.1f ms a frame%@", ms >= 0 ? "+" : "−", abs(ms), perStep), chosen: false))
            } else {
                costs.append(Row(id: "cost:" + name, title: Learn.describe(name).prefix(1).uppercased() + Learn.describe(name).dropFirst(),
                                 detail: "not measured yet — played one way so far", chosen: false))
            }
        }
        var setups: [Row] = []
        let pct = { (v: Double) in String(format: "%.0f%%", v * 100) }
        if profiled {
            for level in [GraphicsLevel.light, .medium] {
                for rt in reflectionsChosen.map({ [$0] }) ?? [false, true] {
                    let parts = Learn.parts(level: level, reflections: rt, halfResolution: nil, unreal: [:])
                    guard let p = model.predict(parts, target: target, fit: fit), p.known else { continue }
                    let detail = "\(Int(target))+ fps \(pct(p.shareAt)) of the time, typically \(Int(p.typicalFPS.rounded()))"
                    let chosen = parts.sorted() == current.sorted()
                    // With the reflections switched on, Light and Medium set the same: one row for both.
                    if let i = setups.firstIndex(where: { $0.detail == detail && $0.id.hasSuffix(rt ? "+rt" : "-rt") }) {
                        setups[i] = Row(id: setups[i].id, title: "Light or Medium\(rt ? " with reflections" : "")", detail: detail,
                                        chosen: setups[i].chosen || chosen)
                        continue
                    }
                    setups.append(Row(id: "setup:\(level.rawValue)" + (rt ? "+rt" : "-rt"), title: "\(level.title)\(rt ? " with reflections" : "")",
                                      detail: detail, chosen: chosen))
                }
            }
        }
        // An Unreal game: the one setting a step lower would buy the most time at the target.
        var advice: String?
        if let now = model.predict(current, target: target, fit: fit) {
            var best: (name: String, gain: Double, share: Double)?
            for part in current where part.hasPrefix("sg.") {
                let f = LearnModel.feature(part)
                guard f.amount > 0, fit.known(f.name), (fit.costs[f.name] ?? 0) > 0.05 else { continue }
                let lower = current.map { $0 == part ? "\(f.name)=\(Int(f.amount) - 1)" : $0 }
                guard let p = model.predict(lower, target: target, fit: fit) else { continue }
                let gain = p.shareAt - now.shareAt
                if gain > (best?.gain ?? 0.03) { best = (f.name, gain, p.shareAt) }
            }
            if let best {
                advice = "\(Learn.describe(best.name)) one step lower in the game's own settings would keep it at \(Int(target)) fps or more \(pct(best.share)) of the time, against \(pct(now.shareAt)) now — the most any one of its settings buys here."
            }
        }
        return Report(minutes: fit.minutes, sessions: fit.sessions, costs: costs, setups: setups, advice: advice, timed: fit.timed)
    }
}
