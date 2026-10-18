import SwiftUI

/// A game of Anvil's in Steam's library, started through Anvil (SteamShortcuts). Only ever when
/// the player presses the button: Anvil never puts a game in Steam by itself.
struct AddToSteamSection: View {
    let game: Game

    @EnvironmentObject private var launcher: Launcher
    @State private var working = false
    @State private var message: String?
    @State private var failure: String?
    @State private var listed = false

    var body: some View {
        if let c = SteamSupport.shared.container, game.steamAppID == nil, StoreArt.store(of: game) == nil {
            SwiftUI.Section("Steam") {
                HStack {
                    Button {
                        Task { await change(add: true) }
                    } label: {
                        Label(listed ? "Update in Steam's Library" : "Add to Steam's Library", systemImage: "plus.rectangle.on.rectangle")
                    }
                    if listed {
                        Button(role: .destructive) {
                            Task { await change(add: false) }
                        } label: {
                            Label("Remove from Steam", systemImage: "minus.rectangle")
                        }
                    }
                }
                .disabled(working || launcher.isBusy(game))
                if working {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Changing Steam's library…").font(.caption) }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Only if you want it there: puts \(game.title) in Steam's library with its cover, and Play in Steam starts it through Anvil, the same as Play here — its store sign-in, FSR, frame pacing, controller fixes and save backups all come with it. Steam closes for a moment while it's changed, and opens again. A game that needs its store's sign-in to start still needs it from Steam. All your games are in Settings › Steam too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .task { listed = SteamShortcuts.contains(game, in: c) }
        }
    }

    private func change(add: Bool) async {
        working = true
        failure = nil
        defer { working = false }
        do {
            if add {
                _ = try await SteamShortcuts.add(game)
                message = "\(game.title) is in Steam's library. Press Play there and Anvil starts it."
            } else {
                try await SteamShortcuts.remove(game)
                message = "\(game.title) is no longer in Steam's library."
            }
            if let c = SteamSupport.shared.container { listed = SteamShortcuts.contains(game, in: c) }
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Settings › Steam: every game that can go in Steam's library, each added or taken out with its
/// own button. Nothing is added unless the player presses one.
struct SteamLibrarySettings: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var steam = SteamSupport.shared
    @ObservedObject private var launcher = Launcher.shared
    @State private var listed: Set<UUID> = []
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        SwiftUI.Section("Steam") {
            if let c = steam.container {
                let games = SteamShortcuts.candidates(in: library.games)
                if games.isEmpty {
                    Text("No games to put in Steam yet.").foregroundStyle(.secondary)
                }
                ForEach(games) { game in
                    LabeledContent(game.title) {
                        if listed.contains(game.id) {
                            Button("Remove") { run(add: [], remove: [game], in: c) }
                        } else {
                            Button("Add to Steam") { run(add: [game], remove: [], in: c) }
                        }
                    }
                    .disabled(working || launcher.isBusy(game))
                }
                if games.count > 1 {
                    HStack {
                        Button("Add All") { run(add: games.filter { !listed.contains($0.id) }, remove: [], in: c) }
                            .disabled(working || games.allSatisfy { listed.contains($0.id) })
                        Button("Remove All") { run(add: [], remove: games.filter { listed.contains($0.id) }, in: c) }
                            .disabled(working || !games.contains { listed.contains($0.id) })
                    }
                }
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Changing Steam's library — Steam closes for a moment and opens again…").font(.caption)
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Anvil never puts a game in Steam by itself. A game added here shows in Steam's library with its cover, and Play there starts it through Anvil, in its own container with its own saves, FSR and controller fixes. Remove takes out only what Anvil put there; your own Steam shortcuts are left as they are.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Set up Steam in Anvil's Stores to put your games in its library.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        listed = steam.container.map { SteamShortcuts.listed(in: $0) } ?? []
    }

    private func run(add: [Game], remove: [Game], in c: Container) {
        working = true
        failure = nil
        Task {
            defer { working = false; refresh() }
            do { _ = try await SteamShortcuts.change(adding: add, removing: remove) }
            catch { failure = error.localizedDescription }
        }
    }
}
