import SwiftUI
import AppKit

/// A store's page: its state, the one button that matters next, and its games.
struct StoreHeader<Actions: View>: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle).bold()
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions
        }
    }
}

struct Notice: View {
    var text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Steam

struct SteamStoreView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var steam = SteamSupport.shared
    @State private var working = false
    @State private var error: String?
    @State private var filter = ""
    /// The account's games and what's installed, read off the main thread: Steam's own files,
    /// and each installed game's folder walked for anti-cheat.
    @State private var rows: [Row] = []
    @State private var loaded = false
    @State private var asked: Set<String> = []

    struct Row: Identifiable {
        var id: String { appID }
        var appID: String
        var name: String
        var title: SteamLibrary.Title?
        var installed: SteamSupport.InstalledGame?
        var antiCheat: [AntiCheat]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StoreHeader(title: "Steam",
                            subtitle: "Windows Steam, inside Anvil. Its games start with Steam signed in beside them, so online play, cloud saves and achievements work.",
                            symbol: "cloud.fill", tint: Color(red: 0.11, green: 0.24, blue: 0.42)) {
                    actions
                }
                if let status = steam.status {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(status) }
                }
                if let error = error ?? steam.lastError { Notice(text: error) }
                if let found = steam.lastFound, found != "No new Steam games." { Notice(text: found, symbol: "checkmark.circle.fill", tint: .green) }

