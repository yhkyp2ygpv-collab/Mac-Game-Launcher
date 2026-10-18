import Foundation

/// A launch log on disk.
///
/// The in-app log disappears with the window and cannot be read after the fact, so
/// "I pressed Play and nothing happened" had no evidence behind it — which is how
/// two rounds of guessing at the cause happened. Every step of a launch is written
/// here with a timestamp, so the next failure can be read rather than theorised.
enum AnvilLog {
    private static let queue = DispatchQueue(label: "anvil.log")

    static var url: URL {
        RuntimeManager.support.appendingPathComponent("anvil.log")
    }

    /// Made once: every line a game prints comes through here.
    private static let stamper = ISO8601DateFormatter()

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(stamper.string(from: now))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: RuntimeManager.support, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// The last `bytes` of the log, after everything written so far has reached it.
    static func tail(bytes: Int) -> String? {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
            guard let data = try? handle.readToEnd() else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The log was never trimmed and reached a megabyte in a month. Past 8 MB it is
    /// moved to anvil.old.log, replacing the previous one, so two files at most.
    static func rotateIfNeeded(limit: Int = 8_000_000) {
        queue.sync {
            let fm = FileManager.default
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit else { return }
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
    }
}
