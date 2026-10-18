import Foundation

/// The look check: what's on and off in a game's picture, why, and what would bring it back — read at once from
/// what Anvil already knows (the game's own settings file, its graphics scan, Graphics Prep's simulated test of
/// FSR 3 and Smooth Motion on this Mac), with nothing to run.
///
/// Anvil turns some of a game's effects down to make it faster (GameTuning's Light and Medium levels), and the
/// player sees the result as the game looking worse: LEGO Star Wars' reflections were off from 11 October, at
/// Light, and on 14 October "shadows and reflections aren't good" was the first thing said about it. The check
/// says so, and offers the reflections back (Medium, since 0.52) — and the game's own look, all of it, though with
/// its water and heat distortion on the picture was seen to distort (15 October): that effect warps the picture a
/// little differently every frame, which FSR 3's blend and Smooth Motion's made frames can't follow.
enum LookCheck {
    struct Item: Identifiable, Equatable {
        enum Kind: Int { case off = 0, info, good }
        enum Fix: Equatable {
            /// The game's graphics at a level, with what the button says.
            case graphics(GraphicsTuning, String)
            case rayTracing(Bool)
        }
        var id: String
        var kind: Kind
        var title: String
        var detail: String
        var fix: Fix?
    }

    @MainActor
    static func items(for game: Game, container: Container) -> [Item] {
        var out: [Item] = []
        // The game's own effects, where Anvil knows its settings file.
        if let profile = GameTuning.profile(for: game) {
            let level = Tuner.shared.graphicsLevel(for: game)
            let off = Set(profile.settings(for: level).map(\.key))
            let chosenBy = game.graphicsTuning.level == nil ? "Auto-Tune chose \(level.title) graphics for it" : "\(level.title) graphics is chosen for it"
            // The game's own ray tracing — its screen-space reflections — as its Ray Tracing switch, or the level, has it.
            let set = GameTuning.wanted(profile, level: level, rayTracing: game.rayTracing, tier: DeviceProfile.current?.tier,
                                        values: [:], original: [:])
            if set.contains(where: { $0.key == "ScreenSpaceReflectionsEnabled" && $0.value == "0" }) {
                out.append(Item(id: "reflections", kind: .off, title: "Ray-traced reflections: off",
                                detail: game.rayTracing == false
                                    ? "Off, as its Ray Tracing switch is set: the game's reflections in floors, water and metal, traced through what's on screen. On, they cost the heaviest places a little."
                                    : "Off for speed: \(chosenBy), which turns the game's reflections in floors, water and metal off — traced through what's on screen (screen-space ray tracing). Its Ray Tracing switch turns them on at any level, at the game's own quality (a step lighter on an entry-level GPU); Smooth Motion carries the frames in the heaviest places.",
                                fix: .rayTracing(true)))
            } else {
                out.append(Item(id: "reflections", kind: .good, title: "Ray-traced reflections: on",
                                detail: "As the game draws them in floors, water and metal — traced through the depth of what's on screen (screen-space ray tracing), the way a DirectX 11 game reflects"
                                    + (set.contains { $0.key == "ScreenSpaceReflectionsQuality" } ? ", a step lighter for this Mac's GPU." : ".")
                                    + " Its Ray Tracing switch turns them off.",
                                fix: .rayTracing(false)))
            }
            if off.contains("DoFEnabled") {
                out.append(Item(id: "depth-of-field", kind: .info, title: "Depth of field: off",
                                detail: "The game's focus blur behind what's near, in cutscenes: off at \(level.title), as it costs frames there and blurs what FSR sharpens. The game's own look turns it on.",
                                fix: level == .medium ? .graphics(.gameDefault, "Use the Game's Own Look") : nil))
            } else {
                out.append(Item(id: "depth-of-field", kind: .good, title: "Depth of field: on", detail: "As the game draws its focus blur, in cutscenes.", fix: nil))
            }
            if off.contains("WaterDistortionEnabled") {
                out.append(Item(id: "water", kind: .good, title: "Water and heat distortion: off",
                                detail: "The game ripples the picture behind water and heat a little differently every frame. FSR 3's blend and Smooth Motion's made frames follow a picture that moves, not one that warps, and with it on the picture distorted (14 October) — off at Light and Medium.",
                                fix: nil))
            } else {
                out.append(Item(id: "water", kind: .off, title: "Water and heat distortion: on",
                                detail: "The game ripples the picture behind water and heat a little differently every frame, which FSR 3's blend and Smooth Motion's made frames can't follow: it shows as the picture distorting around it. Medium turns it off and keeps the reflections.",
                                fix: .graphics(.medium, "Use Medium (Reflections Kept)")))
            }
            out.append(Item(id: "shadows", kind: .good, title: "Shadows and shading: as the game draws them",
                            detail: "Anvil leaves the game's shadows, soft shadows and ambient occlusion alone at every graphics level.", fix: nil))
            if !profile.forFSR.isEmpty {
                out.append(Item(id: "blur", kind: .good, title: "Motion blur: off while FSR upscales",
                                detail: "The game's motion and speed blurs smear across FSR 3's blend and Smooth Motion's made frames; its own sharpening and edge blur are off for FSR's too. All of them back as the game had them when FSR is off.",
                                fix: nil))
            }
        }

        // Ray tracing.
        let analysis = GameAnalysis.cached(for: game.executableURL)
        if analysis?.primary == .d3d12 || analysis?.apis.contains(.d3d12) == true {
            let rt = Launcher.rayTracing(for: game, container: container)
            if GameAnalysis.offersRayTracing(executable: game.executableURL) {
                out.append(Item(id: "ray-tracing", kind: rt.on ? .good : .off, title: "Ray tracing: \(rt.on ? "available" : "off")",
                                detail: rt.on
                                    ? "The game's ray-traced reflections, shadows and lighting can be turned on in its own graphics settings; this Mac's GPU traces rays in hardware. They cost frames — Smooth Motion carries them."
                                    : (MetalCapability.current.hardwareRayTracing
                                       ? "Off for this game, as chosen."
                                       : "This Mac's GPU traces rays in its shader cores — M3 and later do it in hardware — too slowly for the game's ray-traced effects to be worth it."),
                                fix: rt.on ? .rayTracing(false) : (MetalCapability.current.hardwareRayTracing ? .rayTracing(true) : nil)))
            } else {
                out.append(Item(id: "ray-tracing", kind: .info, title: "Ray tracing: none in this game",
                                detail: "Its DirectX 12 renderer has no ray-traced effects of its own to offer.", fix: nil))
            }
        } else if let api = analysis?.primary {
            out.append(Item(id: "ray-tracing", kind: .info, title: "Hardware ray tracing: not in \(api.title)",
                            detail: "\(game.title) draws with \(api.title), which has no way to trace rays through a scene (DirectX 12's DXR is what does), so this Mac's ray-tracing hardware can't be given its scene: only the game knows where everything is, on screen or not. What \(api.title) games trace is what's on screen — screen-space reflections and ambient occlusion, from the depth of each pixel — and those are the game's own effects above.",
                            fix: nil))
        }

        // Graphics Prep's simulated test on this Mac: FSR 3, and Smooth Motion's made frames.
        if let prep = GraphicsPrep.stored(gameID: game.id), prep.status == .ready, let fsr3 = prep.fsr3 {
            out.append(Item(id: "fsr3", kind: fsr3.better ? .good : .info, title: "FSR 3 (tested on this Mac)",
                            detail: fsr3.text(off: prep.fsr3Off == true), fix: nil))
            if let made = fsr3.smoothMadeError, let older = fsr3.smoothOlderError {
                out.append(Item(id: "smooth-check", kind: made < older ? .good : .info, title: "Smooth Motion (tested on this Mac)",
                                detail: String(format: "A frame made halfway between two came out %.1f from the true picture at its moment, against %.1f for the older frame it stands in for.", made, older)
                                    + (fsr3.smoothMs.map { String(format: " %.1f ms of GPU time.", $0) } ?? "")
                                    + " Where the two frames don't agree — reflections, heat, sparks, motion too fast to follow — it shows the nearer of them instead of half of each.",
                                fix: nil))
            }
        } else {
            out.append(Item(id: "prep", kind: .info, title: "Simulated test: before the next start",
                            detail: "Graphics Prep tests FSR 3 and Smooth Motion's made frames on a moving scene on this Mac, against the true picture, before the game's next start.",
                            fix: nil))
        }
        return out.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Carry out a fix.
    @MainActor
    static func apply(_ fix: Item.Fix, gameID: UUID) {
        guard var game = Library.shared.games.first(where: { $0.id == gameID }) else { return }
        switch fix {
        case .graphics(let tuning, _):
            game.graphicsTuning = tuning
            AnvilLog.write("look check: \(game.title) — \(tuning == .gameDefault ? "the game's own look chosen (all its effects on; motion blurs still off while FSR upscales)" : "\(tuning.level?.title ?? "Anvil's choice of") graphics chosen")")
        case .rayTracing(let on):
            game.rayTracing = on
            AnvilLog.write("look check: \(game.title) — ray tracing \(on ? "on" : "off"), as chosen")
        }
        Library.shared.update(game)
    }
}
