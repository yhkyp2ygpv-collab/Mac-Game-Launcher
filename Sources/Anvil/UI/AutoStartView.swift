import SwiftUI

/// Auto start's wait for a connection: what it's waiting for, for how long, and the ways out.
struct AutoStartPanel: View {
    let waiting: AutoStart.Waiting
    @ObservedObject private var auto = AutoStart.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Waiting for internet to start \(waiting.title)")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("It needs internet to start: it signs in to its store every time it starts, and with no connection it stays on its loading screen. Anvil starts it by itself as soon as there's a connection, with your saves, FSR and everything else as usual. Once it's past its loading screen you can go offline and it keeps playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: waiting.since, by: 1)) { context in
                        Text("Waiting \(Self.clock(context.date.timeIntervalSince(waiting.since)))")
                            .monospacedDigit()
                    }
                    Text(waiting.reason.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Start Offline Anyway") { auto.startOfflineAnyway() }
                    .help("Starts it now with no connection. It has stayed on its loading screen every time it was started like this.")
                Spacer()
                Button("Cancel") { auto.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 4)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The panel over a window, the window dimmed behind it: the main window's, or a game's page
/// (a sheet, which would otherwise cover the main window's copy).
private struct AutoStartOverlay: ViewModifier {
    let sheetGameID: UUID?
    @ObservedObject private var auto = AutoStart.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if let waiting = auto.waiting, shows(waiting) {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        AutoStartPanel(waiting: waiting)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: auto.waiting?.id)
            .onAppear { if let id = sheetGameID { auto.sheetGameID = id } }
            .onDisappear { if let id = sheetGameID, auto.sheetGameID == id { auto.sheetGameID = nil } }
    }

    private func shows(_ waiting: AutoStart.Waiting) -> Bool {
        if let id = sheetGameID { return waiting.gameID == id }
        return auto.sheetGameID != waiting.gameID
    }
}

extension View {
    /// Auto start's wait over this view while it lasts. `sheetFor`: the game whose page this is.
    func autoStartOverlay(sheetFor gameID: UUID? = nil) -> some View {
        modifier(AutoStartOverlay(sheetGameID: gameID))
    }
}
