import Foundation

/// One switch that sets every related option coherently.
///
/// The individual settings interact in ways that are easy to get wrong: choosing
/// "native" scaling and then an upscaler quality mode multiplies to *below* the
/// game's own resolution — 1512×982 became 889×577 on a 3024×1964 display, which
/// looks far worse than doing nothing at all. Frame generation and queue depth
/// likewise trade against input latency. A profile picks a consistent set.
enum PerformanceProfile: String, Codable, CaseIterable, Identifiable {
    case sharpest
    case balanced
    case smoothest
    case lowestLatency
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharpest: "Sharpest"
        case .balanced: "Balanced"
        case .smoothest: "Smoothest"
        case .lowestLatency: "Lowest input lag"
        case .custom: "Custom"
        }
    }

    var summary: String {
        switch self {
        case .sharpest:
            "Every pixel the display has, nothing upscaled, no generated frames. The best image and the most GPU work."
        case .balanced:
            "Renders at two-thirds and sharpens with AMD's RCAS. Close to native, noticeably cheaper."
        case .smoothest:
            "Fewer rendered pixels, generated frames in between, a deeper queue. The highest frame counter, at the cost of a little input lag."
        case .lowestLatency:
            "Projected frames rather than interpolated ones, so nothing is held back, plus two-thirds resolution to keep GPU headroom — a frame that only just finishes in time is a late frame with input waiting behind it."
        case .custom:
            "Your own combination. Anvil stops managing these."
        }
    }

    /// Resolution the game will actually render, given the display's pixel size.
    /// Only whole-number fractions of the display.
    ///
    /// Balanced used to render at two-thirds of the backing store — 1.334, which on a
    /// 3024x1964 panel is a 2017x1310 drawable stretched back up by 1.4993. At a
    /// fraction like that every output pixel is a shifting blend of its neighbours, so
    /// edges crawl and detail boils as the camera moves. That was reported as the
    /// graphics shaking, and it was not a frame-rate problem at all.
    ///
    /// 2.0 is one drawable pixel per display pixel; 1.0 is exactly half, which resolves
    /// to a clean two-to-one. Nothing in between is offered, because nothing in between
    /// looks stable. The injector snaps to the nearest clean ratio regardless, so a
    /// custom scale cannot reintroduce it either.
    func renderScale() -> Double {
        switch self {
        case .sharpest: 2.0            // one drawable pixel per display pixel
        case .balanced: 2.0            // the same: this Mac holds 120 fps at full res
        case .smoothest: 1.0           // exactly half, upscaled cleanly
        case .lowestLatency: 1.0
        case .custom: 1.0
        }
    }

    func apply(to container: inout Container) {
        guard self != .custom else { return }
        container.profile = self
        // Retina in every case: it is what makes the drawable match the display
        // rather than being handed half of it. The quality mode then decides what
        // fraction of that to render — never a fraction of a fraction.
        container.scaling = .retina

        switch self {
        case .sharpest:
            container.upscaler.mode = .off
            container.upscaler.frameGeneration = false
            container.maxQueuedFrames = 3
            container.upscaler.sharpness = 0.3

        case .balanced:
            container.upscaler.mode = .fsr3Every
            container.upscaler.quality = .quality
            container.upscaler.frameGeneration = false
            container.maxQueuedFrames = 3
            container.upscaler.sharpness = 0.5

        case .smoothest:
            container.upscaler.mode = .fsr3Every
            container.upscaler.quality = .performance
            // Smooth through the display, not through guessed frames: on a
            // variable-refresh panel the game's own frames are shown evenly at whatever
            // rate it manages, and every session where generated frames ran drew a
            // report of distorted motion. Still available as a switch.
            container.upscaler.frameGeneration = false
            // Projected, not interpolated: the frame counter is the same and the
            // latency is not.
            container.upscaler.useMetalFXFrameGen = false
            container.upscaler.interpolationScale = 0.5
            container.maxQueuedFrames = 3
            container.upscaler.sharpness = 0.5

        case .lowestLatency:
            // No generated frames: a guessed frame is never lower latency than a
            // real one, and they distorted motion wherever they ran.
            container.upscaler.mode = .off
            container.upscaler.frameGeneration = false
            container.upscaler.useMetalFXFrameGen = false
            container.upscaler.flowDivisor = 8
            container.maxQueuedFrames = 2
            container.upscaler.sharpness = 0.3
            container.pacing = false

        case .custom:
            break
        }
    }

    /// What the game will render at, for showing in the UI.
    func resolutionDescription(displayPixels: (Int, Int)) -> String {
        guard self != .custom else { return "—" }
        let fraction = renderScale() / 2.0
        let w = Int(Double(displayPixels.0) * fraction)
        let h = Int(Double(displayPixels.1) * fraction)
        if fraction >= 0.999 { return "\(w)×\(h) — full display resolution" }
        return "\(w)×\(h), upscaled to \(displayPixels.0)×\(displayPixels.1)"
    }
}
