import Foundation
import Metal
import MetalFX

/// Metal 4 and MetalFX capability, read from the running system rather than assumed.
///
/// Metal 4 matters here for three things a game can benefit from without being
/// rewritten: a far cheaper command-encoding path, a compiler/archive model that
/// lets pipelines be built ahead of time instead of mid-frame, and MTL4's machine
/// learning pipelines, which are what MetalFX's temporal scaler runs on.
struct MetalCapability {
    let hasMetal4: Bool
    let hasMLPipelines: Bool
    let hasMetalFXSpatial: Bool
    let hasMetalFXTemporal: Bool
    let hasMetalFXDenoisedTemporal: Bool
    let hasFrameInterpolation: Bool
    let supportsResidencySets: Bool
    /// Ray tracing in the GPU's own hardware: Apple's family 9 GPUs (M3, M4 and later). Earlier ones trace rays
    /// in their shader cores, at a cost no game's ray-traced effects are worth.
    let hardwareRayTracing: Bool
    let deviceName: String

    static let current = MetalCapability()

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        deviceName = device?.name ?? "No Metal device"
        hardwareRayTracing = device?.supportsFamily(.apple9) == true

        // Protocol lookup is the honest test: it reports what this OS actually
        // exposes, not what the SDK was built against.
        hasMetal4 = NSProtocolFromString("MTL4CommandQueue") != nil
                 || NSProtocolFromString("MTL4CommandBuffer") != nil
        hasMLPipelines = NSProtocolFromString("MTL4MachineLearningPipelineState") != nil
                      || NSClassFromString("MTL4MachineLearningPipelineDescriptor") != nil

        // Ask MetalFX about this specific device rather than testing for class names.
        // Class lookup reports absent until the framework is loaded, which made an
        // M4 that supports all of this look like it supported none of it.
        if let device {
            hasMetalFXSpatial = MTLFXSpatialScalerDescriptor.supportsDevice(device)
            hasMetalFXTemporal = MTLFXTemporalScalerDescriptor.supportsDevice(device)
            if #available(macOS 26.0, *) {
                hasMetalFXDenoisedTemporal = MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
                hasFrameInterpolation = MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
            } else {
                hasMetalFXDenoisedTemporal = false
                hasFrameInterpolation = false
            }
            if #available(macOS 15.0, *) {
                supportsResidencySets = (try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor())) != nil
            } else {
                supportsResidencySets = false
            }
        } else {
            hasMetalFXSpatial = false
            hasMetalFXTemporal = false
            hasMetalFXDenoisedTemporal = false
            hasFrameInterpolation = false
            supportsResidencySets = false
        }
    }

    var summary: String {
        var parts: [String] = []
        if hasMetal4 { parts.append("Metal 4") }
        if hasMLPipelines { parts.append("ML pipelines") }
        if hasMetalFXTemporal { parts.append("MetalFX temporal") }
        if hasFrameInterpolation { parts.append("Frame interpolation") }
        if supportsResidencySets { parts.append("Residency sets") }
        return parts.isEmpty ? "Metal 3 only" : parts.joined(separator: " · ")
    }
}

/// Which Metal generation a container asks the translation layer to target.
enum MetalGeneration: String, Codable, CaseIterable, Identifiable {
    case automatic, metal3, metal4
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .metal3: "Metal 3 (compatibility)"
        case .metal4: "Metal 4"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Use Metal 4 where the runtime supports it, fall back to Metal 3 otherwise. The safe choice."
        case .metal3:
            "Force the older path. Use this if a game regressed after switching to Metal 4."
        case .metal4:
            "Force Metal 4: cheaper command encoding, ahead-of-time pipeline compilation from a Metal 4 archive, and residency sets instead of per-draw residency calls. The encoding and compilation wins are the ones that show up as fewer frame-time spikes."
        }
    }
}

struct Metal4Config: Codable, Hashable {
    var generation: MetalGeneration = .automatic
    var precompilePipelines: Bool = true      // build the shader archive before play
    var residencySets: Bool = true
    var metalFXFrameInterpolation: Bool = false
    var metalFXTemporalUpscaling: Bool = false

    /// Nothing, deliberately.
    ///
    /// This used to return MTL_ENABLE_METAL4, D3DM_METAL_VERSION, MTL_RESIDENCY_SETS,
    /// MTL_BINARY_ARCHIVE, MTL4_COMPILER_ARCHIVE, MTL_FX_* and a set of DXMT_* names.
    /// None exists in the D3DMetal binary of either installed engine, DXMT is not
    /// installed at all, and ANVIL_METAL_GENERATION was never read by the injector.
    /// Kept as a method so stored containers still decode; it contributes nothing.
    func environment(capability: MetalCapability) -> [String: String] { [:] }
}
