import SwiftUI
import AppKit

// MARK: - Menu bar

/// Anvil's menu bar menu: the running game with Show, Quit and Force Quit — reachable
/// while the game has the screen and Anvil is hidden — and every game one click away.
struct MenuBarMenu: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var launcher: Launcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(launcher.sessions) { session in
            SwiftUI.Section(session.game.title) {
                Text("Playing since \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                Button("Show Game") { GameFocus.handOff(to: session.game, startedAt: session.startedAt) }
                if launcher.closing.contains(session.id) {
                    Text("Closing…")
                } else {
                    Button("Quit Game") { launcher.quit(session.game) }
                }
                Button("Force Quit Game") { launcher.forceQuit(session.game) }
            }
            Divider()
        }

        let games = QuickLaunch.recentGames(limit: 10).filter { !launcher.isRunning($0) }
        if !games.isEmpty {
            SwiftUI.Section("Play") {
                ForEach(games) { game in
                    Button(game.title) { QuickLaunch.play(game) }
                        .disabled(!game.exists || launcher.launching != nil)
                }
            }
            Divider()
        }
        if let status = launcher.launching {
            Text(status)
            Divider()
        }

        OfflineModeToggle()
        SurroundSoundMenuItems()
        Divider()
        Button("Open Anvil") {
            QuickLaunch.openWindowAction = openWindow
            QuickLaunch.showMainWindow()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Anvil") { NSApp.terminate(nil) }
    }
}

/// The menu bar icon: Anvil's own anvil, as a template so it follows the menu bar's
/// colour. Filled while a game runs.
struct MenuBarLabel: View {
    @EnvironmentObject private var launcher: Launcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: AnvilMark.template(filled: !launcher.sessions.isEmpty))
            .onAppear { QuickLaunch.openWindowAction = openWindow }
            .accessibilityLabel(launcher.sessions.isEmpty ? "Anvil" : "Anvil — a game is running")
    }
}

/// The anvil silhouette from the app icon, drawn for the menu bar.
enum AnvilMark {
    private static var cache: [Bool: NSImage] = [:]

    static func template(filled: Bool) -> NSImage {
        if let hit = cache[filled] { return hit }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            let w = bounds.width * 0.98, cx = bounds.midX
            let top = bounds.height * 0.74
            let bodyH = bounds.height * 0.2
            let faceL = cx - w * 0.36, faceR = cx + w * 0.26
            let p = NSBezierPath()
            p.move(to: NSPoint(x: faceL, y: top))
            p.line(to: NSPoint(x: faceR, y: top))
            p.curve(to: NSPoint(x: cx + w * 0.48, y: top - bodyH * 0.55),
                    controlPoint1: NSPoint(x: cx + w * 0.40, y: top),
                    controlPoint2: NSPoint(x: cx + w * 0.48, y: top - bodyH * 0.15))
            p.curve(to: NSPoint(x: faceR - w * 0.02, y: top - bodyH),
                    controlPoint1: NSPoint(x: cx + w * 0.43, y: top - bodyH * 0.9),
                    controlPoint2: NSPoint(x: cx + w * 0.36, y: top - bodyH))
            p.line(to: NSPoint(x: faceL + w * 0.03, y: top - bodyH))
            p.line(to: NSPoint(x: faceL - w * 0.06, y: top))
            p.close()
            let waistTop = top - bodyH, waistBot = waistTop - bounds.height * 0.24
            p.move(to: NSPoint(x: cx - w * 0.13, y: waistTop))
            p.curve(to: NSPoint(x: cx - w * 0.19, y: waistBot),
                    controlPoint1: NSPoint(x: cx - w * 0.18, y: waistTop - bounds.height * 0.1),
                    controlPoint2: NSPoint(x: cx - w * 0.21, y: waistBot + bounds.height * 0.07))
            p.line(to: NSPoint(x: cx + w * 0.19, y: waistBot))
            p.curve(to: NSPoint(x: cx + w * 0.13, y: waistTop),
                    controlPoint1: NSPoint(x: cx + w * 0.21, y: waistBot + bounds.height * 0.07),
                    controlPoint2: NSPoint(x: cx + w * 0.18, y: waistTop - bounds.height * 0.1))
            p.close()
            let baseH = bounds.height * 0.11
            p.append(NSBezierPath(roundedRect: NSRect(x: cx - w * 0.33, y: waistBot - baseH, width: w * 0.66, height: baseH),
                                  xRadius: baseH * 0.3, yRadius: baseH * 0.3))
            NSColor.black.set()
            if filled {
                p.fill()
            } else {
                p.lineWidth = 1.3
                p.lineJoinStyle = .round
                p.stroke()
            }
            return true
        }
        image.isTemplate = true
        cache[filled] = image
        return image
    }
}

