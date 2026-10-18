import Foundation

/// The compilers Anvil needs to turn AMD's published source into a library a game
/// can load. Nothing here is a mod or a third-party runtime — they are compilers,
/// and the output is built on this machine from source you downloaded yourself.
struct Toolchain {

    enum Component: String, CaseIterable, Identifiable {
        case mingw          // Windows-targeting C++ compiler
        case dxc            // HLSL -> DXIL, required for FSR's shaders
        case cmake          // AMD's build files are CMake
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mingw: "MinGW-w64 (Windows C++ compiler)"
            case .dxc: "DirectX Shader Compiler"
            case .cmake: "CMake"
            }
        }

        var why: String {
            switch self {
            case .mingw: "Compiles AMD's C++ into a Windows DLL that a game inside a container can load."
            case .dxc: "Compiles FSR's HLSL into the DXIL bytecode the shaders ship as. Without it the C++ builds but every FSR pass is empty."
            case .cmake: "Drives AMD's own build files."
            }
        }

        var probeBinaries: [String] {
            switch self {
            case .mingw: ["x86_64-w64-mingw32-g++", "x86_64-w64-mingw32-clang++"]
            case .dxc: ["dxc"]
            case .cmake: ["cmake"]
            }
        }

        var installHint: String {
            switch self {
            case .mingw: "brew install mingw-w64"
            case .dxc: "Built from source — Homebrew has no macOS package for it."
            case .cmake: "brew install cmake"
            }
        }

        var installableViaBrew: Bool { self != .dxc }
    }

    /// Where a component was found, if it was.
    private(set) var found: [Component: String] = [:]

    static func probe() -> Toolchain {
        var t = Toolchain()
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                           NSHomeDirectory() + "/Library/Application Support/Anvil/Toolchain/bin"]
        for component in Component.allCases {
            for binary in component.probeBinaries {
                for dir in searchPaths {
                    let path = dir + "/" + binary
                    if FileManager.default.isExecutableFile(atPath: path) {
                        t.found[component] = path
                        break
                    }
                }
                if t.found[component] != nil { break }
            }
        }
        return t
    }

    func path(for component: Component) -> String? { found[component] }
    func has(_ component: Component) -> Bool { found[component] != nil }

    var missing: [Component] { Component.allCases.filter { !has($0) } }

    /// C++ alone gets you a DLL that loads and hooks but whose FSR passes do nothing,
    /// so the distinction between "can build" and "can build usefully" matters.
    var canBuildHookOnly: Bool { has(.mingw) }
    var canBuildFSR: Bool { has(.mingw) && has(.dxc) }

    var summary: String {
        if canBuildFSR { return "Ready to build FSR from source." }
        if canBuildHookOnly { return "Can build the hook, but not FSR's shaders — DirectX Shader Compiler is missing." }
        return "No Windows-targeting compiler installed."
    }
}
