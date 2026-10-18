import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var artwork: ArtworkStore
    @EnvironmentObject private var importer: GameImporter
    @EnvironmentObject private var shortcuts: ShortcutStore

    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @State private var search = ""
    @State private var selected: Game?
    @State private var importError: String?
    /// A game asked to be deleted from its menu, until the question is answered.
    @State private var deleting: Game?
    @State private var deleteError: String?
    @State private var showImport = false
    @State private var syncResult: GameImporter.SyncResult?
    @State private var syncing = false
    /// Save import for one game, or for the whole container when `nil` is chosen
    /// from the library menu.
    @State private var dataImport: DataImport?

    private struct DataImport: Identifiable {
        let id = UUID()
        var container: Container
        var game: Game?
    }

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 22, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // The game most likely to be played next, one click away.
                if search.isEmpty, let featured {
                    HeroBanner(game: featured,
                               image: artwork.banner(for: featured),
                               isRunning: isRunning(featured), isClosing: launcher.isClosing(featured),
                               isStarting: launcher.launching != nil,
                               play: { play(featured) }, quit: { launcher.quit(featured) },
                               settings: { selected = featured })
                        .contextMenu { menu(for: featured) }
                }
                if !library.games.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(search.isEmpty ? "All Games" : "Results")
                                .font(.title2.weight(.semibold))
                            Text("\(filtered.count)")
                                .font(.title3).foregroundStyle(.tertiary)
                            Spacer()
                            Text(sort.title).font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                            ForEach(filtered) { game in
                                GameTile(game: game, isRunning: isRunning(game), isClosing: launcher.isClosing(game),
                                         isStarting: launcher.launching != nil,
                                         image: artwork.thumbnail(for: game),
                                         play: { play(game) }, quit: { launcher.quit(game) })
                                    .onTapGesture { selected = game }
                                    .contextMenu { menu(for: game) }
                                    // Drop an image straight onto a tile to set its cover.
                                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                                        handleDrop(providers, for: game)
                                    }
                            }
                            AddTile(add: { addGame() },
                                    importGames: { showImport = true },
                                    importData: { importData(for: nil) },
                                    canImport: !library.containers.isEmpty)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .navigationTitle("Library")
        .searchable(text: $search, prompt: "Search games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SurroundSoundButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort the library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { _ = await ArtworkFetcher.shared.fetchMissing(in: library.games) }
                } label: {
                    Label("Find Missing Artwork", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(library.games.isEmpty)
                .help("Look up cover art for any game that has none")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { sync() } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(library.containers.isEmpty || syncing)
                .help("Re-check the other launchers: add new installs, repair moved games, flag ones that are gone")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showImport = true } label: {
                    Label("Import Installed", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(library.containers.isEmpty)
                .help("Find games Mythic, Heroic and other launchers have already installed")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { addGame() } label: { Label("Add Game", systemImage: "plus") }
                    .disabled(library.containers.isEmpty)
            }
        }
        .sheet(item: $selected) { game in
            GameDetailView(gameID: game.id)
        }
        .sheet(isPresented: $showImport) { ImportGamesView() }
        .sheet(item: $dataImport) { request in
            SaveTransferView(container: request.container, game: request.game)
        }
        .alert("Sync complete", isPresented: .constant(syncResult != nil)) {
            Button("OK") { syncResult = nil }
        } message: {
            Text(syncResult.map { result in
                var text = result.summary
                if !result.added.isEmpty { text += "\n\nAdded: " + result.added.joined(separator: ", ") }
                if !result.repaired.isEmpty { text += "\n\nRepaired: " + result.repaired.joined(separator: ", ") }
                if !result.missing.isEmpty {
                    text += "\n\nNo longer installed: " + result.missing.joined(separator: ", ")
                    text += "\nNothing was removed — a disconnected drive looks the same as an uninstall."
                }
                return text
            } ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .anvilImportGames)) { _ in
            if !library.containers.isEmpty { showImport = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .anvilAddGame)) { _ in addGame() }
        .onReceive(NotificationCenter.default.publisher(for: .anvilShowGame)) { note in
            if let id = note.object as? UUID, let game = library.games.first(where: { $0.id == id }) { selected = game }
        }
        .overlay(alignment: .bottom) {
            if let message = launcher.launching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 8, y: 2)
                .frame(maxWidth: 360)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: launcher.launching)
        .alert("Couldn't add game", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .alert("Couldn't delete the game", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: { Text(deleteError ?? "") }
        .confirmationDialog("Delete \(deleting?.title ?? "this game")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { game in
            Button("Export Saves and Move to Trash", role: .destructive) { delete(game, permanently: false) }
            Button("Export Saves and Delete Now", role: .destructive) { delete(game, permanently: true) }
            Button("Cancel", role: .cancel) {}
        } message: { game in
            Text("Its saves are exported first, to Documents › Anvil Saves. Then its folder, \(GameRemoval.plan(for: game).folder?.path ?? "")\(GameRemoval.plan(for: game).bytes.map { " (\(EpicLibrary.bytes($0)))" } ?? ""), goes to the Trash — the space is freed once the Trash is emptied — or, with Delete Now, is deleted at once.")
        }
        .overlay {
            if library.containers.isEmpty {
                ContentUnavailableView {
                    Label("No containers yet", systemImage: "cube.transparent")
                } description: {
                    Text("A container is the Windows environment your games run inside. Create one and you can add games straight away — nothing else needs setting up.")
                } actions: {
                    Button("Create a Container") {
                        NotificationCenter.default.post(name: .anvilNewContainer, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if library.games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Add a .exe, or point Anvil at a game folder and it will find the right executable.")
                } actions: {
                    Button("Import Installed Games…") { showImport = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add a .exe…") { addGame() }
                }
            }
        }
    }

    /// What the banner shows: a game that is running, else the one played last.
    private var featured: Game? {
        if let running = launcher.sessions.last?.game,
           let game = library.games.first(where: { $0.id == running.id }) { return game }
        return library.games.filter { $0.lastPlayed != nil && $0.exists }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    private var filtered: [Game] {
        let games = search.isEmpty ? library.games
                                   : library.games.filter { $0.title.localizedCaseInsensitiveContains(search) }
        return sort.sorted(games)
    }

    private func importData(for game: Game?) {
        guard let container = game.flatMap({ library.container(id: $0.containerID) })
                ?? library.containers.first else { return }
        dataImport = DataImport(container: container, game: game)
    }

    private func isRunning(_ game: Game) -> Bool {
        launcher.sessions.contains { $0.game.id == game.id }
    }

    @ViewBuilder
    private func menu(for game: Game) -> some View {
        if launcher.isRunning(game) {
            Button(launcher.isClosing(game) ? "Closing…" : "Quit Game") { launcher.quit(game) }
                .disabled(launcher.isClosing(game))
            Button("Force Quit Game") { launcher.forceQuit(game) }
        } else {
            Button("Play") { play(game) }
        }
        Button("Settings…") { selected = game }
        Button("Import Saves & Game Data…") { importData(for: game) }
        Divider()
        if let shortcut = shortcuts.shortcuts[game.id] {
            Button("Show Shortcut in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shortcut]) }
            Button("Remove Shortcut") { shortcuts.remove(for: game) }
        } else {
            Button("Add Shortcut to Applications") { makeShortcut(for: game) }
        }
        Divider()
        Button("Choose Artwork…") { chooseArtwork(for: game) }
        Button("Find Artwork Automatically") {
            Task { await ArtworkFetcher.shared.fetchArtwork(for: game) }
        }
        if artwork.image(for: game) != nil {
            Button("Remove Artwork") { artwork.removeArtwork(for: game) }
        }
        Divider()
        Button("Show Executable in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.executableURL])
        }
        Divider()
        if GameRemoval.plan(for: game).folder != nil {
            Button("Delete Game…", role: .destructive) { deleting = game }
                .disabled(launcher.isBusy(game))
        }
        Button("Remove from Library", role: .destructive) { library.removeGame(game) }
    }

    /// Deleted as its page's Delete does (GameRemoval), saying how it went.
    private func delete(_ game: Game, permanently: Bool) {
        deleting = nil
        Task {
            switch await GameRemoval.delete(game, permanently: permanently) {
            case .done(_, let zip): if let zip { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            case .failed(let why): deleteError = why
            }
        }
    }

    /// A shortcut app for the game, shown in Finder so it can be dragged to the Dock.
    private func makeShortcut(for game: Game) {
        do {
            let app = try shortcuts.create(for: game)
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            importError = "Couldn't make a shortcut for \(game.title): \(error.localizedDescription)"
        }
    }

    private func play(_ game: Game) {
        guard QuickLaunch.engine(for: game) != nil else { return }
        // Online, offline, or once the connection is back — or another copy of it (AutoStart).
        AutoStart.shared.play(game) { chosen in
            guard let engine = QuickLaunch.engine(for: chosen) else { return }
            Task {
                do { try await launcher.prepareAndLaunch(game: chosen, container: engine.container, runtime: engine.runtime) }
                catch Launcher.LaunchError.alreadyStarting {}
                catch { importError = error.localizedDescription }
            }
        }
    }

    /// Many installers drop cover art beside the executable; use it rather than
    /// making the user go looking for an image.
    private func autoArtwork(for executable: URL) {
        guard let game = library.games.last,
              let found = artwork.findBundledArtwork(near: executable.path) else { return }
        _ = try? artwork.setArtwork(from: found, for: game)
    }

    private func sync() {
        guard let container = library.containers.first else { return }
        syncing = true
        Task { @MainActor in
            defer { syncing = false }
            SaveTransfer.shared.discoverPrefixes()
            syncResult = importer.sync(into: container)
        }
    }

    private func chooseArtwork(for game: Game) {
        let panel = NSOpenPanel()
        panel.message = "Choose cover art for \(game.title)."
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .heic, .webP]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try artwork.setArtwork(from: url, for: game) }
        catch { importError = error.localizedDescription }
    }

    private func handleDrop(_ providers: [NSItemProvider], for game: Game) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                do { try artwork.setArtwork(from: url, for: game) }
                catch { importError = error.localizedDescription }
            }
        }
        return true
    }

    private func addGame() {
        guard let container = library.containers.first else {
            // Previously this returned silently, so clicking Add Game appeared to do
            // nothing at all when no container existed yet.
            importError = "Create a container first — it's the Windows environment your games run inside. Use “New Container” in the sidebar."
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose a Windows executable, or the game's folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // A program inside another app's Wine setup — Steam in a Whisky bottle — gets a
        // container made from that setup; anything else goes in the first container.
        if url.hasDirectoryPath {
            let candidates = library.discoverExecutables(in: url)
            guard let best = candidates.first else {
                importError = "No launchable .exe found in that folder."
                return
            }
            Task {
                let game = await library.addGameKeepingItsSetup(title: url.lastPathComponent, executable: best, otherwise: container)
                autoArtwork(for: URL(fileURLWithPath: game.executablePath))
            }
        } else {
            Task {
                let game = await library.addGameKeepingItsSetup(title: url.deletingPathExtension().lastPathComponent,
                                                                executable: url, otherwise: container)
                autoArtwork(for: URL(fileURLWithPath: game.executablePath))
            }
        }
    }
}

private struct GameTile: View {
    let game: Game
    let isRunning: Bool
    let isClosing: Bool
    /// Some game is being started; Play waits until it has.
    let isStarting: Bool
    let image: NSImage?
    let play: () -> Void
    let quit: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ArtworkPlaceholder(title: game.title)
                    }
                }
                .overlay {
                    // Play straight from the library — one click, no settings sheet on the way.
                    if hovering && game.exists && !isClosing {
                        ZStack {
                            Color.black.opacity(0.28)
                            Button(action: isRunning ? quit : play) {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 52, height: 52)
                                    .background(isRunning ? Color.red : Color.accentColor, in: Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isRunning && isStarting)
                            .help(isRunning ? "Quit \(game.title)" : "Play \(game.title)")
                        }
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isRunning {
                        StatusBadge(text: isClosing ? "Closing" : "Playing", color: isClosing ? .orange : .green)
                            .padding(9)
                    } else if OfflineStarts.needsConnection(game) {
                        // Said before the player goes offline, not after: start it online first.
                        StatusBadge(text: "Needs internet to start", color: .orange)
                            .padding(9)
                            .help(OfflineStarts.howToPlayOffline)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08),
                                      lineWidth: hovering ? 2 : 1)
                }
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.18), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.03 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(game.exists ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
    }

    private var subtitle: String {
        guard game.exists else { return "Executable missing" }
        if isRunning { return "Playing now" }
        guard let last = game.lastPlayed else { return "Not played yet" }
        return "\(game.playtimeDescription) · \(last.formatted(.relative(presentation: .named)))"
    }
}

