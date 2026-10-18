import SwiftUI

/// Release notes, shown once per version and available from the sidebar.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    private let release = AnvilVersion.latest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Anvil \(release.version)").font(.title2).bold()
                    Text(release.date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(release.headline)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    section("Fixed", release.fixed, "wrench.and.screwdriver.fill", .green)
                    section("New", release.added, "plus.circle.fill", .accentColor)
                    section("Known limitations", release.known, "exclamationmark.triangle.fill", .orange)
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text(AnvilVersion.display)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(width: 620, height: 560)
        .onDisappear { AnvilVersion.markVersionSeen() }
    }

    private func section(_ title: String, _ items: [String],
                         _ symbol: String, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.callout).bold()
                .foregroundStyle(colour)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
