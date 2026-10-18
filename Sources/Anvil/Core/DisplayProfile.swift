import AppKit

/// The display games are played on, and what "steady" means on it.
///
/// Anvil's measure of a game running well was fixed at 80 fps: right for a MacBook Pro's
/// 120 Hz ProMotion panel, where 80 is the steady rate below 120 (two frames every three
/// refreshes), and impossible on a MacBook Air's 60 Hz display, where every game would
/// have read as failing, Auto-Tune would have chosen its lightest look and Autopilot a new
/// engine for nothing. The target follows the display now:
/// - 120 Hz ProMotion (MacBook Pro 14" and 16", M1 Pro and later): 80, as before;
/// - 60 Hz (MacBook Air, and most external displays): 60, the display's own rate;
/// - a faster variable-refresh display: two thirds of its rate, 96 at 144 Hz, as the
///   steady mode in libanvil holds it.
enum DisplayProfile {
    /// Set on the main thread at start and whenever the displays change; read anywhere.
    nonisolated(unsafe) private(set) static var maxHz: Double = 120
    nonisolated(unsafe) private(set) static var variableRefresh: Bool = true

    /// The frame rate a game should hold here to count as smooth.
    static var steadyTarget: Double {
        guard maxHz >= 90 else { return maxHz.rounded() }
        return variableRefresh ? (maxHz / 1.5).rounded() : (maxHz / 2).rounded()
    }

    /// The target as it is written in sentences: "80".
    static var targetText: String { String(Int(steadyTarget)) }

    /// A ProMotion-style panel, where the steady mode applies.
    static var steadyModeApplies: Bool { maxHz >= 90 && variableRefresh }

    /// Read the main display. Call on the main thread.
    @MainActor static func refresh() {
        guard let screen = NSScreen.main else { return }
        let hz = Double(screen.maximumFramesPerSecond)
        if hz > 0 { maxHz = hz }
        variableRefresh = screen.minimumRefreshInterval < screen.maximumRefreshInterval - 0.0005
    }

    /// Whether games' frames have been seen followed by this display: libanvil confirms it in a
    /// session by watching shown frames land between refreshes ("variable refresh confirmed" in
    /// game.log). The look is made on loading screens and menus, often at the display's own
    /// rate, where a panel that follows looks no different from one that doesn't — on 12 October
    /// LEGO Star Wars spent its first four minutes judged fixed, its frames held to the 120 Hz
    /// grid, on a MacBook Pro whose panel had been confirmed in 57 sessions before. Three
    /// confirmations in the recent log, and the display is taken as following from the start.
    nonisolated static func followsGamesConfirmed(log: URL) -> Int {
        guard variableRefresh, let handle = try? FileHandle(forReadingFrom: log) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 3_000_000 ? size - 3_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return 0 }
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "(variable refresh confirmed)").count - 1
    }

    /// Keep it current as displays come and go.
    @MainActor static func start() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in DisplayProfile.refresh() }
        }
        AnvilLog.write(String(format: "display: %.0f Hz%@ — games count as smooth at %@ fps or more",
                              maxHz, variableRefresh ? ", variable refresh" : "", targetText))
    }
}
