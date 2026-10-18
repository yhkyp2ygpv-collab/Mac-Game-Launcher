import Foundation
import Metal

/// Static facts about the host that drive Anvil's automatic tuning decisions.
struct SystemInfo {
    let cpuBrand: String
    let performanceCores: Int
    let efficiencyCores: Int
    let totalCores: Int
    let memoryBytes: UInt64
    let gpuName: String
    let gpuUnifiedMemory: Bool
    let recommendedVRAMMB: Int
    let macOSVersion: String
    let hasRosetta: Bool

    static let current = SystemInfo()

    private init() {
        cpuBrand = SystemInfo.sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        performanceCores = SystemInfo.sysctlInt("hw.perflevel0.logicalcpu") ?? SystemInfo.sysctlInt("hw.ncpu") ?? 8
        efficiencyCores = SystemInfo.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        totalCores = SystemInfo.sysctlInt("hw.ncpu") ?? 8
        memoryBytes = UInt64(SystemInfo.sysctlInt("hw.memsize") ?? 8 << 30)

        let device = MTLCreateSystemDefaultDevice()
        gpuName = device?.name ?? "Unknown GPU"
        gpuUnifiedMemory = device?.hasUnifiedMemory ?? true

        // On unified memory, "VRAM" is a budget hint handed to D3DMetal/DXVK, not a
        // hardware partition. Apple's recommendedMaxWorkingSetSize is the honest ceiling.
        if let device {
            recommendedVRAMMB = Int(device.recommendedMaxWorkingSetSize / (1024 * 1024))
        } else {
            recommendedVRAMMB = Int(memoryBytes / (1024 * 1024)) / 2
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        macOSVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        hasRosetta = SystemInfo.rosettaWorks()
    }

    /// Whether this Mac can actually run Intel code right now.
    ///
    /// This used to check that /usr/libexec/rosetta/oahd exists. After the macOS 27
    /// update that file was still there and Rosetta was not: every Intel binary failed
    /// with "Bad CPU type in executable", Wine included, while Anvil reported Rosetta
    /// as installed. The only honest test is to run something, so this runs Apple's
    /// own `true` as x86_64 — a few milliseconds — and asks whether it worked.
    static func rosettaWorks() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// True when the executable has no Apple-silicon slice, so it can only run
    /// through Rosetta. Read from the Mach-O header rather than assumed.
    static func needsRosetta(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 8 + 20 * 8), head.count >= 8 else { return false }
        try? handle.close()
        let bytes = [UInt8](head)
        func le32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24 }
        func be32(_ o: Int) -> UInt32 { UInt32(bytes[o]) << 24 | UInt32(bytes[o+1]) << 16 | UInt32(bytes[o+2]) << 8 | UInt32(bytes[o+3]) }
        let arm64: UInt32 = 0x0100_000C
        if le32(0) == 0xFEED_FACF { return le32(4) != arm64 }        // thin 64-bit
        if be32(0) == 0xCAFE_BABE {                                   // universal
            let count = Int(be32(4))
            for i in 0..<min(count, 8) where 8 + i * 20 + 4 <= bytes.count {
                if be32(8 + i * 20) == arm64 { return false }
            }
            return true
        }
        return false
    }

    var memoryGB: Int { Int(memoryBytes / (1024 * 1024 * 1024)) }

    /// Safe upper bound for a container's memory budget: never let a prefix claim
    /// so much that the compositor and wineserver start swapping.
    var maxAssignableMemoryMB: Int { max(2048, Int(memoryBytes / (1024 * 1024)) - 6144) }

    /// Memory as the kernel sees it right now, for the launch log.
    ///
    /// Swap is macOS's to decide — no app can forbid it — but whether a game is what
    /// pushes the Mac into it is a measurable question: swap in use when the game
    /// starts and when it ends, and how much memory was free.
    struct MemorySnapshot {
        var totalMB: Int
        var availableMB: Int      // free, inactive and speculative pages: reclaimable without swap
        var swapUsedMB: Int

        var summary: String {
            "\(availableMB) MB of \(totalMB) MB available, swap in use "
                + (swapUsedMB >= 0 ? "\(swapUsedMB) MB" : "unknown")
        }
    }

    static func memory() -> MemorySnapshot {
        let total = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)

        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapMB = sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0
            ? Int(usage.xsu_used / 1_048_576) : -1

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        var available = -1
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            available = Int(pages * UInt64(vm_kernel_page_size) / 1_048_576)
        }
        return MemorySnapshot(totalMB: total, availableMB: available, swapUsedMB: swapMB)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
