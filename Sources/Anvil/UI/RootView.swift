import SwiftUI
import UniformTypeIdentifiers

enum Section: Hashable {
    case library
    case container(UUID)
    case runtimes
    case activity
    case steam
    case epic
    case minecraft
    case checkUp
}

struct RootView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager
    @EnvironmentObject private var launcher: Launcher
    @ObservedObject private var connectivity = Connectivity.shared
    @ObservedObject private var tuner = Tuner.shared
    @ObservedObject private var autopilot = Autopilot.shared
    @ObservedObject private var checkUp = CheckUp.shared
    @ObservedObject private var saveChoice = SaveChoice.shared

    @Environment(\.openWindow) private var openWindow

    @State private var selection: Section = .library
    @State private var showNewContainer = false
    @State private var showWhatsNew = false
    @State private var showSetup = false
    @State private var newContainerName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                // Inset rather than overlaid, so the last row of games is never under it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !launcher.sessions.isEmpty {
                        NowPlayingBar()
                            .padding(.horizontal, 22).padding(.bottom, 14).padding(.top, 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: launcher.sessions.map(\.id))
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let checking = saveChoice.checking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(checking).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.bar))
                        .padding(.horizontal, 22).padding(.top, 8)
                    }
                }
        }
        .sheet(isPresented: $showNewContainer) { newContainerSheet }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
        .sheet(isPresented: $showSetup) { SetupView() }
        // A game back with saves from before it: which to play on (SaveVault).
        .sheet(item: $saveChoice.pending, onDismiss: { saveChoice.finish() }) { request in
            SaveChoiceSheet(choice: saveChoice, request: request)
        }
        .onAppear {
            // The first start: the setup. After that, what's new — shown once per version,
            // so it is obvious whether the running build includes a given fix.
            if !UserDefaults.standard.bool(forKey: SetupView.doneKey) {
                showSetup = true
                AnvilVersion.markVersionSeen()
            } else if AnvilVersion.isFirstRunOfThisVersion { showWhatsNew = true }
            QuickLaunch.openWindowAction = openWindow
        }
        .onReceive(NotificationCenter.default.publisher(for: .anvilNewContainer)) { _ in
            showNewContainer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .anvilShowSetup)) { _ in
            showSetup = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .anvilShowRuntimes)) { _ in
            selection = .runtimes
        }
        // What the check after a session found: said once, with the way to the details.
        .overlay(alignment: .top) {
            if let banner = autopilot.banner {
                HealthBanner(banner: banner, open: {
                    autopilot.banner = nil
                    selection = .library
                    // After the switch to the library, so its sheet is there to open.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .anvilShowGame, object: banner.gameID)
                    }
                }, close: { autopilot.banner = nil })
                .frame(maxWidth: 560)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(20))
                    if autopilot.banner?.id == banner.id { autopilot.banner = nil }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: autopilot.banner)
        // Every game whose last session hasn't been checked — the first start of a new
        // version reads the sessions played before it. The engine list is refreshed now
        // and then so a newer D3DMetal can be pointed out.
        .task {
            DisplayProfile.start()
            try? await Task.sleep(for: .seconds(2))
            let catalog = EngineCatalog.shared
            if Connectivity.isOnlineNow, catalog.lastChecked.map({ Date().timeIntervalSince($0) > 3 * 86_400 }) ?? true {
                await catalog.check()
            }
            // Anvil's own copy of every engine a container uses, before anything runs on it,
            // and its own Epic sign-in and legendary.
            await RuntimeManager.shared.ownEnginesInUse(by: library.containers)
            library.tidyEmptyStoreContainers()
            // Every engine sealed, and checked in full once a day; the Epic sign-in encrypted.
            await RuntimeManager.shared.checkSeals()
            EpicVault.sealLeftover()
            EpicVault.checkAtStart()
            // Engines installed or updated since the last start, made ready for this Mac —
            // in the background, offline or not, once nothing is running or starting.
            EngineOptimizer.shared.prepareWhenIdle(after: .seconds(30))
            await EpicAccount.shared.prepare()
            // Games installed in Steam or through Anvil's Epic since the last start.
            SteamSupport.shared.importGames()
            await EpicLibrary.shared.importInstalled()
            // Epic's list of games read again in the background a little after the start, when the
            // copy kept is old, so the Epic page opens with it at once — not with a game starting.
            Task {
                try? await Task.sleep(for: .seconds(20))
                guard Launcher.shared.sessions.isEmpty, Launcher.shared.launching == nil else { return }
                await EpicLibrary.shared.refreshIfStale(maxAge: 6 * 3600)
            }
            await autopilot.atLaunch()
            // Every game's graphics looked at before its first start, in the background.
            GraphicsScan.scanMissing()
            // Graphics Prep's archives for games no longer in the library.
            GraphicsPrep.tidy()
            // Everything else Anvil depends on, put right where it safely can be.
            await checkUp.run()
        }
        .overlay(alignment: .bottom) { busyBar }
        // Graphics Prep's wait before a start, wherever the start came from.
        .graphicsPrepOverlay()
        // Auto start waiting for a connection, wherever Play was pressed.
        .autoStartOverlay()
        // Auto-Tune finished: said once, wherever Anvil is.
        .alert(item: $tuner.announcement) { note in
            Alert(title: Text(note.title), message: Text(note.message + " See the game's Performance tab for what was measured."),
                  dismissButton: .default(Text("OK")))
        }
        .onAppear {
            // Land on the library, unless the user has containers but no games yet —
            // then the container is the thing they were most likely coming back to.
            if library.games.isEmpty, let first = library.containers.first {
                selection = .container(first.id)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            SwiftUI.Section {
                Label("Library", systemImage: "square.grid.2x2").tag(Section.library)
                Label("Activity", systemImage: "waveform").tag(Section.activity)
            }

            SwiftUI.Section("Containers") {
                ForEach(library.containers) { container in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(container.name)
                            Text(container.backend.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "cube.transparent")
                    }
                    .tag(Section.container(container.id))
                }
                Button {
                    showNewContainer = true
                } label: {
                    Label("New Container", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            SwiftUI.Section("Stores") {
                Label("Steam", systemImage: "cloud.fill").tag(Section.steam)
                Label("Epic Games", systemImage: "bag.fill").tag(Section.epic)
                Label("Minecraft", systemImage: "cube.fill").tag(Section.minecraft)
            }

            SwiftUI.Section("System") {
                Label("Runtimes", systemImage: "shippingbox").tag(Section.runtimes)
                Label("Check-Up", systemImage: "stethoscope")
                    .badge(checkUp.attention)
                    .tag(Section.checkUp)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        .safeAreaInset(edge: .bottom) { hostSummary }
    }

    private var hostSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().padding(.bottom, 4)
            Button {
                showWhatsNew = true
            } label: {
                HStack(spacing: 4) {
                    Text(AnvilVersion.display)
                        .font(.system(size: 10, design: .monospaced))
                    Image(systemName: "info.circle").font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("What's new in this version")

            if connectivity.offlineMode {
                Button {
                    connectivity.setOfflineMode(false)
                } label: {
                    Label("Offline Mode", systemImage: "airplane")
                        .font(.caption2).bold().foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Games start in Epic's offline mode and Anvil downloads nothing. Click to go back online.")
            } else if !connectivity.isOnline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.caption2).bold().foregroundStyle(.orange)
                    .help("Everything works offline. Games start in Epic's offline mode, and cover art and engine downloads wait for a connection.")
            }
            SurroundSoundStatus()
            Text(SystemInfo.current.gpuName).font(.caption).bold()
            Text("\(SystemInfo.current.totalCores) cores · \(SystemInfo.current.memoryGB) GB unified")
                .font(.caption2).foregroundStyle(.secondary)
            if !launcher.sessions.isEmpty {
                Text("\(launcher.sessions.count) running")
                    .font(.caption2).foregroundStyle(.green)
            }
            // Who made it: there, but quiet.
            Text(AppProtection.shortCredit)
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .padding(.top, 2)
                .help("\(AppProtection.credit) · \(AppProtection.copyright)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .library:
            LibraryView()
        case .container(let id):
            if let container = library.container(id: id) {
                ContainerDetailView(containerID: container.id)
                    .id(container.id)
            } else {
                ContentUnavailableView("Container not found", systemImage: "questionmark.folder")
            }
        case .runtimes:
            RuntimesView()
        case .activity:
            ActivityView()
        case .steam:
            SteamStoreView()
        case .epic:
            EpicStoreView()
        case .minecraft:
            MinecraftView()
        case .checkUp:
            CheckUpView(showEngines: { selection = .runtimes })
        }
    }

    // MARK: New container

    private var newContainerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Container").font(.title2).bold()
            Text("A container is an isolated Windows environment. Give each game engine its own — a bad DLL override in one can never reach another.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $newContainerName, prompt: Text("e.g. Unreal Titles"))
                .textFieldStyle(.roundedBorder)

            if let runtime = runtimes.defaultRuntime {
                Label("Will use \(runtime.displayName)\(runtime.hasD3DMetal ? " · D3DMetal available" : "")",
                      systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("No usable Wine runtime found. Open Runtimes to install one.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { showNewContainer = false }
                Button("Create") {
                    guard let runtime = runtimes.defaultRuntime else { return }
                    let name = newContainerName.isEmpty ? "Container \(library.containers.count + 1)" : newContainerName
                    showNewContainer = false
                    newContainerName = ""
                    Task { await library.createContainer(named: name, runtime: runtime) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(runtimes.defaultRuntime == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private var busyBar: some View {
        if let message = library.busyMessage {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message).font(.callout)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
