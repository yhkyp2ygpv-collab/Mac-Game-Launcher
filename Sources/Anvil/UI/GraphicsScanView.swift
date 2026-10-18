import SwiftUI

/// The game's graphics scan, on its Performance tab: what it ships, what draws it, what Anvil
/// does for it, and what its first session showed. See GraphicsScan.
struct GraphicsScanSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @State private var scan: GraphicsScan?
    @State private var scanning = false

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        SwiftUI.Section {
            if let scan {
                content(scan)
            } else {
                Text(scanning ? "Looking at the game's graphics…" : "Not scanned yet — Anvil looks before the game's first start.")
                    .foregroundStyle(.secondary)
            }
            Button(scanning ? "Scanning…" : "Scan Again") {
                guard let game else { return }
                scanning = true
                Task {
                    await GraphicsScan.rescan(game)
                    scan = GraphicsScan.stored(gameID: gameID)
                    scanning = false
                }
            }
            .disabled(scanning || game == nil)
        } header: {
            Text("Graphics Scan")
        }
        .task(id: gameID) { scan = GraphicsScan.stored(gameID: gameID) }
        .onReceive(NotificationCenter.default.publisher(for: .graphicsScanChanged)) { _ in
            scan = GraphicsScan.stored(gameID: gameID)
        }
    }

    @ViewBuilder
    private func content(_ s: GraphicsScan) -> some View {
        LabeledContent("Draws with", value: [s.api ?? "Graphics not known", s.engine, s.is64Bit ? "64-bit" : "32-bit"].joined(separator: " · "))
        LabeledContent("Built in") {
            Text(s.builtins.isEmpty ? "No upscaler or frame generation of its own" : s.builtins.map(\.title).joined(separator: " · "))
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Runs through", value: s.path.title + (s.d3dMetal.map { " \($0)" } ?? "") + " in \(s.engineName)")

        LabeledContent("Upscaling") {
            VStack(alignment: .trailing, spacing: 2) {
                if s.plan.dlssThroughMetalFX && game?.dlssThroughMetalFX == true {
                    Text("DLSS through Apple's MetalFX")
                }
                Text(s.plan.anvilFSR ? s.fsrText : "macOS's stretch — FSR can't reach it")
                    .foregroundStyle(s.plan.anvilFSR ? .primary : .secondary)
            }
        }
        LabeledContent("Frame generation", value: s.plan.anvilFrameGen ? "Anvil's, from the picture" : "Not for this game")

        if s.plan.dlssThroughMetalFX, let game {
            Toggle("DLSS through MetalFX", isOn: Binding(
                get: { game.dlssThroughMetalFX },
                set: { var g = game; g.dlssThroughMetalFX = $0; library.update(g) }))
        }

        if let live = s.liveText {
            LabeledContent("Seen in play") {
                Text(live).multilineTextAlignment(.trailing)
            }
        } else {
            LabeledContent("Seen in play", value: "After its next session")
        }

        ForEach(s.plan.inGame, id: \.self) { line in
            Label(line, systemImage: "gamecontroller")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let why = s.plan.anvilFSRWhyNot, !s.plan.anvilFSR {
            note("FSR to the display isn't possible here: \(why).")
        }
        note(explanation(s))
    }

    private func explanation(_ s: GraphicsScan) -> String {
        let when = s.scannedAt.formatted(date: .abbreviated, time: .shortened)
        if s.hasTemporal {
            return "Scanned \(when). Temporal upscaling — what FSR 3 itself does — rebuilds detail from the motion vectors and depth a game hands its upscaler; this game has them, so its own option is the way to it. Anvil's FSR and frame generation work on every game without them."
        }
        return "Scanned \(when). This game hands no upscaler motion vectors or depth — the data FSR 3's own upscaling and frame generation are built on — so nothing outside it can switch FSR 3 itself on. What works on any game is what AMD's own driver does for games without it: FSR 1 on the finished picture, sharper than macOS's stretch, and frames generated from the picture. Anvil does both."
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
