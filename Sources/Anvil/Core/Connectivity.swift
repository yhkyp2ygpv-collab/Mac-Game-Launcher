import Foundation
import Network
import os
import SystemConfiguration
import CFNetwork

/// Whether this Mac can reach the internet right now.
///
/// Everything in Anvil works without a connection — games, tuning, settings, saves.
/// A few things are better with one: the Epic sign-in that unlocks DLC, cover art, and
/// new engines. Those check here first, so an offline Mac gets the offline path at
/// once rather than after a network timeout: an Epic sign-in used to wait up to 30
/// seconds for legendary to give up before the game started offline.
///
/// Offline Mode makes Anvil behave exactly as it does with no connection while the Mac
/// stays connected for everything else: Epic games use Epic's own offline start, and Anvil
/// downloads and fetches nothing until it is switched off. A game that itself needs a
/// connection still needs one.
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    nonisolated static let offlineModeKey = "offlineMode"

    /// Online as far as Anvil is concerned: connected, and Offline Mode off.
    @Published private(set) var isOnline: Bool
    /// The Mac's own connection, whatever Offline Mode says.
    @Published private(set) var networkUp = true
    @Published private(set) var offlineMode: Bool
    /// When the connection last came back, for "downloads resume" style messages.
    @Published private(set) var cameOnlineAt: Date?

    private struct State: Sendable { var network = true; var offlineMode = false }

    /// Read from any thread. The monitor's own queue updates it.
    nonisolated static var isOnlineNow: Bool { state.withLock { $0.network && !$0.offlineMode } }
    nonisolated static var offlineModeNow: Bool { state.withLock { $0.offlineMode } }
    /// The Mac's own connection, whatever Offline Mode says.
    nonisolated static var networkUpNow: Bool { state.withLock { $0.network } }
    nonisolated private static let state = OSAllocatedUnfairLock(
        initialState: State(offlineMode: UserDefaults.standard.bool(forKey: offlineModeKey)))

    private let monitor = NWPathMonitor()
    private var waiting: [() -> Void] = []

    private init() {
        let chosen = UserDefaults.standard.bool(forKey: Self.offlineModeKey)
        offlineMode = chosen
        isOnline = !chosen
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Connectivity.state.withLock { $0.network = online }
            Task { @MainActor in Connectivity.shared.update(network: online) }
        }
        monitor.start(queue: DispatchQueue(label: "anvil.connectivity"))
    }

    /// Starts the monitor. Called once at launch so the first answer is ready before a
    /// game is started.
    func start() { _ = isOnline }

    private func update(network online: Bool) {
        guard online != networkUp else { return }
        networkUp = online
        AnvilLog.write(online ? "network: back online" : "network: offline — Anvil works offline; Epic sign-in, cover art and engine downloads wait for a connection")
        refresh()
    }

    func setOfflineMode(_ on: Bool) {
        guard on != offlineMode else { return }
        UserDefaults.standard.set(on, forKey: Self.offlineModeKey)
        Self.state.withLock { $0.offlineMode = on }
        offlineMode = on
        AnvilLog.write(on ? "offline mode: on — games start offline, and Anvil downloads nothing until it's off"
                          : "offline mode: off")
        refresh()
    }

    private func refresh() {
        let online = networkUp && !offlineMode
        guard online != isOnline else { return }
        isOnline = online
        if online {
            cameOnlineAt = Date()
            let pending = waiting
            waiting.removeAll()
            for work in pending { work() }
        }
    }

    /// Run `work` now if online, or as soon as the connection comes back.
    func whenOnline(_ work: @escaping () -> Void) {
        if isOnline { work() } else { waiting.append(work) }
    }

    /// Words for the sidebar and settings.
    var summary: String {
        if offlineMode { return "Offline Mode — games start offline; nothing is downloaded until it's off" }
        return isOnline ? "Online" : "Offline — games start offline; downloads wait for a connection"
    }

    /// The VPN this Mac's traffic goes through right now, by name when macOS knows it
    /// ("ProtonVPN"), else "a VPN" when a tunnel carries the network settings; nil when
    /// none. Steam picks its servers by where a connection seems to come from, and on
    /// 1 October, through Proton VPN, it tried servers from Frankfurt to Johannesburg and
    /// never signed in.
    nonisolated static func activeVPN() -> String? {
        if let prefs = SCPreferencesCreate(nil, "Anvil" as CFString, nil),
           let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            // SystemConfiguration's interface types; "VPN" (an app's own VPN, as Proton VPN
            // is) has no constant Swift can see.
            let tunnels: Set<String> = ["VPN", "PPP", "IPSec", "L2TP"]
            for service in services {
                guard let interface = SCNetworkServiceGetInterface(service),
                      let type = SCNetworkInterfaceGetInterfaceType(interface) as String?, tunnels.contains(type),
                      let id = SCNetworkServiceGetServiceID(service),
                      let connection = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil),
                      SCNetworkConnectionGetStatus(connection) == .connected else { continue }
                return (SCNetworkServiceGetName(service) as String?) ?? "a VPN"
            }
        }
        // Without its name: a tunnel interface among the scoped network settings.
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let scoped = settings["__SCOPED__"] as? [String: Any],
           scoped.keys.contains(where: { key in ["utun", "ipsec", "ppp", "tun", "tap"].contains { key.hasPrefix($0) } }) {
            return "a VPN"
        }
        return nil
    }

    /// Whether `url` answers at all within `timeout` — any reply counts. For a connection
    /// that is up but doesn't reach anywhere: a VPN still connecting, a network that wants
    /// its sign-in page first.
    nonisolated static func reaches(_ url: URL, timeout: TimeInterval) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
