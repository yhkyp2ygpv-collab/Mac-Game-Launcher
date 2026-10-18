import SwiftUI

/// Per-widget control over the Metal performance overlay: FPS alone, or any
/// combination, rather than the all-or-nothing switch every other launcher offers.
struct HUDEditor: View {
    @Binding var config: HUDConfig

    var body: some View {
        Toggle("Show performance overlay", isOn: $config.enabled)

        if config.enabled {
            HStack(spacing: 8) {
                presetButton("FPS only", .fpsOnly)
                presetButton("Everything", .full)
                presetButton("Frame timing", HUDConfig(enabled: true,
                                                       widgets: [.fps, .frameInterval, .frameIntervalGraph]))
            }
            .padding(.vertical, 2)

            ForEach(HUDWidget.allCases) { widget in
                Toggle(widget.title, isOn: Binding(
                    get: { config.widgets.contains(widget) },
                    set: { on in
                        if on { config.widgets.insert(widget) } else { config.widgets.remove(widget) }
                    }
                ))
                .toggleStyle(.checkbox)
            }

            Picker("Position", selection: $config.position) {
                Text("Top left").tag("top-left")
                Text("Top right").tag("top-right")
                Text("Bottom left").tag("bottom-left")
                Text("Bottom right").tag("bottom-right")
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Opacity")
                    Spacer()
                    Text("\(Int(config.opacity * 100))%").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $config.opacity, in: 0.1...1.0)
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Scale")
                    Spacer()
                    Text(String(format: "%.1f×", config.scale)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $config.scale, in: 0.5...3.0, step: 0.1)
            }

            Text(config.anvilDrawsIt
                 ? "Anvil draws this one itself: a small frame-rate counter" + (config.widgets.contains(.thermal) ? " whose plate turns red while the Mac is hot" : "") + ", and nothing else. Apple's Metal HUD reports everything it knows — device, Rosetta mode, memory, draw counts — and has no supported way to ask for less."
                 : "Anything beyond the frame rate and the Mac's heat has to come from Apple's Metal HUD, which shows its full panel — device, Rosetta mode, memory and draw counts included — at no more than its own size. Choose only “Frames per second” and “Thermal pressure” for Anvil's small counter instead. In a game, ⌘F9 hides Apple's panel.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetButton(_ title: String, _ preset: HUDConfig) -> some View {
        Button(title) {
            config.widgets = preset.widgets
            config.enabled = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
