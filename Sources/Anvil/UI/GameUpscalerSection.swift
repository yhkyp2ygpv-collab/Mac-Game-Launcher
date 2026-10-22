import SwiftUI

/// A game's own upscalers on its Performance tab — DLSS, run by Apple's MetalFX, Intel's XeSS, or its own FSR — for a
/// game whose settings file Anvil knows (GameUpscaler).
struct GameUpscalerSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @State private var inGame: GameUpscaler.InGame?
    @State private var record: GameUpscaler.Record?
    @State private var available: [GameUpscaler.Brand] = []

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        if let game, let profile = GameUpscaler.profile(for: game) {
            SwiftUI.Section {
                Picker("Upscaler", selection: binding(\.gameUpscaler, game)) {
                    Text("Automatic — \(automaticBrand?.title ?? "the game's own")").tag(GameUpscaler.Choice.automatic)
                    ForEach(GameUpscaler.Brand.allCases.filter { profile.modes[$0] != nil }) { brand in
                        Text(brand.title + (available.contains(brand) ? "" : " — not on this Mac")).tag(choice(brand))
                    }
                    Text("As set in the game's own menu").tag(GameUpscaler.Choice.asInGame)
                }
                if game.gameUpscaler != .asInGame {
                    Picker("Quality", selection: binding(\.gameUpscalerQuality, game)) {
                        Text("Automatic — \((record?.autoQuality ?? GameUpscaler.startQuality(DeviceProfile.current?.tier)).title) now")
                            .tag(UpscaleQuality?.none)
                        ForEach(GameUpscaler.qualities) { q in
                            Text("\(q.title) — draws \(Int((q.renderScale * 100).rounded()))% of its window each way").tag(Optional(q))
                        }
                    }
                }
                Toggle("Clean picture — film grain and colour fringing off", isOn: binding(\.cleanPicture, game))
                if let inGame {
                    LabeledContent("In its settings now", value: inGame.text + (inGame.frameGen.map { " · its own frame generation on (\($0))" } ?? ""))
                        .font(.callout)
                }
                if let note = record?.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if record?.changedInGame != nil, game.gameUpscaler != .asInGame {
                    Button("Set It Again at the Next Start") { setAgain(game) }
                        .controlSize(.small)
                }
                note("DLSS and XeSS are AI upscalers: the game draws part of its window and they fill in the rest from its last frames, moved by its own motion data, so edges come out clean where a plain stretch leaves them jagged. DLSS's own neural network needs NVIDIA's hardware, so on a Mac Apple's D3DMetal hands the same inputs to MetalFX, Apple's temporal upscaler, on the GPU's own path. XeSS runs Intel's network on any GPU, for some more GPU time a frame. Automatic picks DLSS where it runs here, then XeSS.")
                note("Quality on Automatic starts at \(GameUpscaler.startQuality(DeviceProfile.current?.tier).title) on this Mac and moves a step after a session that shows room for more, or too little: sharper where the game made well over what it needs even in its heaviest places, quicker where the GPU held it under. Its own frame generation is turned off while Anvil's is on — frames made from made frames warp — and its sharpening goes back to its default, as Anvil's FSR sharpens the picture to the display. Set before its next start; anything you change afterwards in the game's own menu stays as you set it.")
            } header: {
                Text("The Game's Own Upscaler")
            }
            .task(id: game) { refresh(game) }
        }
    }

    private var automaticBrand: GameUpscaler.Brand? {
        GameUpscaler.resolve(.automatic, available: available, unavailable: record?.unavailable ?? [])
    }

    private func choice(_ brand: GameUpscaler.Brand) -> GameUpscaler.Choice {
        switch brand {
        case .dlss: .dlss
        case .xess: .xess
        case .fsr: .fsr
        }
    }

    private func binding<T>(_ key: WritableKeyPath<Game, T>, _ game: Game) -> Binding<T> {
        Binding(get: { (library.games.first { $0.id == gameID } ?? game)[keyPath: key] },
                set: { value in
                    guard var g = library.games.first(where: { $0.id == gameID }) else { return }
                    g[keyPath: key] = value
                    library.update(g)
                })
    }

    private func refresh(_ game: Game) {
        guard let container = library.container(id: game.containerID), let profile = GameUpscaler.profile(for: game) else { return }
        inGame = GameUpscaler.inGame(game, in: container)
        record = GameUpscaler.record(for: game)
        // DLSS where the graphics scan found it and D3DMetal can translate it — as a start decides.
        let dlss = game.dlssThroughMetalFX && GraphicsScan.stored(gameID: game.id)?.plan.dlssThroughMetalFX == true
        available = GameUpscaler.available(for: game, profile: profile, dlssReady: dlss)
    }

    /// Forgets that the player changed it in the game's menu, so the next start sets it again.
    private func setAgain(_ game: Game) {
        guard var r = record else { return }
        r.changedInGame = nil
        r.wrote = nil
        GameUpscaler.save(r, for: game)
        record = r
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
