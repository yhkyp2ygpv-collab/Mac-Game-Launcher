import Foundation
import Darwin
import IOKit.ps

/// The memory warm-up: the parts of a game's data played most, read into the Mac's unified memory as it
/// starts, so the places played before load from memory rather than the disk.
///
/// A Mac keeps what it has read from disk in memory while there is room, and a game's second visit to a
/// place in a session reads it from there. The first visit each session reads it from disk: LEGO Star Wars
/// keeps 38 GB in nine archives of up to 4.3 GB, and on 13 October 21 of its 22 gaps of 100 ms or more came
/// as it reached somewhere new. libanvil (anvil_io.mm) counts, while the game plays, which 4 MB pieces of its
/// large files it reads — this session's in full, earlier sessions' at half — and at the next start the most
/// read are read ahead into memory, as many as fit in what the Mac has spare: never more than half of what's
/// free beyond 4 GB, nor more than 8 GB, half that on battery. The read runs below the game's own reads in
/// the disk's priority, so it never holds up what the game itself asks for. Only ever reads.
enum MemoryWarmup {
    nonisolated static var directory: URL {
        RuntimeManager.support.appendingPathComponent("Warmup", isDirectory: true)
    }

    static func stateURL(for gameID: UUID) -> URL {
        directory.appendingPathComponent("\(gameID.uuidString).txt")
    }

    static let pieceBytes: Int64 = 4 << 20

    /// One large file's pieces, as libanvil kept them.
    struct FileHeat: Equatable {
        var path: String
        var size: Int64
        var pieces: [(index: Int, count: Double)]
        static func == (a: FileHeat, b: FileHeat) -> Bool {
            a.path == b.path && a.size == b.size && a.pieces.map(\.index) == b.pieces.map(\.index)
                && a.pieces.map(\.count) == b.pieces.map(\.count)
        }
    }

    /// libanvil's file (anvil_io.mm's AnvilReadHeatSave), read.
    static func parse(_ text: String) -> [FileHeat] {
        guard text.hasPrefix("anvil-warm 1") else { return [] }
        var out: [FileHeat] = []
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("file ") {
                let rest = line.dropFirst(5)
                guard let space = rest.firstIndex(of: " "), let size = Int64(rest[..<space]) else { continue }
                out.append(FileHeat(path: String(rest[rest.index(after: space)...]), size: size, pieces: []))
            } else if line.hasPrefix("c "), !out.isEmpty {
                let f = line.split(separator: " ")
                guard f.count == 3, let i = Int(f[1]), let n = Double(f[2]), n > 0, i >= 0 else { continue }
                out[out.count - 1].pieces.append((i, n))
            }
        }
        return out.filter { !$0.pieces.isEmpty }
    }

    /// What the Mac has spare for it, in bytes: half of what's free beyond 4 GB, at most 8 GB — half that on
    /// battery. Zero when there's little to spare.
    static func budget(availableBytes: Int64, onBattery: Bool) -> Int64 {
        let gb: Int64 = 1 << 30
        var b = min(max(0, availableBytes - 4 * gb) / 2, 8 * gb)
        if onBattery { b /= 2 }
        return b >= 256 << 20 ? b : 0
    }

    /// The pieces to read, most read first, as many as fit: (file, offset, length), grouped by file in the
    /// order they sit in it, so the disk reads each file front to back. Files gone or changed are skipped.
    static func plan(_ files: [FileHeat], budget: Int64, exists: (String, Int64) -> Bool) -> [(path: String, offset: Int64, length: Int64)] {
        var all: [(path: String, size: Int64, index: Int, count: Double)] = []
        for f in files where exists(f.path, f.size) {
            for p in f.pieces where Int64(p.index) * pieceBytes < f.size { all.append((f.path, f.size, p.index, p.count)) }
        }
        all.sort { $0.count != $1.count ? $0.count > $1.count : ($0.path, $0.index) < ($1.path, $1.index) }
        var used: Int64 = 0
        var chosen: [(path: String, offset: Int64, length: Int64)] = []
        for p in all {
            let offset = Int64(p.index) * pieceBytes
            let length = min(pieceBytes, p.size - offset)
            if used + length > budget { break }
            used += length
            chosen.append((p.path, offset, length))
        }
        return chosen.sorted { ($0.path, $0.offset) < ($1.path, $1.offset) }
    }

    /// Memory the Mac could give: free, inactive, purgeable and speculative pages.
    static func availableBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count) + Int64(stats.speculative_count)
        return pages * Int64(vm_kernel_page_size)
    }

    /// The environment for a launch: where libanvil keeps where the game reads.
    static func environment(gameID: UUID, on: Bool) -> [String: String] {
        guard on else { return [:] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ["ANVIL_WARM_STATE": stateURL(for: gameID).path]
    }

    /// Read ahead for a game about to start, in the background; its line goes to the launch log when done.
    /// Returns at once.
    static func start(gameID: UUID, title: String, on: Bool, onBattery: Bool) {
        guard on else { return }
        let url = stateURL(for: gameID)
        Task.detached(priority: .utility) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                AnvilLog.write("  memory warm-up: \(title) — nothing to read ahead yet; Anvil notes which parts of its data are played as it runs")
                return
            }
            let files = parse(text)
            let budget = budget(availableBytes: availableBytes(), onBattery: onBattery)
            guard budget > 0 else {
                AnvilLog.write("  memory warm-up: \(title) — skipped, the Mac has little memory to spare right now")
                return
            }
            let pieces = plan(files, budget: budget) { path, size in
                ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value == size
            }
            guard !pieces.isEmpty else { return }
            let started = Date()
            let (bytes, count) = read(pieces)
            let seconds = Date().timeIntervalSince(started)
            let fileCount = Set(pieces.map(\.path)).count
            AnvilLog.write(String(format: "  memory warm-up: %@ — %.1f GB of the data played most read ahead into memory in %.1f s (%d pieces of %d file%@; up to %.1f GB spare)",
                                  title, Double(bytes) / 1_073_741_824, seconds, count, fileCount, fileCount == 1 ? "" : "s",
                                  Double(budget) / 1_073_741_824))
        }
    }

    /// The pieces read, below the game's own reads in the disk's priority. Bytes read and pieces.
    static func read(_ pieces: [(path: String, offset: Int64, length: Int64)]) -> (Int64, Int) {
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        defer { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_DEFAULT) }
        var buffer = [UInt8](repeating: 0, count: Int(pieceBytes))
        var bytes: Int64 = 0, done = 0
        var fd: Int32 = -1, openPath = ""
        for p in pieces {
            if p.path != openPath {
                if fd >= 0 { close(fd) }
                fd = open(p.path, O_RDONLY)
                openPath = p.path
            }
            guard fd >= 0 else { continue }
            let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(p.length), off_t(p.offset)) }
            if got > 0 { bytes += Int64(got); done += 1 }
        }
        if fd >= 0 { close(fd) }
        return (bytes, done)
    }

    /// Whether the Mac runs on its battery now.
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return source == kIOPSBatteryPowerValue
    }

    static func forget(gameID: UUID) {
        try? FileManager.default.removeItem(at: stateURL(for: gameID))
    }
}
