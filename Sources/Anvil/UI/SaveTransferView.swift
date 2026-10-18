import SwiftUI

/// Import saves from another launcher's prefix into an Anvil container.
struct SaveTransferView: View {
    let container: Container
    /// When opened from a game, its own saves are found and ticked for you.
    var game: Game? = nil

    @EnvironmentObject private var transfer: SaveTransfer
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPrefix: SaveTransfer.ExternalPrefix?
    @State private var chosen: Set<String> = []
    @State private var error: String?
    @State private var includeRegistry = true
    @State private var autoPicked: Set<String>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                prefixList.frame(minWidth: 210)
                candidateList.frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .onAppear {
            transfer.discoverPrefixes()
            if let game { findSaves(for: game) }
        }
        .alert("Import failed", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.map { "Import Saves & Data for \($0.title)" } ?? "Import Saves").font(.title3).bold()
                Text("Copying into “\(container.name)”. Nothing is removed from the launcher you're importing from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Folder…") { addCustom() }
        }
        .padding(16)
    }

    private var prefixList: some View {
        List(selection: $selectedPrefix) {
            SwiftUI.Section("Found on this Mac") {
                ForEach(transfer.prefixes) { prefix in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(prefix.name).font(.callout)
                        Text(prefix.launcher).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(prefix)
                }
            }
        }
        .onChange(of: selectedPrefix) { _, new in
            // Switching source clears the ticks, except for the ones findSaves chose.
            chosen = autoPicked ?? []
            autoPicked = nil
            if let new { transfer.scan(new) }
        }
        .overlay {
            if transfer.prefixes.isEmpty {
                ContentUnavailableView("No other launchers found", systemImage: "magnifyingglass",
                                       description: Text("Use Add Folder to point at a prefix directly."))
            }
        }
    }

    private var candidateList: some View {
        Group {
            if selectedPrefix == nil {
                ContentUnavailableView("Choose a source", systemImage: "arrow.left",
                                       description: Text("Pick a container on the left to see its saves."))
            } else if transfer.scanning {
                ProgressView("Scanning…")
            } else if transfer.candidates.isEmpty {
                ContentUnavailableView("No saves found", systemImage: "tray",
                                       description: Text("Anvil looks in AppData, My Games, Saved Games and Documents."))
            } else {
                List {
                    ForEach(transfer.candidates) { candidate in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(candidate.id) },
                            set: { on in
                                if on { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName).font(.callout)
                                Text("\(candidate.publisher) · \(candidate.sizeDescription) · played \(candidate.modified.formatted(.relative(presentation: .named)))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Also copy registry settings", isOn: $includeRegistry)
                .toggleStyle(.checkbox)
                .help("Unity and older engines keep options, key bindings and sometimes progress in the Windows registry rather than in files.")
            if let status = transfer.status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(1)
            } else if !chosen.isEmpty {
                Text("\(chosen.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
            Button("Import Selected") { importSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
        }
        .padding(14)
    }

    /// Look through every launcher's prefix for this game's saves, open the first
    /// that has them, and tick them. Matched on the save folder's name against the
    /// game's title and executable, which is how every engine names it.
    private func findSaves(for game: Game) {
        let wanted = [game.title, game.executableURL.deletingPathExtension().lastPathComponent]
            .map(Self.squash).filter { $0.count >= 3 }
        func matches(_ candidate: SaveTransfer.SaveCandidate) -> Bool {
            let name = Self.squash(candidate.displayName)
            guard name.count >= 3 else { return false }
            return wanted.contains { $0 == name || $0.contains(name) || name.contains($0) }
        }
        for prefix in transfer.prefixes {
            transfer.scan(prefix)
            let hits = transfer.candidates.filter(matches)
            if !hits.isEmpty {
                autoPicked = Set(hits.map(\.id))
                selectedPrefix = prefix
                chosen = autoPicked ?? []
                return
            }
        }
        selectedPrefix = nil
        transfer.status = nil
    }

    /// Lowercase letters and digits only, so "Cat Quest II", "CatQuestII" and
    /// "cat_quest_ii" compare equal.
    private static func squash(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func addCustom() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Wine prefix (the folder containing drive_c), or drive_c itself."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let prefix = transfer.addCustomPrefix(url) {
            selectedPrefix = prefix
            transfer.scan(prefix)
        } else {
            error = transfer.status
        }
    }

    private func importSelected() {
        let picked = transfer.candidates.filter { chosen.contains($0.id) }
        for candidate in picked {
            do { try transfer.importSave(candidate, into: container) }
            catch { self.error = error.localizedDescription; return }
        }

        // A file-only import leaves registry-backed settings behind, which is why
        // this is on by default. Keys are matched on the save's own folder name.
        if includeRegistry, let prefix = selectedPrefix,
           let runtime = RuntimeManager.shared.runtime(id: container.runtimeID)
                       ?? RuntimeManager.shared.defaultRuntime {
            Task {
                for candidate in picked {
                    try? await transfer.importRegistry(from: prefix,
                                                       matching: candidate.displayName,
                                                       into: container, runtime: runtime)
                }
            }
        }
        chosen.removeAll()
    }
}
