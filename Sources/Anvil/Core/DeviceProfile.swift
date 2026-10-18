import Foundation
import Metal
import IOKit

/// What Anvil learned about this Mac in its setup: the chip, its graphics cores and
/// memory, the display, and how fast its GPU actually is, measured rather than looked up.
/// It decides where Anvil starts on a game it hasn't measured yet; Auto-Tune and
/// Autopilot then go by how each game really runs.
struct DeviceProfile: Codable, Hashable {
    enum Tier: String, Codable, Comparable {
        case entry, base, pro, max, ultra
        static func < (a: Tier, b: Tier) -> Bool { a.order < b.order }
        private var order: Int { [.entry, .base, .pro, .max, .ultra].firstIndex(of: self)! }
        var title: String {
            switch self {
            case .entry: "entry-level graphics"
            case .base: "standard graphics"
            case .pro: "Pro-class graphics"
            case .max: "Max-class graphics"
            case .ultra: "Ultra-class graphics"
            }
        }
    }

    var chip: String
    var model: String
    var performanceCores: Int
    var efficiencyCores: Int
    var gpuCores: Int?
    var memoryGB: Int
    var displayHz: Int
    var variableRefresh: Bool
    /// Measured single-precision throughput, in GFLOPS.
    var gpuGFLOPS: Double
    var tier: Tier
    var lowPowerMode: Bool
    var measuredAt: Date

    /// Where a game Anvil hasn't measured starts.
    var startingLevel: GraphicsLevel {
        if memoryGB <= 8 { return tier >= .pro ? .medium : .light }
        switch tier {
        case .entry: return .light
        case .base: return .medium
        case .pro, .max, .ultra: return .full
        }
    }

    var summary: String {
        var parts = ["\(chip)", "\(performanceCores)+\(efficiencyCores) CPU cores"]
        if let gpuCores { parts.append("\(gpuCores)-core GPU") }
        parts.append("\(memoryGB) GB")
        parts.append("\(displayHz) Hz\(variableRefresh ? " ProMotion" : "")")
        return parts.joined(separator: " · ")
    }

    // MARK: Kept

    nonisolated static var url: URL { RuntimeManager.support.appendingPathComponent("device.json") }

    nonisolated(unsafe) private static var cached: DeviceProfile??

    /// The profile from the setup, if it has run.
    static var current: DeviceProfile? {
        if let cached { return cached }
        let loaded = load()
        cached = .some(loaded)
        return loaded
    }

    /// Read from disk, as written by save().
    static func load() -> DeviceProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeviceProfile.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(self) {
            // Atomic where it can be; plainly where the folder forbids the temporary file.
            if (try? data.write(to: Self.url, options: .atomic)) == nil { try? data.write(to: Self.url) }
        }
        Self.cached = .some(self)
    }

    // MARK: Measuring

    /// Read the hardware and run the GPU test (about a second).
    @MainActor static func measure() async -> DeviceProfile {
        DisplayProfile.refresh()
        let sys = SystemInfo.current
        let gpuCores = graphicsCoreCount()
        let gflops = await Task.detached(priority: .userInitiated) { gpuThroughput() }.value
        let memoryGB = Int((Double(sys.memoryBytes) / 1_073_741_824).rounded())
        let profile = DeviceProfile(
            chip: sys.cpuBrand, model: sysctl("hw.model") ?? "Mac",
            performanceCores: sys.performanceCores, efficiencyCores: sys.efficiencyCores,
            gpuCores: gpuCores, memoryGB: memoryGB,
            displayHz: Int(DisplayProfile.maxHz.rounded()), variableRefresh: DisplayProfile.variableRefresh,
            gpuGFLOPS: gflops, tier: tier(gpuCores: gpuCores, gflops: gflops),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, measuredAt: Date())
        AnvilLog.write("device: \(profile.summary) — "
                       + (gflops > 0 ? String(format: "GPU measured at %.0f GFLOPS", gflops) : "GPU test couldn't run")
                       + " (\(profile.tier.title)); new games start at \(profile.startingLevel.title)")
        return profile
    }

    /// Graphics cores beat the measurement when they're known: a Mac in Low Power Mode,
    /// or warm, measures slower than it plays when plugged in.
    static func tier(gpuCores: Int?, gflops: Double) -> Tier {
        if let cores = gpuCores, cores > 0 {
            switch cores {
            case ...8: return .entry
            case ...10: return .base
            case ...20: return .pro
            case ...40: return .max
            default: return .ultra
            }
        }
        switch gflops {
        case ..<2_800: return .entry
        case ..<4_500: return .base
        case ..<9_000: return .pro
        case ..<20_000: return .max
        default: return .ultra
        }
    }

    /// The GPU's core count, as Apple's graphics driver publishes it.
    static func graphicsCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Fused multiply-adds across the whole GPU, timed by the GPU itself. Compiled at run
    /// time by Metal, so it needs no developer tools.
    nonisolated static func gpuThroughput() -> Double {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void anvil_fma(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float a = float(id) * 1e-7f, b = 1.000001f, c = 0.999999f;
            float x = a, y = a + 1.0f, z = a + 2.0f, w = a + 3.0f;
            for (int i = 0; i < 1024; i++) {
                x = fma(x, b, c); y = fma(y, b, c); z = fma(z, b, c); w = fma(w, b, c);
            }
            out[id] = x + y + z + w;
        }
        """
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "anvil_fma"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue() else { return 0 }
        let threads = 1 << 21
        guard let buffer = device.makeBuffer(length: threads * 4, options: .storageModePrivate) else { return 0 }
        let flopsPerDispatch = Double(threads) * 1024 * 4 * 2
        func run(_ dispatches: Int) -> Double {
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return 0 }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            let width = pipeline.maxTotalThreadsPerThreadgroup
            for _ in 0..<dispatches {
                encoder.dispatchThreads(MTLSize(width: threads, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            }
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            return commands.gpuEndTime - commands.gpuStartTime
        }
        _ = run(4)   // warm up: clocks rise, the pipeline is resident
        var best = 0.0
        for _ in 0..<3 {
            let seconds = run(24)
            if seconds > 0 { best = max(best, flopsPerDispatch * 24 / seconds / 1e9) }
        }
        return best
    }
}
