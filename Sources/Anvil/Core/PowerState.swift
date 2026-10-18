import Foundation

/// Lines from the running games and the launch steps, for the Activity screen.
@MainActor
final class LaunchOutput: ObservableObject {
    @Published private(set) var lines: [String] = []

    func append(_ text: String) {
        lines.append(contentsOf: text.split(separator: "\n").map(String.init))
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
    }
}

/// What the Mac's power state allows a game, and keeping the Mac awake while one runs.
///
/// A controller is not keyboard or mouse input as far as macOS's idle timer goes, so a
/// long session played only on a pad let the display sleep mid-game (display sleep is
/// set to 120 minutes on this Mac; the last LEGO session ran 92). While any game runs
/// Anvil holds the same assertion a video player does.
@MainActor
final class PowerState: ObservableObject {
    static let shared = PowerState()

    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    private var activity: NSObjectProtocol?

    private init() {
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in PowerState.shared.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in PowerState.shared.thermal = ProcessInfo.processInfo.thermalState }
        }
    }

    /// For the launch log: a slow session on Low Power Mode or a hot Mac is not a bug.
    var summary: String {
        let heat: String = switch thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious — macOS is slowing the Mac down"
        case .critical: "critical — macOS is slowing the Mac down hard"
        @unknown default: "unknown"
        }
        return "Low Power Mode \(lowPowerMode ? "ON — CPU and GPU held back" : "off"), thermal \(heat)"
    }

    /// Long sessions: hours of play on a MacBook. On battery, in Low Power Mode or with the Mac
    /// hot, frames past an even 80 cost power and heat for little — LEGO Star Wars let run at
    /// 95–110 fps kept the GPU 90–100% busy on 3 October. libanvil then holds an even 80 with no
    /// looking for 120, and runs FSR 3 only in the GPU's spare time (ANVIL_ENDURANCE).
    enum LongSessions: String, CaseIterable, Identifiable {
        case automatic, always, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "On battery, in Low Power Mode or hot"
            case .always: "Always"
            case .never: "Never"
            }
        }
        var environmentValue: String {
            switch self {
            case .automatic: "auto"
            case .always: "1"
            case .never: "0"
            }
        }
        var launchLine: String {
            switch self {
            case .automatic: "automatic — an even 80 on battery, in Low Power Mode or with the Mac hot; up to 120 plugged in"
            case .always: "always — an even 80 all session, FSR 3 only in the GPU's spare time"
            case .never: "never — up to 120 whatever the power (a hot Mac isn't eased either)"
            }
        }
    }
    nonisolated static let longSessionsKey = "longSessions"
    nonisolated static var longSessions: LongSessions {
        UserDefaults.standard.string(forKey: longSessionsKey).flatMap(LongSessions.init(rawValue:)) ?? .automatic
    }

    /// Settings switch; on unless turned off.
    static let keepAwakeKey = "keepAwakeWhilePlaying"
    static var keepAwake: Bool { UserDefaults.standard.object(forKey: keepAwakeKey) as? Bool ?? true }

    /// Called with the titles of the games now running.
    func gamesRunning(_ titles: [String]) {
        if titles.isEmpty || !Self.keepAwake {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Playing \(titles.joined(separator: ", "))")
        }
    }
}
