import SwiftUI

/// A game's DLC on Epic, on its page: what's yours — installed, or downloaded here with a button — and, folded away,
/// what isn't. Before 0.61 every DLC the store lists was shown as "Not installed", owned or not, and nothing downloaded
/// it: LEGO Star Wars' Classic Obi-Wan, owned, sat among thirteen packs that weren't.
struct EpicDLCList: View {
    let game: Game
    let link: EpicLink
    /// Read the game's DLC again — after a download, or Epic's list read again.
    var reload: () -> Void

    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var connectivity = Connectivity.shared
    @State private var showOthers = false
    @State private var checking = false

    private var running: Bool { launcher.isBusy(game) }
    private var mine: [EpicLink.DLC] { link.ownedDLC }
    private var others: [EpicLink.DLC] { link.dlc.filter { !$0.owned && !$0.installed } }
    private var ours: Bool { link.launcher == "Anvil" }

    var body: some View {
        Group {
            if link.dlc.isEmpty {
                LabeledContent("DLC", value: "None for this game")
            } else {
                if mine.isEmpty {
                    LabeledContent("Your DLC", value: "None of its \(link.dlc.count) on your account")
                }
                ForEach(mine) { row($0) }
                if link.dlcToDownload.count > 1, ours {
                    Button("Download All \(link.dlcToDownload.count) of Yours") {
                        Task { await epic.installDLC(link.dlcToDownload, of: game.title); reload() }
                    }
                    .disabled(running || !connectivity.isOnline || downloading)
                }
                if let why = blocked { note(why) }
                if let error = epic.lastError, !downloading { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if !others.isEmpty {
                    DisclosureGroup("Not on your account (\(others.count))", isExpanded: $showOthers) {
                        ForEach(others) { item in
                            Text(item.title).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            HStack {
                note("Yours, as Epic last listed it\(epic.updatedAt.map { " (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""). DLC with files of its own downloads into the game's folder; the rest unlocks in the game when it starts signed in.")
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Epic Again") {
                        checking = true
                        Task { await epic.refresh(); reload(); checking = false }
                    }
                    .controlSize(.small)
                    .disabled(!connectivity.isOnline || epic.refreshing)
                }
            }
        }
        .onChange(of: epic.dlcChanges) { _, _ in reload() }
        // Bought since Epic's list was last read: read it again when it's old.
        .task { await epic.refreshIfStale(maxAge: 6 * 3600) }
    }

    private var downloading: Bool { link.dlc.contains { $0.appName.map { epic.installing[$0] != nil } ?? false } }

    private var blocked: String? {
        guard !link.dlcToDownload.isEmpty else { return nil }
        if !ours { return "\(link.launcher) installed this game: download its DLC there, and Anvil picks it up." }
        if running { return "Close the game to download its DLC — its files are in use while it runs." }
        if !connectivity.isOnline { return "Downloading DLC needs an internet connection." }
        return nil
    }

    private func row(_ item: EpicLink.DLC) -> some View {
        LabeledContent {
            if item.installed {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let app = item.appName, let p = epic.installing[app] {
                HStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 90)
                    Text(EpicStoreView.downloadText(p, epic.downloads[app])).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop") { epic.cancel(app, deleting: false) }.controlSize(.small)
                }
            } else if item.toDownload {
                Button("Download") { Task { await epic.installDLC([item], of: game.title); reload() } }
                    .disabled(running || !connectivity.isOnline || !ours || downloading)
            } else {
                Text("Unlocks in the game").foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let app = item.appName, let stopped = epic.stopped[app], !item.installed {
                    Text(stopped).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A Steam game's DLC, on its page: what the account owns, read from Steam's own files. Steam downloads owned DLC with
/// the game and keeps it up to date; its page in Steam turns any of it on or off.
struct SteamDLCList: View {
    let game: Game
    let container: Container

    @State private var dlc: [SteamLibrary.DLC]?
    @State private var opening = false
    @State private var error: String?

    var body: some View {
        Group {
            if let dlc {
                if dlc.isEmpty {
                    LabeledContent("DLC", value: "None of yours for this game")
                } else {
                    ForEach(dlc) { item in
                        LabeledContent(item.name) {
                            if !item.hasFiles {
                                Label("Unlocked", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if item.installed {
                                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Text("Steam downloads it with the game").foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
                HStack {
                    Text("Steam downloads the DLC you own with the game and keeps it up to date. Its page in Steam lists all of it, where any can be turned on or off.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(opening ? "Opening…" : "Show in Steam") { show() }
                        .controlSize(.small).disabled(opening)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading Steam's list…").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task(id: game.steamAppID) {
            guard let app = game.steamAppID else { dlc = []; return }
            let c = container
            dlc = await Task.detached(priority: .userInitiated) { SteamLibrary.dlc(of: app, in: c) }.value
        }
    }

    private func show() {
        guard let app = game.steamAppID else { return }
        opening = true
        error = nil
        Task {
            do { try await SteamSupport.shared.openInSteam("steam://nav/games/details/\(app)", in: container) }
            catch { self.error = error.localizedDescription }
            opening = false
        }
    }
}
