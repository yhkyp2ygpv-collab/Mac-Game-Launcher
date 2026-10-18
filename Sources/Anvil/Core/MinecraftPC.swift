import AppKit
import Foundation

/// Bedrock's PC version on this Mac, the genuine one: in Windows 11 for Arm in a VMware Fusion virtual machine (0.56).
///
/// Bedrock's PC version is a Microsoft Store app that arrives encrypted and licence-locked: it can't run under Wine without
/// breaking that protection (see Minecraft). In Windows it runs as it is — the Store, the player's own Microsoft account, the
/// Xbox sign-in, Realms and the Marketplace as on any PC, nothing for Microsoft to ban. On an M-series Mac that Windows has to
/// be a virtual machine with 3D graphics: Apple's own Virtualization framework gives a Windows guest none, so Minecraft
/// couldn't draw. VMware Fusion is free and gives Windows 11 for Arm Metal-accelerated DirectX 11 from 13.5, what Bedrock's
/// base renderer uses; the player chose it (17 October).
///
/// What's Fusion's: making the virtual machine. Windows 11 needs a TPM, which Fusion only adds to a machine it encrypts
/// itself, in its own new-machine assistant; adding one by hand to its settings file is, in Broadcom's words, experimental and
/// not recommended. What's the player's: installing Fusion and Windows, and signing in to Microsoft — Anvil never handles a
/// password. What Anvil does:
/// - finds the machine, and sets it for Minecraft while it's off (`tuning`): cores, memory, 3D graphics and its memory, full
///   screen, the controller plugged in to Windows as it starts, a folder shared with Windows;
/// - puts its setup in that folder (Resources/MinecraftPC): run once in Windows, it takes out Windows' consumer extras and
///   keeps everything Minecraft needs, sets Windows for games, installs Minecraft's own launcher from the Store and opens
///   Minecraft at sign-in — and says what it did, in the same folder, for this page;
/// - starts the machine straight into Minecraft, and puts it away (suspends it) after, so the next start resumes inside the
///   game in seconds instead of booting Windows.
@MainActor
final class MinecraftPC: ObservableObject {
    static let shared = MinecraftPC()

    enum State: Equatable {
        /// Fusion isn't on this Mac.
        case noFusion
        /// Fusion is, but no Windows virtual machine was found.
        case noMachine
        case off, suspended, running
    }

    struct Machine: Equatable, Identifiable {
        var id: String { vmx.path }
        var vmx: URL
        var name: String
        var guestOS: String
        var bundle: URL { vmx.deletingLastPathComponent() }
    }

    /// What the setup in Windows wrote back (status.json in the shared folder).
    struct SetupReport: Codable, Equatable {
        var version: Int?
        var finished: String?
        var undone: Bool?
        var windows: String?
        var arch: String?
        var removed: [String]?
        var launcher: String?
        var minecraft: String?
        var startsMinecraft: Bool?
        var graphics: [String]?
        var controllers: [String]?
        var problems: [String]?
    }

    @Published private(set) var fusionApp: URL?
    @Published private(set) var fusionVersion: String?
    @Published private(set) var machines: [Machine] = []
    @Published private(set) var machine: Machine?
    @Published private(set) var state: State = .noFusion
    @Published private(set) var tuned = false
    @Published private(set) var report: SetupReport?
    /// What's under way ("Starting…"), nil when nothing is.
    @Published private(set) var busy: String?
    @Published private(set) var message: String?
    @Published private(set) var problem: String?

    nonisolated static let fusionBundleID = "com.vmware.fusion"
    /// Broadcom's page for Fusion (free for personal use; their download asks for a Broadcom account).
    nonisolated static let fusionPage = URL(string: "https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion")!
    /// Microsoft's own download of Windows 11 for Arm, which runs on Apple silicon.
    nonisolated static let windowsArmPage = URL(string: "https://www.microsoft.com/software-download/windows11arm64")!
    /// Marks the settings Anvil has set, in the machine's settings file.
    nonisolated static let tunedKey = "anvil.minecraftTuned"
    nonisolated static let tuningVersion = 1
    private static let chosenKey = "minecraftPC.vmx"

    private init() { refresh() }

    // MARK: Where things are

    nonisolated static var support: URL { RuntimeManager.support.appendingPathComponent("MinecraftPC", isDirectory: true) }
    /// Shared with Windows as "Anvil": the setup, and what it reports back.
    nonisolated static var sharedFolder: URL { support.appendingPathComponent("Shared", isDirectory: true) }
    nonisolated static var reportURL: URL { sharedFolder.appendingPathComponent("status.json") }

