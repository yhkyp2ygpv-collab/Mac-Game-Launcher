import SwiftUI

/// What Anvil found looking over itself, the Mac and every game — and what it put right.
struct CheckUpView: View {
    var showEngines: () -> Void

    @ObservedObject private var checkUp = CheckUp.shared
    @State private var showEpicSignIn = false
    @State private var stopping = false

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack(spacing: 10) {
                    if checkUp.running {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    } else if let at = checkUp.checkedAt {
                        Image(systemName: checkUp.attention == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(checkUp.attention == 0 ? .green : .orange)
                        Text(checkUp.attention == 0 ? "Nothing needs you" : "\(checkUp.attention) thing\(checkUp.attention == 1 ? "" : "s") need\(checkUp.attention == 1 ? "s" : "") you")
                            .bold()
                        Text("· checked \(at.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Again") { Task { await checkUp.run() } }
                        .disabled(checkUp.running)
                }
                Text("Anvil checks this when it starts and after every game, with or without a connection, and fixes what it safely can by itself: copies of saves, offline starts made ready, files of its own left behind. What a game's sessions showed is on each game's Overview.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach([CheckUp.Item.State.problem, .fixed, .advice, .ok], id: \.self) { state in
                let rows = checkUp.items.filter { $0.state == state }
                if !rows.isEmpty {
                    SwiftUI.Section(title(state)) {
                        ForEach(rows) { row($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Check-Up")
        .task { if checkUp.checkedAt == nil { await checkUp.run() } }
        .sheet(isPresented: $showEpicSignIn, onDismiss: { Task { await checkUp.run() } }) { EpicSignInView() }
    }

    private func title(_ state: CheckUp.Item.State) -> String {
        switch state {
        case .problem: "Needs you"
        case .fixed: "Put right"
        case .advice: "Worth knowing"
        case .ok: "Fine"
        }
    }

    private func row(_ item: CheckUp.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(item.title).bold()
            } icon: {
                switch item.state {
                case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                case .fixed: Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.blue)
                case .advice: Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let action = item.action {
                Button(action.label) { perform(action) }
                    .controlSize(.small)
                    .disabled(stopping)
            }
        }
        .padding(.vertical, 2)
    }

    private func perform(_ action: CheckUp.Action) {
        switch action {
        case .epicSignIn:
            showEpicSignIn = true
        case .showEngines:
            showEngines()
        case .stopLeftovers:
            stopping = true
            Task { await checkUp.stopLeftovers(); stopping = false }
        case .testOffline:
            OfflineTest.shared.testAll()
        }
    }
}