/// A small pill over artwork.
private struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// Artwork for a game that has none: a colour of its own, from its title, and its
/// initials — so a library of unmatched games is not a wall of identical tiles.
struct ArtworkPlaceholder: View {
    let title: String
    var compact = false

    var body: some View {
        let hue = Self.hue(for: title)
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.62),
                                    Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.32)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(Self.initials(of: title))
                .font(.system(size: compact ? 22 : 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
    }

    /// Stable across launches, unlike `hashValue`.
    static func hue(for title: String) -> Double {
        var h: UInt32 = 5381
        for scalar in title.unicodeScalars { h = (h &* 33) &+ scalar.value }
        return Double(h % 360) / 360
    }

    static func initials(of title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}

/// The game most likely to be played next, large, with Play one click away.
private struct HeroBanner: View {
    let game: Game
    let image: NSImage?
    let isRunning: Bool
    let isClosing: Bool
    let isStarting: Bool
    let play: () -> Void
    let quit: () -> Void
    let settings: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ArtworkPlaceholder(title: game.title)
                    }
                }
                .clipped()
            // Legibility: dark where the text is, clear where the art is.
            LinearGradient(stops: [.init(color: .black.opacity(0.88), location: 0),
                                   .init(color: .black.opacity(0.55), location: 0.45),
                                   .init(color: .black.opacity(0.0), location: 1)],
                           startPoint: .bottomLeading, endPoint: .topTrailing)
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center)

            VStack(alignment: .leading, spacing: 10) {
                Text(isRunning ? "PLAYING NOW" : "CONTINUE PLAYING")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.72))
                Text(game.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                HStack(spacing: 16) {
                    Label(game.playtimeDescription, systemImage: "clock")
                    if let last = game.lastPlayed, !isRunning {
                        Label(last.formatted(.relative(presentation: .named)).capitalizedFirst, systemImage: "calendar")
                    }
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                if let stats = game.lastSession {
                    SessionBadge(stats: stats)
                }
                HStack(spacing: 10) {
                    Button(action: isRunning ? quit : play) {
                        Label(isRunning ? (isClosing ? "Closing…" : "Quit") : "Play",
                              systemImage: isRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: true, tint: isRunning ? .red : .accentColor))
                    .disabled((!isRunning && isStarting) || isClosing || !game.exists)
                    .keyboardShortcut(.return, modifiers: [])
                    Button(action: settings) {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: false, tint: .white))
                }
                .padding(.top, 6)
            }
            .padding(30)
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }
}

