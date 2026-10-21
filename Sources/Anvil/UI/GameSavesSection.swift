import AppKit
import SwiftUI

/// A game's saves out of Anvil and back, and deleting a game while keeping them. See GameSaves.
struct GameSavesSection: View {
    let gameID: UUID
    /// Called once the game is gone from the library, so its page can close.
    var onDeleted: () -> Void = {}

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var launcher: Launcher
    @State private var working: String?
    @State private var message: String?
    @State private var failure: String?
    @State private var confirmDelete = false
    /// What the game's folder takes, measured when the delete is asked for.
    @State private var folderBytes: Int64?
    @State private var offered = false
    @ObservedObject private var saveChoice = SaveChoice.shared

    private var game: Game? { library.games.first { $0.id == gameID } }

    var body: some View {
        Group {
            Button { Task { await export() } } label: {
                Label("Export Saves…", systemImage: "square.and.arrow.up")
            }
            .disabled(working != nil || game == nil)
            Button {
                if let game { Task { await SaveChoice.shared.askIfNeeded(game, force: true); offered = true } }
            } label: {
                Label("Choose Saves from Before…", systemImage: "clock.arrow.circlepath")
            }
            .disabled(working != nil || game == nil || running || saveChoice.pending != nil)
            if offered, saveChoice.pending == nil, game.map({ SaveVault.askedUpTo($0) }) == 0 {
                Text("No exports or other Windows setups with saves of this game were found. Restore from a File… picks any export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await restore() } } label: {
                Label("Restore from a File…", systemImage: "doc.zipper")
            }
            .disabled(working != nil || game == nil || running)
            Button(role: .destructive) { askDelete() } label: {
                Label("Delete Game, Keep Saves…", systemImage: "trash")
            }
            .disabled(working != nil || game == nil || running)
            if let working {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working).font(.caption) }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Export puts this game's saves in one .zip file — only its saves, not the game — kept in Documents › Anvil Saves and in Anvil too. Choose Saves from Before lists every export of this game and any other Windows setup that has its saves, by date, and puts the one you pick back; what it has now is exported first, and anything in the way is moved aside, not overwritten. Delete exports the saves first, then moves the game's folder to the Trash, or deletes it at once to free the space now.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Export Saves and Move to Trash", role: .destructive) { Task { await deleteKeepingSaves(permanently: false) } }
            if game.map({ GameRemoval.plan(for: $0).folder != nil }) == true {
                Button("Export Saves and Delete Now\(folderBytes.map { " (frees \(EpicLibrary.bytes($0)))" } ?? "")", role: .destructive) {
                    Task { await deleteKeepingSaves(permanently: true) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var running: Bool { game.map { launcher.isBusy($0) } ?? false }

    private var others: Bool {
        guard let game else { return true }
        return library.games.contains { $0.id != game.id && $0.containerID == game.containerID }
    }

    private var deleteTitle: String { "Delete \(game?.title ?? "this game")?" }

    private func askDelete() {
        folderBytes = nil
        confirmDelete = true
        guard let game else { return }
        let plan = GameRemoval.plan(for: game)
        folderBytes = plan.bytes
        if plan.bytes == nil, let folder = plan.folder {
            Task { folderBytes = await Task.detached(priority: .userInitiated) { EpicLibrary.allocatedSize(of: folder) }.value }
        }
    }

    private var deleteMessage: String {
        guard let game else { return "" }
        let plan = GameRemoval.plan(for: game)
        var text = "Its saves are exported first, to Documents › Anvil Saves."
        if let folder = plan.folder {
            text += " Then its folder, \(folder.path)\(folderBytes.map { " (\(EpicLibrary.bytes($0)))" } ?? ""), goes to the Trash — you can take it back out until the Trash is emptied, and the space is freed then — or, with Delete Now, is deleted at once."
        } else if plan.steam {
            text += " Its files are Steam's: uninstall it in Steam to free the space. Anvil removes it from the library."
        } else {
            text += " Anvil can't tell which folder is only this game's, so its files stay where they are; it's removed from the library."
        }
        return text + " Its container and Anvil's save backups stay."
    }

    private static var savesFolder: URL { GameRemoval.savesFolder }

    private func export(to folder: URL? = nil) async -> URL? {
        guard let game, let container = library.container(id: game.containerID) else { return nil }
        var destination = folder
        if destination == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Where should \(game.title)'s saves go?"
            try? FileManager.default.createDirectory(at: Self.savesFolder, withIntermediateDirectories: true)
            panel.directoryURL = Self.savesFolder
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            destination = url
        }
        guard let destination else { return nil }
        working = "Exporting \(game.title)'s saves…"
        failure = nil
        defer { working = nil }
        let alone = !others
        do {
            let zip = try await Task.detached(priority: .userInitiated) {
                try GameSaves.export(game: game, container: container, aloneInContainer: alone, to: destination)
            }.value
            let size = ByteCountFormatter.string(fromByteCount: Int64((try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file)
            let places = SaveVault.keepCopy(of: zip)
            message = "Saved \(zip.lastPathComponent) (\(size)) in \(destination.lastPathComponent)" + (places.count > 1 ? ", with a copy kept in Anvil." : ".")
            AnvilLog.write("saves: \(game.title) — exported to \(zip.path) (\(size)); copies in \(places.count) place\(places.count == 1 ? "" : "s")")
            if folder == nil { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            return zip
        } catch {
            failure = error.localizedDescription
            AnvilLog.write("saves: \(game.title) — export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func restore() async {
        guard let game, let container = library.container(id: game.containerID) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Restore"
        panel.message = "Choose a save export of \(game.title)."
        panel.directoryURL = Self.savesFolder
        guard panel.runModal() == .OK, let zip = panel.url else { return }
        working = "Restoring saves…"
        failure = nil
        defer { working = nil }
        do {
            let manifest = try await Task.detached(priority: .userInitiated) { try GameSaves.restore(from: zip, into: container) }.value
            message = "Restored \(manifest.places.count) save folder\(manifest.places.count == 1 ? "" : "s") from \(manifest.game)'s export."
            AnvilLog.write("saves: \(game.title) — restored \(manifest.places.count) folder(s) from \(zip.lastPathComponent)")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func deleteKeepingSaves(permanently: Bool) async {
        guard let game else { return }
        working = permanently ? "Exporting the saves, then deleting \(game.title)…" : "Exporting the saves, then moving \(game.title) to the Trash…"
        failure = nil
        defer { working = nil }
        switch await GameRemoval.delete(game, permanently: permanently) {
        case .failed(let why):
            failure = why
        case .done(_, let zip):
            if let zip { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            onDeleted()
        }
    }
}