// MARK: - Game menu

/// The Game menu in the menu bar: play the last game, and close the running one.
struct GameCommands: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var library: Library

    var body: some View {
        if let last = QuickLaunch.lastPlayed, !launcher.isRunning(last) {
            Button("Play \(last.title)") { QuickLaunch.play(last) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(launcher.launching != nil || !last.exists)
        } else {
            Button("Play Last Game") {}
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(true)
        }
        Divider()
        if let session = launcher.sessions.last {
            Button("Show \(session.game.title)") { GameFocus.handOff(to: session.game, startedAt: session.startedAt) }
            Button("Quit \(session.game.title)") { launcher.quit(session.game) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(launcher.closing.contains(session.id))
            Button("Force Quit \(session.game.title)") { launcher.forceQuit(session.game) }
                .keyboardShortcut(".", modifiers: [.command, .option])
        } else {
            Button("Quit Game") {}
                .keyboardShortcut(".", modifiers: .command)
                .disabled(true)
        }
        Divider()
        OfflineModeToggle()
    }
}

/// Offline Mode, as a menu item with a check mark.
struct OfflineModeToggle: View {
    @ObservedObject private var connectivity = Connectivity.shared

    var body: some View {
        Toggle("Offline Mode", isOn: Binding(get: { connectivity.offlineMode },
                                             set: { connectivity.setOfflineMode($0) }))
    }
}

// MARK: - Settings

struct AnvilSettingsView: View {
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage(PowerState.keepAwakeKey) private var keepAwake = true
    @AppStorage(PowerState.longSessionsKey) private var longSessions: PowerState.LongSessions = .automatic
    @ObservedObject private var power = PowerState.shared
    @ObservedObject private var connectivity = Connectivity.shared

    var body: some View {
        Form {
            Toggle("Offline Mode", isOn: Binding(get: { connectivity.offlineMode },
                                                 set: { connectivity.setOfflineMode($0) }))
            Text("Play without connecting, even when the Mac is online. Epic games start in Epic's own offline mode as your account, with your saves; Anvil downloads nothing until it's off. A game that needs a connection to play still needs one. Without a connection Anvil does this by itself.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show Anvil in the menu bar", isOn: $showMenuBarIcon)
            Text("Quit, force quit or switch to a running game from the menu bar while it has the screen, and start any game in one click.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Keep the Mac awake while a game runs", isOn: $keepAwake)
            Text("A controller doesn't count as activity to macOS, so without this the display can sleep in the middle of a game played only on a pad.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Long sessions", selection: $longSessions) {
                ForEach(PowerState.LongSessions.allCases) { Text($0.title).tag($0) }
            }
            Text("For hours of play: an even 80 fps with no reaching for 120, and FSR 3 only when the GPU has time to spare, so the battery lasts and the Mac stays cool. A Mac that gets hot gets FSR 1 until it cools. Plugged in and cool, games run up to 120 as before. Takes effect at a game's next start.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SwiftUI.Section {
                SurroundSoundPanel()
            }

            LabeledContent("Game shortcuts") {
                Button("Show in Finder") {
                    let folder = ShortcutStore.folder
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            Text("Add a game there from its right-click menu or its settings. It then starts from Spotlight, Launchpad or the Dock — drag it to the Dock to keep it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if power.lowPowerMode {
                Label("Low Power Mode is on. macOS holds the CPU and GPU back, so games run slower until it is turned off in System Settings › Battery.",
                      systemImage: "bolt.slash.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SteamLibrarySettings()

            SwiftUI.Section("About") {
                LabeledContent("Version", value: "\(AnvilVersion.current) · \(AppProtection.editionName)")
                LabeledContent("Made by", value: "\(AppProtection.author), \(AppProtection.place)")
                Text(AppProtection.copyright).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Source code") {
                    Link("github.com/yhkyp2ygpv-collab/Mac-Game-Launcher", destination: AppProtection.sourceURL)
                }
                Text(AppProtection.licenceSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Protection") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("512-bit key belonging to this Mac")
                        Text("Engines sealed · Epic sign-in encrypted (AES-256)")
                        Text(AppProtection.isPublicEdition
                             ? "Self-checked at every start · closed to debuggers"
                             : "Private edition: no self-check, debuggable")
                        Text("Game files and saves left as they are")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                }
                Button("Run Setup Again…") {
                    UserDefaults.standard.set(false, forKey: SetupView.doneKey)
                    NotificationCenter.default.post(name: .anvilShowSetup, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: keepAwake) { _, _ in
            PowerState.shared.gamesRunning(Launcher.shared.sessions.map(\.game.title))
        }
    }
}

// MARK: - Now playing

/// A bar along the bottom of the window for each running game: how long it has been
/// running, and Show, Quit and Force Quit, so closing a game never means hunting for it.
struct NowPlayingBar: View {
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var artwork: ArtworkStore
    @ObservedObject private var steam = SteamSupport.shared
    @State private var confirmQuit: Launcher.Session?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(launcher.sessions) { session in
                row(session)
            }
        }
        .confirmationDialog("\(confirmQuit?.game.title ?? "The game") is probably still loading",
                            isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } }),
                            presenting: confirmQuit) { session in
            Button("Show the Game") { GameFocus.handOff(to: session.game, startedAt: session.startedAt) }
            Button("Quit Anyway", role: .destructive) { launcher.quit(session.game) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(loadingNote(session, now: Date()) ?? "")
        }
    }

    /// While a game is still within the time it has taken to load before. Shown because a
    /// game loading looks exactly like a game stuck, and because it stops loading the moment
    /// another app — Anvil included — comes in front of it.
    private func loadingNote(_ session: Launcher.Session, now: Date) -> String? {
        guard launcher.readyAt[session.game.id] == nil else { return nil }
        let elapsed = now.timeIntervalSince(session.startedAt)
        let pauses = launcher.runsBehind.contains(session.game.id)
            ? "It keeps loading while you use other apps, and Anvil tells you when it's ready."
            : "It pauses while another app is in front, so press Show and leave it there."
        if let e = launcher.loadEstimates[session.game.id] {
            guard elapsed < e.longest + 20 else { return nil }
            let range = e.longest > e.typical * 1.3 ? ", up to \(LoadTime.text(e.longest))" : ""
            return "Loading takes about \(LoadTime.text(e.typical)) on this Mac\(range). " + pauses
        }
        guard elapsed < 120 else { return nil }
        return "Games can take a minute or two to load the first time. " + pauses
    }

    private func row(_ session: Launcher.Session) -> some View {
        let closing = launcher.closing.contains(session.id)
        return HStack(spacing: 12) {
            Group {
                if let image = artwork.thumbnail(for: session.game) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.game.title).font(.callout).bold().lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(closing ? Color.orange : Color.green).frame(width: 7, height: 7)
                    if closing {
                        Text("Closing…")
                    } else if launcher.readyAt[session.game.id] != nil {
                        Text("Ready ·")
                        Text(session.startedAt, style: .timer).monospacedDigit()
                    } else {
                        Text("Playing ·")
                        Text(session.startedAt, style: .timer).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !closing {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let note = loadingNote(session, now: context.date) {
                            VStack(alignment: .leading, spacing: 3) {
                                if let e = launcher.loadEstimates[session.game.id] {
                                    let elapsed = max(0, context.date.timeIntervalSince(session.startedAt))
                                    HStack(spacing: 6) {
                                        ProgressView(value: min(elapsed, e.typical), total: max(e.typical, 1)).frame(width: 140)
                                        Text("\(Int(elapsed)) s of about \(LoadTime.text(e.typical))").monospacedDigit()
                                    }
                                }
                                Text(note).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if let update = steam.updating[session.container.id] {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(update.percent), total: 100).frame(width: 90)
                        Text("Steam is updating — \(update.amounts). Leave it open until its window appears.")
                    }
                    .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            Button("Show") { GameFocus.handOff(to: session.game, startedAt: session.startedAt) }
                .help("Switch to the game")
            if closing {
                Button("Force Quit", role: .destructive) { launcher.forceQuit(session.game) }
                    .help("End it now. Anything unsaved in the game is lost.")
            } else {
                Menu {
                    Button("Force Quit", role: .destructive) { launcher.forceQuit(session.game) }
                } label: {
                    Text("Quit")
                } primaryAction: {
                    if loadingNote(session, now: Date()) != nil { confirmQuit = session }
                    else { launcher.quit(session.game) }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("Close the game the way its own close button would, so it can save")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}
