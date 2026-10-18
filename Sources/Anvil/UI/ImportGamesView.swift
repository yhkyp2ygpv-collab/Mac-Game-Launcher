import SwiftUI

/// Pull in games another launcher already installed, rather than hunting for .exe
/// files by hand.
struct ImportGamesView: View {
    @EnvironmentObject private var importer: GameImporter
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    @State private var chosen: Set<String> = []
    @State private var targetContainer: UUID?
    @State private var sizeChecks: [String: Bool] = [:]
    @State private var shortfalls: [String: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 700, height: 500)
        .onAppear {
            SaveTransfer.shared.discoverPrefixes()
            importer.scan()
            targetContainer = library.containers.first?.id
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Installed Games").font(.title3).bold()
                Text("Found by reading what Mythic, Heroic and other launchers have installed. Nothing is copied or moved — Anvil launches them where they are.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { importer.scan() } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(16)
    }

    private var list: some View {
        Group {
            if importer.scanning {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if importer.discovered.isEmpty {
                ContentUnavailableView("No installed games found", systemImage: "magnifyingglass",
                                       description: Text("Anvil reads Mythic's and Heroic's install records, and looks inside other launchers' prefixes."))
            } else {
                List {
                    ForEach(importer.discovered) { game in
                        HStack(alignment: .top) {
                            Toggle(isOn: Binding(
                                get: { chosen.contains(game.id) },
                                set: { on in
                                    if on { chosen.insert(game.id) } else { chosen.remove(game.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(game.title).font(.callout).bold()
                                        if !game.exists {
                                            Text("MISSING").font(.system(size: 9)).bold()
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Color.red.opacity(0.2), in: Capsule())
                                                .foregroundStyle(.red)
                                        }
                                        if let short = shortfalls[game.id] {
                                            Text("\(short)% MISSING").font(.system(size: 9)).bold()
                                                .padding(.horizontal, 5).padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.2), in: Capsule())
                                                .foregroundStyle(.orange)
                                        } else if sizeChecks[game.id] == true {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.system(size: 10)).foregroundStyle(.green)
                                        }
                                    }
                                    Text("\(game.source) · \(game.sizeDescription)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(game.installPath)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!game.exists)

                            Spacer()
                            if let expected = game.expectedBytes, game.exists {
                                Button("Check size") {
                                    let r = IntegrityChecker.quickCheck(installPath: game.installPath,
                                                                        expectedBytes: expected)
                                    sizeChecks[game.id] = r.ok
                                    shortfalls[game.id] = IntegrityChecker.shortfall(
                                        installPath: game.installPath, expectedBytes: expected)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Picker("Into", selection: $targetContainer) {
                ForEach(library.containers) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .frame(maxWidth: 240)
            if !shortfalls.isEmpty {
                Label("An incomplete install won't run correctly — finish downloading it in the launcher that owns it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done") { dismiss() }
            Button("Import \(chosen.count > 0 ? "\(chosen.count)" : "")") {
                guard let id = targetContainer, let container = library.container(id: id) else { return }
                for game in importer.discovered where chosen.contains(game.id) {
                    importer.import(game, into: container)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty || targetContainer == nil)
        }
        .padding(14)
    }
}

/// Baseline-and-verify for a game's files.
struct IntegrityView: View {
    let game: Game
    @EnvironmentObject private var checker: IntegrityChecker
    @State private var report: IntegrityChecker.Report?
    @State private var error: String?

    var body: some View {
        Group {
            if let manifest = checker.manifest(for: game) {
                LabeledContent("Baseline") {
                    Text("\(manifest.fileCount) files · \(ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file)) · \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        do { report = try await checker.verify(game) }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label("Verify Files Now", systemImage: "checkmark.shield")
                }
                .disabled(checker.busy)
            } else {
                Text("No baseline yet. Record one while the game is known-good, and Anvil can tell you afterwards exactly which files changed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    do { _ = try await checker.recordBaseline(for: game) }
                    catch { self.error = error.localizedDescription }
                }
            } label: {
                Label(checker.hasBaseline(for: game) ? "Re-record Baseline" : "Record Baseline",
                      systemImage: "doc.badge.plus")
            }
            .disabled(checker.busy)

            if checker.busy {
                ProgressView(value: checker.progress)
                Text(checker.status ?? "Working…").font(.caption).foregroundStyle(.secondary)
            } else if let report {
                Label(report.summary,
                      systemImage: report.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(report.isClean ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array((report.missing.prefix(5) + report.modified.prefix(5)).enumerated()),
                        id: \.offset) { _, path in
                    Text(path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Text("Anvil compares against the baseline you recorded, not the publisher's hashes — it has no access to those. What it finds is drift from a known-good state: a failed update, an interrupted copy, disk corruption, or a mod.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