    nonisolated static func findFusion() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: fusionBundleID) { return url }
        let standard = URL(fileURLWithPath: "/Applications/VMware Fusion.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: standard.path) ? standard : nil
    }

    nonisolated static func vmrun(in fusion: URL) -> URL { fusion.appendingPathComponent("Contents/Library/vmrun") }

    /// Where Fusion keeps its virtual machines: its own folder in the home folder (and the Documents one of older versions).
    nonisolated static func machineFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Virtual Machines.localized", "Virtual Machines", "Documents/Virtual Machines.localized", "Documents/Virtual Machines"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// The Windows virtual machines in `folders`: each .vmwarevm bundle's settings file, where it says the guest is Windows.
    nonisolated static func findMachines(in folders: [URL]) -> [Machine] {
        let fm = FileManager.default
        var found: [Machine] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for bundle in items where bundle.pathExtension == "vmwarevm" {
                guard let files = try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil),
                      let vmx = files.first(where: { $0.pathExtension == "vmx" }),
                      let text = try? String(contentsOf: vmx, encoding: .utf8) else { continue }
                let file = VMXFile(text: text)
                let guest = file["guestOS"] ?? ""
                guard guest.lowercased().contains("windows") else { continue }
                let name = file["displayName"] ?? bundle.deletingPathExtension().lastPathComponent
                if !found.contains(where: { $0.vmx.standardizedFileURL == vmx.standardizedFileURL }) {
                    found.append(Machine(vmx: vmx, name: name, guestOS: guest))
                }
            }
        }
        return found
    }

    /// A machine put away: Fusion keeps its suspended memory beside its settings, a .vmss file.
    nonisolated static func isSuspended(_ machine: Machine) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: machine.bundle.path)) ?? []
        return files.contains { $0.hasSuffix(".vmss") }
    }

    /// The machines `vmrun list` says are running: its first line a count, then one settings file a line.
    nonisolated static func running(fromList output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasSuffix(".vmx") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    // MARK: State

    func refresh() {
        fusionApp = Self.findFusion()
        fusionVersion = fusionApp.flatMap(Minecraft.version(of:))
        machines = fusionApp == nil ? [] : Self.findMachines(in: Self.machineFolders())
        let chosen = UserDefaults.standard.string(forKey: Self.chosenKey)
        machine = machines.first { $0.vmx.path == chosen } ?? (machines.count == 1 ? machines.first : nil)
        report = Self.readReport()
        if let machine, let text = try? String(contentsOf: machine.vmx, encoding: .utf8) {
            tuned = Int(VMXFile(text: text)[Self.tunedKey] ?? "") ?? 0 >= Self.tuningVersion
        } else {
            tuned = false
        }
        Self.placeSetup()
        updateState()
    }

    func choose(_ machine: Machine) {
        UserDefaults.standard.set(machine.vmx.path, forKey: Self.chosenKey)
        refresh()
    }

    private func updateState() {
        guard let fusion = fusionApp else { state = .noFusion; return }
        guard let machine else { state = .noMachine; return }
        let suspended = Self.isSuspended(machine)
        state = suspended ? .suspended : .off
        Task {
            let (status, out) = await Self.run(Self.vmrun(in: fusion), ["-T", "fusion", "list"], timeout: 15)
            guard status == 0 else { return }
            let isRunning = Self.running(fromList: out).contains(machine.vmx.standardizedFileURL.path)
            await MainActor.run {
                guard self.machine == machine else { return }
                self.state = isRunning ? .running : (Self.isSuspended(machine) ? .suspended : .off)
            }
        }
    }

    nonisolated static func readReport() -> SetupReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        // PowerShell writes UTF-8 with a byte-order mark.
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return try? JSONDecoder().decode(SetupReport.self, from: Data(body))
    }

    /// The setup into the shared folder, from the app's own copy each time — an update of Anvil updates it.
    nonisolated static func placeSetup() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("MinecraftPC", isDirectory: true) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        for name in ["Set up Minecraft.cmd", "anvil-minecraft-setup.ps1", "Read me.txt"] {
            let from = source.appendingPathComponent(name), to = sharedFolder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: from) else { continue }
            if (try? Data(contentsOf: to)) != data { try? data.write(to: to) }
        }
    }

    // MARK: Setting the machine for Minecraft

    struct Setting: Equatable { var key: String; var value: String; var label: String }

    /// What a Mac with `cores` and `memoryGB` sets: the share Minecraft can use under Windows' x64 emulation with macOS still
    /// smooth beside it, and the controller in `controller` (vendor, product) plugged in to Windows as it starts.
    nonisolated static func tuning(cores: Int, memoryGB: Int, shared: URL, controller: (vendor: Int, product: Int, name: String)?) -> [Setting] {
        let cpus = max(2, min(8, cores * 2 / 3))
        let memoryMB = max(4096, min(8192, memoryGB * 1024 / 3 / 1024 * 1024))
        let graphicsGB = memoryGB >= 24 ? 4 : (memoryGB >= 16 ? 2 : 1)
        var out = [
            Setting(key: "numvcpus", value: "\(cpus)", label: "\(cpus) processor cores"),
            Setting(key: "cpuid.coresPerSocket", value: "\(cpus)", label: ""),
            Setting(key: "memsize", value: "\(memoryMB)", label: "\(memoryMB / 1024) GB of memory"),
            Setting(key: "mks.enable3d", value: "TRUE", label: "3D graphics on (DirectX 11 through Metal)"),
            Setting(key: "svga.graphicsMemoryKB", value: "\(graphicsGB * 1024 * 1024)", label: "\(graphicsGB) GB of graphics memory"),
            Setting(key: "gui.viewModeAtPowerOn", value: "fullscreen", label: "full screen as it starts"),
            Setting(key: "gui.lastPoweredViewMode", value: "fullscreen", label: ""),
            Setting(key: "sound.present", value: "TRUE", label: "sound"),
            Setting(key: "isolation.tools.hgfs.disable", value: "FALSE", label: ""),
            Setting(key: "sharedFolder.maxNum", value: "1", label: ""),
            Setting(key: "sharedFolder0.present", value: "TRUE", label: "a folder shared with Windows as \"Anvil\", for the setup"),
            Setting(key: "sharedFolder0.enabled", value: "TRUE", label: ""),
            Setting(key: "sharedFolder0.readAccess", value: "TRUE", label: ""),
            Setting(key: "sharedFolder0.writeAccess", value: "TRUE", label: ""),
            Setting(key: "sharedFolder0.hostPath", value: shared.path, label: ""),
            Setting(key: "sharedFolder0.guestName", value: "Anvil", label: ""),
            Setting(key: "sharedFolder0.expiration", value: "never", label: ""),
        ]
        if let c = controller {
            // Broadcom's form for it, hex with 0x (KB 343950).
            out.append(Setting(key: "usb.present", value: "TRUE", label: ""))
            out.append(Setting(key: "usb_xhci.present", value: "TRUE", label: ""))
            out.append(Setting(key: "usb.autoConnect.device0", value: String(format: "0x%04x:0x%04x", c.vendor, c.product),
                               label: "\(c.name) plugged in to Windows as it starts"))
        }
        out.append(Setting(key: tunedKey, value: "\(tuningVersion)", label: ""))
        return out
    }

    /// The controller to give Windows: the first pad on this Mac, wired or Bluetooth (USB is what Fusion passes through).
    private func controllerForWindows() -> (vendor: Int, product: Int, name: String)? {
        let pads = HIDControllerScanner.shared.devices
        guard let pad = pads.first(where: { $0.transport == .usb }) ?? pads.first else { return nil }
        return (pad.vendorID, pad.productID, pad.name)
    }

    /// The machine set for Minecraft — only while it's off and Fusion is closed, so neither writes its settings back over
    /// these. A copy of its settings as they were is kept beside them first.
    func tune() {
        problem = nil; message = nil
        guard let machine else { problem = "Choose the Windows virtual machine first."; return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.fusionBundleID).contains(where: { !$0.isTerminated }) {
            problem = "Quit VMware Fusion first — while it's open it can write the machine's settings back over Anvil's."
            return
        }
        guard state == .off else {
            problem = state == .suspended
                ? "Shut Windows down first (Start › Power › Shut down): a suspended machine's settings can't be changed."
                : "Shut Windows down first: a running machine's settings can't be changed."
            return
        }
        guard let text = try? String(contentsOf: machine.vmx, encoding: .utf8) else {
            problem = "The machine's settings file couldn't be read."
            return
        }
        let device = DeviceProfile.current
        let cores = device.map { $0.performanceCores + $0.efficiencyCores } ?? ProcessInfo.processInfo.activeProcessorCount
        let memoryGB = device?.memoryGB ?? Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        Self.placeSetup()
        let settings = Self.tuning(cores: cores, memoryGB: memoryGB, shared: Self.sharedFolder, controller: controllerForWindows())
        var file = VMXFile(text: text)
        for s in settings { file[s.key] = s.value }
        let backup = machine.vmx.appendingPathExtension("before-anvil")
        do {
            if !FileManager.default.fileExists(atPath: backup.path) { try Data(text.utf8).write(to: backup) }
            try Data(file.text.utf8).write(to: machine.vmx)
        } catch {
            problem = "The machine's settings couldn't be written: \(error.localizedDescription)"
            return
        }
        let said = settings.map(\.label).filter { !$0.isEmpty }
        message = "Set for Minecraft: " + said.joined(separator: ", ") + "."
        AnvilLog.write("minecraft pc: \(machine.name) set for Minecraft — \(said.joined(separator: ", ")) (its settings as they were: \(backup.lastPathComponent))")
        refresh()
    }

    /// Fusion quit, for tuning; it asks about anything still running itself.
    func quitFusion() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.fusionBundleID) { app.terminate() }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); refresh() }
    }

    // MARK: Playing

    /// Start the machine, or resume it, in Fusion's window, full screen: Windows opens Minecraft as it signs in, and a machine
    /// put away resumes where it was, inside the game.
    func play() {
        guard let fusion = fusionApp, let machine else { return }
        problem = nil; message = nil
        busy = state == .suspended ? "Resuming Windows…" : "Starting Windows…"
        AnvilLog.write("minecraft pc: \(state == .suspended ? "resuming" : "starting") \(machine.name)")
        Task {
            let (status, out) = await Self.run(Self.vmrun(in: fusion), ["-T", "fusion", "start", machine.vmx.path, "gui"], timeout: 180)
            await MainActor.run {
                self.busy = nil
                if status != 0 {
                    // An encrypted machine (Windows 11's TPM needs it) can be one vmrun won't start without its password,
                    // which is Fusion's to keep: then Fusion opens it itself.
                    let why = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    AnvilLog.write("minecraft pc: vmrun didn't start it (\(status)) — \(why); opening it in Fusion")
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([machine.bundle], withApplicationAt: fusion, configuration: config) { _, error in
                        guard let error else { return }
                        Task { @MainActor in
                            self.problem = "Fusion didn't start the machine" + (why.isEmpty ? "" : " (\(why))") + ": \(error.localizedDescription)"
                        }
                    }
                    self.message = "Opened in Fusion — press its Play button if Windows doesn't start by itself."
                }
                self.refresh()
            }
        }
    }

    /// Put the machine away: suspended, Windows and Minecraft as they are, its memory given back to the Mac.
    func putAway() {
        guard let fusion = fusionApp, let machine else { return }
        problem = nil; message = nil
        busy = "Putting Windows away…"
        AnvilLog.write("minecraft pc: suspending \(machine.name)")
        Task {
            let (status, out) = await Self.run(Self.vmrun(in: fusion), ["-T", "fusion", "suspend", machine.vmx.path], timeout: 180)
            await MainActor.run {
                self.busy = nil
                if status != 0 {
                    let why = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.problem = "Fusion didn't suspend the machine" + (why.isEmpty ? "." : ": \(why)")
                } else {
                    self.message = "Put away — the next Play resumes inside Minecraft."
                }
                self.refresh()
            }
        }
    }

    func openFusion() {
        guard let fusion = fusionApp else { NSWorkspace.shared.open(Self.fusionPage); return }
        NSWorkspace.shared.openApplication(at: fusion, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealSharedFolder() {
        Self.placeSetup()
        NSWorkspace.shared.activateFileViewerSelecting([Self.sharedFolder.appendingPathComponent("Set up Minecraft.cmd")])
    }

    /// `tool` with `args`, its output and exit status (-1 when it didn't finish in `timeout` seconds).
    nonisolated static func run(_ tool: URL, _ args: [String], timeout: TimeInterval) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = tool
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (Int32(-2), error.localizedDescription) }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            if p.isRunning { p.terminate(); return (Int32(-1), "took longer than \(Int(timeout)) s") }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus, out)
        }.value
    }
}

/// A VMware settings file (.vmx): `key = "value"` lines, keys in any case, everything else kept as it is.
struct VMXFile {
    private(set) var lines: [String]

    init(text: String) {
        lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    private static func parse(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return key.isEmpty ? nil : (key, value)
    }

    private func index(of key: String) -> Int? {
        lines.firstIndex { Self.parse($0)?.key.lowercased() == key.lowercased() }
    }

    subscript(key: String) -> String? {
        get { index(of: key).flatMap { Self.parse(lines[$0])?.value } }
        set {
            if let i = index(of: key) {
                if let newValue {
                    let existing = Self.parse(lines[i])?.key ?? key
                    lines[i] = "\(existing) = \"\(newValue)\""
                } else {
                    lines.remove(at: i)
                }
            } else if let newValue {
                lines.append("\(key) = \"\(newValue)\"")
            }
        }
    }
}
