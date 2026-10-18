import SwiftUI

/// The look check on a game's page: what's on and off in its picture, and why. See LookCheck.
struct LookCheckSection: View {
    let gameID: UUID

    @EnvironmentObject private var library: Library
    @State private var items: [LookCheck.Item] = []

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        SwiftUI.Section {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.title, systemImage: item.kind == .good ? "checkmark.circle.fill"
                                                 : item.kind == .off ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundStyle(item.kind == .good ? .green : item.kind == .off ? .orange : .secondary)
                    Text(item.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fix = item.fix {
                        Button(label(fix)) { LookCheck.apply(fix, gameID: gameID); refresh() }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Look Check")
        } footer: {
            Text("Takes effect at the game's next start.")
        }
        .task(id: gameID) { refresh() }
        .onReceive(library.objectWillChange) { _ in DispatchQueue.main.async { refresh() } }
    }

    private func label(_ fix: LookCheck.Item.Fix) -> String {
        switch fix {
        case .graphics(_, let label): label
        case .rayTracing(let on): on ? "Turn Ray Tracing On" : "Turn Ray Tracing Off"
        }
    }

    private func refresh() {
        guard let game, let container = library.container(id: game.containerID) else { items = []; return }
        let new = LookCheck.items(for: game, container: container)
        if new != items { items = new }
    }
}
