import Foundation

/// The three shapes of the same trade-off, plus whatever the user builds by hand.
enum PresetKind: String, Codable, CaseIterable, Identifiable {
    case maxFPS, balanced, maxGraphics, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .maxFPS: "Maximum FPS"
        case .balanced: "Balanced"
        case .maxGraphics: "Maximum Graphics"
        case .custom: "Custom"
        }
    }

    var summary: String {
        switch self {
        case .maxFPS: "Lowest latency and the highest frame rate this Mac can hold. Renders below native and upscales."
        case .balanced: "Native resolution with the expensive extras off. The setting most games should sit on."
        case .maxGraphics: "Full Retina resolution, no upscaling, every cache warm. Trades frames for sharpness."
        case .custom: "Your own settings. Anvil stops changing them."
        }
    }

    var symbol: String {
        switch self {
        case .maxFPS: "hare.fill"
        case .balanced: "dial.medium.fill"
        case .maxGraphics: "sparkles"
        case .custom: "slider.horizontal.3"
        }
    }
}

/// Predicted or measured outcome of running a game under a preset.
struct PerformanceEstimate: Codable, Hashable {
    var fpsLow: Int
    var fpsHigh: Int
    var qualityTier: String        // e.g. "High · native 3024×1964"
    var isMeasured: Bool
    var sampleCount: Int = 0
    /// Presented frames when frame generation is on. Always shown next to, never
    /// instead of, the rendered figure — generated frames don't reduce input latency.
    var generatedFPS: Int? = nil

    var fpsDescription: String {
        isMeasured ? "\(fpsLow)–\(fpsHigh) fps measured"
                   : "~\(fpsLow)–\(fpsHigh) fps estimated"
    }

    var frameGenDescription: String? {
        generatedFPS.map { "~\($0) fps presented with frame generation — latency stays at the rendered rate" }
    }

    var confidence: String {
        if isMeasured { return sampleCount >= 3 ? "Measured over \(sampleCount) sessions" : "Measured once" }
        return "Model estimate — play once to replace it with a real number"
    }
}

/// A preset applied to a container, plus its predicted result.
struct PresetPlan {
    var kind: PresetKind
    var container: Container
    var estimate: PerformanceEstimate
    var changes: [String]          // human-readable diff vs. current settings
}

@MainActor
final class PresetEngine: ObservableObject {

    /// Recorded results, keyed "gameID/preset".
    @Published private(set) var measured: [String: PerformanceEstimate] = [:]

    static let shared = PresetEngine()
    private var storeURL: URL { RuntimeManager.support.appendingPathComponent("performance.json") }

