import Foundation

/// Point-in-time copies of a prefix, taken before anything risky.
///
/// On APFS these are `clonefile` copies: they take a second and almost no disk
/// until blocks diverge. That makes it cheap enough to snapshot automatically
/// before every runtime change, which is the actual answer to "update Metal
/// without losing progress or corrupting game files".
@MainActor
final class SnapshotManager: ObservableObject {

    struct Snapshot: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var containerID: UUID
        var label: String
        var createdAt: Date
        var runtimeID: String
        var sizeBytes: Int64

        var url: URL {
            RuntimeManager.snapshotsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        }
    }

    @Published private(set) var snapshots: [Snapshot] = []
    @Published var status: String?

    static let shared = SnapshotManager()
    private var indexURL: URL { RuntimeManager.snapshotsDir.appendingPathComponent("index.json") }

    private init() {
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([Snapshot].self, from: data) {
            snapshots = list
        }
    }

    func snapshots(for container: Container) -> [Snapshot] {
        snapshots.filter { $0.containerID == container.id }.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Create

    @discardableResult
    func snapshot(_ container: Container, label: String) async throws -> Snapshot {
        status = "Snapshotting “\(container.name)”…"
        defer { status = nil }

        var snap = Snapshot(containerID: container.id,
                            label: label,
                            createdAt: Date(),
                            runtimeID: container.runtimeID,
                            sizeBytes: 0)
        try FileManager.default.createDirectory(at: RuntimeManager.snapshotsDir, withIntermediateDirectories: true)
        try clone(from: container.prefixURL, to: snap.url)
        snap.sizeBytes = Self.size(of: snap.url)
        snapshots.append(snap)
        persist()
        return snap
    }

    /// `cp -Rc` asks APFS for a copy-on-write clone and falls back to a real copy on
    /// other filesystems, so this is correct either way — just slower off APFS.
    private func clone(from src: URL, to dst: URL) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rc", src.path, dst.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SnapshotError.cloneFailed }
    }

    // MARK: Restore

    /// Roll a prefix back. `preserveSaves` keeps everything under the Windows user
    /// profile — saves, configs, screenshots — at its current state while reverting
    /// the system side (registry, DLLs, runtime bindings) to the snapshot.
    func restore(_ snapshot: Snapshot, to container: Container, preserveSaves: Bool) async throws {
        // Never under a running game: the prefix would be swapped out from under it.
        guard !Launcher.shared.sessions.contains(where: { $0.container.id == container.id }),
              Launcher.shared.launching == nil else { throw SnapshotError.inUse }
        status = "Restoring “\(container.name)”…"
        defer { status = nil }

        let fm = FileManager.default
        // Wine's server for it stopped first, so nothing is writing the registry mid-swap.
        if let runtime = RuntimeManager.shared.runtime(id: container.runtimeID) {
            let server = runtime.wineserver, prefix = container.prefixURL
            await Task.detached(priority: .userInitiated) { Launcher.killPrefix(wineserver: server, prefix: prefix) }.value
        }
        // And its saves, whichever way the restore goes.
        let id = container.id, name = container.name, prefixURL = container.prefixURL, label = snapshot.label
        let names = SaveGuard.gameNames(in: container)
        let saved = await Task.detached(priority: .userInitiated) {
            SaveGuard.backUp(prefix: prefixURL, containerID: id, containerName: name,
                             reason: "Before restoring the snapshot “\(label)”", force: true, games: names)
        }.value
        AnvilLog.write("snapshot restore: \(saved.logLine)")
        let staging = RuntimeManager.snapshotsDir.appendingPathComponent("restore-\(UUID().uuidString)")

        // Build the restored prefix beside the live one, then swap. A crash mid-restore
        // leaves the original prefix untouched instead of half-written.
        try clone(from: snapshot.url, to: staging)

        if preserveSaves {
            let liveUsers = container.driveC.appendingPathComponent("users")
            let stagedUsers = staging.appendingPathComponent("drive_c/users")
            if fm.fileExists(atPath: liveUsers.path) {
                try? fm.removeItem(at: stagedUsers)
                try clone(from: liveUsers, to: stagedUsers)
            }
        }

        let retired = RuntimeManager.snapshotsDir.appendingPathComponent("retired-\(UUID().uuidString)")
        if fm.fileExists(atPath: container.prefixURL.path) {
            try fm.moveItem(at: container.prefixURL, to: retired)
        }
        do {
            try fm.moveItem(at: staging, to: container.prefixURL)
        } catch {
            // Swap failed — put the original back before surfacing the error.
            try? fm.moveItem(at: retired, to: container.prefixURL)
            throw error
        }
        // What it replaced goes to the Trash, not away for good: any game installed inside
        // the container since the snapshot is in it.
        if fm.fileExists(atPath: retired.path) {
            do { try fm.trashItem(at: retired, resultingItemURL: nil) }
            catch { AnvilLog.write("snapshot restore: the replaced copy of “\(container.name)” stays at \(retired.path)") }
        }
        AnvilLog.write("snapshot restore: “\(container.name)” restored from “\(snapshot.label)”\(preserveSaves ? ", saves kept as they were" : "")")
    }

    func delete(_ snapshot: Snapshot) {
        try? FileManager.default.removeItem(at: snapshot.url)
        snapshots.removeAll { $0.id == snapshot.id }
        persist()
    }

    // MARK: Runtime switching

    /// Change which toolchain a container runs on, with an automatic restore point.
    /// This is the "update Metal / D3DMetal safely" path.
    func switchRuntime(of container: inout Container, to runtime: Runtime) async throws {
        _ = try await snapshot(container, label: "Before switching to \(runtime.displayName)")
        container.runtimeID = runtime.id
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshots) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in walker {
            total += Int64((try? f.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
        return total
    }

    enum SnapshotError: LocalizedError {
        case cloneFailed
        case inUse
        var errorDescription: String? {
            switch self {
            case .cloneFailed: "Could not copy the container. Check free disk space."
            case .inUse: "A game is running or starting in this container. Quit it first, then restore."
            }
        }
    }
}
