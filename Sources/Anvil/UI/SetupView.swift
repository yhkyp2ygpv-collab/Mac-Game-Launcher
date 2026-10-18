import SwiftUI
import AppKit

/// The first start: Anvil gets to know the Mac, makes sure an engine is installed, and
/// connects the stores — so someone who has never used Wine, Mythic or Whisky is ready to
/// play when it closes.
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runtimes = RuntimeManager.shared
    @ObservedObject private var catalog = EngineCatalog.shared
    @ObservedObject private var steam = SteamSupport.shared
    @AppStorage(SetupView.doneKey) private var done = false

    static let doneKey = "setup.completed"

    enum Step: Int, CaseIterable { case welcome, mac, engine, stores, ready }
    @State private var step: Step = .welcome
    @State private var profile: DeviceProfile?
    @State private var measuring = false
    @State private var rosetta = true
    @State private var engineError: String?
    @State private var installingEngine = false
    @State private var steamError: String?
    @State private var showEpicSignIn = false
    @State private var importAfter = true

    init(start: Step = .welcome) { _step = State(initialValue: start) }

    var body: some View {
        VStack(spacing: 0) {
            progressDots.padding(.top, 18)
            Group {
                switch step {
                case .welcome: welcome
                case .mac: mac
                case .engine: engine
                case .stores: stores
                case .ready: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36).padding(.top, 18)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 640, height: 560)
        .animation(.easeInOut(duration: 0.25), value: step)
        .sheet(isPresented: $showEpicSignIn) { EpicSignInView() }
        .interactiveDismissDisabled()
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: s == step ? 22 : 8, height: 8)
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            Text("Welcome to Anvil").font(.system(size: 30, weight: .bold))
            Text("Play your Windows games from Steam and Epic on this Mac — set up, tuned and checked for you.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                feature("cpu", "Learns this Mac", "Measures its chip and graphics, so every game starts at settings it can hold.")
                feature("gauge.with.dots.needle.67percent", "Tunes every game", "Checks how each session ran and picks the best frame rate and look by itself.")
                feature("cart", "Steam and Epic built in", "No other launcher, engine or download to hunt for.")
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            Text(AppProtection.credit).font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mac: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Getting to know your Mac", "A short test of its graphics — about two seconds.")
            if measuring || profile == nil {
                HStack(spacing: 12) { ProgressView(); Text("Measuring…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let p = profile {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    fact("Chip", p.chip)
                    fact("Processor", "\(p.performanceCores) performance + \(p.efficiencyCores) efficiency cores")
                    fact("Graphics", [p.gpuCores.map { "\($0) cores" },
                                      p.gpuGFLOPS > 0 ? String(format: "%.1f TFLOPS measured", p.gpuGFLOPS / 1000) : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                    fact("Memory", "\(p.memoryGB) GB")
                    fact("Display", "\(p.displayHz) Hz" + (p.variableRefresh ? ", ProMotion" : ""))
                }
                .padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("What Anvil will do here").font(.headline)
                    bullet("Aim for a steady \(DisplayProfile.targetText) fps\(DisplayProfile.steadyModeApplies ? ", and \(p.displayHz) when a game can" : "").")
                    bullet("Start each new game at \(p.startingLevel.title) graphics, right for a Mac with \(p.tier.title), then measure it as you play and adjust.")
                    if p.memoryGB <= 8 { bullet("Keep memory use down: 8 GB is tight for big games, so close other apps while playing.") }
                    if p.lowPowerMode { bullet("Low Power Mode is on — games will be slower until it's off (System Settings › Battery).") }
                }
                .font(.callout)
                if !rosetta {
                    Notice2(text: "Rosetta isn't installed, and Windows games need it. Install it with this Terminal command, then come back:\nsoftwareupdate --install-rosetta --agree-to-license")
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            guard profile == nil else { return }
            measuring = true
            let measured = await DeviceProfile.measure()
            measured.save()
            rosetta = await Task.detached { SystemInfo.rosettaWorks() }.value
            profile = measured
            measuring = false
        }
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("The engine", "Windows games run on an engine: Wine, with Apple's D3DMetal for graphics.")
            if let best = runtimes.defaultRuntime, best.hasD3DMetal {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(best.displayName).font(.headline)
                        Text("D3DMetal \(best.d3dMetalVersion ?? "") · ready").foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2) }
                Text("Autopilot moves a game to a newer engine by itself when that makes it faster, and back if it doesn't.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("None is installed yet. Anvil downloads one from its publisher (about 200 MB) and keeps its own copy.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                switch catalog.state {
                case .downloading(let f):
                    ProgressView(value: f) { Text(String(format: "Downloading — %.0f%%", f * 100)).font(.caption) }
                case .verifying: ProgressView { Text("Checking the download…").font(.caption) }
                case .installing: ProgressView { Text("Installing…").font(.caption) }
                default:
                    Button(installingEngine ? "Getting the list…" : "Download the Engine") { installEngine() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(installingEngine)
                }
                if let engineError { Notice2(text: engineError) }
            }
            Spacer(minLength: 0)
        }
    }

    private var stores: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Your games", "Connect a store now, or later from the sidebar.")
            storeRow(symbol: "cloud.fill", title: "Steam",
                     detail: steam.isSetUp ? "Set up. Sign in to Steam in its own window the first time it opens."
                                           : "Installs Windows Steam from Valve, in a Windows setup of its own.") {
                if steam.isSetUp {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let status = steam.status {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(status).font(.caption) }
                } else {
                    Button("Set Up Steam") {
                        steamError = nil
                        Task { do { try await steam.setUp() } catch { steamError = error.localizedDescription } }
                    }
                    .disabled(runtimes.defaultRuntime == nil)
                }
            }
            storeRow(symbol: "bag.fill", title: "Epic Games",
                     detail: EpicAccount.isSignedIn ? "Signed in. Your games are listed on the Epic Games page."
                                                    : "Sign in once on Epic's own page; your password never reaches Anvil.") {
                if EpicAccount.isSignedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Sign In…") { showEpicSignIn = true }
                }
            }
            storeRow(symbol: "square.and.arrow.down.on.square", title: "Games already on this Mac",
                     detail: "From Mythic, Heroic, Whisky or CrossOver — added with their settings.") {
                Toggle("After setup", isOn: $importAfter).toggleStyle(.checkbox)
            }
            if let steamError { Notice2(text: steamError) }
            Spacer(minLength: 0)
        }
    }

    private func storeRow<Trailing: View>(symbol: String, title: String, detail: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var ready: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("Ready to play").font(.system(size: 28, weight: .bold))
            Text("Press Play on any game. Anvil checks how each session ran, fixes what it safely can, and tunes the game for this Mac as you play — that's Autopilot, on for every game.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(AppProtection.credit).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.top, 30)
    }

    // MARK: Pieces

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title).bold()
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark").labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .ready {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            }
            Spacer()
            if step == .ready {
                Button("Start Playing") { finish() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                if step != .welcome {
                    Button("Skip Setup") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button(step == .welcome ? "Set Up" : "Continue") { step = Step(rawValue: step.rawValue + 1) ?? .ready }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(step == .mac && measuring)
            }
        }
    }

    private func finish() {
        done = true
        dismiss()
        AnvilLog.write("setup: finished — \(profile?.summary ?? "Mac not measured")")
        let lookForGames = importAfter && step.rawValue >= Step.stores.rawValue
        Task { @MainActor in
            // Games already installed: Steam's, Epic's, then other launchers' (a sheet of its own).
            SteamSupport.shared.importGames()
            await EpicLibrary.shared.importInstalled()
            if lookForGames {
                try? await Task.sleep(for: .milliseconds(600))
                NotificationCenter.default.post(name: .anvilImportGames, object: nil)
            }
        }
    }

    private func installEngine() {
        installingEngine = true
        engineError = nil
        Task {
            defer { installingEngine = false }
            if catalog.releases.isEmpty { await catalog.check() }
            // The newest stable engine; a preview only when there's nothing else.
            guard let release = catalog.available(includePreview: false).first ?? catalog.available(includePreview: true).first else {
                engineError = "The engine list couldn't be fetched. Check the connection and try again."
                return
            }
            do { try await catalog.install(release) }
            catch { engineError = error.localizedDescription }
        }
    }
}

private struct Notice2: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Notification.Name {
    /// Settings › Run Setup Again.
    static let anvilShowSetup = Notification.Name("anvil.showSetup")
}
