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

            Text(config.widgets == [.fps]
                 ? "Anvil draws this one itself: a frame-rate counter and nothing else. Apple's Metal HUD reports everything it knows — device, Rosetta mode, memory, draw counts — and has no supported way to ask for less, so asking it for “FPS only” still fills the corner of the screen."
                 : "Anything beyond the frame rate has to come from Apple's Metal HUD, which shows its full panel — device, Rosetta mode, memory and draw counts included. Select only “Frames per second” to get Anvil's minimal counter instead.")
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