/// How the last session ran, in one line, coloured by how often it held 80.
struct SessionBadge: View {
    let stats: SessionStats
    var onDark = true

    var body: some View {
        let color: Color = stats.shareAt80 >= 0.9 ? .green : (stats.shareAt80 >= 0.7 ? .yellow : .orange)
        HStack(spacing: 7) {
            Image(systemName: "speedometer").foregroundStyle(color)
            Text("Last session: ").foregroundStyle(onDark ? Color.white.opacity(0.7) : Color.secondary)
                + Text(String(format: "%.0f fps average", stats.averageFPS)).bold()
                + Text(String(format: " · 80+ fps %.0f%% of the time", stats.shareAt80 * 100))
        }
        .font(.callout)
        .foregroundStyle(onDark ? Color.white.opacity(0.92) : Color.primary)
        .help(String(format: "Over %.0f minutes of play: 120 fps %.0f%% of the time; the lowest 1%% low was %.0f fps.",
                     stats.minutes, stats.shareAt120 * 100, stats.lowestOnePercent))
    }
}

/// Large capsule buttons for use over artwork.
struct HeroButtonStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, prominent ? 26 : 18)
            .padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.white : Color.white)
            .background {
                if prominent {
                    Capsule().fill(tint)
                } else {
                    Capsule().fill(.white.opacity(0.16))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// How the library is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, playtime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recently Played"
        case .title: "Title"
        case .playtime: "Most Played"
        }
    }

    func sorted(_ games: [Game]) -> [Game] {
        let byTitle: (Game, Game) -> Bool = { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        switch self {
        case .title:
            return games.sorted(by: byTitle)
        case .playtime:
            return games.sorted { $0.totalPlaySeconds != $1.totalPlaySeconds ? $0.totalPlaySeconds > $1.totalPlaySeconds : byTitle($0, $1) }
        case .recent:
            return games.sorted { a, b in
                switch (a.lastPlayed, b.lastPlayed) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byTitle(a, b)
                }
            }
        }
    }
}

