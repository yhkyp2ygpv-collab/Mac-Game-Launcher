import SwiftUI

/// Which saves a game plays on, after it came back — every export of it and every Windows setup with its saves,
/// newest first, and what it has now. See SaveVault.
struct SaveChoiceSheet: View {
    @ObservedObject var choice: SaveChoice
    let request: SaveChoice.Request
    @State private var picked: String?

    private var offer: SaveVault.Offer { request.offer }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Saves from before for \(offer.game.title)", systemImage: "clock.arrow.circlepath")
                .font(.title3.bold())
            Text("\(offer.game.title) has saves from before it was downloaded again or moved. Choose the ones to play on — newest first. What it has now is exported first, so you can come back to it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let done = request.done {
                Label(done, systemImage: done.hasPrefix("Those saves couldn't") ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .foregroundStyle(done.hasPrefix("Those saves couldn't") ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { choice.finish() }.keyboardShortcut(.defaultAction) }
            } else if let working = request.working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working) }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(offer.candidates) { row($0) }
                        if let current = offer.current { row(current) }
                    }
                }
                .frame(maxHeight: 320)
                HStack {
                    Button("Ask Me Later") { choice.finish() }
                    Spacer()
                    if let current = offer.current, picked == nil || picked == current.id {
                        Button("Keep What It Has Now") { choice.choose(current) }
                    }
                    Button("Use These Saves") {
                        let all = offer.candidates + [offer.current].compactMap { $0 }
                        choice.choose(all.first { $0.id == picked })
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked == nil || picked == offer.current?.id)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { picked = offer.candidates.first?.id }
    }

    private func row(_ c: SaveVault.Candidate) -> some View {
        Button { picked = c.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked == c.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked == c.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(c)).bold()
                    Text(detail(c)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(picked == c.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func when(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown" }

    private func title(_ c: SaveVault.Candidate) -> String {
        switch c.kind {
        case .export(_, let at): "Exported \(when(at))"
        case .otherSetup(_, let name, _): "Left in the “\(name)” Windows setup"
        case .current: "What it has now"
        }
    }

    private func detail(_ c: SaveVault.Candidate) -> String {
        let size = ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file)
        let saved = "last saved \(when(c.lastSaved)) · \(c.files) file\(c.files == 1 ? "" : "s"), \(size)"
        switch c.kind {
        case .export(let zips, _):
            let places = zips.map { $0.path.contains("/Documents/") ? "Documents › Anvil Saves" : "Anvil" }
            return "The game \(saved) · kept in " + Array(Set(places)).sorted().joined(separator: " and ")
        case .otherSetup:
            return "Where it was before it was downloaded again — the game \(saved)"
        case .current:
            return "Since it was downloaded again — the game \(saved)"
        }
    }
}
