import Foundation
import IOKit.hid

/// Raw HID enumeration of game controllers.
///
/// Apple's GameController framework only surfaces pads it has a profile for. A
/// PowerA wired pad plugged into this Mac returns nothing from
/// `GCController.controllers()` while IOKit reports it fine, and a Steam Controller
/// is never surfaced at all. Enumerating HID directly is the only way to see every
/// pad, wired or Bluetooth, branded or generic.
@MainActor
final class HIDControllerScanner: ObservableObject {

    struct Device: Identifiable, Hashable {
        var id: String { "\(vendorID)-\(productID)-\(locationID)" }
        var name: String
        var vendorID: Int
        var productID: Int
        var version: Int
        var transport: Transport
        var locationID: Int
        var family: ControllerFamily
        /// What the device itself says it has, read from its HID descriptor.
        var layout: HIDLayout = HIDLayout()
        /// Whether GameController also reports it, meaning full profile support.
        var hasNativeProfile: Bool = false

        enum Transport: String {
            case usb = "USB", bluetooth = "Bluetooth", other = "Other"

            var symbol: String {
                switch self {
                case .usb: "cable.connector"
                case .bluetooth: "wave.3.right"
                case .other: "questionmark"
                }
            }
        }

        var description: String {
            "\(family.displayName) · \(transport.rawValue)"
        }

        /// SDL identifies a controller by a 16-byte GUID built from bus type, vendor,
        /// product and version. A mapping keyed to the wrong GUID silently never
        /// applies, so this has to be derived from the real device rather than
        /// borrowed from another pad.
        var sdlGUID: String {
            let bus: UInt16 = transport == .bluetooth ? 0x05 : 0x03
            var bytes = [UInt8](repeating: 0, count: 16)
            func put(_ value: UInt16, at offset: Int) {
                bytes[offset]     = UInt8(value & 0xFF)
                bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
            }
            put(bus, at: 0)
            put(0, at: 2)                       // name CRC, optional
            put(UInt16(truncatingIfNeeded: vendorID), at: 4)
            put(0, at: 6)
            put(UInt16(truncatingIfNeeded: productID), at: 8)
            put(0, at: 10)
            put(UInt16(truncatingIfNeeded: version), at: 12)
            put(0, at: 14)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    @Published private(set) var devices: [Device] = []

    static let shared = HIDControllerScanner()
    private var manager: IOHIDManager?

    private init() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Everything that presents as a stick or pad, including the multi-axis
        // controllers that flight sticks and some third-party pads report as.
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)

        // Hotplug. GameController posts nothing for a pad it has no profile for, so
        // without this a controller connected while Anvil is running stays invisible
        // until something forces a rescan.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let onChange: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let scanner = Unmanaged<HIDControllerScanner>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                scanner.refresh()
                ControllerManager.shared.refresh()
            }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, onChange, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, onChange, context)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)

        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        refresh()
    }

    func refresh() {
        guard let manager else { return }
        let found = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []

        devices = found.compactMap { device in
            func string(_ key: String) -> String? {
                IOHIDDeviceGetProperty(device, key as CFString) as? String
            }
            func number(_ key: String) -> Int {
                (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
            }

            let vendor = number(kIOHIDVendorIDKey)
            let product = number(kIOHIDProductIDKey)
            let name = string(kIOHIDProductKey) ?? "Controller"

            let transport: Device.Transport
            switch (string(kIOHIDTransportKey) ?? "").lowercased() {
            case let t where t.contains("usb"): transport = .usb
            case let t where t.contains("bluetooth"): transport = .bluetooth
            default: transport = .other
            }

            return Device(name: name,
                          vendorID: vendor,
                          productID: product,
                          version: number(kIOHIDVersionNumberKey),
                          transport: transport,
                          locationID: number(kIOHIDLocationIDKey),
                          family: ControllerFamily.detect(vendorID: vendor, productID: product, name: name),
                          layout: HIDLayout(device: device))
        }
        .sorted { $0.name < $1.name }
    }
}

extension ControllerFamily {
    /// Identify by USB vendor and product ID first. Names are inconsistent — a
    /// PowerA pad for a Nintendo console does not say "Nintendo" anywhere in its
    /// product string — while vendor IDs are assigned and stable.
    static func detect(vendorID: Int, productID: Int, name: String) -> ControllerFamily {
        switch vendorID {
        case 0x054C:                       // Sony
            return productID == 0x0CE6 || productID == 0x0DF2 ? .dualsense : .dualshock4
        case 0x057E:                       // Nintendo
            return (productID == 0x2006 || productID == 0x2007) ? .joyConPair : .switchPro
        case 0x045E:                       // Microsoft
            return .xbox
        case 0x28DE:                       // Valve
            return .steam
        // Third-party makers licence for a specific console, so their pads follow
        // that console's button layout and glyphs even though the vendor differs.
        case 0x20D6, 0x0F0D, 0x0E6F, 0x2DC8, 0x1D79:   // PowerA, Hori, PDP, 8BitDo, Nyko
            let lower = name.lowercased()
            if lower.contains("switch") || lower.contains("nintendo") { return .switchPro }
            if lower.contains("xbox") { return .xbox }
            if lower.contains("ps5") || lower.contains("ps4") || lower.contains("playstation") {
                return .dualshock4
            }
            return .generic
        case 0x146B, 0x1532, 0x24C6, 0x0079, 0x2563:   // Nacon, Razer, PowerA/Xbox, generic
            return name.lowercased().contains("xbox") ? .xbox : .generic
        default:
            // Fall back to the name for anything unrecognised.
            return ControllerFamily.detect(vendor: name, productCategory: nil)
        }
    }
}


/// A controller's inputs as its own HID descriptor declares them.
///
/// Anvil used to assume one layout for every pad — buttons 1 to 13 in Nintendo
/// order, a hat, and the right stick on the third and fourth axes. That is true of
/// the PowerA pad it was verified on and false for a great many others: a DualSense
/// on the same path puts its right stick on Z and Rz and its triggers on Rx and Ry,
/// so the old mapping sent L2 to the right stick. Reading the descriptor is what lets
/// an unrecognised pad get a mapping that matches what it actually has.
struct HIDLayout: Codable, Hashable {
    /// Generic Desktop axis usages present (0x30 X … 0x35 Rz, sliders, dials), sorted.
    /// SDL's IOKit backend numbers axes in usage order, so an axis's position in
    /// this list is its SDL index.
    var axisUsages: [Int] = []
    var buttonCount: Int = 0
    var hatCount: Int = 0

    init() {}

    init(device: IOHIDDevice) {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil,
                                                             IOOptionBits(kIOHIDOptionsTypeNone))
                as? [IOHIDElement] else { return }
        var axes = Set<Int>(), buttons = Set<Int>(), hats = 0
        for element in elements {
            let type = IOHIDElementGetType(element)
            guard type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button
                    || type == kIOHIDElementTypeInput_Axis else { continue }
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            switch page {
            case kHIDPage_Button: buttons.insert(usage)
            case kHIDPage_GenericDesktop:
                switch usage {
                case 0x30...0x38: axes.insert(usage)        // X Y Z Rx Ry Rz Slider Dial Wheel
                case 0x39: hats += 1                         // hat switch
                default: break
                }
            default: break
            }
        }
        axisUsages = axes.sorted()
        buttonCount = buttons.count
        hatCount = hats
    }

    /// SDL's index for an axis usage, or nil if the pad has no such axis.
    func axisIndex(_ usage: Int) -> Int? { axisUsages.firstIndex(of: usage) }
}