    private init() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: PerformanceEstimate].self, from: data) {
            measured = decoded
        }
    }

    // MARK: Applying a preset

    func apply(_ kind: PresetKind, to container: Container) -> Container {
        var c = container
        let sys = SystemInfo.current

        switch kind {
        case .maxFPS:
            // Output stays native; the upscaler is what reduces rendered pixels.
            // Lowering output resolution *as well* would double the cut and just
            // produce a soft image for no extra frames.
            c.scaling = .native
            c.dpi = 96
            c.raytracing = false
            c.lodBias = -1.0        // sharper mips to offset rendering below native
            // Upscaling is the cheapest frame rate on offer, so Max FPS leans on it.
            // The mode is downgraded automatically if the game can't accept it.
            // Only ever a built-in mode. FSR 1 runs on Anvil's own Metal shaders and
            // needs nothing downloaded; picking an FSR 3 mode here would make a
            // preset silently demand files the user does not have.
            c.upscaler.mode = .fsr1
            c.upscaler.quality = .performance
            // Deliberately off. Frame generation has been observed closing a real
            // game after a minute or two, and a preset called "Maximum FPS" must not
            // hand someone an unstable game by default.
            c.upscaler.frameGeneration = false
            c.maxQueuedFrames = 2          // one less frame of queue latency
            c.sync = .msync
            c.avx2 = true
            c.rosettaAOT = true
            c.persistentShaderCache = true
            c.dxvkAsync = true
            c.videoMemoryMB = min(sys.recommendedVRAMMB, sys.maxAssignableMemoryMB)

        case .balanced:
            c.scaling = .native
            c.dpi = 96
            c.raytracing = false
            c.lodBias = -0.5
            // Anvil's FSR 3: steadier edges for about 2 ms more a frame than FSR 1 (Max FPS keeps
            // FSR 1, the cheaper).
            c.upscaler.mode = .fsr3Every
            c.upscaler.quality = .quality
            c.upscaler.frameGeneration = false
            c.maxQueuedFrames = 3
            c.sync = .msync
            c.avx2 = true
            c.rosettaAOT = true
            c.persistentShaderCache = true
            c.dxvkAsync = true
            c.videoMemoryMB = min(sys.recommendedVRAMMB, sys.maxAssignableMemoryMB)

        case .maxGraphics:
            c.scaling = .retina
            c.dpi = 192
            // Ray tracing only in the preset that is explicitly buying quality with
            // frames, and only where the game offers it at all.
            c.raytracing = true
            c.lodBias = 0
            // Native AA where the game supports temporal FSR — it costs nothing and
            // cleans up aliasing; otherwise upscaling is off entirely.
            c.upscaler.mode = .off
            c.upscaler.frameGeneration = false
            c.maxQueuedFrames = 3
            c.sync = .msync
            c.avx2 = true
            c.rosettaAOT = true
            c.persistentShaderCache = true
            c.dxvkAsync = false            // compile fully rather than show placeholders
            c.videoMemoryMB = min(sys.recommendedVRAMMB, sys.maxAssignableMemoryMB)

        case .custom:
            break
        }
        return c
    }

    func plan(_ kind: PresetKind, from container: Container, game: Game?) -> PresetPlan {
        let proposed = apply(kind, to: container)
        return PresetPlan(kind: kind,
                          container: proposed,
                          estimate: estimate(kind, container: proposed, game: game),
                          changes: Self.diff(container, proposed))
    }

    /// Which preset Anvil recommends on this Mac for this title.
    func recommended(for game: Game?, container: Container) -> PresetKind {
        // If we have measurements, recommend the highest-quality preset that still
        // clears 60 fps. That is a real answer, not a guess.
        if let game {
            for kind in [PresetKind.maxGraphics, .balanced, .maxFPS] {
                if let m = measured[key(game, kind)], m.isMeasured, m.fpsLow >= 60 {
                    return kind
                }
            }
            if measured.keys.contains(where: { $0.hasPrefix(game.id.uuidString) }) {
                return .maxFPS
            }
        }
        // No data yet: base it on the host's GPU class.
        return Self.gpuScore() >= 1.4 ? .balanced : .maxFPS
    }

    // MARK: Estimation

    /// A cost model, not a benchmark. It multiplies a per-GPU baseline by the
    /// measurable costs of the current settings, then widens the range to reflect how
    /// little it knows about the specific game. Replaced by real numbers on first play.
    func estimate(_ kind: PresetKind, container: Container, game: Game?) -> PerformanceEstimate {
        if let game, let m = measured[key(game, kind)] { return m }

        
        // Baseline: a demanding 3D title at 1080p on an M1 through translation.
        // A light indie game will beat this comfortably — which is exactly why the
        // model is labelled an estimate and replaced the moment you log a real number.
        var fps = 62.0 * Self.gpuScore()

        // Pixel cost dominates everything else. The upscaler reduces the pixels
        // actually rendered, so it belongs inside this one term rather than being
        // applied again on top of it.
        let up = container.upscaler
        let outputPixels = Self.pixelCount(container)
        let renderedPixels = up.mode == .off ? outputPixels : outputPixels * up.quality.pixelFraction
        fps *= pow(2_073_600.0 / max(renderedPixels, 1), 0.62)

        switch up.mode {
        case .fsr1: fps *= 0.96              // one cheap spatial pass over the frame
        case .fsr3Every: fps *= 0.93         // the temporal pass and its motion: 3.6 ms against FSR 1's 1.4 on an M4
        case .metalFX: fps *= 0.95
        case .fsr3Native, .fsr3Translated: fps *= 0.91   // temporal pass costs more
        case .off: break
        }

        // Nothing scales past what the display can present.
        fps = min(fps, 240)
        // Ray tracing is the most expensive thing this translation layer can be asked
        // to do, and only a DirectX 12 title on D3DMetal can be asked for it.
        if container.raytracing && container.backend == .d3dmetal { fps *= 0.62 }
        if !container.persistentShaderCache { fps *= 0.94 }
        if container.sync != .msync { fps *= 0.90 }
        if !container.avx2 { fps *= 0.86 }
        if container.backend == .wined3d { fps *= 0.45 }
        if container.backend == .dxvk { fps *= 0.92 }

        // Translation overhead: nothing here runs natively.
        fps *= 0.72

        let rendered = fps
        // Frame generation raises presented frames without lowering input latency, so
        // it is reported as a separate number rather than folded into the headline.
        let presented = (container.upscaler.frameGeneration
                         && container.upscaler.mode.supportsFrameGeneration)
                        ? fps * 1.8 : nil

        // Wide, because the model knows the hardware and the settings but nothing
        // about how heavy this particular game is.
        let spread = 0.35
        return PerformanceEstimate(
            fpsLow: max(15, Int(rendered * (1 - spread))),
            fpsHigh: Int(rendered * (1 + spread)),
            qualityTier: Self.qualityTier(container),
            isMeasured: false,
            generatedFPS: presented.map { Int($0) })
    }

    private static func pixelCount(_ c: Container) -> Double {
        switch c.scaling {
        case .custom: Double(c.customWidth * c.customHeight)
        case .native: 2_073_600 * 1.6
        case .retina: 3024.0 * 1964.0
        }
    }

    static func qualityTier(_ c: Container) -> String {
        let res: String
        switch c.scaling {
        case .custom: res = "\(c.customWidth)×\(c.customHeight)"
        case .native: res = "native 1×"
        case .retina: res = "full Retina"
        }
        var tier: String
        switch c.scaling {
        case .retina: tier = "Ultra"
        case .native: tier = "High"
        case .custom: tier = c.customWidth >= 2560 ? "High" : (c.customWidth >= 1920 ? "Medium" : "Low")
        }
        let up = c.upscaler
        if up.mode != .off {
            let internalRes: String
            switch c.scaling {
            case .custom:
                internalRes = "\(Int(Double(c.customWidth) * up.quality.renderScale))p internal"
            default:
                internalRes = "\(Int(up.quality.renderScale * 100))% internal"
            }
            return "\(tier) · \(res) · \(up.quality.title) (\(internalRes))"
        }
        if c.raytracing && c.backend == .d3dmetal { tier += " · ray tracing" }
        return "\(tier) · \(res)"
    }

    /// Rough per-chip multiplier against an M1 baseline of 1.0. Deliberately coarse —
    /// it only has to rank presets sensibly until a real measurement lands.
    static func gpuScore() -> Double {
        let name = SystemInfo.current.gpuName.lowercased()
        var score = 1.0
        if name.contains("m4") { score = 1.75 }
        else if name.contains("m3") { score = 1.5 }
        else if name.contains("m2") { score = 1.25 }
        else if name.contains("m1") { score = 1.0 }
        if name.contains("ultra") { score *= 2.4 }
        else if name.contains("max") { score *= 1.9 }
        else if name.contains("pro") { score *= 1.35 }
        return score
    }

    private static func diff(_ old: Container, _ new: Container) -> [String] {
        var changes: [String] = []
        if old.scaling != new.scaling || old.customWidth != new.customWidth {
            changes.append("Resolution → \(qualityTier(new).components(separatedBy: " · ").last ?? "")")
        }
        if old.raytracing != new.raytracing {
            changes.append(new.raytracing ? "Ray tracing on" : "Ray tracing off")
        }
        if old.maxQueuedFrames != new.maxQueuedFrames {
            changes.append("Queue depth → \(new.maxQueuedFrames) frames")
        }
        if old.dxvkAsync != new.dxvkAsync {
            changes.append(new.dxvkAsync ? "Async shader compilation on" : "Async shader compilation off")
        }
        if old.upscaler.mode != new.upscaler.mode {
            changes.append("Upscaler → \(new.upscaler.mode.title)")
        }
        if old.upscaler.quality != new.upscaler.quality && new.upscaler.mode != .off {
            changes.append("Upscale quality → \(new.upscaler.quality.title)")
        }
        if old.upscaler.frameGeneration != new.upscaler.frameGeneration {
            changes.append(new.upscaler.frameGeneration ? "Frame generation on" : "Frame generation off")
        }
        if old.sync != new.sync { changes.append("Synchronisation → \(new.sync.title)") }
        return changes
    }

    // MARK: Measurement

    /// Record what the player actually saw. The overlay is right there; one number
    /// from it beats any model Anvil could ship.
    func record(fps: Int, for game: Game, preset: PresetKind, container: Container) {
        let k = key(game, preset)
        var entry = measured[k] ?? PerformanceEstimate(fpsLow: fps, fpsHigh: fps,
                                                       qualityTier: Self.qualityTier(container),
                                                       isMeasured: true)
        entry.fpsLow = min(entry.fpsLow, fps)
        entry.fpsHigh = max(entry.fpsHigh, fps)
        entry.qualityTier = Self.qualityTier(container)
        entry.isMeasured = true
        entry.sampleCount += 1
        measured[k] = entry
        persist()
    }

    func measurement(for game: Game, preset: PresetKind) -> PerformanceEstimate? {
        measured[key(game, preset)]
    }

    func clearMeasurements(for game: Game) {
        measured = measured.filter { !$0.key.hasPrefix(game.id.uuidString) }
        persist()
    }

    private func key(_ game: Game, _ preset: PresetKind) -> String {
        "\(game.id.uuidString)/\(preset.rawValue)"
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(measured) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
