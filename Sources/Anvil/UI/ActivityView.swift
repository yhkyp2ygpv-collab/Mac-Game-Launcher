import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var launcher: Launcher
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var runtimes: RuntimeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if launcher.sessions.isEmpty {
                ContentUnavailableView("Nothing running", systemImage: "waveform",
                                       description: Text("Launch a game and its live output appears here."))
                    .frame(maxHeight: 220)
            } else {
                ForEach(launcher.sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.game.title).bold()
                            Text("Started \(session.startedAt.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if launcher.closing.contains(session.id) {
                            Text("Closing…").foregroundStyle(.secondary)
                        } else {
                            Button("Quit") { launcher.quit(session.game) }
                        }
                        Button("Force Quit", role: .destructive) { launcher.forceQuit(session.game) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    Divider()
                }
            }

            Text("Output")
                .font(.headline)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)

            OutputList(output: launcher.output)
        }
        .navigationTitle("Activity")
    }
}

/// Observes the output on its own, so a busy game redraws only this list.
private struct OutputList: View {
    @ObservedObject var output: LaunchOutput

    var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(output.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("err:") ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .onChange(of: output.lines.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
    }
}

/// Shows the exact variable set a launch will use. Nothing Anvil does is hidden —
/// if a setting doesn't change anything here, it doesn't change anything at all.
struct EnvironmentInspector: View {
    let container: Container
    @EnvironmentObject private var runtimes: RuntimeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Launch Environment").font(.title3).bold()
                    Text("Applied to every game in “\(container.name)”")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }
            }
            .padding(18)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .frame(width: 620, height: 520)
    }

    private var text: String {
        guard let runtime = runtimes.runtime(id: container.runtimeID) ?? runtimes.defaultRuntime else {
            return "No runtime available."
        }
        let probe = Game(title: "probe", executablePath: "/probe.exe", containerID: container.id)
        let env = Launcher.shared.environment(for: probe, in: container, runtime: runtime)
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }
}
