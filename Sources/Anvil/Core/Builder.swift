import Foundation

/// Builds Anvil's hook — and, when a shader compiler is present, AMD's FSR — into a
/// Windows DLL, on this Mac, from source.
///
/// The output is the only binary that ends up in a game folder, and it was produced
/// here from AMD's published source plus Anvil's own hook file. No downloaded mod.
@MainActor
final class Builder: ObservableObject {

    @Published private(set) var log: [String] = []
    @Published private(set) var isBuilding = false
    @Published var lastProduct: URL?

    static let shared = Builder()
    private init() {}

    nonisolated static var buildDir: URL {
        RuntimeManager.support.appendingPathComponent("Build", isDirectory: true)
    }

    /// The hook alone. Needs only a C++ compiler, and produces a dxgi proxy that
    /// forwards correctly and intercepts Present.
    func buildHook(toolchain: Toolchain) async throws -> URL {
        guard let compiler = toolchain.path(for: .mingw) else {
            throw BuildError.missing(.mingw)
        }
        let source = Bundle.main.url(forResource: "anvil_hook", withExtension: "cpp")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Native/anvil_hook.cpp")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BuildError.sourceMissing(source.path)
        }

        try FileManager.default.createDirectory(at: Self.buildDir, withIntermediateDirectories: true)
        let output = Self.buildDir.appendingPathComponent("dxgi.dll")

        isBuilding = true
        defer { isBuilding = false }
        append("Building Anvil hook with \(URL(fileURLWithPath: compiler).lastPathComponent)…")

        try await run(compiler, [
            "-shared", "-O2", "-municode",
            "-static", "-static-libgcc", "-static-libstdc++",   // no runtime DLLs to ship
            "-o", output.path,
            source.path,
            "-ldxgi", "-ld3d12", "-lole32", "-luuid"
        ])

        append("Built \(output.lastPathComponent).")
        lastProduct = output
        return output
    }

    /// AMD's FidelityFX source, compiled here. This is the path that needs no
    /// third-party binary at all — you download AMD's SDK, Anvil builds it.
    func buildFSR(fromSDK sdkRoot: URL, toolchain: Toolchain) async throws -> URL {
        guard toolchain.has(.mingw) else { throw BuildError.missing(.mingw) }
        guard toolchain.has(.dxc) else { throw BuildError.missing(.dxc) }
        guard toolchain.has(.cmake) else { throw BuildError.missing(.cmake) }

        isBuilding = true
        defer { isBuilding = false }

        let build = Self.buildDir.appendingPathComponent("fsr", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

        append("Configuring AMD FidelityFX SDK…")
        try await run(toolchain.path(for: .cmake)!, [
            "-S", sdkRoot.path,
            "-B", build.path,
            "-DCMAKE_SYSTEM_NAME=Windows",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_CXX_COMPILER=\(toolchain.path(for: .mingw)!)",
            "-DFFX_API_BACKEND=DX12",
            "-DFFX_DXC_PATH=\(toolchain.path(for: .dxc)!)"
        ])

        append("Compiling…")
        try await run(toolchain.path(for: .cmake)!, ["--build", build.path, "--parallel",
                                                     String(SystemInfo.current.totalCores)])

        // Find whatever the build actually produced rather than assuming a filename.
        let produced = FileManager.default.enumerator(at: build, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "dll" } ?? []
        guard let product = produced.first else { throw BuildError.noProduct }

        append("Built \(produced.count) librar\(produced.count == 1 ? "y" : "ies").")
        lastProduct = product
        return product
    }

    // MARK: Process

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.append(text.trimmingCharacters(in: .newlines)) }
            }
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: BuildError.compileFailed(proc.terminationStatus)) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        log.append(contentsOf: text.split(separator: "\n").map(String.init))
        if log.count > 1500 { log.removeFirst(log.count - 1500) }
    }

    enum BuildError: LocalizedError {
        case missing(Toolchain.Component)
        case sourceMissing(String)
        case compileFailed(Int32)
        case noProduct

        var errorDescription: String? {
            switch self {
            case .missing(let c): return "\(c.title) is not installed. \(c.installHint)"
            case .sourceMissing(let p): return "Source file not found at \(p)."
            case .compileFailed(let code): return "The compiler exited with code \(code). See the build log."
            case .noProduct: return "The build finished but produced no DLL."
            }
        }
    }
}