/// Always the last tile, so adding and importing are never out of reach once the
/// library has games in it — the empty-library buttons disappear with the first one.
private struct AddTile: View {
    let add: () -> Void
    let importGames: () -> Void
    let importData: () -> Void
    let canImport: Bool

    @State private var hovering = false
    @State private var choosing = false

    var body: some View {
        // A button with its own popover: a Menu would flatten this tile to a line of text.
        Button { choosing = true } label: {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                    }
                    .background(Color.primary.opacity(hovering ? 0.07 : 0.035),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .foregroundStyle(hovering ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add or Import").font(.headline)
                    Text("A .exe, or games other launchers installed").font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                choice("Add a Game…", detail: "A .exe, or a game's folder", icon: "plus.app") { add() }
                choice("Import Installed Games…", detail: "From Mythic, Heroic, Whisky or CrossOver",
                       icon: "square.and.arrow.down.on.square", enabled: canImport) { importGames() }
                choice("Import Saves & Game Data…", detail: "Progress and settings from another launcher",
                       icon: "arrow.down.doc", enabled: canImport) { importData() }
            }
            .padding(8)
            .frame(width: 300)
        }
    }

    private func choice(_ title: String, detail: String, icon: String, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        Button {
            choosing = false
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 24).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowStyle())
        .disabled(!enabled)
    }
}

/// A row that highlights under the pointer, for choices in a popover.
private struct PopoverRowStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? 1 : 0.4)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.25 : (hovering && enabled ? 0.12 : 0))))
            .onHover { hovering = $0 }
    }
}
