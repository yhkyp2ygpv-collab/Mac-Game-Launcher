import SwiftUI

/// Unreal Engine's own settings tuned for this Mac, on an Unreal game's Performance tab (UnrealTuning): what's on trial,
/// kept or dropped and what it measured, its switch, and the way back to the game's own.
struct UnrealTuningSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @State private var record: UnrealTuning.Record?
    @State private var restored: String?

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        // From the analysis kept of its program (made before its first start): nothing at all shown for another engine.
        if let game, UnrealTuning.isUnreal(game) {
            SwiftUI.Section {
                if !UnrealTuning.fromStore(game) {
                    note("Only for Unreal games bought on Steam or Epic and installed through Anvil — not for a game added from its program. Install it from Steam or Epic in Anvil to have it tuned.")
                } else {
                    Toggle("Tune Unreal Engine for this Mac", isOn: binding(\.unrealTuning, game))
                    Picker("Frame rate to hold", selection: binding(\.fpsGoal, game)) {
                        Text("\(DisplayProfile.targetText) — this display's steady rate").tag(Int?.none)
                        Text("60").tag(Int?.some(60))
                    }
                    if game.unrealTuning, let record {
                        if record.acknowledged == nil {
                            note("Starts at its next start, after Anvil has told you what it does.")
                        }
                        ForEach(UnrealTuning.summary(record), id: \.title) { item in
                            LabeledContent(item.title, value: item.text).font(.callout)
                        }
                        if let b = record.baseline {
                            LabeledContent("Its own stutters before", value: String(format: "%.1f a minute over %.0f minutes of play", b.perMinute, b.minutes))
                                .font(.callout)
                        }
                        if let d = record.detail, d > 0 {
                            LabeledContent("Distant detail trimmed", value: "step \(d) of \(UnrealTuning.detailLevels.count)").font(.callout)
                        }
                    }
                    if game.unrealTuning, GameUpscaler.profile(for: game) == nil {
                        Picker("Distant detail", selection: binding(\.gameGraphics, game)) {
                            Text("Trimmed a step at a time for 80").tag(GameUpscaler.Graphics.automatic)
                            Text("As the game has it").tag(GameUpscaler.Graphics.asSet)
                        }
                    }
                    if record != nil {
                        Button("Put Its Own Settings Back") { restore(game) }
                            .controlSize(.small)
                    }
                    if let restored {
                        Label(restored, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    note("Unreal Engine has its own settings for how it streams the world and how much it draws. Anvil sets a few of them in the game's Engine.ini, the file it keeps them in, and never changes the game's files or its code. Each is tried for a session and kept only if that session measured better than the ones before it; a game that ends unexpectedly with one on trial starts without it next time. Only settings the game's own program has are written, and the file is backed up before the first change.")
                    note("Garbage collection: as you travel, Unreal drops the parts of the world behind you, and by default it then stops the game for a moment to reclaim their memory — every few seconds while flying. With this, the memory is reclaimed at its regular collection instead. Hogwarts Legacy stuttered every 5–9 seconds for minutes at a time over its open world on a base M4 (24 October); its castle, which stays loaded, ran smoothly.")
                    note("Loading: the game's start and its loading screens stop while it works. Anvil tries preparing its pipelines for at most a second at its start, the rest in the background as it plays — Hogwarts Legacy stopped for 5.1–5.3 s every start — and loading on Unreal's own loading thread, where its loading screens stopped for 1.8–2.8 s. Each kept only if its stops measurably shorten without more stutters in play; one of each kind is tried at a time.")
                    note("Latency: where the GPU sets the pace, the game hands over each frame while the GPU is still on the ones before, and what you do reaches the screen that much later — felt as the controls going slow when the frame rate falls. Anvil measures that wait in every session and tries Unreal's own settings for a shorter queue, kept only if the wait measurably shortens without the GPU going idle.")
                    note("Memory: over an open world a big game can take nearly all of a Mac's memory, and what macOS moves to the SSD is read back as hitches — Hogwarts Legacy took up to 20.7 GB of 24 and swap grew 2.2 GB in a session. Where a game nearly fills this Mac, Anvil sizes its textures' memory to it (\(UnrealTuning.texturePoolMB / 1024 == 0 ? "1" : String(format: "%.1f", Double(UnrealTuning.texturePoolMB) / 1024)) GB here), kept only if swap measurably falls without more stutters from reading its data. Then the world streamed in smaller pieces as you travel — shorter frames, more of them — kept only if its own stutters fall.")
                    note("Dynamic resolution: where the game falls short of the frame rate it should hold — flying over an open world — Unreal draws fewer pixels in just the frames that would miss, down to two-fifths of its window each way, and more where there's room, up to two-thirds: sharper than a Performance upscaler there. Kept only if the game really changes the size it draws at and holds 80 more of the time; the even-80 steps hold still while it's tried.")
                    if GameUpscaler.profile(for: game) == nil {
                        note("Distant detail: after a session short of 80 fps, distant things switch to their simpler models a little sooner, distant foliage too, and the smallest things stop casting shadows — three steps in all, one or two a session, and a step back after a session with room to spare. Its menu's settings stay as set.")
                    }
                    note("What's tuned is measured on this Mac and stays on it.")
                }
            } header: {
                Text("Unreal Engine Tuning")
            }
            .task(id: game) { refresh(game) }
        }
    }

    private func refresh(_ game: Game) {
        record = UnrealTuning.record(for: game)
    }

    private func restore(_ game: Game) {
        guard let container = library.container(id: game.containerID) else { return }
        let ok = UnrealTuning.restore(game, in: container)
        if var g = library.games.first(where: { $0.id == gameID }) {
            g.unrealTuning = false
            library.update(g)
        }
        record = nil
        restored = ok ? "Its Engine.ini is as the game had it: Anvil's settings taken out, and tuning off."
                      : "Its Engine.ini couldn't be written — Anvil's settings are still in it."
        AnvilLog.write("unreal tuning: \(game.title) — put back as the game had it" + (ok ? "" : " (its Engine.ini couldn't be written)"))
    }

    private func binding<T>(_ key: WritableKeyPath<Game, T>, _ game: Game) -> Binding<T> {
        Binding(get: { (library.games.first { $0.id == gameID } ?? game)[keyPath: key] },
                set: { value in
                    guard var g = library.games.first(where: { $0.id == gameID }) else { return }
                    g[keyPath: key] = value
                    library.update(g)
                })
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
