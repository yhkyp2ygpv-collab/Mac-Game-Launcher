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
                if profile.ownFrameGen != nil {
                    Picker("Frame generation", selection: binding(\.gameFrameGen, game)) {
                        Text("Automatic — the game's own (\(profile.ownFrameGenTitle))").tag(GameUpscaler.FrameGen.automatic)
                        Text("Anvil's Smooth Motion").tag(GameUpscaler.FrameGen.anvil)
                        Text("Off").tag(GameUpscaler.FrameGen.off)
                    }
                }
                if !profile.scalability.isEmpty {
                    Picker("Graphics", selection: binding(\.gameGraphics, game)) {
                        Text("For an even 80 — the costliest a step lower until it holds").tag(GameUpscaler.Graphics.automatic)
                        Text("Exactly as set in the game's menu").tag(GameUpscaler.Graphics.asSet)
                    }
                    if game.gameGraphics == .automatic, let lowered = record?.lowered, !lowered.isEmpty {
                        LabeledContent("Lowered for an even 80", value: lowered.compactMap { key in
                            (record?.graphicsNext?[key] ?? record?.graphicsSet?[key]).map { "\(GameUpscaler.groupName(key)) \(GameUpscaler.levelName($0))" }
                        }.joined(separator: ", "))
                        .font(.callout)
                    }
                }
                if !profile.rayTracingSwitches.isEmpty {
                    Picker("Ray tracing", selection: rayTracingBinding(game)) {
                        Text("Automatic — \(automaticRayTracing(game))").tag(GameUpscaler.RayTracing.automatic)
                        Text("Reflections").tag(GameUpscaler.RayTracing.reflections)
                        Text("Reflections, shadows and ambient occlusion").tag(GameUpscaler.RayTracing.all)
                        Text("Off").tag(GameUpscaler.RayTracing.off)
                    }
                    .disabled(!MetalCapability.current.hardwareRayTracing)
                }
                Toggle("Clean picture — film grain and colour fringing off", isOn: binding(\.cleanPicture, game))
                if let inGame {
                    LabeledContent("In its settings now", value: inGame.text + (inGame.frameGen.map { " · its own frame generation on (\($0))" } ?? "")
                                   + (inGame.rayTraced.isEmpty ? "" : " · ray-traced \(GameUpscaler.effectNames(inGame.rayTraced))"
                                      + (inGame.rayReconstruction ? " with Ray Reconstruction" : "")))
                        .font(.callout)
                }
                if let note = record?.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if (record?.changedInGame != nil && game.gameUpscaler != .asInGame) || (record?.frameGenLeftOff == true && game.gameFrameGen == .automatic)
                    || (record?.rayTracingLeft == true && game.gameRayTracing != .automatic) {
                    Button("Set It Again at the Next Start") { setAgain(game) }
                        .controlSize(.small)
                }
                note("DLSS and XeSS are AI upscalers: the game draws part of its window and they fill in the rest from its last frames, moved by its own motion data, so edges come out clean where a plain stretch leaves them jagged. DLSS's own neural network needs NVIDIA's hardware, so on a Mac Apple's D3DMetal hands the same inputs to MetalFX, Apple's temporal upscaler, on the GPU's own path. XeSS runs Intel's network on any GPU, for some more GPU time a frame. Automatic picks DLSS where it runs here, then XeSS.")
                if profile.ownFrameGen != nil {
                    note("Frame generation on Automatic is the game's own: \(profile.ownFrameGenTitle), made from the game's own motion vectors and depth — what Anvil's Smooth Motion can only estimate from the finished pictures. Anvil's then stands down and only takes the picture to the display, a millisecond or so of the GPU's time a frame where Smooth Motion with FSR 3 took five to eight. In Hogwarts Legacy at Ultra on a base M4 (22 October): 67 fps on average with its own frame generation and its FSR 3 at Performance; 48 with Smooth Motion and DLSS at Performance.")
                }
                if !profile.scalability.isEmpty {
                    note("Graphics for an even 80: after each session of five minutes or more that held 80 fps or more less than 80% of the time, quality goes to Performance first, then the setting that costs the most frame time for the least to see goes a step lower — Effects, then Fog and light shafts, Shadows, Foliage, Post-processing — never below High. Textures, view distance and shading are never touched. After a session that held 80 for 95% of it, the last one lowered goes back up. Anything you set in the game's own menu stays as you set it.")
                }
                if !profile.rayTracingSwitches.isEmpty {
                    note(MetalCapability.current.hardwareRayTracing
                         ? "Ray tracing is traced by this Mac's ray-tracing hardware, which D3DMetal hands the game's DirectX ray tracing to. With DLSS as its upscaler, NVIDIA's Ray Reconstruction cleans what a few rays a pixel leave grainy — D3DMetal runs it as Apple's MetalFX denoiser — and the effects trace at Medium; with FSR or XeSS, the game's own denoisers do, at High. It costs frame rate: in Hogwarts Legacy at Ultra a base M4's GPU is already 97–99% busy, so with reflections on, Graphics for an even 80 lowers the costliest settings further to make room. Automatic leaves it as set in the game's menu, and turns its reflections on only after a session that held 80 fps for 95% of it with nothing lowered."
                         : "Ray tracing needs an M3 or later: this Mac's GPU traces rays in its shader cores, too slowly to be worth it.")
                }
                note("Quality on Automatic starts at \(GameUpscaler.startQuality(DeviceProfile.current?.tier).title) on this Mac. After a session that held 80 fps or more for 95% of it with nothing lowered, it goes a step sharper; after one under 80%, back to Performance first. Its own frame generation is turned off while Anvil's is on — frames made from made frames warp — and its sharpening goes back to its default, as Anvil's FSR sharpens the picture to the display. Set before its next start; anything you change afterwards in the game's own menu stays as you set it.")
            } header: {
                Text("The Game's Own Upscaler")
            }
            .task(id: game) { refresh(game) }
        }
    }

    private var automaticBrand: GameUpscaler.Brand? {
        guard let game, let profile = GameUpscaler.profile(for: game) else { return nil }
        return GameUpscaler.resolve(.automatic, available: available, unavailable: record?.unavailable ?? [],
                                    gamesFrameGen: GameUpscaler.usesGamesFrameGen(game, profile: profile, record: record),
                                    frameGenRefusedWith: record?.frameGenRefusedWith ?? [])
    }

    private func choice(_ brand: GameUpscaler.Brand) -> GameUpscaler.Choice {
        switch brand {
        case .dlss: .dlss
        case .xess: .xess
        case .fsr: .fsr
        }
    }

    /// Ray tracing chosen on: D3DMetal's ray tracing on too, where the Ray Tracing switch had it off.
    private func rayTracingBinding(_ game: Game) -> Binding<GameUpscaler.RayTracing> {
        Binding(get: { (library.games.first { $0.id == gameID } ?? game).gameRayTracing },
                set: { value in
                    guard var g = library.games.first(where: { $0.id == gameID }) else { return }
                    g.gameRayTracing = value
                    if value.effects?.isEmpty == false, g.rayTracing == false { g.rayTracing = nil }
                    library.update(g)
                })
    }

    private func automaticRayTracing(_ game: Game) -> String {
        guard MetalCapability.current.hardwareRayTracing else { return "off on this Mac" }
        if game.rayTracing == false { return "off, with the Ray Tracing switch off — its menu can't turn it on" }
        if record?.rayTracingByAnvil == true { return "reflections on, with room to spare" }
        guard let inGame else { return "as in the game's menu" }
        return inGame.rayTraced.isEmpty ? "off, as in the game's menu" : "\(GameUpscaler.effectNames(inGame.rayTraced)), as in the game's menu"
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
        r.frameGenLeftOff = nil
        r.rayTracingLeft = nil
        GameUpscaler.save(r, for: game)
        record = r
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