                if let c = steam.container {
                    gamesList(in: c)
                    Text("Install opens Steam's own install window, where you choose where it goes. Steam downloads it and keeps it up to date, and once it's ready it joins your library here by itself. Steam is a Windows program running under Wine: its window can be slow, and if it ever stays blank Anvil starts it again in a safer mode by itself.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    setUpExplainer
                }
                AccountSafetyNote()
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        // Read now, then again every 10 s while the page is open: a download going on in Steam
        // shows here as it goes, and a game it finished joins the library.
        .task(id: steam.container?.id) {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func reload() async {
        guard let c = steam.container else { rows = []; loaded = true; return }
        let fresh = await Task.detached(priority: .userInitiated) { () -> [Row] in
            let owned = SteamLibrary.owned(in: SteamSupport.steamDir(in: c))
            let installed = SteamSupport.installedGames(in: c)
            var out = owned.map { t in
                Row(appID: t.appID, name: t.name, title: t, installed: installed.first { $0.appID == t.appID }, antiCheat: [])
            }
            // Installed but not in what Steam's cache lists (a game shared from family, say).
            for game in installed where !out.contains(where: { $0.appID == game.appID }) {
                out.append(Row(appID: game.appID, name: game.name, title: nil, installed: game, antiCheat: []))
            }
            for i in out.indices { if let dir = out[i].installed?.installDir { out[i].antiCheat = AntiCheat.detect(in: dir) } }
            return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
        rows = fresh
        loaded = true
        // A game Steam finished downloading, not in the library yet: added now.
        if fresh.contains(where: { r in r.installed?.ready == true && !library.games.contains { $0.steamAppID == r.appID && $0.containerID == c.id } }) {
            steam.importGames()
        }
    }

    @ViewBuilder private var actions: some View {
        if let c = steam.container {
            HStack {
                Button("Find Games") { steam.importGames(); Task { await reload() } }
                Button("Open Steam") { open(c) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Button(working ? "Setting Up…" : "Set Up Steam") { setUp() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working)
        }
    }

    private var setUpExplainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What happens").font(.headline)
            Label("Anvil downloads Steam's installer from Valve and installs it in a Windows setup of its own.", systemImage: "arrow.down.circle")
            Label("You sign in to Steam once, in its own window. Anvil never sees your password.", systemImage: "person.badge.key")
            Label("Your Steam games then show here, each a click from installing, and in your library once installed — tuned for this Mac.", systemImage: "square.grid.2x2")
            Label("Games with anti-cheat are marked: Anvil tells you up front whether their online play can work on a Mac.", systemImage: "shield.lefthalf.filled")
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func inLibrary(_ row: Row, _ c: Container) -> Bool {
        library.games.contains { $0.steamAppID == row.appID && $0.containerID == c.id }
    }

    private func gamesList(in c: Container) -> some View {
        let shown = rows.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { (inLibrary($0, c) ? 0 : 1, $0.name.lowercased()) < (inLibrary($1, c) ? 0 : 1, $1.name.lowercased()) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Steam games").font(.headline)
                if !rows.isEmpty {
                    Text("\(rows.count) · \(rows.filter { inLibrary($0, c) }.count) in your library").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if rows.count > 8 {
                    TextField("Search your games", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                }
            }
            if loaded && rows.isEmpty {
                Text(SteamSupport.rememberedSignIn(in: c) == nil
                     ? "Open Steam and sign in: the games on your account show here, each a click from installing."
                     : "No games on this Steam account yet. Games you buy or add in Steam show here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(shown) { row in steamRow(row, in: c) }
            }
        }
    }

    private func steamRow(_ row: Row, in c: Container) -> some View {
        HStack(spacing: 12) {
            CachedCover(key: "steam-\(row.appID)",
                        local: row.title?.localCover ?? SteamSupport.cachedArtwork(appID: row.appID, in: c),
                        remote: row.title?.remoteCover)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    if let game = row.installed {
                        if let size = game.sizeOnDisk, size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if !game.ready { Text("downloading or updating in Steam").foregroundStyle(.orange) }
                    } else if asked.contains(row.appID) {
                        Text("Steam's install window is open — choose Install there").foregroundStyle(.secondary)
                    }
                    ForEach(row.antiCheat) { kind in
                        Label(kind.name, systemImage: kind.canBeAllowedUnderWine ? "shield.lefthalf.filled" : "shield.slash")
                            .foregroundStyle(kind.canBeAllowedUnderWine ? .orange : .red)
                            .help(AntiCheat.note(for: [kind]) ?? "")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if inLibrary(row, c) {
                Label("In library", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            } else if let game = row.installed {
                if game.ready {
                    Button("Add to Library") { steam.importGames(); Task { await reload() } }
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if let title = row.title {
                Button("Install") { install(title, in: c) }
                    .disabled(asked.contains(row.appID) && steam.status != nil)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func install(_ title: SteamLibrary.Title, in c: Container) {
        error = nil
        asked.insert(title.appID)
        Task {
            do { try await steam.install(title, in: c) }
            catch { self.error = error.localizedDescription; asked.remove(title.appID) }
        }
    }

    private func setUp() {
        working = true
        error = nil
        Task {
            do { try await steam.setUp() } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func open(_ c: Container) {
        let client = steam.ensureClientEntry(in: c)
        guard let runtime = RuntimeManager.shared.runtime(id: c.runtimeID) else {
            error = "Steam's engine isn't installed any more. Choose another for the Steam container."
            return
        }
        Task {
            do { _ = try await launcher.prepareAndLaunch(game: client, container: c, runtime: runtime) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Epic

struct EpicStoreView: View {
    @EnvironmentObject private var library: Library
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var account = EpicAccount.shared
    @State private var showSignIn = false
    @State private var confirmSignOut = false
    @State private var filter = ""
    @State private var signedIn = EpicAccount.isSignedIn
    @State private var leftovers: [EpicLibrary.Leftover] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StoreHeader(title: "Epic Games",
                            subtitle: "Your Epic games, installed and signed in by Anvil itself — no other launcher needed.",
                            symbol: "bag.fill", tint: Color(white: 0.18)) {
                    actions
                }
                if let error = epic.lastError { Notice(text: error) }

                if !signedIn || account.signInExpired {
                    EpicSignInPanel(webHeight: 460, onDone: { signedIn = EpicAccount.isSignedIn })
                        .padding(18)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    accountCard
                    leftoversNotice
                    gamesList
                }
                Text("Games install to \(EpicLibrary.gamesDir.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")). Anvil uses legendary, the open-source Epic client, downloaded from its own project. Your list is kept on this Mac, so the page opens at once; Anvil reads it again from Epic in the background.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AccountSafetyNote()
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .sheet(isPresented: $showSignIn) { EpicSignInView() }
        .confirmationDialog("Sign out of Epic in Anvil?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                account.signOut()
                signedIn = false
            }
        } message: {
            Text("Your installed games stay installed. They need you signed in again before they next start online.")
        }
        .task {
            signedIn = EpicAccount.isSignedIn
            guard signedIn else { return }
            await epic.importInstalled()
            leftovers = await epic.leftovers()
            await epic.refreshIfStale()
        }
        // Looked at again when a download starts or stops.
        .onChange(of: epic.installing.isEmpty) { _, _ in Task { leftovers = await epic.leftovers() } }
    }

    /// Downloads stopped or failed earlier that left a folder behind, with what each takes and a way to clear it.
    @ViewBuilder private var leftoversNotice: some View {
        if !leftovers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Unfinished downloads on this Mac", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
                ForEach(leftovers) { left in
                    HStack {
                        Text(left.folder.lastPathComponent).font(.callout)
                        Text(EpicLibrary.bytes(left.bytes)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Move to Trash") {
                            Task { await epic.trashLeftover(left); leftovers = await epic.leftovers() }
                        }
                    }
                }
                Text("Folders in \(EpicLibrary.gamesDir.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) no installed game uses — a download that was stopped or didn't finish. Installing that game again carries on from what's there; Move to Trash frees the space once the Trash is emptied.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder private var actions: some View {
        if signedIn && !account.signInExpired {
            Button(epic.refreshing ? "Refreshing…" : "Refresh") { Task { await epic.refresh() } }
                .buttonStyle(.borderedProminent)
                .disabled(epic.refreshing)
        }
    }

    private var installedNames: Set<String> { Set(library.games.compactMap(\.epicAppName)) }

    private var accountCard: some View {
        HStack(spacing: 12) {
            Text(String((account.accountName ?? "E").prefix(1)).uppercased())
                .font(.title3.weight(.bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .top, endPoint: .bottom), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(account.accountName.map { "Signed in as \($0)" } ?? "Signed in to Epic").font(.headline)
                Text(epic.owned.isEmpty ? "Your games are being read from Epic…"
                     : "\(epic.owned.count) games · \(epic.owned.filter { installedNames.contains($0.appName) }.count) in your library")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Switch Account…") { showSignIn = true }
            Button("Sign Out…") { confirmSignOut = true }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var gamesList: some View {
        if epic.owned.isEmpty {
            if epic.refreshing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading your games from Epic — the first time can take half a minute. After that the page opens at once.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Choose Refresh to list the games you own.").foregroundStyle(.secondary)
            }
        } else {
            HStack {
                TextField("Search your games", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                if epic.refreshing {
                    ProgressView().controlSize(.small)
                    Text("Updating from Epic…").font(.caption).foregroundStyle(.secondary)
                } else if let at = epic.updatedAt {
                    Text("Updated \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
            let names = installedNames
            let shown = epic.owned.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
                .sorted { (names.contains($0.appName) ? 0 : 1, $0.title.lowercased()) < (names.contains($1.appName) ? 0 : 1, $1.title.lowercased()) }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(shown) { title in row(title) }
            }
        }
    }

    private func row(_ title: EpicLibrary.Title) -> some View {
        EpicGameRow(title: title)
    }

    /// "Downloading — 42% of 30.1 GB · 13.8 MB/s · about 8 min left", or getting ready before the first byte.
    static func downloadText(_ fraction: Double, _ d: EpicLibrary.Download?) -> String {
        guard fraction > 0 || d?.speed != nil else {
            return d?.downloadBytes.map { "Getting ready — \(EpicLibrary.bytes($0)) to download…" } ?? "Getting ready — Epic's file list first…"
        }
        var parts = [String(format: "Downloading — %.0f%%", fraction * 100) + (d?.downloadBytes.map { " of \(EpicLibrary.bytes($0))" } ?? "")]
        if let speed = d?.speed, speed > 0 { parts.append(String(format: "%.1f MB/s", speed * 1.048576)) }
        if let left = d?.secondsLeft, left > 0 {
            parts.append(left >= 3600 ? String(format: "about %d h %02d min left", left / 3600, (left % 3600) / 60)
                                      : left >= 60 ? "about \(left / 60) min left" : "less than a minute left")
        }
        return parts.joined(separator: " · ")
    }
}


/// One Epic game on the Epic page: its sizes (the ⓘ), Install, the download as it goes with a way to stop it, and —
/// installed — what it takes on this Mac with a way to delete it.
struct EpicGameRow: View {
    let title: EpicLibrary.Title

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var epic = EpicLibrary.shared
    @State private var showInfo = false
    @State private var confirmStop = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteResult: String?
    /// The installed game's DLC, read when the row shows and after each DLC download.
    @State private var dlc: EpicLink?

    private var game: Game? { library.games.first { $0.epicAppName == title.appName } }
    private var installed: EpicLibrary.Installed? { EpicLibrary.installed().first { $0.appName == title.appName } }

    var body: some View {
        let progress = epic.installing[title.appName]
        let download = epic.downloads[title.appName]
        HStack(spacing: 12) {
            CachedCover(key: "epic-\(title.appName)", remote: title.cover)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.title).font(.body.weight(.medium))
                if let progress {
                    ProgressView(value: progress).frame(maxWidth: 260)
                    Text(EpicStoreView.downloadText(progress, download)).font(.caption).foregroundStyle(.secondary)
                } else if deleting {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Exporting saves and deleting…") }
                        .font(.caption).foregroundStyle(.secondary)
                } else if let deleteResult {
                    Text(deleteResult).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let stopped = epic.stopped[title.appName] {
                    Text(stopped).font(.caption).foregroundStyle(.secondary)
                } else if let installed, game != nil {
                    Text(installed.installSize.map { "\(EpicLibrary.bytes($0)) on this Mac" } ?? "Installed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let dlc, dlc.launcher == "Anvil", progress == nil { dlcLine(dlc) }
            }
            Spacer()
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("How big it is")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { info }
            if progress != nil {
                Button("Cancel") { confirmStop = true }
            } else if let game {
                Label("In library", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                Button("Delete…") { confirmDelete = true }
                    .disabled(deleting || launcher.isBusy(game))
            } else if !deleting {
                Button("Install") { Task { await epic.install(title) } }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: "\(epic.dlcChanges)-\(game?.id.uuidString ?? "")") {
            guard let game else { dlc = nil; return }
            dlc = await Task.detached(priority: .utility) { EpicLink.find(for: game) }.value
        }
        .confirmationDialog("Stop downloading \(title.title)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop, Keep What's Downloaded") { epic.cancel(title.appName, deleting: false) }
            Button("Stop and Delete the Download", role: .destructive) { epic.cancel(title.appName, deleting: true) }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("Kept, installing it again carries on from where it stopped. Deleted, what's downloaded so far goes to the Trash.")
        }
        .confirmationDialog("Delete \(title.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Export Saves and Move to Trash", role: .destructive) { delete(permanently: false) }
            Button("Export Saves and Delete Now\(installed?.installSize.map { " (frees \(EpicLibrary.bytes($0)))" } ?? "")", role: .destructive) {
                delete(permanently: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saves are exported first, to Documents › Anvil Saves. Then its folder\(installed.map { ", \($0.installPath.path)," } ?? "") goes to the Trash — the space is freed once the Trash is emptied — or, with Delete Now, is deleted at once. It leaves your library; Install brings it back.")
        }
    }

    /// The DLC of yours it has, and what isn't downloaded yet, with the download.
    @ViewBuilder
    private func dlcLine(_ link: EpicLink) -> some View {
        let apps = link.dlc.compactMap(\.appName)
        if let app = apps.first(where: { epic.installing[$0] != nil }), let p = epic.installing[app] {
            let name = link.dlc.first { $0.appName == app }?.title ?? "DLC"
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 120)
                Text("\(name) — " + EpicStoreView.downloadText(p, epic.downloads[app])).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if !link.dlcToDownload.isEmpty {
            HStack(spacing: 8) {
                Label(link.dlcToDownload.count == 1 ? "Your DLC \(link.dlcToDownload[0].title) isn't downloaded"
                                                    : "\(link.dlcToDownload.count) DLC of yours aren't downloaded",
                      systemImage: "arrow.down.circle").foregroundStyle(.orange)
                Button("Download") { Task { await epic.installDLC(link.dlcToDownload, of: title.title) } }
                    .controlSize(.small)
                    .disabled(game.map { launcher.isBusy($0) } ?? true)
            }
            .font(.caption)
        } else if !link.ownedDLC.isEmpty {
            Text("\(link.ownedDLC.count) DLC of yours, all here").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func delete(permanently: Bool) {
        guard let game else { return }
        deleting = true
        deleteResult = nil
        Task {
            switch await GameRemoval.delete(game, permanently: permanently) {
            case .done(let text, _): deleteResult = text
            case .failed(let why): deleteResult = why
            }
            deleting = false
        }
    }

    /// The ⓘ: what it downloads, what it takes installed, and what's free.
    private var info: some View {
        let size = epic.sizes[title.appName]
        return VStack(alignment: .leading, spacing: 8) {
            Text(title.title).font(.headline)
            if epic.sizing.contains(title.appName) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking Epic…").foregroundStyle(.secondary) }
            } else if let size {
                if let failed = size.failed { Text(failed).foregroundStyle(.orange) }
                if let d = size.download { LabeledContent("Download", value: EpicLibrary.bytes(d)) }
                if let i = size.install { LabeledContent("Installed", value: EpicLibrary.bytes(i)) }
                if let installed, let s = installed.installSize, game != nil { LabeledContent("On this Mac now", value: EpicLibrary.bytes(s)) }
                if let free = size.free {
                    LabeledContent("Free on this Mac", value: EpicLibrary.bytes(free))
                    if let need = size.install, installed == nil, need > free {
                        Label("Not enough room: \(EpicLibrary.bytes(need - free)) more is needed.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
            }
            Text("From Epic's list of the game's files. It downloads compressed, so the download is smaller than what it takes installed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .task { await epic.fetchSize(title) }
    }
}

/// What Anvil does, and doesn't, to keep an account in good standing — said plainly, with no
/// promise it can't keep: a ban is the store's or the game's decision, not Anvil's.
struct AccountSafetyNote: View {
    var body: some View {
        Label {
            Text("Your account: the store's own app runs unchanged — the one thing Anvil adds is the Wine fix that lets Steam see its own sign-in window. Anvil never changes a game's files or puts its own into a game with anti-cheat, and never works around anti-cheat or a store's sign-in or ownership checks. Running games through Wine, as CrossOver, Whisky and Heroic do, isn't what gets accounts banned; cheating tools and altered game files are. Games with kernel anti-cheat (Fortnite, Valorant) don't run under Wine at all.")
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
