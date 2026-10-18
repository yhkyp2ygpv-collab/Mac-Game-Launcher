import SwiftUI
import AppKit

@main
struct AnvilApp: App {
    /// `Anvil --launch-test` runs the real Play path for the first game in the
    /// library and prints what happened, without needing anyone to click anything.
    /// It exists because two rounds were spent guessing at a launch failure that
    /// could not be reproduced from the outside.
    init() {
        // The public edition refuses to start if anything inside it was altered.
        AppProtection.checkAtLaunch()
        if CommandLine.arguments.contains("--launch-test") {
            LaunchSelfTest.run()
        }
        // One Anvil at a time. Two copies both edit the library and both launch into
        // the same prefixes; on 27 September one opened with `open` and one started
        // from Terminal each launched the game in the same second, and both games
        // exited within 0.3 seconds. A second copy now hands over to the first.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.anvil.launcher")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        if let first = others.first {
            // Unhide as well as activate: Anvil hides itself while a game runs, and
            // activating a hidden app leaves it hidden — so handing over to it made
            // "open Anvil" appear to do nothing at all.
            first.unhide()
            first.activate()
            exit(0)
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    @StateObject private var library = Library.shared
    @StateObject private var runtimes = RuntimeManager.shared
    @StateObject private var launcher = Launcher.shared
    @StateObject private var snapshots = SnapshotManager.shared
    @StateObject private var controllers = ControllerManager.shared
    @StateObject private var presets = PresetEngine.shared
    @StateObject private var upscalers = UpscalerManager.shared
    @StateObject private var artwork = ArtworkStore.shared
    @StateObject private var saves = SaveTransfer.shared
    @StateObject private var importer = GameImporter.shared
    @StateObject private var integrity = IntegrityChecker.shared
    @StateObject private var shortcuts = ShortcutStore.shared
    @StateObject private var power = PowerState.shared

    var body: some Scene {
        // One window. A WindowGroup offered File › New Window, and a second library
        // window launching into the same prefixes is the double-launch that killed both
        // games on 27 September.
        Window("Anvil", id: "main") {
            RootView()
                .onAppear { AppIconController.shared.start() }
                .environmentObject(library)
                .environmentObject(runtimes)
                .environmentObject(launcher)
                .environmentObject(snapshots)
                .environmentObject(controllers)
                .environmentObject(presets)
                .environmentObject(upscalers)
                .environmentObject(artwork)
                .environmentObject(saves)
                .environmentObject(importer)
                .environmentObject(integrity)
                .environmentObject(shortcuts)
                .environmentObject(power)
                .frame(minWidth: 1_040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Anvil") { AnvilApp.showAbout() }
            }
            CommandMenu("Game") {
                GameCommands(launcher: launcher, library: library)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Game…") { NotificationCenter.default.post(name: .anvilAddGame, object: nil) }
                    .keyboardShortcut("n")
                Button("Import Installed Games…") {
                    NotificationCenter.default.post(name: .anvilImportGames, object: nil)
                }
                .keyboardShortcut("i")
                Button("New Container…") { NotificationCenter.default.post(name: .anvilNewContainer, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        // Reachable while a game has the screen and Anvil is hidden behind it.
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarMenu()
                .environmentObject(library)
                .environmentObject(launcher)
        } label: {
            MenuBarLabel()
                .environmentObject(launcher)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            AnvilSettingsView()
        }
    }
}

extension AnvilApp {
    /// The standard About window, with who made Anvil and which edition this is.
    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "\(AppProtection.credit)\n\(AppProtection.editionName)\n\nThird-party software and licences: Anvil.app › Contents › Resources › Legal.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Anvil",
            .applicationVersion: AnvilVersion.current,
            .version: AnvilVersion.build,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): AppProtection.copyright,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
