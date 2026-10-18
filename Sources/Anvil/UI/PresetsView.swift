import SwiftUI

/// Side-by-side preset cards. Each one states what it will change, the quality tier
/// it lands on and the frame rate to expect — labelled honestly as an estimate until
/// a real session replaces it.
struct PresetsView: View {
    @Binding var container: Container
    var game: Game?

    @EnvironmentObject private var presets: PresetEngine
    @State private var reportingFPS = ""
    @State private var showReport = false

    private var recommended: PresetKind { presets.recommended(for: game, container: container) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([PresetKind.maxFPS, .balanced, .maxGraphics], id: \.self) { kind in
                card(presets.plan(kind, from: container, game: game))
            }

            if container.activePreset == .custom {
                Label("Custom settings — Anvil isn't managing this container's graphics options.",
                      systemImage: "slider.horizontal.3")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let game {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Log a real frame rate").font(.callout).bold()
                        Text("Turn on the FPS overlay, play for a minute, and type what you saw. One real number beats any estimate.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    TextField("fps", text: $reportingFPS)
                        .frame(width: 62).textFieldStyle(.roundedBorder)
                    Button("Record") {
                        if let v = Int(reportingFPS), v > 0 {
                            presets.record(fps: v, for: game, preset: container.activePreset, container: container)
                            reportingFPS = ""
                        }
                    }
                    .disabled(Int(reportingFPS) == nil)
                }
            }
        }
    }

    private func card(_ plan: PresetPlan) -> some View {
        let isActive = container.activePreset == plan.kind
        let isRecommended = plan.kind == recommended

        return Button {
            container = presets.apply(plan.kind, to: container)
            container.activePreset = plan.kind
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: plan.kind.symbol)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(plan.kind.title).font(.callout).bold()
                        if isRecommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 9)).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(plan.kind.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 16) {
                        metric("Frame rate", plan.estimate.fpsDescription,
                               measured: plan.estimate.isMeasured)
                        metric("Quality", plan.estimate.qualityTier, measured: true)
                    }
                    .padding(.top, 2)

                    if let fg = plan.estimate.frameGenDescription {
                        Text(fg)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(plan.estimate.confidence)
                        .font(.system(size: 10)).foregroundStyle(.tertiary)

                    if !plan.changes.isEmpty && !isActive {
                        Text("Changes: " + plan.changes.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(13)
            .background(isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    private func metric(_ label: String, _ value: String, measured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9)).bold().foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption, design: .rounded)).bold()
                .foregroundStyle(measured ? Color.primary : Color.secondary)
        }
    }
}
